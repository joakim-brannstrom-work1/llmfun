## Task 27: D - the pipeline payloads carry the batch index

Priority: P1. Dependencies: none (first task of the follow-up wave).

### Description
The drill-down's live pipeline path overwrites one `reasoning#0`/`content#0` pair per turn
because the payload carries no batch boundary: every step's ticks land in the same batch
(`<turnId>#0`), so a run shows one Thinking fold whose body is the last tick's text, while
the main thread's typed walk emits one reasoning/content pair per batch
(`app_agent/package.d:1091-1100`). The wire must carry the batch index; the C++ task that
consumes it is task_28 (emitter first, per the overview's cross-cutting rule).

### Changes Made
- `cpp_tui/tui_api.h:85-96` (`PipelineChatMessage`, edit): gains
  `int64_t batch; /* 0-based step index within the run */` after `tokensPerSecond`.
  The struct grows 104 -> 112 bytes; update the field note above the struct.
- `cpp_tui/tui_api.h:98-109` (`TuiToolCallParam`) and `:111-121` (`TuiToolResultParam`), edit:
  each gains `int64_t batch;` (the batch whose response carried the call / that the
  result answers).
- `cpp_tui/tui_api.h:26-29` (`TUI_API_VERSION`), edit: 15 -> 16. This bump is a *real*
  ABI change, unlike task_03's doc-only bump; the comment stays.
- `source/llm/app_agent/ui.d:560-604` (`PipelineStreamMessageUpdater`, edit): gains a
  private `long batch_;` (starts 0); `messageUpdate` (`:574-581`) sends it;
  `streamMessageDone` (`:583-587`) moves it; `stepEvent` (`:593-595`) reports the
  batch that just closed.

```d
override void messageUpdate(StreamMessage msg, StreamToolCall[] tools, ServerStat stat) {
    ...
    uiMsg.pipelineStreamChatMessage(agentId: agentId, content: content, thinking: msg.reasoning,
            role: msg.role, batch: batch_, ...);
}

override void streamMessageDone() {
    // Still no close: the run boundary rides runDone below (closing here split one
    // run into one drill-down group per batch). But the index moves: the next
    // step's ticks belong to the next response batch.
    batch_++;
}

override void stepEvent(ProcessResult result) {
    // A step's calls belong to the batch whose streaming just closed; batch_ has
    // already moved past it. 0 when no batch closed yet (clamped).
    emitStepToolEvents(uiMsg, agentId, batch_ > 0 ? batch_ - 1 : 0, result);
}
```

- `source/llm/app_agent/ui.d:544-558` (`emitStepToolEvents`, edit): gains a
  `long batch` parameter, forwards it into the tool call / tool result messages.
- `source/llm/tui/package.d:1196-1226` (edit): `UiPipelineStreamChatMessage`,
  `UiPipelineToolCall` and `UiPipelineToolResult` each gain `long batch;`.
- `source/llm/tui/package.d:485-521` (edit): the three `pipeline*` composers copy
  `msg.batch` into the C structs.
- Every static assert / round-trip that pins the moved layouts: `grep -rn
  "PipelineChatMessage\|TuiToolCallParam\|TuiToolResultParam" source/ cpp_tui/`
  - `cpp_tui/test_tui_api_v4.cpp` case 1f (`:1005-1030`): `sizeof == 112`, the
    new offsets (`batch` at 104), and the round-trip pins `batch`.

### Verification
- [ ] `dub build --config=application` clean.
- [ ] The updater tests (`source/llm/app_agent/tests.d:3100-3148`, extend): two ticks,
      `streamMessageDone()`, one more tick -> the recorded batches are 0, 0, 1; a
      `stepEvent` between them reports batch 0.
- [ ] `make test_tui_api_v4 && ./test_tui_api_v4` green (case 1f's new layout pins).
- [ ] `./test_agents_tab` goldens unchanged (the lane ignores `batch`).
- [ ] `dub test` green.
- [ ] Regression: the overview's regression command passes.

### Notes
- The batch count lives in the updater, not the payload: `streamMessageDone` is the
  only per-batch signal the pipeline gives the UI seam today.
- Task 28 consumes `batch`; nothing on the C++ side reads it before that task lands.

Plan pointers:
- DD-19, DD-20, FR-24, FR-27; `plan/requirements_notes.md` (follow-up wave).
- Anchors verified at plan time against the current tree (post task_15); re-verify before each edit.
