## Task 30: C++ - the run's task draws the drill-down's query row

Priority: P1. Dependencies: Task 29.

### Description
Implement `tuiPipelineAgentStart`: the run's turn opens at the run's start (not
at the first tick) and gains the query row - the exact block the main thread's
turn start emits (`app_agent/package.d:1041-1043`: id `query`, batch
`<turnId>#q`, kind Prose, role `user`), so the drill-down's turn anatomy matches
the main thread's: query -> work batches -> answer.

### Changes Made
- `cpp_tui/tui_api.cpp` (edit), implement beside `tuiPipelineAgentUpdate`
  (`:681-718`):

```cpp
void tuiPipelineAgentStart(TuiState* state, String agentId, String task) {
    if (!state || !state->inner)
        return;
    std::string id(agentId.data ? agentId.data : "", agentId.data ? agentId.len : 0);
    if (id.empty())
        return;
    std::string t(task.data ? task.data : "", task.data ? task.len : 0);
    auto& agent = agentStore(*state->inner, id);
    // The run's query row, the same shape the main thread's turn start emits:
    // one prose block on the query batch ("<turnId>#q", role "user").
    const std::int64_t turnId = openTypedTurn(agent);
    upsertTypedBlock(agent, turnId, "query", std::to_string(turnId) + "#q",
                     TuiBlockKind_Prose, TuiBlockStatus_None, 0, "", "user", t);
}
```

- `cpp_tui/test_agents_tab.cpp` (edit): the task_28 two-step scene gains the
  `runStart` call before the first tick - the drill-down transcript shows
  `YOU - <task>` above the work, and the first tick joins the already-open turn
  (no second turn).
- Regolden what moves with a one-line reason (the drill-down goldens that are
  tick-fed now gain the query row).

### Verification
- [ ] `make test_agents_tab && ./test_agents_tab` green after the regolden.
- [ ] The scene: the query block exists (`query`, batch `<turnId>#q`), the
      turn opened by `runStart` is the turn the ticks join (one turn per run),
      and the turn still closes on `tuiPipelineAgentDone`.
- [ ] `queryBatchId` parity: the C++ builds the batch string, never parses one
      (DD-4/NFR-3).
- [ ] `./test_tui_api_v4` still green.
- [ ] Regression: the overview's regression command passes.

### Notes
- `openTypedTurn` (`tui_api.cpp:108-129`) already opens only when none is active,
  so `runStart` before the first tick owns the turn and the ticks merge into it -
  no new state on the agent.
- The `evictForCapacity` ride in `tuiTurnUpsert` (`tui_api.cpp:880-889`) is the
  turn-upsert path; `tuiPipelineAgentStart` goes through the same `openTypedTurn`
  turn upsert, so eviction applies unchanged.

Plan pointers:
- DD-21, FR-25, I-2 (the query row is turn-level, not batch-owned); design FR-17.
- Anchors verified at plan time against the current tree; re-verify before each edit.
