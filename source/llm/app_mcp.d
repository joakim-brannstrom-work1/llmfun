/// CLI entry point for the 'mcp' subcommand -- runs the MCP server over stdio.
///
/// Actor model: the main thread creates one my.actor System and spawns the
/// MCP server actor (McpServerActor) on the shared pool. It drives the server
/// from a manually pumped ActorShell client kernel: the configure request goes
/// out through a typed Channel!McpServerActor and the reply is awaited before
/// the pump loop starts by pumping client.process(Clock.currTime()); a failed
/// startup (or a 30 s timeout) exits before the loop is entered. The server
/// actor and the StdioReaderActor (see llm.mcp_server) each make their own
/// StdioTransport in their onSpawn launch hooks; the reader forwards complete
/// stdin frames to the server actor.
/// There is no shared mutable state; the only cross-thread value is the exit
/// cell (a my.gc.refc RefCounted!int) which the server actor writes on its
/// stop path and the main thread polls. Termination signals (SIGINT/SIGTERM)
/// are blocked in all threads and consumed by the main thread itself with
/// sigtimedwait, which turns them into shutdown requests.
module llm.app_mcp;

import logger = std.logger;
import std.datetime : Clock, dur;
import std.datetime.systime : SysTime;
import std.exception : collectException;
import std.typecons : Tuple;

import core.sys.posix.signal : SIG_BLOCK, SIGINT, SIGTERM, pthread_sigmask,
    sigaddset, sigemptyset, sigset_t, sigtimedwait;
import core.sys.posix.time : timespec;
import core.thread : Thread;

import my.actor.channel : Channel;
import my.actor.msg : capture;
import my.actor.system : ActorShell, ErrorMsg, makeAddress, makeSystem, timeout;

import my.path : Path;

import llm.app_config : UserConfig;
import llm.config : LlmConfig, readConfig;
import llm.mcp_server.transport : StdioTransport, Transport;
import llm.mcp_server : McpConfigData, McpServerActor, ReadyReply, StdioReaderActor;

int appMain(UserConfig uconf, UserConfig.Mcp conf) {
    import colorlog;
    import llm.subsystem : initLlmfunLocalModel, deinitLlmfunLocalModel;

    initLlmfunLocalModel();
    scope (exit)
        deinitLlmfunLocalModel();

    if (uconf.verbosity != VerboseMode.trace) {
        confLogger(VerboseMode.warning);
    }

    LlmConfig llmConf;
    try {
        llmConf = readConfig(uconf.config.Path, silent: true, noCwdConfig: uconf.noCwdConfig,
                trustedConfig: uconf.trustedConfig);
    } catch (Exception e) {
        logger.errorf("Failed to read configuration: %s", e.msg).collectException;
        return 1;
    }

    if (conf.listTools) {
        listTools(uconf, conf, llmConf);
    }
    return runServer(uconf, conf, llmConf);
}

private:

// Diagnostic mode: print filtered tool list and exit.
int listTools(UserConfig uconf, UserConfig.Mcp conf, LlmConfig llmConf) nothrow {
    import std.algorithm : sort;
    import std.array : array, empty;
    import std.json : JSONType;
    import std.stdio : writeln;

    import llm.tool_call : descAllFunctions, filterToolDescriptions;

    try {
        auto allTools = descAllFunctions();
        auto filtered = filterToolDescriptions(allTools, llmConf.toolFilter.to);

        if (filtered.array.length == 0) {
            logger.errorf("No tools match the filter (include: %s, , exclude: %s)",
                    llmConf.toolFilter.include, llmConf.toolFilter.exclude);
            return 1;
        }

        writeln("Available tools (", filtered.array.length, "):");
        writeln();
        foreach (tool; filtered.array) {
            auto func = tool["function"];
            auto name = func["name"].str;
            auto desc = func["description"].str;
            writeln("  ", name);
            if (!desc.empty) {
                writeln("    ", desc);
            }
            // Print parameters if any (sorted for deterministic output).
            if ("parameters" in func && "properties" in func["parameters"]) {
                auto props = func["parameters"]["properties"];
                if (props.type == JSONType.object && !props.object.empty) {
                    auto paramNames = props.object.byKey.array;
                    paramNames.sort();
                    foreach (paramName; paramNames) {
                        auto param = props[paramName];
                        string paramType = "string";
                        if ("type" in param)
                            paramType = param["type"].str;
                        string paramDesc = "";
                        if ("description" in param)
                            paramDesc = param["description"].str;
                        string extra = paramDesc.empty ? "" : " - " ~ paramDesc;
                        writeln("      ", paramName, " (", paramType, ")", extra);
                    }
                }
            }
            writeln();
        }
    } catch (Exception e) {
        logger.error("Error listing tools: ", e.msg).collectException;
        return 1;
    }
    return 0;
}

