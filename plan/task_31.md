## Task 31: D - /code and /plan open a display-only turn in the main store

Priority: P1. Dependencies: none among 27-30 (independent; ordered last so the
wire tasks land first).

### Description
The slash path consumes the query (`runAgent`, `app_agent/package.d:947`:
`query = null`), so no typed turn opens for `/code` or `/plan`; the handlers'
progress notices and the final report attach via `sendChatMessage` ->
`emitNoticeTyped` (`:1217-1222`) to `agent_.chat.currentTurnId()` - the last
*settled* turn of the loaded history (or 0). A settled turn's group folds in both
modes, so the report never draws; turn 0 creates an implicit orphan slot. The
handlers open their own turn for the query - the same bracket a non-slash query
gets (`:954-975`) - and close it after the run.

### Changes Made
- `source/llm/app_agent/package.d` (edit), beside `emitNoticeTyped` (`:1217`):

```d
/// The /code and /plan bracket: the slash path consumes the query, so no
/// runAgent loop opens a turn. The pipeline's own turn is display-only - no
/// history entry (the pipeline's query must not enter the main agent's LLM
/// context), and a session reload drops the turn with it.
package void openPipelineTurnTyped(string query) {
    agent_.chat.beginNewTurn();
    emitTurnStartTyped(query);
}

package void closePipelineTurnTyped(bool stopped) {
    auto ctx = typedCtx_;
    if (ctx is null)
        return;
    if (stopped) {
        emitStopTyped(); // the honest Cancelled flips
        return;
    }
    // No Answer block closes a pipeline turn, so the run-ended close would
    // land Interrupted; a run that was not stopped succeeded - close Done.
    uiMsg.turnUpsert(UiTurnData(ctx.turnId, TuiTurnState_Done, ctx.messageCount));
    typedCtx_ = null;
}
```

- `source/llm/app_agent/slash_pipeline.d:26-62` (edit): both handlers gain the
  bracket - open after `pipelineClear`, close after the report notice (both
  exit paths of `/code`):

```d
app.uiMsg.pipelineClear;
auto q = arg;
if (app.uiMsg.isActive())
    app.openPipelineTurnTyped(q);
app.sendChatMessage("assistant: Running coder pipeline: %s", q);
...
app.sendChatMessage(i"assistant: $(prettyPrint(result))".text);
if (app.uiMsg.isActive())
    app.closePipelineTurnTyped(result.wasInterrupted);
```

(`/plan` closes with `false`; `/code`'s interrupted branch closes `true` before
its early return.)

### Verification
- [ ] `dub build --config=application` clean.
- [ ] The recording-sink test (`source/llm/app_agent/tests.d`, extend - the
      `TuiRecordingSink` pattern at `ui.d:223-400`): `openPipelineTurnTyped("q")`,
      two `sendChatMessage` calls, `closePipelineTurnTyped(false)` -> the
      notices' turnId equals the opened turn's id, the query block exists on
      that turn, the final turn upsert is `Done`.
- [ ] The stopped path: `closePipelineTurnTyped(true)` -> the `Cancelled` /
      `Interrupted` flips (`emitStopTyped`, `:1158-1167` unchanged).
- [ ] The close no-ops without an open turn (`typedCtx_ is null`).
- [ ] The chat history is unchanged by the bracket (no new entry - the turn is
      display-only), and `chatDirty` stays false.
- [ ] `dub test` green.
- [ ] Regression: the overview's regression command passes.

### Notes
- `emitRunEndedTyped` (`:1195-1212`) is deliberately *not* reused for the
  non-stopped close: with no Answer block the close would land `Interrupted`,
  mislabelling a successful pipeline run. Re-verify its body before wiring
  (stop-and-re-plan if it has grown runAgent-only coupling).
- `beginNewTurn` (`source/llm/chat.d:74-77`) exists for exactly this shape of
  turn start; the counter high-water mark persists in the session header, so
  the display-only turn never collides after a reload.
- Accepted limitation (DD-22): the pipeline turn is lost on session reload. The
  alternative - an `addUserQuery`-style history entry - would feed pipeline
  queries into the main agent's LLM context.
- The console path is unchanged: the bracket's sends are gated on
  `uiMsg.isActive()`, like `runAgent`'s (`:974`).

Plan pointers:
- DD-22, FR-26; `plan/requirements_notes.md` (follow-up wave).
- Anchors verified at plan time against the current tree; re-verify before each edit.
