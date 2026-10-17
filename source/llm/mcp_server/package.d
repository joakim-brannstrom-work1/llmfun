/// MCP server that bridges JSON-RPC 2.0 to llmfun's @Function tool infrastructure.
///
/// The server runs on the my.actor framework: appMain spawns an McpServerActor
/// on a System and communicates with it exclusively through the typed
/// Channel!McpServerActor (message-method contracts: configure, stdin, eof,
/// pollTick, shutdown). A StdioReaderActor forwards complete stdin frames to
/// the server actor and self-reschedules a pollTick tick on the shared pool.
/// There is no shared mutable state between the threads; cross-thread exit
/// signaling goes through the ExitCell flag and sendExit.
///
/// Shutdown: the main thread calls server.shutdown() and waits up to 30 s for
/// the exit cell (ExitCell, 0 running / 1 stopped ok / 2 stopped with error),
/// which the server actor's stop path writes right before sendExit. Since the
/// transport uses non-blocking fd reads (see transport.d), readMessage() never
/// blocks a handler and shutdown is always honoured promptly. The 30 s deadline
/// is a safety net against unforeseen edge cases.
module llm.mcp_server;

import logger = std.logger;
import std.algorithm : map;
import std.array : array;
import std.datetime : Clock, dur;
import std.json : JSONType, JSONValue;

import my.filter : ReFilter;
import my.path : Path;
import my.actor.behavior : ActorRef;
import my.actor.channel : dynDelayedSend, dynSend;
import my.actor.common : ExitReason;
import my.actor.mailbox : WeakAddress;
import my.actor.msg : sendExit;
import my.gc.refc : RefCounted;

import llm.agent.context : AgentContext;
import llm.app_config : createRag;
import llm.config : LlmConfig, ToolFilter;
import llm.mcp_server.protocol;
import llm.mcp_server.transport : EOFException, StdioTransport, Transport;
import llm.mcp_server.types;
import llm.rag.rag : RAG;
import llm.skill : SkillManager, makeSkillManager;
import llm.tool_call : Context, descAllFunctions, executeFunc, filterToolDescriptions;

/// MCP server that exposes @Function-registered tools over JSON-RPC 2.0. Takes a ReFilter at construction to control which tools are visible to MCP clients. Uses descAllFunctions() and executeFunc() from llm.tool_call. This class is a pure request/response handler -- the event loop lives in the McpServerActor actor, which owns the transport.
class MCPServer {
private:
    ReFilter filter_;
    Context ctx;
    bool initialized_;

public:
    /// Construct server with tool filter and optional execution context. A null context works for stateless tools (most tools don't dereference Context).
    this(ReFilter filter, Context ctx = null) {
        this.filter_ = filter;
        this.ctx = ctx;
    }

    /// Parse a JSON-RPC message and return the serialized response string, or null for notifications (no response required).
    string handleMessage(string message) {
        if (message is null || message.length == 0)
            return null;

        JsonRpcRequest request;
        try {
            request = parseRequest(message);
        } catch (ProtocolException e) {
            if (e.isParseError)
                return serializeResponse(createParseErrorResponse());
            else
                return serializeResponse(createInvalidRequestResponse(JSONValue.init, e.msg));
        }

        // Notifications (no id field) return null -- no response written.
        if (request.isNotification()) {
            return null;
        }

        trace("Received: " ~ message);
        auto response = handleRequest(request);

        auto json = serializeResponse(response);
        trace("Sent: " ~ json);
        return json;
    }

private:
    /// Route a parsed request to the appropriate handler.
    JsonRpcResponse handleRequest(JsonRpcRequest request) {
        // Reject methods other than initialize before the server is initialized.
        if (!initialized_ && request.method != "initialize"
                && request.method != "notifications/initialized"
                && request.method != "notifications/cancelled") {
            return createInvalidRequestResponse(request.id,
                    "Server not initialized. Send 'initialize' first.");
        }

        switch (request.method) {
        case "initialize":
            return handleInitialize(request);
            // NOTE: "notifications/initialized" and "notifications/cancelled" are intentionally NOT handled in the switch below. They are notifications (no id field), so handleMessage() returns null before reaching handleRequest(). They are only whitelisted in the pre-init check above to allow pre-init notifications without triggering the "not initialized" error.
        case "tools/list":
            return handleToolsList(request);
        case "tools/call":
            return handleToolCall(request);
        case "resources/list":
            return handleResourcesList(request);
        case "prompts/list":
            return handlePromptsList(request);
        case "ping":
            return handlePing(request);
        default:
            return createMethodNotFoundResponse(request.id, request.method);
        }
    }

