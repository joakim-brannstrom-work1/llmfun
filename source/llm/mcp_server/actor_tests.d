/// Unit tests for the McpServerActor message surface (configure/stdin/eof/
/// shutdown). Relocated from llm/mcp_server/package.d: unittest blocks in a
/// package.d module compile and link but are never discovered by the
/// `dub test` runner (dub's generated dub_test_root registers no package.d
/// modules), so these assertions never executed there.
module llm.mcp_server.actor_tests;

import logger = std.logger;

import llm.config : LlmConfig, ToolFilter;
import llm.mcp_server;
import llm.mcp_server.transport : EOFException, Transport;
import my.actor.system : ActorShell, makeAddress;
import my.gc.refc : refCounted;

/// Scripted fake Transport for the no-thread unit tests below (the mylib
/// test pattern). The server actor only calls writeMessage() and close().
private class FakeTransport : Transport {
    string[] written;
    int closeCount;
    bool throwOnWrite; // writeMessage() throws a plain Exception (a
    // fatal stdin-dispatch error is a stop path, not catch-and-continue)

    string readMessage() {
        return "";
    }

    void writeMessage(string jsonMessage) {
        if (throwOnWrite)
            throw new Exception("simulated stdout write failure");
        written ~= jsonMessage;
    }

    void close() {
        closeCount++;
    }

    bool closed() {
        return closeCount > 0;
    }

    bool hasData() {
        return false;
    }
}

/// Drives one configure request/reply through a typed Channel against an
/// ActorShell-wrapped McpServerActor - the mylib no-thread test pattern (bare
/// shells + manual process(Clock.currTime) pumps, no threads).
private ReadyReply pumpConfigure(Transport transport, ToolFilter filter, LlmConfig llmConf) {
    import my.actor.channel : Channel;
    import my.actor.registration : implActor;
    import my.actor.system : ActorShell, makeAddress;
    import std.datetime : Clock;
    import std.typecons : Tuple;

    auto serverShell = ActorShell(makeAddress);
    auto server = new McpServerActor(transport, refCounted(0));
    implActor(server, &serverShell);
    serverShell.process(Clock.currTime); // runs onSpawn

    auto clientShell = ActorShell(makeAddress);
    ReadyReply got;

    auto chan = Channel!McpServerActor(serverShell.address, &clientShell);
    chan.configure(filter, llmConf).then((ReadyReply r) { got = r; });

    foreach (_; 0 .. 8) {
        serverShell.process(Clock.currTime);
        clientShell.process(Clock.currTime);
    }
    return got;
}

@("McpServerActor.configure builds the world and replies ReadyReply(true)")
unittest {
    import std.datetime : Clock;
    import std.typecons : Tuple;

    import my.actor.channel : Channel;
    import my.actor.registration : implActor;
    import my.actor.system : ActorShell, makeAddress;

    // Minimal config the test world needs (LlmConfig.init, no readConfig
    // call - the tests never read the real machine config, F2/F3).
    auto transport = new FakeTransport;
    auto exitState = refCounted(0);
    auto serverShell = ActorShell(makeAddress);
    auto server = new McpServerActor(transport, exitState);
    implActor(server, &serverShell);
    serverShell.process(Clock.currTime); // runs onSpawn

    auto clientShell = ActorShell(makeAddress);
    ReadyReply got;

    auto chan = Channel!McpServerActor(serverShell.address, &clientShell);
    chan.configure(ToolFilter(), LlmConfig.init).then((ReadyReply r) { got = r; });

    foreach (_; 0 .. 8) {
        serverShell.process(Clock.currTime);
        clientShell.process(Clock.currTime);
    }

    assert(got.ok, "configure succeeded: " ~ got.errMsg);
    assert(exitState.get == 0, "still running after a successful configure");

    // The MCPServer instance is really wired up: stdin dispatches into
    // handleMessage and the response is written to the transport.
    chan.stdin(`{"jsonrpc":"2.0","id":1,"method":"ping"}`);
    foreach (_; 0 .. 4)
        serverShell.process(Clock.currTime);
    assert(transport.written.length == 1, "one response written for stdin");
}

@("McpServerActor.configure with an invalid tool filter replies ReadyReply(false) and logs")
unittest {
    import std.array : empty;

    auto transport = new FakeTransport;

    // configure() receives a pre-built LlmConfig (F2/F3: the actor reads no
    // config file), so the remaining failure input is the filter: an invalid
    // include regex makes `filter.to` throw while the MCPServer is
    // constructed - the handler converts it into a ReadyReply(false, msg); no
    // throw escapes the handler.
    auto got = pumpConfigure(transport, ToolFilter(["("], []), LlmConfig.init);

    assert(!got.ok);
    assert(!got.errMsg.empty, "the configure failure is reported: " ~ got.errMsg);
}

