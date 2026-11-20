## Task 13: C++ view - header composition, folded role word, FAIL, disclosure

Priority: P0. Dependencies: Task 9, Task 12.

### Description
One width-aware header composer for both profiles: label -> duration -> chips, chips dropped one
token at a time from the right before the duration, the label never dropped; a folded owner drops
the role word; `FAIL` paints from `failedCalls`; the owner draws a disclosure mark.

### Changes Made
- `cpp_tui/views/blocks.h:143` (edit): the signature gains the metrics and the width.
- `cpp_tui/views/blocks.cpp:39-43` (edit): `separator(const ui::Metrics& m)` reads `m.textGrid`.
- `cpp_tui/views/blocks.cpp:189-239` (rewrite): `blockHeaderText(block, draw, m, availUnits)`.
- `cpp_tui/views/blocks.cpp:304-333` (`renderBlock`, edit): `blockHasDisclosure(block)` (`:308`),
  the header call with the row width (`:327`), FAIL from `failedCalls` (`:329-333`).
- `cpp_tui/test_blocks.cpp:264-266` + `:590` (edit), `cpp_tui/test_streaming.cpp:381-385` +
  `:709-721` (edit): the call sites pass `ui::metricsFor(textGrid, 1.0f, 1.0f)` and a width.

```cpp
// views/blocks.h
/// The row's header text, fitted to `availUnits` in the profile's own unit
/// (`ui::textUnits`). Order: label -> duration -> chips. A folded batch owner drops the
/// role word (FR-8). Chips drop one token at a time from the right before the duration
/// does; the label never drops.
std::string blockHeaderText(const BlockView& block, const BlockDraw& draw, const ui::Metrics& m,
                            float availUnits);
```

```
// The composer (design §7.4, DD-8, DD-18, FR-8, FR-13):
parts = []
if !block.ownsBatch or draw.expanded: parts += label()      # a folded owner has no role word
if block.timingS > 0:                 parts += timing(block.timingS)
if !block.chips.empty():              parts += chips(block.chips)

while textUnits(m, join(parts, sep(m))) > availUnits and chipsRendered > 1:
    drop the rightmost rendered chip; N += 1; rebuild the chips text ("+N" past the last one)
if still too wide and parts has a timing: drop the timing
return join(parts, sep(m))            # sep = " - " on the grid, " · " in the pixel profile
```

```
// Chips fitting, worked (grid, 40 cells):
//   "[bash] [grep] [read_file] +2"  -> too wide
//   "[bash] [grep] +3"              -> still too wide
//   "[bash] +4"                     -> fits            (never fewer than one chip)
// "Thinking" carries neither a count nor a duration (DD-8): label, then chips if any.
```

### Verification
- [x] `make test_blocks test_streaming > build.log 2>&1` clean.
- [x] Grid: `YOU - 1.2 s` and pixel `YOU · 1.2 s` (the separator pins stay).
- [x] Owner, open: `AGENT - 3.2 s - [bash] [grep]`; owner, folded: `3.2 s - [bash] [grep]` (no
      role word, FR-8).
- [x] 40 units, both profiles: `AGENT - 3.2 s` fits; `AGENT - 3.2 s - [bash] [grep] [read_file]`
      fits to `AGENT - 3.2 s - [bash] [grep] +1`; a 10-unit row drops the timing and keeps the
      label. Assert the exact strings with `ui::metricsFor(true/false, 1.0f, 1.0f)`.
- [x] `Thinking` header is the bare word (no count, no duration); `blocks-*` scenes where a
      `Thinking` row carried a duration regolden (the duration is on the owner now).
- [x] `FAIL`: an owner with `failedCalls > 0` paints `FAIL` after its fitted text in
      `stateDanger`; a card with `state == Failed` still paints it; no other state paints.
- [x] An owner draws the disclosure mark (`v`/`>`), in `textLow` (focused: `accent`), exactly
      where a WorkGroup/Thinking row draws it.
- [x] Regression: the overview's regression command passes.

### Coder deviations
- The six task-06a staged needles were re-keyed from the ASCII art legend (`> `, `v `) to the
  pinned glyph set (`ui::icon(..., ui::GlyphSet::Glyphs)`): the run sets `LLMFUN_ASCII=0`, so the
  grid draws the real marks and the legend strings could never match. The shape assertions are
  exactly as strong - only the needles changed.
- `availUnits` is the row width minus the mark/rule column the text starts after
  (`header.w - (penX - pos.x)`): the composer fits what the renderer will actually draw into.
- `ui::textUnits` is not a public symbol - `ui/text.h` deliberately does not reach for
  `CalcTextSize`, which is why every view carries a copy of the measure. `blocks.cpp` carries
  the same local copy (the per-view cost the layering rule names) instead of widening the
  primitive header.
- The tool cards keep their early-return header shape and do not run the fitting loop: they
  hold no chips, so there is nothing to fit.
- The closed preview stays outside the fitting measurement and keeps its two-space join: it is
  the one thing the row says about a hidden body, and a truncated composer would take the row's
  meaning with it.
- `FAIL`'s offset measures with the profile's own unit measure (as the notes require) rather
  than `displayWidth * gu` - pixel-profile exact, golden-neutral (all goldens are grid).
- The staged maxchips needle needed the group pinned open inside the check's own fixture: a
  folded group draws its header only, so the folded owner row was unreachable as staged. The
  pinned-open check reads the owner the way a settled batch folds; the maxchips golden is
  untouched.
- `checkHeaderText` gained composer/fitting checks beyond the task's literal list (owner
  open/folded, the 40-unit and 10-unit fits, the one-chip floor, the pixel separator and order):
  the verification box demands the exact strings.
- `checkHeaderText` gained composer/fitting checks beyond the task's literal list (owner
  open/folded, the 40-unit and 10-unit fits, the one-chip floor, the pixel separator and order):
  the verification box demands the exact strings.

### Review round (task 13 review: approve with one fix)
- Review F1 (the fix): the chips now draw in `textMid` (C8's quiet ink). The composer returns a
  `HeaderRuns` (the text plus the chips run's byte offsets) and `renderBlock` draws three runs - the
  label/timing and what follows the chips in the role ink, the chips run in `textMid` - each offset by
  the same `textUnits` measure the FAIL word uses. `maxlive`, `maxlonglive` and `maxnotice` regolden:
  the chips spans change ink runs only, no text line moves.
- Review M1: `splitChips` counts a token as the dropped batch only when it is `+<digits>` (a chip
  named `+x` stays a shown chip), and a chips string of only whitespace composes no chips part at
  all (no dangling separator in the join).
- Review M2, recorded as accepted: the fit does not reserve room for the `FAIL` word, so a failed
  owner whose fitted header fills the row can push `FAIL` past the clip. This is the failed cards'
  pre-existing shape; the review offers record-or-fix, and this records it.

### Notes
- The metrics argument is what keeps `-` on the grid and `·` in the GUI: do not reintroduce a
  `bool textGrid` parameter, and do not measure with `displayWidth` (that is a cell count; the
  pixel profile would disagree with the renderer).
- `measureBlockHeader` needs no width: a header is one row tall (a compact row's second line is
  not a header row).
- Ink per design C8: owner label `roleAgent`, chips `textMid`, `FAIL` `stateDanger`, the
  disclosure mark `textLow` / `accent` when focused.

Plan pointers:
- DD-8, DD-18, FR-8, FR-9, FR-13, FR-23, C8, C9a; overview open issues 1 and 3.
- Anchors were verified at plan time; re-verify before each edit.
