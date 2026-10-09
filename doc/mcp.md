# MCP Server

llmfun implements an MCP (Model Context Protocol) server that exposes its tool system over JSON-RPC 2.0 via stdio. This allows MCP-compatible clients (Claude Desktop, Cursor, Continue, etc.) to use llmfun's tools.

## Overview

The MCP server bridges MCP's JSON-RPC protocol to llmfun's existing `@Function`/`RegisterLlmFunctions` tool infrastructure. It reuses `descAllFunctions()` for tool discovery and `executeFunc()` for tool execution, with `ReFilter` for tool visibility control.

The server constructs a full `AgentContext` inside the actor thread, providing all tools with their required context. Dependencies like RAG and SkillManager are created with graceful degradation — if unavailable, tools return clear error messages instead of crashing.

## Architecture

### Modules

| Module | Purpose |
|--------|---------|
| `mcp_server/types.d` | JSON-RPC 2.0 types (`JsonRpcRequest`, `JsonRpcResponse`, `ToolResult`) using `std.json.JSONValue` |
| `mcp_server/protocol.d` | JSON-RPC parsing (`parseRequest`) and serialization (`serializeResponse`) |
| `mcp_server/transport.d` | `Transport` interface and `StdioTransport` implementation |
| `mcp_server/package.d` | `MCPServer` class, the `McpServerActor`/`StdioReaderActor` actors, payload types (`McpConfigData`, `ToolFilter`, `ReadyReply`, `ExitCell`) |
| `app_mcp.d` | CLI entry point, signal handling, actor spawning |

### Actor Model

The MCP server runs on the vendored `my.actor` framework
(`vendor/mylib/source/my/actor/`): one `System` per `mcp` subcommand
process, two pool-placed actors, and a manually pumped client kernel on
the main thread.

1. **Main thread** (`app_mcp.d: runServer`) blocks SIGINT/SIGTERM with
   `pthread_sigmask` (signals are consumed on the main thread with
   `sigtimedwait` and turned into shutdown requests), creates the `System`
   via `makeSystem()` and spawns both actors on its shared pool:
   `sys.spawn!McpServerActor(exitState)` and
   `sys.spawn!StdioReaderActor(serverAddr.weakRef)`.
2. **Main thread** sends the startup request
   `configure(ToolFilter, McpConfigData)` through a typed
   `Channel!McpServerActor` and awaits the `ReadyReply` by pumping a bare
   `ActorShell` client kernel (`client.process(Clock.currTime())`). The
   request timeout is pinned at 30 s; any `ScopedActorError` on the reply
   path (peer down, timeout, unknown message, fatal) is logged and exits 1.
3. **Server actor** (`McpServerActor`) runs the heavy startup inside the
   `configure` message handler, not the constructor (the ctor runs
   synchronously on the spawning thread inside `spawn!`): `readConfig`
   reconstructs `LlmConfig` from the flattened `McpConfigData`, then `RAG`
   (may be null - graceful degradation), `AgentContext` with all
   dependencies, `SkillManager` (may be null - graceful degradation), the
   `taskDone` no-op-with-logging handler, and `MCPServer`. A failed startup
   is reported as `ReadyReply(false, errMsg)`; the main thread logs it and
   exits 1.
4. **Reader actor** (`StdioReaderActor`) forwards complete stdin frames:
   each `pollTick()` reads one frame via the existing transport API
   (`hasData()` / `readMessage()`), forwards it to the server actor with
   `dynSend(server_, "stdin", message)`, and re-arms itself with a delayed
   self-send (`dynDelayedSend`) 10 ms later, so between ticks neither actor
   occupies a pool worker.
5. **Server actor** handles one request at a time: `stdin(message)`
   dispatches `MCPServer.handleMessage` and writes the response (a handler
   error is a stop path, not catch-and-continue); `eof()` and `shutdown()`
   are state-guarded idempotent stop requests.
6. **Stop path**: the server actor closes the transport, destroys RAG and
   sets the shared exit cell right before sending its self-exit
   (`sendExit(self_, ExitReason.userShutdown)` - with no `onExit` hook
   declared, the default exit handler force-shuts the actor down). The
   reader observes a closed transport on its next tick and treats it as
   eof-equivalent.
7. **Main thread** pump loop: non-blocking `sigtimedwait`, on the first
   signal `shutdown()` (a second signal forces exit), poll the exit cell,
   sleep 10 ms. The 30 s shutdown deadline, the second-signal force exit
   and the `exitState != 0 -> exit 1` mapping are unchanged.