    /// Handle the MCP initialize handshake.
    JsonRpcResponse handleInitialize(JsonRpcRequest request) {
        initialized_ = true;

        JSONValue caps = JSONValue.emptyObject;
        JSONValue toolsCap = JSONValue.emptyObject;
        toolsCap["listChanged"] = false;
        caps["tools"] = toolsCap;

        JSONValue serverInfo = JSONValue.emptyObject;
        serverInfo["name"] = "llmfun-mcp";
        serverInfo["version"] = "0.1.0";

        JSONValue result = JSONValue.emptyObject;
        result["protocolVersion"] = "2024-11-05";
        result["capabilities"] = caps;
        result["serverInfo"] = serverInfo;

        logger.info("MCP Server initialized by client");
        return createSuccessResponse(request.id, result);
    }

    /// Handle tools/list -- return filtered tool descriptions in MCP format.
    JsonRpcResponse handleToolsList(JsonRpcRequest request) {
        // descAllFunctions() returns JSONValue(JSONValue[]) -- guaranteed array.
        auto allTools = descAllFunctions();
        auto filtered = filterToolDescriptions(allTools, filter_);

        // Convert OpenAI-format tool descriptions to MCP ToolDefinition format.
        JSONValue[] mcpTools;
        foreach (toolEntry; filtered.array) {
            // Each entry has {"type": "function", "function": {"name": ..., "description": ..., "parameters": ...}}
            auto func = toolEntry["function"];
            mcpTools ~= convertToMcpTool(func);
        }

        JSONValue result = JSONValue.emptyObject;
        result["tools"] = JSONValue(mcpTools);
        return createSuccessResponse(request.id, result);
    }

    /// Handle tools/call -- execute a tool with the given arguments.
    JsonRpcResponse handleToolCall(JsonRpcRequest request) {
        try {
            if (request.params.type != JSONType.object)
                return createInvalidParamsResponse(request.id, "params must be an object");

            if ("name" !in request.params)
                return createInvalidParamsResponse(request.id, "Missing 'name' in params");
            if (request.params["name"].type != JSONType.string)
                return createInvalidParamsResponse(request.id, "'name' must be a string");
            auto name = request.params["name"].str;

            // ReFilter rejection: return MethodNotFound to avoid leaking tool existence.
            if (!filter_.match(name))
                return createMethodNotFoundResponse(request.id, name);

            // params["arguments"] is already a parsed JSONValue object. Pass it directly to executeFunc() -- do NOT stringify and re-parse.
            JSONValue args;
            if ("arguments" in request.params) {
                args = request.params["arguments"];
                if (args.type != JSONType.object)
                    return createInvalidParamsResponse(request.id,
                            "params.arguments must be an object");
            } else {
                args = JSONValue.emptyObject;
            }

            // Execute the tool with null Context (stateless tools don't dereference it).
            auto result = executeFunc(ctx, name, args);

            // Wrap result in MCP ToolResult content format.
            ToolResult toolResult;
            toolResult.isError = !result.success;
            toolResult.content = [ToolResult.Content("text", result.msg)];

            return createSuccessResponse(request.id, toolResult.toJson());
        } catch (Exception e) {
            logger.warning("Error in handleToolCall: ", e.toString());
            return createInternalErrorResponse(request.id, e.msg);
        }
    }

    /// Handle ping -- return empty object as result.
    JsonRpcResponse handlePing(JsonRpcRequest request) {
        JSONValue result = JSONValue.emptyObject;
        return createSuccessResponse(request.id, result);
    }

    /// Handle resources/list -- return empty array (no resources).
    JsonRpcResponse handleResourcesList(JsonRpcRequest request) {
        JSONValue result = JSONValue.emptyObject;
        JSONValue[] emptyArr;
        result["resources"] = JSONValue(emptyArr);
        return createSuccessResponse(request.id, result);
    }

    /// Handle prompts/list -- return empty array (no prompts).
    JsonRpcResponse handlePromptsList(JsonRpcRequest request) {
        JSONValue result = JSONValue.emptyObject;
        JSONValue[] emptyArr;
        result["prompts"] = JSONValue(emptyArr);
        return createSuccessResponse(request.id, result);
    }

    /// Convert an OpenAI-format function description to an MCP ToolDefinition.
    /// Input: {"name": ..., "description": ..., "parameters": {"type": "object", "properties": ..., "required": ...}}
    /// Output: {"name": ..., "description": ..., "inputSchema": {"type": "object", "properties": ..., "required": ...}}
    JSONValue convertToMcpTool(JSONValue func) pure @safe {
        ToolDefinition def;
        def.name = func["name"].str;
        def.description = func["description"].str;
        if (auto p = "parameters" in func)
            def.inputSchema = *p;
        else
            def.inputSchema = JSONValue.emptyObject;
        return def.toJson();
    }
}