/// Reply handler for the configure request (runs on the main thread inside
/// client.process).
static void onConfigureReply(ref Tuple!(ReadyReply*, bool*) ctx, ReadyReply r) {
    *ctx[0] = r;
    *ctx[1] = true;
}

/// One control-flow decision of the main pump loop (extracted verbatim from
/// runServer's loop body so the shutdown-deadline/signal/exit-cell logic is
/// unit-testable; the loop's logging and side effects stay in runServer).
private enum PumpAction {
    none, // nothing to do: keep pumping (sleep and loop)
    requestShutdown, // first termination signal: request the actor shutdown
    deadlineExpired, // the shutdown deadline passed without the actor stopping
    secondSignal, // a second termination signal forces the exit
    serverStopped, // the exit cell is set: the server actor stopped
}

/// Pure decision kernel of one pump-loop iteration. `sig` is the raw
/// sigtimedwait result (-1 when nothing was pending).
private pure PumpAction pumpAction(bool shutdownRequested, int sig, SysTime now,
        SysTime shutdownDeadline, int exitCell) {
    if (shutdownRequested && now > shutdownDeadline)
        return PumpAction.deadlineExpired;
    if (sig == SIGINT || sig == SIGTERM)
        return shutdownRequested ? PumpAction.secondSignal : PumpAction.requestShutdown;
    if (exitCell != 0)
        return PumpAction.serverStopped;
    return PumpAction.none;
}

int runServer(UserConfig uconf, UserConfig.Mcp conf, LlmConfig llmConf) {
    import my.gc.refc : refCounted;

    // Only stdio transport is implemented; require the flag.
    if (!conf.stdio) {
        logger.error("--stdio flag is required (HTTP transport not yet implemented)");
        return 1;
    }

    // Extract config parameters for passing to the server actor.
    // The actor will call readConfig() to reconstruct LlmConfig.
    McpConfigData configData;
    configData.configPath = uconf.config.toString;
    configData.noCwdConfig = uconf.noCwdConfig;
    configData.trustedConfig = uconf.trustedConfig;

    // Block termination signals in this thread BEFORE spawning so that every
    // actor thread inherits the blocked mask and the default signal action
    // can never kill the process. The main thread consumes pending signals
    // with sigtimedwait and converts them into shutdown requests -- no signal
    // handler, no shared mutable state and no extra thread.
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGINT);
    sigaddset(&set, SIGTERM);
    if (pthread_sigmask(SIG_BLOCK, &set, null) != 0) {
        logger.error("Failed to block termination signals");
        return 1;
    }

    auto sys = makeSystem();
    // The System must be shut down (pool workers joined) before the model
    // subsystem deinitializes in appMain. scope(exit) blocks run in reverse
    // order of registration, so registering sys.shutdown here in runServer --
    // an inner frame relative to appMain -- guarantees it runs before
    // appMain's deinitLlmfunLocalModel.
    scope (exit)
        sys.shutdown();

    // Shared exit cell (0 running, 1 stopped ok, 2 stopped with error).
    // The server actor writes it on its stop path; the main loop polls it.
    auto exitState = refCounted(0);
    auto serverAddr = sys.spawn!McpServerActor(exitState);
    // The reader actor forwards complete stdin frames to the server actor. It
    // makes its own StdioTransport in its onSpawn launch hook (the same
    // per-actor transport ownership as the server actor - no main-thread
    // transport).
    sys.spawn!StdioReaderActor(serverAddr.weakRef);

    // The main thread is not an actor: it drives a bare ActorShell client
    // kernel used only as the request/reply receiver for the configure call.
    auto client = ActorShell(makeAddress);
    auto server = Channel!McpServerActor(serverAddr, &client, timeout(dur!"seconds"(30)));

    bool running = true;
    immutable ShutdownTimeout = dur!"seconds"(30);
    auto shutdownDeadline = Clock.currTime();
    timespec noWait = timespec(0, 0);
    int sig;

    ReadyReply configureReply;
    bool configureArrived;
    bool hadError = false;
    server.configure(llmConf.toolFilter, configData).capture(&configureReply,
            &configureArrived).then(&onConfigureReply, (scope ref ActorShell self, scope ErrorMsg e) {
        logger.errorf("MCP server failed to confirm startup: %s", e.reason).collectException;
        hadError = true;
        configureArrived = true;
    });

    logger.info("MCP server running in actor thread, press Ctrl+C to stop");

    // Wait for the configure reply before entering the pump loop: the reply
    // is dispatched by pumping the client kernel here on the main thread, so
    // the startup outcome is fully resolved first.
    auto configureDeadline = Clock.currTime() + ShutdownTimeout;
    while (!configureArrived && !hadError && Clock.currTime() < configureDeadline) {
        client.process(Clock.currTime());
        Thread.sleep(dur!"msecs"(1));
    }
    if (!configureArrived && !hadError) {
        // Defensive: the channel timeout should have fired the error path
        // above and set both flags.
        logger.error("MCP server did not confirm startup in time").collectException;
        hadError = true;
    }
    if (configureArrived && !configureReply.ok) {
        // A ReadyReply(false) failure (bad config, AgentContext, ...) - the
        // actor deliberately stays alive and the exit cell stays 0: report the
        // failure and exit 1, mirroring the old in-loop McpFailed handling.
        if (configureReply.errMsg.length)
            logger.error(configureReply.errMsg);
        hadError = true;
    }
    if (hadError) {
        logger.info("MCP server stopped");
        return 1;
    }
    logger.info("MCP server actor confirmed startup");

    bool shutdownRequested = false;
    while (running) {
        // Consume any pending termination signal without blocking.
        sig = sigtimedwait(&set, null, &noWait);
        final switch (pumpAction(shutdownRequested, sig, Clock.currTime(),
                    shutdownDeadline, exitState.get)) with (PumpAction) {
        case none:
            break;
        case requestShutdown:
            logger.info("Shutdown signal received, requesting actor shutdown");
            shutdownRequested = true;
            shutdownDeadline = Clock.currTime() + ShutdownTimeout;
            server.shutdown();
            break;
        case deadlineExpired:
            logger.warning("MCP server did not stop in time, exiting");
            hadError = true;
            running = false;
            break;
        case secondSignal:
            logger.warning("Second shutdown signal received, forcing exit");
            hadError = true;
            running = false;
            break;
        case serverStopped:
            logger.info("MCP server actor stopped");
            hadError = exitState.get == 2;
            running = false;
            break;
        }
        Thread.sleep(dur!"msecs"(10));
    }

    logger.info("MCP server stopped");
    return hadError ? 1 : 0;
}