The only value shared across threads is the exit cell: an `ExitCell` (a
`my.gc.refc` `RefCounted!int`: 0 running, 1 stopped ok, 2 stopped with
error), the mylib-sanctioned cross-thread flag pattern. Each actor creates
its own `StdioTransport` in its `onSpawn` launch hook (per-actor transport
ownership); the transport's `_closed` flag is still `core.atomic`-shared
even though each instance now has a single-user thread. The server mailbox
is deliberately unbounded (`spawn`, not `spawnBounded`): dropping JSON-RPC
requests would be a correctness bug. Lifecycle traces (spawn, stop path,
reader tick cadence) are behind the module's `version(TraceMcp)`-gated
`trace()` helper (emitted at INFO level as `[MCP] ...`).

### Log Parity with the Pre-Migration Lifecycle

Every lifecycle log case of the old `std.concurrency` design (the Task 3
e2e baseline) has a corresponding log or trace in this design:

| Old message | New log / trace |
|---|---|
| `McpStarted` | info `MCP server actor started` (actor, in `configure`) + info `MCP server actor confirmed startup` (main) + trace `configure: ready` |
| `McpShutdown` | info `Shutdown requested, stopping MCP server` (actor, in `shutdown()`) + trace `shutdown: graceful shutdown requested, stopping` |
| `McpStopped` (ok) | exit cell 1 + info `MCP server actor stopped` (main) + info `MCP server stopped` + trace `stop: transport closed, exit cell set, self-exit sent` |
| `McpStopped` (EOF) | info `MCP client disconnected (EOF)` (actor, in `eof()`) + trace `eof: client disconnected, stopping`, then the `McpStopped` (ok) row |
| `McpFailed` | `ReadyReply(false, errMsg)`: actor-side `logger.errorf` + main logs the `errMsg` and `MCP server stopped`, exit 1 |
| drain-loop handler error | warning `Error in MCP loop: ...` (`onException`) or the fatal wrap in `stdin()`/`configure()`; for reader-side cases warning `Error in MCP reader loop: ...` (`StdioReaderActor.onException`, which re-arms the tick) - the `reader: ...` strings are the per-tick/EOF informational traces, not the error path |

Additional traces (all behind `version(TraceMcp)`):

- `stdin: one frame dispatched`
- `reader: one frame forwarded`
- `reader: transport closed, notifying the server and exiting`
- `reader: EOF from readMessage, notifying the server and exiting`
- the reader tick re-arms (in `onException` or after a completed tick)

### Message Contracts

Actor methods are the messages (my.actor: public methods on a plain
class; `void` = one-shot fire-and-forget, non-void = request/reply
returning a promise chain). `StdioReaderActor` sends the strings `stdin`
(with the frame) and `eof` via `dynSend`; a send to a dead server is a
structural no-op (`WeakAddress.lock.get` returns null and drops the
message).

| Contract | Kind | Direction | Purpose |
|---|---|---|---|
| `ReadyReply configure(ToolFilter, McpConfigData)` | request/reply | Main -> Server | Startup: heavy construction, replies ok/errMsg; 30 s pinned timeout |
| `void stdin(string message)` | one-shot | Reader -> Server | One complete JSON-RPC frame; dispatch + write response |
| `void eof()` | one-shot | Reader -> Server | Client disconnected; idempotent stop |
| `void shutdown()` | one-shot | Main -> Server | Graceful shutdown request; idempotent stop |
| `void pollTick()` | one-shot, self-sent | Self (reader) | One non-blocking read/forward iteration; re-arms at +10 ms |
| `ExitCell` (`RefCounted!int`) | shared cell | Server writes, Main polls | 0 running / 1 stopped ok / 2 stopped with error |

`McpConfigData` (flattened scalar-only copy of `LlmConfig`) and
`ToolFilter` remain the payload types: `LlmConfig` holds associative
arrays and my.actor's `Variant` boxing gives no unshared-aliasing
guarantee, so the flatten stays (the `readConfig` reconstruction inside
`configure` is unchanged).

### AgentContext Integration

The MCP server constructs a full `AgentContext` inside the actor thread. `AgentContext` implements all tool context interfaces:

| Context Interface | Tools | Availability in MCP |
|-------------------|-------|---------------------|
| `FileContext` | `readFile`, `writeFile`, `editFile`, `listDirectory`, `removeFile`, `countLinesInFile`, `md5HashFile`, `grepFiles` | Always available |
| `EnvironmentContext` | `executeCommand`, `listEnvironments` | Always available |
| `RAGContext` | `querySemantic`, `queryTextSearch`, `queryBestMatch`, `listRAGDatabases`, `listRAGSources`, `readRAGSource`, `loadFileToRAG`, `loadContentToRAG`, `removeTopicFromRAG`, `queryReadFile` | Available if RAG is configured, graceful degradation otherwise |
| `MemoryContext` | `writeMemory`, `readMemory`, `removeMemory`, `getMemoryTopics` | Always available |
| `CompletionContext` | `taskDone` | Always available (no-op with logging) |
| `MetricsContext` | `getMetrics` | Always available |
| `PipelineControlContext` | `pipelineOutput` | Always available (no-op) |
| `VisionContext` | `loadImageApi` | Always available (inline mode works without vision model) |
| `SkillContext` | `loadSkill` | Available if SkillManager is configured, graceful degradation otherwise |

