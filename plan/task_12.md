## Task 12: C++ view - the body segment

Priority: P0. Dependencies: Task 11.

### Description
Draw a batch's content as a header-less segment: the body directly, at the batch indent, with no
header measure, no hit box, no menu, no copy chip and no `expanded` of its own.

### Changes Made
- `cpp_tui/views/thread.cpp:562-600` (`drawRow`, edit): a segment branch before the header path.

```cpp
// A body segment (DD-7, I-11): no header, so no measure, no InvisibleButton, no menu, no copy
// chip and no `expanded` read. The body is the row, at the batch indent (the same pad2 the
// batch's cards take), and the renderer owns its height.
if (desc.bodySegment) {
    ImGui::Indent(m.pad2);
    ui::Rect body;
    body.x = ImGui::GetCursorScreenPos().x;
    body.y = ImGui::GetCursorScreenPos().y;
    body.w = std::max(0.0f, ImGui::GetContentRegionAvail().x);
    body.h = 0.0f;               // the renderer measures what it draws
    body.cells = m.textGrid;
    thread.renderBlockBody(index, b, body);   // markdown, tables, selection: the one path
    ImGui::Unindent(m.pad2);
    return true;
}
```

### Verification
- [x] `make test_blocks test_streaming > build.log 2>&1` clean.
- [x] A segment draws no header text, no disclosure mark, no `Copy` chip, and does not take the
      focus on a click (its area is body text, not a row hit box).
- [x] The pixel profile keeps mark-and-copy: selecting text inside a segment is rich_md's own
      selection (`renderBodyText`), unchanged.
- [x] `measureBlockHeader` is never called for a segment (assert by a counter in the test, or by
      the row height: the segment's drawn height equals the body's, not `m.row`).
- [x] The body indent equals a card's (`m.pad2`), so a batch's content and cards share one rail.
- [x] `test_streaming.cpp:359-370` (`streamBodyRow`, a predicate scan) still finds the segment.
- [x] Regression: the overview's regression command passes.

### Coder deviations
- The sample's `Indent(m.pad2)` is conditional on the row loop's `child` answer, and the
  no-owner case indents by the mark column (`m.gu`) instead of nothing: under its owner the
  segment takes the batch's `pad2` (C10, the cards' rail), while the minimal live tail's
  segment draws with no owner row on screen (FR-5) and takes the turn-level indent the
  query body reads at (§4.6's art). The unconditional `pad2` would push the no-owner
  segment one step past the turn's text column, and no indent at all would leave it on
  the group's edge (review round 1, F1 - option (a) chosen, the design-conformant shape).
  The goldens the no-owner shape moves (`blocks-answerchip`, `blocks-answerlanded`,
  `streaming-live/cancelled/table/fence`, 100x30) are regoldened here, each diff the
  one-column shift of the segment body and its inks.
- `copyBlock` drops its `desc` parameter: the copy-through-owner wiring reads the text
  and the code answer from the adapter (`blockText`/`blockCopyIsCode`), so the
  descriptor carried nothing the call site does not already hold.
- `copyBlock`'s "What reaches the clipboard" paragraph sits inside the `///` block.
- `blockCopyIsCode`'s non-owner path answers the block's own `code` fact, so any
  non-owner row whose body is one fenced block copies fence-less - a User query
  included - not just the batch content strip S-13 names. Kept: a code block is a
  body shape, not a role (`views/blocks.cpp:124`), and the re-keyed `Assistant`
  case pins the owner path. Recorded here instead of narrowed.

### Notes
- FR-16's "reach the text through the owner" is task_09's `copyable`/`blockText` pair: the
  segment itself is not a copy target, and the grid gains no selection (the terminal owns
  `Ctrl+C`).
- An *empty* body never reaches here: the projection dropped it (task_08).

Plan pointers:
- DD-7, I-11, FR-16, C10, §7.3.3.
- Anchors were verified at plan time; re-verify before each edit.
