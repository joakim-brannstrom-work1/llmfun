## Task 14: C++ view - minimal draws the live content with no owner on screen

Priority: P0. Dependencies: Task 12.

### Description
The regression fix: in minimal, the newest live batch's content segment draws under the folded
group header even though no owner row is drawn, and it stops drawing when the turn closes.

### Changes Made
- `cpp_tui/views/thread.cpp` (no new branch expected): the segment path from task_12 plus the
  adapter's `segmentVisible` clause are the whole feature; this task is the proof and the
  regoldens.
- `cpp_tui/test_blocks.cpp:1024-1031` (edit): the two assertions that minimal *hides* the
  streamed prose flip to the new truth (a live, newest batch draws its content; an older or
  settled one does not).
- `cpp_tui/test/golden/streaming-live-100x30.txt` and the minimal `blocks-*` scenes that carry a
  live content row (regolden here, with the reason).

```cpp
// The case the design exists for (FR-5, FR-21, C7): the segment draws while its owner row does
// not. Both facts are the adapter's - the view only obeys `visible`:
//   ownerVisible == false (minimal-style fold)  &&  segmentVisible == true (newest, live batch)
// Pin it explicitly, not by reading a screen for a substring:
check(!thread.blockAt(group, ownerRow).visible, "no owner row is drawn in minimal's folded group");
check(thread.blockAt(group, segmentRow).visible, "but the live batch's content still draws");
```

### Verification
- [x] `make test_blocks test_streaming > build.log 2>&1` clean.
- [x] The explicit pair above: owner invisible, segment visible, in the same frame.
- [x] The segment disappears when the turn closes (same fixture, `runStop()` -> invisible), and
      when a newer batch starts (the old segment folds with its batch).
- [x] `streaming-live-100x30.txt` shows the text: the regression is pinned by a golden, not only
      by a check.
- [x] An *opened* minimal group draws the segment inside the open owner (both visible), and not
      twice.
- [x] `blocks-*` minimal scenes regoldened; `./test_blocks` green.
- [x] Regression: the overview's regression command passes.

### Coder deviations
- The two flipped assertions the plan names at `test_blocks.cpp:1024-1031` already landed in the
  task-12 round (the plan's line numbers were plan-time; the live checks now read `checkStreaming`
  at the `STREAM-PROSE` block). This task adds what was still missing: the explicit `blockAt` pair
  (owner invisible / segment visible in one frame), the opened-group pin (both visible, drawn once)
  and the two lifetime checks (a newer batch folds the old segment; `runStop()` folds the last one).
- No golden moved: `streaming-live-100x30.txt` and the minimal `blocks-answerchip-100x30.txt` already
  carry the live prose since task 12's regolden - verified green as-is, no `--update` run.
- The two lifetime checks run on a fresh fixture, not the walked one: the copy walk above them leaves
  row pins on the `both` fixture, and a pin would give the fold a second cause (the check would pass
  for the wrong reason). The fresh fixture answers the predicate alone.
- Row selection is by kind predicate (`ownsBatch` / `bodySegment`), never by number - the
  projection's indices move with every insertion (the plan's cross-cutting rule).
- Suites: `test_blocks` 478/0 (was 469; +9 checks), `test_streaming` 91, `test_thread_window` 125,
  `test_typed_thread_store` rc 0, `test_thread_anchor` rc 0, `test_palette` rc 0, `test_thread_view` OK,
  `dub test` 1111 passed / 0 failed.

### Review round (ACCEPT, commit 1515030)
- Item 1 applied: the lifetime comment's change-log phrasing rewritten - "the newest-only
  clause moved to the new response" became "(the newest-only clause lives in the newer
  response)", the semicolon splice became a dash clause, and the plan-artifact citation
  ("the sign-off this task records") dropped; `(R-9)` stays (the file's requirement-id
  baseline). Comment-only, 6 lines; `test_blocks` still 478/0.
- Item 2 (the duplicated owner/segment scan) left as-is: the reviewer notes test-code
  duplication is consistent with this file's style, and the two sites pin different
  frames (folded vs opened) - a shared helper would couple them for no third caller.
- Item 3 (combined conjunct message) left as-is: `blockAt` answers a default `BlockDesc`
  (visible=false) out of range, so a failed shape pin degrades to a check failure, and
  the neighbouring single-conjunct checks already name the failing half.

### Notes
- Sign-off R-9 lives here: in maximal the content folds with its batch, in minimal it stays until
  the turn closes. One predicate line changes it if the user prefers a single lifetime - do not
  decide it in this task.
- The old assertion at `test_blocks.cpp:1025` ("and the streamed prose - the live edge is the
  fold's") is the D7 regression in test form; rewrite its comment, do not delete the test.

Plan pointers:
- DD-10, FR-5, FR-21, I-11, C7, R-9; design §4.6's minimal art.
- Anchors were verified at plan time; re-verify before each edit.