### Tool Availability and the Tool Broker

The tables above list what CAN be available per context interface: the static
`tools/list` / `llmfun mcp --list-tools` view (every registered tool that passes
`toolFilter`), which is unchanged by the tool broker. What the interactive
agent's model actually sees is narrowed further by the broker: ungrouped
tools are always listed (alwaysOn); tools in hidden groups are withheld until
the model activates their group via `listToolTags`
(sticky activation, pruned at compression points).

The MCP protocol paths bypass that per-agent selection: `tools/list` is the
static listing above (`descAllFunctions()` + `filterToolDescriptions`), and
`tools/call` dispatches through the registry + `ReFilter` checks only (the
unknown-tool refusal and the excluded-by-config refusal; the "not
visible to this agent" refusal lives at the interactive agent's dispatch site).
The MCP server's `AgentContext` still carries the broker state and the
`toolBroker.enabled` kill switch, but nothing on the MCP request path consults
it today -- so with the kill switch off, MCP clients see the same tools as
with it on.

MCP tools do join the broker pool: a configured server can carry `tags:`
(free-form - the compile-time tag channel is gone, so runtime tags have no enum
to be checked against), and its tools register at runtime (`registerMcpTool`,
`mcp_server/registration.d`) with the server's tags, so discovery, filtering
and activation treat them like any other tool.

### Graceful Degradation

The MCP server starts even when optional dependencies are unavailable:

**RAG not available**: RAG-dependent tools (`querySemantic`, `queryTextSearch`, `queryBestMatch`, `listRAGDatabases`, `listRAGSources`, `readRAGSource`, `loadFileToRAG`, `loadContentToRAG`, `removeTopicFromRAG`, `queryReadFile`) return `"error: RAG not available"` instead of crashing. The tools still appear in `tools/list` since `AgentContext` implements `RAGContext`.

**SkillManager not available**: `loadSkill` returns `"error: skill manager not available"` instead of crashing. The tool still appears in `tools/list` since `AgentContext` implements `SkillContext`.

**Vision model not configured**: `loadImageApi` operates in inline mode — it loads and base64-encodes the image, returning the data URL directly. No external vision model is called.

### taskDone Behavior

In the MCP context, `taskDone` is a no-op that logs the answer. It does not trigger framework-level task completion behavior. When called, the server logs the answer at INFO level and returns `"done"` to the MCP client. This allows MCP clients to call `taskDone` without causing the server to terminate or change state.

### pipelineOutput Behavior

In the MCP context, `pipelineOutput` returns a success message but does not propagate output to downstream nodes (there is no pipeline). The output is logged at TRACE level and discarded. This allows MCP clients to call `pipelineOutput` without side effects.

### Stdio Transport

The `StdioTransport` uses unbuffered POSIX reads from the file descriptor to avoid the classic poll/FILE buffering race: when the C FILE buffer eagerly reads multiple lines, `poll(2)` sees an empty kernel buffer and returns 0, causing the actor to stall on already-available data. Bypassing FILE means `readMessage()` never blocks in the actor loop -- the actor only calls it after `hasData()` confirms a complete line is available.

## Supported Methods

| Method | Description |
|--------|-------------|
| `initialize` | MCP handshake; returns protocol version, capabilities, server info |
| `tools/list` | Return filtered tool descriptions in MCP format |
| `tools/call` | Execute a tool with the given arguments |
| `ping` | Health check; returns `{}` |
| `resources/list` | Returns empty array (no resources) |
| `prompts/list` | Returns empty array (no prompts) |

### Initialize

Request:
```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": {
      "tools": { "listChanged": false }
    },
    "serverInfo": {
      "name": "llmfun-mcp",
      "version": "0.1.0"
    }
  }
}
```

### Tools/List

Request:
```json
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
```

Response:
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "tools": [
      {
        "name": "readFile",
        "description": "Read file contents with optional line numbering and range selection",
        "inputSchema": {
          "type": "object",
          "properties": {
            "path": { "type": "string" },
            "startLine": { "type": "integer" },
            "count": { "type": "integer" }
          },
          "required": ["path", "startLine", "count"]
        }
      }
    ]
  }
}
```

### Tools/Call

Request:
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "readFile",
    "arguments": {
      "path": "README.md",
      "startLine": 1,
      "count": 10
    }
  }
}
```