@("McpServerActor.eof and shutdown are idempotent stop paths that set the exit cell")
unittest {
    import std.datetime : Clock;

    import my.actor.channel : Channel;
    import my.actor.registration : implActor;
    import my.actor.system : ActorShell, makeAddress;

    auto transport = new FakeTransport;
    auto exitState = refCounted(0);
    auto serverShell = ActorShell(makeAddress);
    auto server = new McpServerActor(transport, exitState);
    implActor(server, &serverShell);
    serverShell.process(Clock.currTime); // runs onSpawn

    // eof/shutdown are one-shot fire-and-forget messages, so a send-only
    // channel (null self) is enough.
    auto chan = Channel!McpServerActor(serverShell.address, null);

    // A frame arriving before a successful configure is dropped (null server
    // guard) instead of dereferencing server_ - the default exception handler
    // would force-kill the actor without the exit-cell cleanup.
    chan.stdin(`{"jsonrpc":"2.0","id":1,"method":"ping"}`);
    foreach (_; 0 .. 4)
        serverShell.process(Clock.currTime);
    assert(transport.written.length == 0, "frames before configure are dropped");

    // Both stop paths, each state-guarded: the duplicate sends are
    // no-ops - shutdown;shutdown and eof;eof exercise the stopping_ guard on
    // a live actor, and eof-after-shutdown the log-parity guard (each info
    // line fires once, on the first caller).
    chan.shutdown();
    chan.shutdown();
    chan.eof();
    chan.eof();
    foreach (_; 0 .. 8)
        serverShell.process(Clock.currTime);

    assert(exitState.get == 1, "stopped ok: no handler errors seen");
    // The actor self-exited via sendExit (default exit handler): the follow-up
    // one-shot sends below are structural no-ops (closeCount stays 1), which
    // only holds for a dead shell - isAlive/isAccepting are package(my.actor)
    // and not observable from here.
    assert(transport.closeCount == 1, "transport closed exactly once");
    assert(transport.closed());

    // Sends to the self-exited actor are structural no-ops: nothing changes.
    chan.shutdown();
    chan.eof();
    foreach (_; 0 .. 8)
        serverShell.process(Clock.currTime);
    assert(exitState.get == 1);
    assert(transport.closeCount == 1);
}

/// Spy server actor for the reader tests below: records the stdin frames and
/// eof calls the reader forwards (the reader dynSends to its weak address).
private class SpyServerActor {
    string[] frames;
    int eofCount;

    void stdin(string message) {
        frames ~= message;
    }

    void eof() {
        eofCount++;
    }
}

/// Scripted fake Transport for the reader tests (the mylib no-thread pattern).
/// The reader only calls hasData()/closed()/readMessage() - writeMessage() and
/// close() are never called (the reader neither writes nor closes: the server
/// actor owns the response/write side and its own transport instance).
private class FakeReaderTransport : Transport {
    string[] incoming; // scripted frames, consumed in order
    bool throwOnRead; // readMessage() throws EOFException (EOF simulation)
    bool throwOther; // readMessage() throws a plain Exception once (a
    // non-EOF error must be logged-and-skipped, not fatal)
    bool closedFlag; // writer-side close simulation
    int hasDataCalls; // ~one per tick: the no-re-arm observability

    string readMessage() {
        if (throwOnRead)
            throw new EOFException;
        if (throwOther) {
            throwOther = false; // one-shot: the NEXT tick forwards the frame
            throw new Exception("simulated non-EOF transport failure");
        }
        assert(incoming.length, "script a frame or set throwOnRead");
        auto message = incoming[0];
        incoming = incoming[1 .. $];
        return message;
    }

    void writeMessage(string jsonMessage) {
        assert(false, "the reader never writes to the transport");
    }

    void close() {
        assert(false, "the reader never closes its transport");
    }

    bool closed() {
        return closedFlag;
    }

    bool hasData() {
        hasDataCalls++;
        return !closedFlag && (throwOnRead || throwOther || incoming.length > 0);
    }
}

/// Wires a StdioReaderActor + SpyServerActor pair on bare ActorShells (the
/// mylib no-thread test pattern) with the scripted transport.
private void wireReader(ref ActorShell spyShell, out SpyServerActor spy,
        ref ActorShell readerShell, out StdioReaderActor reader, FakeReaderTransport transport) {
    import my.actor.registration : implActor;

    spyShell = ActorShell(makeAddress);
    spy = new SpyServerActor;
    implActor(spy, &spyShell);
    readerShell = ActorShell(makeAddress);
    reader = new StdioReaderActor(spyShell.address, transport);
    implActor(reader, &readerShell);
}

