/// Full-loop deterministic tests for the mcp my.actor migration: one
/// no-thread test drives the WHOLE loop end-to-end inside one process
/// (configure -> stdin -> response written to the fake transport -> eof ->
/// exit cell), a second drives the shutdown stop path. Bare ActorShells +
/// manual process(Clock) pumps + a scripted fake Transport implementing the
/// current Transport interface - no threads, no real stdio (the
/// mylib-established no-thread test pattern).
///
/// Distinguishes itself from actor_tests.d (one actor in isolation): here the
/// StdioReaderActor and the McpServerActor run together on separate bare
/// shells sharing one scripted transport, so a scripted frame travels the
/// production path: reader pollTick -> readMessage -> dynSend stdin ->
/// server.stdin -> handleMessage -> transport.writeMessage.
module llm.mcp_server.loop_tests;

import logger = std.logger;

import std.datetime : Clock, SysTime, dur;

import llm.config : LlmConfig, ToolFilter;
import llm.mcp_server;
import llm.mcp_server.transport : EOFException, Transport;
import my.actor.channel : Channel;
import my.actor.msg : capture;
import my.actor.system : ActorShell, makeAddress;
import my.gc.refc : refCounted;

/// Scripted fake Transport for the full-loop tests: the reader reads from
/// `incoming` and the server writes into `written` - both sides of the loop
/// run against this one instance (production uses two transport instances,
/// one per actor; sharing one here is what makes the loop observable).
///
/// Unlike the production StdioTransport, whose closed() ALSO becomes true on
/// reader-side EOF / fd error (_tryRead sets _closed), this fake's closedFlag
/// is set only by close() - the reader-side EOFException-from-readMessage
/// path is simulated in actor_tests.d (FakeReaderTransport.throwOnRead), not
/// here. If a future reader change branches on closed() after an EOF, update
/// this fake first.
private class FakeLoopTransport : Transport {
    string[] incoming; // scripted server-bound frames, consumed in order
    string[] written; // responses the server actor wrote back
    bool closedFlag;
    int closeCount;

    string readMessage() {
        auto message = incoming[0];
        incoming = incoming[1 .. $];
        return message;
    }

    void writeMessage(string jsonMessage) {
        written ~= jsonMessage;
    }

    void close() {
        closeCount++;
        closedFlag = true;
    }

    bool closed() {
        return closedFlag;
    }

    bool hasData() {
        return incoming.length > 0;
    }
}

/// Wires the full loop on bare shells: the server actor (owning the shared
/// fake transport and the exit cell) plus the reader actor forwarding into
/// it. No threads - the mylib no-thread test pattern.
private void wireLoop(ref ActorShell serverShell, out McpServerActor server, ref ActorShell readerShell,
        out StdioReaderActor reader, FakeLoopTransport transport, ExitCell exitState) {
    import my.actor.registration : implActor;

    serverShell = ActorShell(makeAddress);
    server = new McpServerActor(transport, exitState);
    implActor(server, &serverShell);

    readerShell = ActorShell(makeAddress);
    reader = new StdioReaderActor(serverShell.address, transport);
    implActor(reader, &readerShell);
}

/// One manual pump round over all three shells (server first, then client,
/// then reader): a frame the reader forwards via dynSend in round N is
/// dispatched by the server in round N + 1 - pump every shell or forwarded
/// messages sit undispatched in the peer mailbox.
private void pumpLoop(ref ActorShell serverShell, ref ActorShell clientShell,
        ref ActorShell readerShell, SysTime t) {
    serverShell.process(t);
    clientShell.process(t);
    readerShell.process(t);
}

/// Shared setup for the two loop tests below (the wireLoop /
/// pumpLoop helper style): runs the onSpawn launch hooks, drives one
/// configure request/reply through the typed Channel, and pumps until the
/// ready reply lands. The shells, the chan and the actors come in from the
/// caller (bare shells are passed by ref - no copies).
private ReadyReply configureAndWait(ref ActorShell serverShell,
        ref ActorShell clientShell, ref ActorShell readerShell, ref Channel!McpServerActor chan) {
    import std.typecons : Tuple;

    auto t0 = Clock.currTime();
    serverShell.process(t0); // runs onSpawn
    readerShell.process(t0); // arms the first pollTick at ~t0 + 10 ms

    ReadyReply got;
    static void onReady(ref Tuple!(ReadyReply*) ctx, ReadyReply r) {
        *ctx[0] = r;
    }

    // Minimal config the test world needs (LlmConfig.init, no readConfig
    // call - this removes the tests' read of real machine config, F2/F3).
    chan.configure(ToolFilter(), LlmConfig.init).capture(&got).then(&onReady);
    foreach (_; 0 .. 8)
        pumpLoop(serverShell, clientShell, readerShell, Clock.currTime());
    assert(got.ok, "configure succeeded: " ~ got.errMsg);
    return got;
}