@("pumpAction idle: no signal, no exit cell -> keep pumping")
unittest {
    import std.datetime.systime : SysTime;
    import std.datetime : dur;

    auto t = SysTime.fromUnixTime(1000);
    auto deadline = t + dur!"seconds"(30);
    assert(pumpAction(false, -1, t, deadline, 0) == PumpAction.none);
}

@("pumpAction first signal requests the actor shutdown (SIGINT and SIGTERM)")
unittest {
    import std.datetime.systime : SysTime;
    import std.datetime : dur;

    auto t = SysTime.fromUnixTime(1000);
    auto deadline = t + dur!"seconds"(30);
    assert(pumpAction(false, SIGINT, t, deadline, 0) == PumpAction.requestShutdown);
    assert(pumpAction(false, SIGTERM, t, deadline, 0) == PumpAction.requestShutdown);
    // Non-termination signals are ignored (only SIGINT/SIGTERM are blocked).
    assert(pumpAction(false, -1, t, deadline, 0) == PumpAction.none);
}

@("pumpAction second signal forces the exit")
unittest {
    import std.datetime.systime : SysTime;
    import std.datetime : dur;

    auto t = SysTime.fromUnixTime(1000);
    auto deadline = t + dur!"seconds"(30);
    assert(pumpAction(true, SIGINT, t, deadline, 0) == PumpAction.secondSignal);
    assert(pumpAction(true, SIGTERM, t, deadline, 0) == PumpAction.secondSignal);
}

@("pumpAction 30 s timeout expiry forces the exit only once it really passed")
unittest {
    import std.datetime.systime : SysTime;
    import std.datetime : dur;

    auto deadline = SysTime.fromUnixTime(1000);
    auto before = deadline - dur!"msecs"(1);
    auto after = deadline + dur!"msecs"(1);
    assert(pumpAction(true, -1, after, deadline, 0) == PumpAction.deadlineExpired);
    // Not expired yet: keep pumping (the deadline check is strict `>`).
    assert(pumpAction(true, -1, before, deadline, 0) == PumpAction.none);
    // Without a shutdown request there is no deadline check at all - the
    // stale deadline value from before the first signal is never consulted.
    assert(pumpAction(false, -1, after, deadline, 0) == PumpAction.none);
}

@("pumpAction exit cell != 0 means the server actor stopped (signal beats cell)")
unittest {
    import std.datetime.systime : SysTime;
    import std.datetime : dur;

    auto t = SysTime.fromUnixTime(1000);
    auto deadline = t + dur!"seconds"(30);
    // The decision order is deadline -> signal -> cell: a pending signal in
    // the same iteration as a set cell still takes the requestShutdown/
    // secondSignal branch, mirroring the original if-chain.
    assert(pumpAction(false, -1, t, deadline, 1) == PumpAction.serverStopped);
    assert(pumpAction(true, -1, t, deadline, 2) == PumpAction.serverStopped);
    assert(pumpAction(false, SIGTERM, t, deadline, 2) == PumpAction.requestShutdown);
    assert(pumpAction(true, SIGINT, t, deadline, 2) == PumpAction.secondSignal);
}