/// Reply sent from McpServerActor.configure back to the main-thread client
/// kernel. A failed startup is reported as ok=false plus errMsg.
struct ReadyReply {
    bool ok;
    string errMsg;
}

/// Shared exit cell (my.gc.refc RefCounted - the mylib-sanctioned cross-thread
/// flag pattern): 0 running, 1 stopped ok, 2 stopped with error. Written by the
/// server actor's stop path right before sendExit, polled by the main thread.
alias ExitCell = RefCounted!int;

/// Fully reactive MCP server actor. Constructed via
/// `sys.spawn!McpServerActor(transport, exitState)` - spawn args go to the
/// ctor, which only pins the dependencies; the heavy startup work runs in the
/// configure message handler (the ctor runs synchronously inside
/// spawn!). All input arrives as messages - the actor never polls.
class McpServerActor {
    private {
        Transport transport_;
        ExitCell exitState_;
        ActorRef self_;
        MCPServer server_;
        RAG rag_;
        bool stopping_;
        bool hadError_;
    }

    /// The transport parameter is the Transport interface (not StdioTransport)
    /// so unit tests can inject a scripted fake - the mylib no-thread test
    /// pattern. StdioTransport is-a Transport, so production call sites are
    /// unchanged.
    this(Transport transport, ExitCell exitState) {
        transport_ = transport;
        exitState_ = exitState;
    }

    this(ExitCell exitState) {
        exitState_ = exitState;
    }

    /// Framework launch hook - runs before the first message and provides the
    /// self handle used by the stop path's sendExit.
    void onSpawn(ActorRef self) @trusted {
        self_ = self;
        if (transport_ is null) {
            try {
                transport_ = new StdioTransport();
            } catch (Exception e) {
                logger.errorf("Failed to create stdio transport: %s", e.msg);
                exitState_.get = 2;
                sendExit(self_.address, ExitReason.userShutdown);
            }
        }
    }

    /// Startup: heavy construction moved OUT of the ctor. Performs the
    /// exact construction sequence of the old polling loop and replies when
    /// ready. A failed startup is NOT a stop path - the reply carries the
    /// failure and the main thread's exit logic reacts to it. An exception
    /// escaping the internal catches is still fatal - logged, the exit cell
    /// set to 2 (stopped with error) and a self-exit sent so main converges
    /// instead of waiting out the 30 s Channel timeout; the failure reply
    /// additionally lets main exit immediately.
    ReadyReply configure(ToolFilter filter, LlmConfig llmConf) {
        try {
            return configureWorld(filter, llmConf);
        } catch (Exception e) {
            trace("configure: handler exception, fatal stop");
            logger.errorf("Failed to configure MCP server actor: %s", e.msg);
            stop(true);
            return ReadyReply(false, "Failed to configure MCP server actor: " ~ e.msg);
        }
    }

    private ReadyReply configureWorld(ToolFilter filter, LlmConfig llmConf) {
        trace("configure: constructing the world");

        // Create RAG instance - non-fatal if it fails (graceful degradation).
        try {
            rag_ = createRag(llmConf);
            if (rag_ is null) {
                logger.warningf("RAG creation returned null, MCP will operate without RAG");
            }
        } catch (Exception e) {
            rag_ = null;
            logger.warningf("Failed to create RAG: %s. MCP will operate without RAG.", e.msg);
        }

        // Create AgentContext - fatal if it fails.
        AgentContext agentCtx;
        try {
            agentCtx = new AgentContext(llmConf, rag_);
        } catch (Exception e) {
            logger.errorf("Failed to create AgentContext: %s", e.msg);
            destroyRag;
            return ReadyReply(false, "Failed to create AgentContext: " ~ e.msg);
        }

        // Create SkillManager - non-fatal if it fails (graceful degradation).
        try {
            auto skillMgr = makeSkillManager(llmConf);
            agentCtx.setSkillManager(skillMgr);
        } catch (Exception e) {
            logger.warningf("Failed to create SkillManager: %s. MCP will operate without skills.",
                    e.msg);
        }

        // Set taskDone handler - logs the answer rather than triggering
        // framework behavior. Fatal if it fails - cannot operate without a
        // taskDone handler.
        try {
            agentCtx.setTaskDoneHandler((string answer) {
                logger.infof("MCP taskDone called: %s", answer);
            });
        } catch (Exception e) {
            logger.errorf("Failed to set taskDone handler: %s", e.msg);
            destroyRag;
            return ReadyReply(false, "Failed to set taskDone handler: " ~ e.msg);
        }

        try {
            server_ = new MCPServer(filter.to, agentCtx);
        } catch (Exception e) {
            logger.errorf("Failed to create MCP server: %s", e.msg);
            destroyRag;
            return ReadyReply(false, "Failed to create MCP server: " ~ e.msg);
        }

        logger.info("MCP server actor started");
        trace("configure: ready");
        return ReadyReply(true, "");
    }

