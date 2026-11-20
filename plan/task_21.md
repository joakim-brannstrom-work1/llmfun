## Task 21: Documentation

Priority: P1. Dependencies: Task 19.

### Description
Write the modes chapter the code now implements: the glossary, the fold, the one visibility rule,
the live edge, pins and anchors - and replace stale `file:line` anchors with symbol names.

### Changes Made
- `llmfun/doc/tui_design.md` (edit): new chapter "Thread modes: the response-owned fold"
  (§§ below), and the thread/block sections updated where they describe the old fold.
- `llmfun/doc/todo.md` (edit): the remainder (R-9's single lifetime, the grid-copy decision of
  task_26, any check left unwritten).
- `llmfun/doc/ui_keys.md` (edit): the "Collapse all" palette row from task_24, if task_24 lands
  first.

```
## Thread modes: the response-owned fold
1. Vocabulary: turn, response, batch, owner row, child, body segment, settled, live tail, pin,
   live edge. Two profiles (grid `" - "`, pixel `" \xC2\xB7 "`).
2. The fold: groupOpen = groupPins ?? (maximal && turnLive); styleIsMinimal = minimal &&
   !groupOpen; ownerOpen = rowPins ?? batchLive; a settled batch folds to
   "> <duration> - [chips]".
3. Visibility (the one rule): ownerVisible = groupOpen; childVisible = ownerVisible &&
   ownerOpen; the content segment = that OR (minimal-style && live && newest); a plain row
   follows its group. The view draws iff `visible` and keeps no exception list.
4. The live edge: chips while a call runs / the Thinking shadow while reasoning streams, in
   minimal style and for the newest group only.
5. Pins are absolute and session state; pruned with their turn and by "Collapse all".
6. Anchors and hints: the group header is the anchor; the height hint is an estimate and does
   not move with the fold.
```

### Verification
- [ ] `dub test` and the C++ suite unchanged (docs-only task, but the suite must be green).
- [ ] The chapter's rule text is *quoted from* `store/thread_store.cpp`'s predicate (same names:
      `groupOpen`, `groupStyleIsMinimal`, `ownerVisible`, `ownerOpen`, `segmentVisible`).
- [ ] Every `file:line` reference in the new chapter is a symbol instead; a grep for `\.cpp:[0-9]`
      in the new chapter is empty.
- [ ] `doc/todo.md` names R-9, task_26's decision and the "40-column pass" note (overview open
      issue 3).
- [ ] The chips art in the doc uses the shipped notation (`[bash] [grep]`, `+N`), not the
      investigation's `[bash, grep]`.
- [ ] Regression: the overview's regression command passes.

### Notes
- Do not restate the design document: the *code* is the authority now, and the chapter should be
  readable by someone who has never seen `plan/`.
- The investigation (`plan/maximal_investigation.md`) stays as the record of the old behaviour; the
  new chapter says so in one line.

Plan pointers:
- C14, §10.1/§10.2; overview open issues 1 and 3.
- Anchors were verified at plan time; re-verify before each edit.
Plan pointers:
- C14, §10.1/§10.2; overview open issues 1 and 3.
- Anchors were verified at plan time; re-verify before each edit.

### Coder deviations

1. `doc/ui_keys.md` NOT touched: its "Collapse all" palette row is task_24's
   deliverable and task_24 has not landed (the task's edit is conditional on
   "if task_24 lands first").
2. The sketch's pin line "pruned with their turn and by 'Collapse all'" would
   document unbuilt behaviour (task_24 owns both). The chapter states what the
   code does - pins go with the thread on clear/session switch - and
   `doc/todo.md` carries the pruning + "collapse all" remainder instead.
3. The visibility rules are quoted from the projection's actual shape
   (`resolveVisible`'s clauses, named ownerVisible/ownerOpen/segmentVisible as
   the code's comments name them); the owner's live default is spelled with
   the code's `batchLiveFor`/`childLiveFor` split (the sketch's single
   "batchLive" line conflates the two: a child folds on `!allSettled` alone).
4. The chapter names `plan/maximal_investigation.md` as the old fold's record
   (one line, per the task's Notes) - the doc already references `plan/` paths
   (key_gate.md), so this follows the file's convention.
5. The chapter documents behaviour, not the test list: the pinned §10.3 check
   texts stay in `test_blocks.cpp` (the doc names no check strings).

## Review round (2026-11-19): ACCEPT WITH ONE FIX — applied, commit pending

- F1 (Important, pins pruning): `tuiTurnRemove` does prune the removed turn's
  rowPins/groupPins (tui_api.cpp:917-925, "The turn's pins die with the turn")
  — the chapter's "future work" claim and todo.md:81 were wrong. Fixed both:
  the chapter now says a removed turn takes its pins with it (`tuiTurnRemove`)
  and only eviction-time pruning + "collapse all" are future work; todo.md's
  pin-hygiene line states turnRemove/thread-clear pruning and the eviction gap.
- M1: one line added above the visibility block — the group's header row and
  the turn's query/answer rows always draw; the segment clause is the content
  segment only (resolveVisible:964-965 hard-codes the header true, the
  turn-level rows 826-828, the segment kind guard 982).
- M2: the folded-header bullet now says the disclosure mark and FAIL are drawn
  around composeBlockHeader's text (renderBlock/ui::iconMark/after-fit), the
  duration and chips in it.
- M3 (labels): taken doc-side — the chapter now names ownerVisible/plainVisible
  as the projection's comment names, ownerOpen its local, childVisible/
  segmentVisible labels used here for resolveVisible's two tail clauses (the
  reviewer's "labels used here" option; no code comments changed).
5. The chapter documents behaviour, not the §10.3 check list.

## Review round (2026-11-19): ACCEPT WITH ONE FIX — applied

- F1 (Important): the pins text misstated pruning — `tuiTurnRemove` DOES prune
  the removed turn's rowPins/groupPins (tui_api.cpp:917-925, "The turn's pins
  die with the turn", carried over from task 10's groupOverrides.erase). Fixed
  both files: the chapter now reads "…both go with the thread on a clear or a
  session switch, and a removed turn takes its pins with it (`tuiTurnRemove`).
  Pruning the pins of an evicted turn and a 'collapse all' affordance are
  future work"; todo.md's pin-hygiene line reads "pins die with the turn on
  turnRemove and with the thread (clear / session switch); eviction does not
  prune the evicted turn's pins and a 'collapse all' affordance is not
  implemented".
- M1: one line added above the visibility block — the group's header row and
  the turn's query/answer rows always draw; the segment clause is the content
  segment only (the block omitted resolveVisible's hard-coded-true header and
  turn-level rows and the segment's kind == Assistant guard).
- M2: the folded-header bullet reworded — the disclosure mark and FAIL are
  drawn around composeBlockHeader's text (renderBlock), the duration and tool
  chips are in it.
- M3 (labels): taken doc-side per the reviewer's "labels used here" option —
  the chapter now states ownerVisible/plainVisible are the projection's
  comment names, ownerOpen its local, childVisible/segmentVisible labels used
  here for resolveVisible's two tail clauses. No code comments changed.
- M4: todo.md:79 now names "(task 26)".
- M3's other option (adding the names to resolveVisible's comments) left to a
  later test-only commit if wanted.
- Docs-only diff (doc/tui_design.md, doc/todo.md); no code, test or golden
  change, so the suite gates stand as run for the task commit.