@("StdioReaderActor forwards one scripted frame per tick and re-arms at +10 ms")
unittest {
    import std.datetime : Clock, dur;

    auto transport = new FakeReaderTransport;
    transport.incoming = [
        `{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}`,
        `{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\"}`
    ];

    ActorShell spyShell;
    SpyServerActor spy;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireReader(spyShell, spy, readerShell, reader, transport);

    auto t0 = Clock.currTime();
    readerShell.process(t0); // onSpawn: arms the first pollTick at +10 ms
    spyShell.process(t0); // pumps the spy mailbox (empty here)

    // The first tick is delayed (+10 ms from the onSpawn arm): not yet due
    // at +5 ms.
    readerShell.process(t0 + 5.dur!"msecs");
    spyShell.process(t0 + 5.dur!"msecs");
    assert(spy.frames.length == 0, "no tick before the first delayed arm is due");

    // Tick 1 (due at ~+10 ms): exactly one frame forwarded, one re-arm.
    readerShell.process(t0 + 15.dur!"msecs");
    spyShell.process(t0 + 15.dur!"msecs"); // dispatches the forwarded frame
    assert(spy.frames.length == 1, "exactly one frame forwarded per tick");
    assert(spy.frames[0] == `{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}`,
            "the first scripted frame is forwarded verbatim");
    assert(transport.incoming.length == 1, "one frame consumed per tick");

    // Tick 2: the re-arm landed at fire1 + 10 ms = t0 + 25 ms - the +10 ms
    // re-arm cadence, observed via the pending timestamp (this pump fires it
    // exactly at its trigger time).
    readerShell.process(t0 + 25.dur!"msecs");
    spyShell.process(t0 + 25.dur!"msecs");
    assert(spy.frames.length == 2, "frame 2 forwarded on the re-armed tick");
    assert(spy.eofCount == 0, "no eof on the happy path");
}

@("StdioReaderActor: closed() (a writer-side close, whose atomic _closed "
        ~ "update makes it observable) is eof-equivalent - forwards eof and self-exits "
        ~ "without re-arm")
unittest {
    import std.datetime : Clock, dur;

    auto transport = new FakeReaderTransport;
    transport.closedFlag = true;

    ActorShell spyShell;
    SpyServerActor spy;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireReader(spyShell, spy, readerShell, reader, transport);

    auto t0 = Clock.currTime();
    readerShell.process(t0); // onSpawn: arms the first pollTick
    spyShell.process(t0);
    readerShell.process(t0 + 15.dur!"msecs"); // the tick: closed() -> eof
    spyShell.process(t0 + 15.dur!"msecs"); // dispatches the forwarded eof
    assert(spy.eofCount == 1, "eof forwarded to the server");
    assert(spy.frames.length == 0, "no frames on the eof path");

    // No re-arm after the eof path - the actor self-exited (the mylib exit
    // handler; isAlive/isAccepting are package(my.actor) and not observable
    // from here, so the death is asserted via the effects: the frozen
    // hasDataCalls count and exactly one eof).
    auto hasDataCalls = transport.hasDataCalls;
    readerShell.process(t0 + 100.dur!"msecs");
    assert(transport.hasDataCalls == hasDataCalls, "no re-arm after the eof path");
    assert(spy.eofCount == 1, "still exactly one eof");
}

@("StdioReaderActor: an EOFException from readMessage is treated exactly "
        ~ "like the closed() case - eof, self-exit, no re-arm")
unittest {
    import std.datetime : Clock, dur;

    auto transport = new FakeReaderTransport;
    transport.throwOnRead = true;

    ActorShell spyShell;
    SpyServerActor spy;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireReader(spyShell, spy, readerShell, reader, transport);

    auto t0 = Clock.currTime();
    readerShell.process(t0); // onSpawn: arms the first pollTick
    spyShell.process(t0);

    // Tick 1: hasData() true (throwOnRead) -> readMessage() throws -> the eof
    // path.
    readerShell.process(t0 + 15.dur!"msecs");
    spyShell.process(t0 + 15.dur!"msecs"); // dispatches the forwarded eof
    assert(spy.eofCount == 1, "eof forwarded to the server");
    assert(transport.hasDataCalls == 1, "exactly one tick ran");

    // No re-arm after the EOF path (same effect assertion as above).
    readerShell.process(t0 + 100.dur!"msecs");
    assert(transport.hasDataCalls == 1, "no re-arm after the EOF path");
    assert(spy.eofCount == 1, "still exactly one eof");
}

@("StdioReaderActor: a non-EOF exception from a tick is logged and skipped - "
        ~ "the actor survives and keeps ticking (the old catch-and-continue parity)")
