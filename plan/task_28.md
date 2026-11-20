## Task 28: C++ - the drill-down draws the main-thread shape per run

Priority: P1. Dependencies: Task 27.

### Description
Consume task_27's batch index: the live pipeline path stops merging every step
into `<turnId>#0` and adopts the main thread's per-batch vocabulary, one
reasoning/content pair per step. One typed turn per run is unchanged (DD-19) -
the run boundary still closes on `tuiPipelineAgentDone`; only the batches inside
the turn multiply.

### Changes Made
- `cpp_tui/tui_api.cpp:705-717` (`tuiPipelineAgentUpdate`, edit): the batch id
  and the block ids are batch-scoped, matching the main thread's typed walk
  (`app_agent/package.d:1091-1100`):

```cpp
// One batch per step, one reasoning/content pair per batch - the shape the
// main thread's typed walk emits. A batch's ticks still merge in place and
// the newest tick wins, per batch.
const std::int64_t turnId = openTypedTurn(agent);
const std::string batchId = std::to_string(turnId) + "#" + std::to_string(msg.batch);
upsertTypedBlock(agent, turnId, "content#" + std::to_string(msg.batch), batchId,
                 TuiBlockKind_Prose, TuiBlockStatus_None, 0, "", role_, c);
if (!r.empty())
    upsertTypedBlock(agent, turnId, "reasoning#" + std::to_string(msg.batch),
                     batchId, TuiBlockKind_Reasoning, TuiBlockStatus_None,
                     TuiBlockFlag_Collapsible, "", "", r);
```

- `cpp_tui/tui_api.cpp:733` (`tuiPipelineAgentToolCall`, edit):
  `batchId` becomes `std::to_string(turnId) + "#" + std::to_string(call.batch)`.
- `cpp_tui/tui_api.cpp:761` (`tuiPipelineAgentToolResult`, edit): same for
  `result.batch` (both the merged-step branch and the result-only branch).
- `cpp_tui/test_agents_tab.cpp` (edit): a two-step scene - tick batch 0, tool
  call, tool result, tick batch 1, done - asserts two reasoning blocks (no
  overwrite), two batches, the calls in batch 0.
- Regolden what moves with a one-line reason (`--update` under `xvfb-run -a`).

### Verification
- [ ] `make test_agents_tab && ./test_agents_tab` green after the regolden.
- [ ] The two-step scene: `reasoning#0` and `reasoning#1` both present; the
      batch-1 tick did not overwrite batch 0's reasoning.
- [ ] The drill-down goldens (`inspector-agents-drilldown-100x30.txt` and the
      `test_agents_tab_gui` captures) unchanged unless the scene feeds them
      ticks - the golden's store is typed-seeded, not tick-fed.
- [ ] `./test_tui_api_v4` still green.
- [ ] Regression: the overview's regression command passes.

### Notes
- Batch ids are still never parsed (DD-4/NFR-3): the pipeline now *emits* the
  same `<turnId>#<n>` shape, no consumer splits on `#`.
- `openTypedTurn` (`tui_api.cpp:108-129`) is untouched: a turn per run, not per
  batch (that split was the already-fixed per-batch-group bug).

Plan pointers:
- DD-19, DD-20, FR-24, I-1/I-4 (per batch); design FR-17 via task_20's shape parity.
- Anchors verified at plan time against the current tree; re-verify before each edit.