    /// One complete JSON-RPC frame from the reader actor (reader -> server).
    /// Null-guarded: a frame arriving before a successful configure is dropped
    /// (the main thread reacts to the configure failure reply instead; a null
    /// deref here would hit the default exception handler and force-kill the
    /// actor without the exit-cell/transport cleanup the convergence logic
    /// relies on).
    void stdin(string message) {
        if (server_ is null)
            return;
        trace("stdin: one frame dispatched");
        try {
            auto response = server_.handleMessage(message);
            if (response !is null)
                transport_.writeMessage(response);
        } catch (Exception e) {
            // A handler error is a stop path like eof()/shutdown(), not the
            // old drain loop's catch-and-continue - the actor self-exits and
            // main converges instead of serving on with a half-broken server.
            logger.warning("Error in MCP loop: ", e.msg);
            stop(true);
        }
    }

    /// Client disconnected (reader -> server). Idempotent: state-guarded
    /// no-op if already stopping.
    void eof() {
        if (!stopping_)
            logger.info("MCP client disconnected (EOF)");
        trace("eof: client disconnected, stopping");
        stop;
    }

    /// Graceful shutdown request (main -> server). The old loop polled for
    /// this as a control message; the actor now exposes it as a method.
    /// Idempotent: state-guarded no-op if already stopping.
    void shutdown() {
        if (!stopping_)
            logger.info("Shutdown requested, stopping MCP server");
        trace("shutdown: graceful shutdown requested, stopping");
        stop;
    }

    /// Last-resort exception net for the handlers that are not fatal-wrapped
    /// internally: a throw from eof()/shutdown() is logged and skipped - the
    /// actor survives, matching the old drain loop's catch-and-continue; the
    /// error is reported via the exit cell at stop time (hadError -> cell 2).
    /// Declaring this hook replaces the default exception handler (which would
    /// force-shutdown the actor instead). The stdin/configure dispatches are
    /// fatal-wrapped inside their own handlers, so their exceptions
    /// never reach this hook.
    void onException(Exception e) {
        hadError_ = true;
        logger.warning("Error in MCP loop: ", e.msg);
    }

private:
    /// Stop path shared by eof() and shutdown(): close the transport and
    /// destroy RAG, set the exit cell (1 stopped ok / 2 stopped with error)
    /// right before sendExit so main's pump loop observes a fully cleaned-up
    /// stop, then self-exit. NO onExit
    /// hook: declaring one would REPLACE the default exit handler, which is
    /// the only forceShutdown death path - with a user onExit hook the actor
    /// survives sendExit(userShutdown) (the TrappedExit semantics verified in
    /// my/actor/registration.d:476-503). With no onExit hook the default exit
    /// handler force-shuts the actor down: a real death (the mylib-sanctioned
    /// self-exit pattern, README "one-shot task actors").
    void stop(bool hadError = false) {
        if (stopping_)
            return;
        stopping_ = true;

        transport_.close();
        destroyRag;

        hadError_ = hadError_ || hadError;
        exitState_.get = hadError_ ? 2 : 1;
        trace("stop: transport closed, exit cell set, self-exit sent");
        sendExit(self_.address, ExitReason.userShutdown);
    }

    void destroyRag() {
        if (rag_ !is null)
            rag_.destroy;
        rag_ = null;
    }
}

/// Reader tick cadence: the pollTick self-rescheduling delay. The practical
/// cadence is ~10-20 ms, not exactly 10 ms (the worker inactiveLimit sleep),
/// which the pump loops tolerate.
private enum TickInterval = 10.dur!"msecs";

