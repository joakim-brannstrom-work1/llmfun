## Task 29: D - the run's task is the drill-down's query row

Priority: P1. Dependencies: Task 27 (shares the wire-machinery pattern; no
field dependency, but the two land in the same files).

### Description
The pipeline payload never carries the agent's task, so the drill-down never
shows a query row: the golden's `YOU - get the parser building` line exists only
because the golden's store is typed-seeded. The run's start becomes a UI event -
fired once per run, before the agent's first batch, carrying the task - and the
C++ handler that draws the query row is task_30 (emitter first).

### Changes Made
- `source/llm/types.d:88-96` (edit): beside `IRunDoneEmitter`:

```d
/// What one agent run's start hands the emitter: fired once per run, before
/// the agent's first batch, with the task the node was invoked with.
interface IRunStartEmitter {
    void runStart(string task);
}
```

- `source/llm/pipeline/package.d` (edit):
  - `PipelineNode` gains `IRunStartEmitter runStartEmitter_;` beside
    `runDoneEmitter_` (`:97`, same comment pattern).
  - The builder's per-node wiring (`:837-846`) gains the cast, beside the
    `IRunDoneEmitter` one (`:844-845`).
  - The submit site (`:495`) fires it right after the query is set:

```d
pn.addUserQuery(query);
// The drill-down's query row: the run's task, fired before the agent's
// first batch (the turn it opens is the run's).
if (pn.runStartEmitter_ !is null)
    pn.runStartEmitter_.runStart(query);
```

- `source/llm/app_agent/ui.d` (`PipelineStreamMessageUpdater`, edit): implements
  the new interface beside `runDone` (`:589-591`):

```d
override void runStart(string task) {
    uiMsg.pipelineAgentStart(agentId, task);
}
```

- `source/llm/tui/package.d` (edit):
  - `struct UiPipelineAgentStart { string agentId; string task; }` beside
    `UiPipelineStreamDone` (`:1207-1209`).
  - The `UiMessenger` interface method (beside the `:699` pattern) and the
    forwarder (beside `:1068-1070`).
  - The TUI composer (beside `:497-500`):

```d
void pipelineMessage(UiPipelineAgentStart msg) {
    auto id = msg.agentId.toTuiString;
    auto task = msg.task.toTuiString;
    tuiPipelineAgentStart(tuiState, id, task);
}
```

- `cpp_tui/tui_api.h` (edit): declare, beside `tuiPipelineAgentUpdate` (`:591`):

```c
/* tuiPipelineAgentStart - one pipeline agent run started. `task` is inbound
 * (copied by the receiver), the run's task as the node was invoked with. */
void tuiPipelineAgentStart(TuiState* state, String agentId, String task);
```

- Pipeline tests (`source/llm/pipeline/tests.d`, edit): a `RecordingEmitter`
  variant records `runStart` per run; the builder test asserts one event per
  run, before the first stream tick, with the node's query as the task.

### Verification
- [ ] `dub build --config=application` clean.
- [ ] The pipeline test: two runs (and a looped re-run) -> one `runStart` each,
      ordered before that run's first `messageUpdate`, carrying the query.
- [ ] A node whose emitter is not an `IRunStartEmitter` runs unchanged (the
      cast is optional, like `:844-845`).
- [ ] `dub test` green.
- [ ] Regression: the overview's regression command passes.

### Notes
- The emitter runs under the submit path's mutex today (`:495` is inside it);
  `runDone` fires from `onAgentComplete` the same way, so the threading model is
  unchanged - but re-verify that the UI send is as thread-safe as the existing
  per-node sends before wiring (stop-and-re-plan if it is not).
- `tui.h`/`tui_api.cpp` do not change in this task: nothing consumes the event
  until task_30.

Plan pointers:
- DD-21, FR-25; `plan/requirements_notes.md` (follow-up wave).
- Anchors verified at plan time against the current tree; re-verify before each edit.