@("Full loop: configure -> reader-forwarded stdin -> response written -> "
        ~ "eof -> exit cell 1, transport closed - all on bare shells, no threads")
unittest {
    import std.algorithm : canFind;

    auto transport = new FakeLoopTransport;
    auto exitState = refCounted(0);

    ActorShell serverShell;
    McpServerActor server;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireLoop(serverShell, server, readerShell, reader, transport, exitState);

    auto clientShell = ActorShell(makeAddress);
    auto chan = Channel!McpServerActor(serverShell.address, &clientShell);
    configureAndWait(serverShell, clientShell, readerShell, chan);
    assert(exitState.get == 0, "still running after a successful configure");

    // The full loop: one scripted frame via the READER path (production
    // stdin plumbing, not a direct chan.stdin call). The configure-phase
    // pumps ran at real Clock.currTime() times, so the reader's delayed
    // pollTick arms track real fire time + 10 ms - the tick chain lives at
    // real-now offsets, not t0 offsets. Anchored at a fresh currTime()
    // reading (now1): the pending arm after the configure phase is at most
    // ~10 ms past now1, so round 1 at now1 + 15 ms fires tick 1 however long
    // configure took; the 25 ms round spacing (8-round cap) outruns the
    // 10 ms re-arm cadence (TickInterval, private enum in package.d) - every
    // round fires its tick, and the same round's server step (running before
    // the reader step) dispatches the forwarded frame one round after it
    // lands. Only the TickInterval magnitude is assumed - a changed interval
    // shifts which round dispatches, never whether one does.
    transport.incoming ~= `{"jsonrpc":"2.0","id":1,"method":"ping"}`;
    auto now1 = Clock.currTime();
    foreach (k; 0 .. 8) {
        pumpLoop(serverShell, clientShell, readerShell, now1 + (15 + 25 * k).dur!"msecs");
        if (transport.written.length == 1)
            break;
    }
    assert(transport.written.length == 1, "exactly one response written for the scripted frame");
    assert(canFind(transport.written[0], `"id":1`),
            "the response answers the scripted frame: " ~ transport.written[0]);
    // The response CONTENT is MCP-protocol semantics (protocol.d), not loop
    // plumbing: without an MCP `initialize` handshake first, handleRequest
    // answers the pre-init "Server not initialized" error - the actor loop
    // forwards and writes it exactly the same way (actor_tests.d asserts only
    // the one-response count for the same reason).

    // eof stop path: cell 1, transport closed, self-exit (further sends are
    // structural no-ops on the dead shell, so the still-ticking reader is
    // harmless). The stop-path assertions travel through the channel to the
    // server and never depend on the reader ticking.
    chan.eof();
    foreach (_; 0 .. 8)
        pumpLoop(serverShell, clientShell, readerShell, Clock.currTime());
    assert(exitState.get == 1, "stopped ok: no handler errors seen");
    assert(transport.closeCount == 1, "transport closed exactly once");
    assert(transport.closed());
}

@("Full loop shutdown path: configure then shutdown -> exit cell 1, "
        ~ "transport closed - bare shells, no threads")
unittest {
    auto transport = new FakeLoopTransport;
    auto exitState = refCounted(0);

    ActorShell serverShell;
    McpServerActor server;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireLoop(serverShell, server, readerShell, reader, transport, exitState);

    auto clientShell = ActorShell(makeAddress);
    auto chan = Channel!McpServerActor(serverShell.address, &clientShell);
    configureAndWait(serverShell, clientShell, readerShell, chan);

    // Graceful shutdown through the typed channel: the actor stops (exit cell
    // 1) and closes the transport; the reader keeps ticking into the dead
    // server (structural no-ops) and outlives the test harmlessly.
    chan.shutdown();
    foreach (_; 0 .. 8)
        pumpLoop(serverShell, clientShell, readerShell, Clock.currTime());
    assert(exitState.get == 1, "stopped ok: no handler errors seen");
    assert(transport.closeCount == 1, "transport closed exactly once");
    assert(transport.closed());
}