unittest {
    import std.datetime : Clock, dur;

    auto transport = new FakeReaderTransport;
    transport.throwOther = true; // tick 1 fails with a plain Exception
    transport.incoming = ["frame1"];

    ActorShell spyShell;
    SpyServerActor spy;
    ActorShell readerShell;
    StdioReaderActor reader;
    wireReader(spyShell, spy, readerShell, reader, transport);

    auto t0 = Clock.currTime();
    readerShell.process(t0); // onSpawn: arms the first pollTick
    spyShell.process(t0);

    // Tick 1: hasData() true (throwOther) -> readMessage() throws a non-EOF
    // Exception -> routed to onException, which logs, skips and re-arms.
    readerShell.process(t0 + 15.dur!"msecs");
    spyShell.process(t0 + 15.dur!"msecs");
    assert(spy.frames.length == 0, "the failing tick forwards nothing");

    // The onException re-arm scheduled the next tick: the actor is not dead
    // (this is what keeps the tick chain alive across a failed tick).
    readerShell.process(t0 + 25.dur!"msecs");
    spyShell.process(t0 + 25.dur!"msecs");
    assert(spy.frames.length == 1, "the actor keeps ticking after a failed tick");
    assert(spy.frames[0] == "frame1", "the next tick forwards the frame");
}

@("McpServerActor: a throwing stdin dispatch is a fatal stop path - exit cell 2, "
        ~ "transport closed, self-exit")
unittest {
    import std.datetime : Clock;
    import std.typecons : Tuple;

    import my.actor.channel : Channel;
    import my.actor.registration : implActor;
    import my.actor.system : ActorShell, makeAddress;

    // The dispatch itself succeeds (handleMessage returns a response), but
    // writing the response throws - the exception escapes the stdin handler
    // body and must hit the fatal wrap.
    auto transport = new FakeTransport;
    transport.throwOnWrite = true;
    auto exitState = refCounted(0);
    auto serverShell = ActorShell(makeAddress);
    auto server = new McpServerActor(transport, exitState);
    implActor(server, &serverShell);
    serverShell.process(Clock.currTime); // runs onSpawn

    // A successful configure opens the null server guard: without it the
    // fatal path is unreachable (frames before configure are dropped).
    LlmConfig llmConf;

    ReadyReply got;

    auto clientShell = ActorShell(makeAddress);
    auto chan = Channel!McpServerActor(serverShell.address, &clientShell);
    chan.configure(ToolFilter(), llmConf).then((ReadyReply r) { got = r; });
    foreach (_; 0 .. 8) {
        serverShell.process(Clock.currTime);
        clientShell.process(Clock.currTime);
    }
    assert(got.ok, "configure succeeded: " ~ got.errMsg);

    // The fatal path: the response write throws -> the wrap logs via the
    // existing drain-loop convention and stops with the error cell; the actor
    // self-exits (default exit handler), so main's pump loop observes cell 2
    // and converges instead of waiting out the 30 s deadline (the deadline
    // reactions are covered by the llm.app_mcp pumpAction tests).
    chan.stdin(`{"jsonrpc":"2.0","id":2,"method":"ping"}`);
    foreach (_; 0 .. 4)
        serverShell.process(Clock.currTime);

    assert(exitState.get == 2, "stopped with error: exit cell 2");
    assert(transport.closeCount == 1, "transport closed on the fatal path");
    assert(transport.written.length == 0, "the response write failed");

    // Sends to the self-exited actor are structural no-ops: the fatal
    // stop path is state-guarded like eof/shutdown, so a follow-up batch
    // changes nothing.
    chan.shutdown();
    chan.eof();
    foreach (_; 0 .. 8)
        serverShell.process(Clock.currTime);
    assert(exitState.get == 2);
    assert(transport.closeCount == 1);
}

@("McpServerActor: eof alone is a clean stop path - exit cell 1, transport "
        ~ "closed, and shutdown() after the self-exit is a no-op")
unittest {
    import std.datetime : Clock;

    import my.actor.channel : Channel;
    import my.actor.registration : implActor;
    import my.actor.system : ActorShell, makeAddress;

    auto transport = new FakeTransport;
    auto exitState = refCounted(0);
    auto serverShell = ActorShell(makeAddress);
    auto server = new McpServerActor(transport, exitState);
    implActor(server, &serverShell);
    serverShell.process(Clock.currTime); // runs onSpawn

    // eof/shutdown are one-shot fire-and-forget messages: a send-only channel
    // (null self) is enough.
    auto chan = Channel!McpServerActor(serverShell.address, null);

    chan.eof();
    foreach (_; 0 .. 8)
        serverShell.process(Clock.currTime);

    assert(exitState.get == 1, "stopped ok: no handler errors seen");
    assert(transport.closeCount == 1, "transport closed exactly once");
    assert(transport.closed());

    // shutdown() to the already self-exited actor is a structural no-op (the
    // post-self-exit case; the same-message duplicates are covered by the
    // idempotence test above): the cell and the close count stay put.
    chan.shutdown();
    foreach (_; 0 .. 8)
        serverShell.process(Clock.currTime);
    assert(exitState.get == 1);
    assert(transport.closeCount == 1);
}