/// Reader-side actor: forwards complete JSON-RPC frames from the transport to
/// the server actor, one per pollTick (a self-rescheduling tick on the
/// shared pool - between ticks neither actor occupies a pool worker). Spawned
/// via `sys.spawn!StdioReaderActor(serverAddr.weakRef)` - the spawn arg goes to
/// the ctor, which only pins the server's weak address (the ctor runs on
/// the spawning thread inside spawn!). The reader makes its own StdioTransport
/// in the onSpawn launch hook, on the actor thread - the same per-actor
/// transport ownership as the server actor (no main-thread shared transport).
///
/// The tick uses ONLY the existing transport API: hasData() for the
/// zero-timeout availability check, closed() to detect end of stream
/// (eof-equivalent) and readMessage() for the frame. No waitData and no new
/// Transport methods.
class StdioReaderActor {
    private {
        /// Weak address of the server actor: a dynSend/dynDelayedSend to a
        /// dead server is a structural no-op (WeakAddress.lock.get == null).
        WeakAddress server_;
        ActorRef self_;
        Transport transport_;
    }

    /// Optional transport override: tests inject a fake here; production
    /// (null) makes the real StdioTransport in onSpawn, on the actor thread.
    this(WeakAddress server, Transport transport = null) {
        server_ = server;
        transport_ = transport;
    }

    /// Framework launch hook - saves the self handle for the delayed re-arms
    /// and arms the first pollTick: nothing else sends it, so without this the
    /// tick loop would never start.
    void onSpawn(ActorRef self) @trusted {
        self_ = self;
        try {
            transport_ = transport_ !is null ? transport_ : new StdioTransport();
        } catch (Exception e) {
            logger.errorf("Failed to create stdio reader transport: %s", e.msg);
            // Tell the server the reader is gone (eof is idempotent server-side
            // and a dynSend to a dead server is a structural no-op): without
            // this, a reader-side transport failure would leave the server (and
            // main) waiting for stdin that never arrives.
            dynSend(server_, "eof");
            sendExit(self_.address, ExitReason.userShutdown);
            return;
        }
        dynDelayedSend(self_.address, Clock.currTime() + TickInterval, "pollTick");
    }

    /// One non-blocking iteration. Never blocks a worker thread between ticks:
    /// no polling sleeps inside the tick handler; the actor is unscheduled
    /// between ticks (the delayed self-send re-arms it).
    void pollTick() {
        if (transport_ is null)
            return; // spawn-failed guard: the actor is dead, do not re-arm

        if (transport_.closed()) {
            // End of stream (eof-equivalent): notify the server and self-exit.
            trace("reader: transport closed, notifying the server and exiting");
            dynSend(server_, "eof");
            sendExit(self_.address, ExitReason.userShutdown);
            return; // no re-arm
        }
        if (transport_.hasData()) {
            try {
                auto message = transport_.readMessage(); // skips blanks; throws EOFException on EOF
                trace("reader: one frame forwarded");
                dynSend(server_, "stdin", message);
            } catch (EOFException e) {
                // The EOF path is treated exactly like the closed() case (eof +
                // self-exit, no re-arm).
                trace("reader: EOF from readMessage, notifying the server and exiting");
                dynSend(server_, "eof");
                sendExit(self_.address, ExitReason.userShutdown);
                return; // no re-arm
            }
        }
        // Re-arm (self-sent delayed message); 10 ms keeps the current latency
        // envelope. The practical tick cadence is ~10-20 ms, not exactly 10 ms
        // (the worker inactiveLimit sleep), which the pump
        // loops already tolerate.
        dynDelayedSend(self_.address, Clock.currTime() + TickInterval, "pollTick");
    }

    /// A throwing tick handler is logged and skipped - the actor survives and
    /// keeps ticking, matching the old drain loop's catch-and-continue. A
    /// stopped tick would silently stop forwarding stdin (the server would hang
    /// until a signal). Declaring this hook replaces the default exception
    /// handler (which would force-shutdown the actor instead).
    ///
    /// The hook re-arms the tick: an exception that escaped pollTick skipped
    /// that method's trailing re-arm (it is pollTick's last statement), so
    /// without this the actor would survive but never tick again - stdin
    /// forwarding would stop silently. The guard makes double-arming
    /// impossible (the in-handler re-arm only lands when the handler ran to
    /// completion) and the spawn-failed case (transport_ null, no self-tick
    /// wanted) stays dead.
    void onException(Exception e) {
        logger.warning("Error in MCP reader loop: ", e.msg);
        if (transport_ !is null)
            dynDelayedSend(self_.address, Clock.currTime() + TickInterval, "pollTick");
    }
}

/// Optional trace logging for this module, enabled with a NEW version
/// identifier (TraceMcp) defined here - not a pre-existing convention.
private void trace(string msg) {
    version (TraceMcp) {
        logger.info("[MCP] " ~ msg);
    }
}