Response (success):
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      { "type": "text", "text": "file content here..." }
    ],
    "isError": false
  }
}
```

Response (error):
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "content": [
      { "type": "text", "text": "error message" }
    ],
    "isError": true
  }
}
```

## Error Handling

The server follows JSON-RPC 2.0 error codes:

| Code | Meaning | When |
|------|---------|------|
| `-32700` | Parse error | Malformed JSON |
| `-32600` | Invalid request | Missing `jsonrpc` or `method` field |
| `-32601` | Method not found | Unknown method or filtered-out tool |
| `-32602` | Invalid params | Missing or wrong-type parameters |
| `-32603` | Internal error | Unexpected exception during tool execution |

### Notification Suppression

Requests without an `id` field are treated as notifications. Per JSON-RPC 2.0 spec, the server sends no response for notifications.

### Pre-Initialize Rejection

Methods other than `initialize`, `notifications/initialized`, and `notifications/cancelled` are rejected with `-32600` (InvalidRequest) if sent before the `initialize` handshake.

### Tool Filtering

When `tools/call` requests a tool that is hidden by `ReFilter` (via `--include`/`--exclude`), the server returns `-32601` (MethodNotFound) to avoid leaking which tools exist but are hidden.

## CLI Usage

The `--stdio` flag is required to start the server (HTTP transport is not yet implemented). `--stdio` and `--list-tools` are mutually exclusive.

### Start MCP Server

```bash
llmfun mcp --stdio
```

### List Available Tools

```bash
llmfun mcp --list-tools
```

### Filter Tools

```bash
# Only file-related tools
llmfun mcp --stdio --include "^read.*" --include "^write.*" --include "^list.*"

# Exclude dangerous tools
llmfun mcp --stdio --exclude "executeCommand" --exclude "removeFile"
```

### Pipe Requests

```bash
# Single request
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | llmfun mcp --stdio

# Multiple requests (use a here-doc or process substitution)
llmfun mcp --stdio <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
EOF
```

## Integration with MCP Clients

### Claude Desktop

Add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "llmfun": {
      "command": "path/to/build/llmfun",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

### Cursor

Add to `.cursor/mcp.json`:

```json
{
  "mcpServers": {
    "llmfun": {
      "command": "path/to/build/llmfun",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

## Debugging

The actor scheduler used by the MCP server (`my.actor`) delivers wakeups
via real-time signals, which stop `gdb` immediately. Run the server under
`gdb` with the real-time signals passed through:

```bash
gdb -batch -ex 'handle SIG34 nostop noprint pass' -ex run --args \
    ./build/llmfun mcp --stdio
```

An empty backtrace from an attached `gdb` is an attach failure (e.g.
`yama ptrace_scope`), not missing debug info: launch the process under
`gdb` from the start instead of attaching to it.

## Design Decisions

### std.json over mir

The implementation uses `std.json.JSONValue` instead of `mir.algebraic_alias.json.JsonAlgebraic`. This avoids the `mir` dependency and keeps the MCP server self-contained within Phobos.

### AgentContext with Graceful Degradation

The MCP server constructs `AgentContext` with all dependencies. RAG and SkillManager are optional — if creation fails, the server logs a warning and continues. Tools that depend on these services return clear error messages when invoked, rather than crashing. This allows the MCP server to start in environments where RAG embeddings or skill paths are not configured.

### McpConfigData for Actor Boundary

Configuration is passed across the actor boundary via `McpConfigData`, a struct containing only scalar/immutable fields. This stays regardless of framework: `LlmConfig` holds associative arrays and the my.actor `Variant` boxing gives no unshared-aliasing guarantee, so the flatten stays and the actor reconstructs `LlmConfig` from this data via `readConfig`.

### Arguments Pass-Through

The `params["arguments"]` JSONValue object is passed directly to `executeFunc()` without stringify/re-parse. This preserves the original JSON structure and avoids serialization artifacts.

### Array Unwrapping

Both `descAllFunctions()` and `filterToolDescriptions()` return guaranteed `JSONValue(JSONValue[])` (array type). The code safely accesses `.array` on these values.

## Future Work

- **HTTP transport**: `--host`/`--port` flags exist but are not yet implemented; the server requires `--stdio`
- **SSE transport**: Server-sent events for bidirectional communication
- **Resource support**: Expose files and directories as MCP resources
- **Prompt support**: Expose prompt templates as MCP prompts
- **Streaming**: Support streaming tool results for long-running operations
