# TUI System — Implementation Description

## Overview

The llmfun TUI is a terminal-based user interface built in C++17 on top of the **imtui** library (a terminal-based ImGui wrapper at `llmfun/vendor/imtui`). It provides a full-screen, three-region layout for interacting with an LLM: a scrollable output area, a multiline input area, and a status line. The TUI is self-contained in the `llmfun/cpp_tui/` directory with four source files.

## File Structure

```
llmfun/cpp_tui/
├── CMakeLists.txt   # Build configuration (CMake 3.10+, C++17)
├── main.cpp         # Entry point, initialization, main event loop (~53 lines)
├── tui.h            # TuiState struct and public API declarations (~79 lines)
└── tui.cpp          # All TUI logic: render, theme, init/shutdown, data feeds (~302 lines)
```

## Architecture

### Three-Region Layout

The terminal is divided vertically into three fixed-position regions:

```
┌──────────────────────────────────────────────┐  ← y=0
│                                              │
│           OUTPUT DISPLAY AREA                │
│         (scrollable child window)            │
│                                              │
│                                              │
│                                              │
├──────────────────────────────────────────────┤  ← y=H-3
│  > User input line 1                         │
│    User input line 2 (multiline)             │
├──────────────────────────────────────────────┤  ← y=H-1
│  Context: 0/0 tokens | Model: none | Ready   │
└──────────────────────────────────────────────┘  ← y=H
```

| Region | Position | Height | ImGui Widget |
|--------|----------|--------|--------------|
| Output area | `(0, 0)` | `DisplaySize.y - 3` | `BeginChild("output", ...)` with `HorizontalScrollbar` |
| Input area | `(0, H-3)` | `2` rows | `BeginChild("input", ...)` containing `InputTextMultiline` |
| Status line | `(0, H-1)` | `1` row | `BeginChild("status", ...)` with all decorations disabled |

All windows use `ImGuiCond_Always` for stable positioning. Minimum terminal size is **40 columns × 15 rows**; below this, an error message is rendered instead of the normal UI.

### State Management

All TUI state is encapsulated in a single `TuiState` struct (non-copyable, non-movable due to `std::mutex`):

```cpp
struct TuiState {
    std::deque<std::string> outputLines;   // Bounded output (deque for O(1) FIFO eviction)
    static constexpr size_t MAX_OUTPUT_LINES = 10000;

    bool autoScroll = true;                // Auto-scroll flag (main-thread-only)

    std::string inputBuf;                  // Dynamic input buffer
    std::string draftBuf;                  // Saved input when navigating history

    bool submitReady = false;              // Submission flag

    std::vector<std::string> inputHistory; // Input history
    int historyPos = -1;                   // History navigation cursor
    static constexpr size_t MAX_HISTORY = 500;

    std::string statusText;                // Status line text

    mutable std::mutex outputMutex;        // Protects: outputLines, statusText, inputBuf, submitReady
};
```

Key design decisions:
- **`std::deque`** for `outputLines` (was `std::vector` in the original plan) for O(1) FIFO eviction at the front.
- **`draftBuf`** field added beyond the original plan to preserve the current input when entering history navigation, allowing full restore when navigating back past the newest history entry.
- **Mutex scope**: Only `outputLines`, `statusText`, `inputBuf`, and `submitReady` are mutex-protected. `autoScroll`, `historyPos`, `draftBuf`, and `inputHistory` are main-thread-only and unlocked for performance.

## Public API

All API functions are declared in `tui.h` and implemented in `tui.cpp`:

| Function | Description | Thread-safe |
|----------|-------------|-------------|
| `tuiInit(ImTui::TScreen** screen)` | Initialize terminal, ImGui context, and dark theme | — |
| `tuiShutdown(ImTui::TScreen* screen)` | Clean up all resources | — |
| `tuiRender(TuiState& state)` | Render one frame; returns `false` to exit | — |
| `tuiAddOutputLine(TuiState&, const string&)` | Append line with FIFO eviction | Yes (mutex) |
| `tuiClearOutput(TuiState&)` | Clear all output lines | Yes (mutex) |
| `tuiSetStatusText(TuiState&, const string&)` | Set status line text | Yes (mutex) |
| `tuiGetInput(const TuiState&)` | Get current input buffer | Yes (mutex) |
| `tuiClearInput(TuiState&)` | Clear input buffer | Yes (mutex) |
| `tuiIsSubmitReady(const TuiState&)` | Check if input is ready to submit | Yes (mutex) |
| `tuiResetSubmit(TuiState&)` | Reset submission flag | Yes (mutex) |

## Main Event Loop (`main.cpp`)

The entry point follows a standard ImGui frame loop:

1. **Initialization**: Call `tuiInit()`, create `TuiState`, set initial status text and welcome message.
2. **Frame loop**:
   - `ImTui_ImplNcurses_NewFrame()` + `ImTui_ImplText_NewFrame()` + `ImGui::NewFrame()`
   - `running = tuiRender(state)` — renders all three regions, handles keyboard shortcuts
   - **Submission check**: If `tuiIsSubmitReady(state)`, extract the query via `tuiGetInput()`, echo it to output as `> query`, clear input, and reset submit flag
   - `ImGui::Render()` + `ImTui_ImplText_RenderDrawData()` + `ImTui_ImplNcurses_DrawScreen()`
3. **Shutdown**: Call `tuiShutdown(screen)` on exit.

## Render Function Details (`tuiRender`)

### Keyboard Shortcuts

| Shortcut | Action | Condition |
|----------|--------|-----------|
| `Ctrl+C` | Exit TUI (return `false`) | Anywhere |
| `Ctrl+D` | Exit TUI (return `false`) | Anywhere |
| `Ctrl+L` | Clear output area | Only when no widget has focus |
| `End` | Scroll to bottom, re-enable auto-scroll | Anywhere |
| `Escape` | Clear input buffer | Input widget active |
| `Ctrl+Up` | Navigate backward in input history | Input widget active |
| `Ctrl+Down` | Navigate forward in input history | Input widget active |

Note: History navigation uses `Ctrl+Up`/`Ctrl+Down` instead of plain `Up`/`Down` to avoid conflicting with `InputTextMultiline`'s internal cursor movement.

### Output Area

- Renders inside a `BeginChild("output")` with `ImGuiWindowFlags_HorizontalScrollbar`.
- **Lock-minimization**: Copies `outputLines` to a local vector under mutex, then renders from the copy without holding the lock. This eliminates deadlock risk from ImGui internals calling back into the TUI API.
- **Auto-scroll**: Automatically follows new content when `autoScroll` is `true`. Manual scroll (scrolling up) disables auto-scroll. Pressing `End` re-enables it.
- Auto-scroll detection compares `GetScrollY()` against `GetScrollMaxY() - 1.0f`.

### Input Area

- Uses `ImGui::InputTextMultiline` with a dynamic `std::string` buffer and a resize callback (`InputResizeCallback`, a static function rather than a per-frame lambda).
- **Resize callback**: Implements the standard `imgui_stdlib` pattern — on `ImGuiInputTextFlags_CallbackResize`, resizes the string and updates `data->Buf`.
- **Buffer safety**: Ensures `inputBuf` is non-empty before passing to `InputTextMultiline` to prevent buffer over-read/write before the resize callback fires.
- **Buffer size**: Passes `state.inputBuf.size() + 1` (for null terminator), following standard ImGui patterns.
- **History navigation**:
  - On first `Ctrl+Up`: saves current input to `draftBuf`, pushes it to `inputHistory` (if not duplicate of last entry), then navigates to the entry before it.
  - `Ctrl+Down` walks forward; past the end restores `draftBuf` and resets `historyPos` to -1.
  - On submission: pushes input to history if non-empty, not a duplicate, and not currently in history navigation (`historyPos == -1`).
  - History is bounded to `MAX_HISTORY` (500) entries with FIFO eviction.

### Status Line

- A child window with all decorations disabled (`NoCollapse`, `NoResize`, `NoMove`, `NoTitleBar`, `NoScrollbar`, `NoScrollWithMouse`).
- Falls back to a default status string (`"Context: 0/0 tokens | Model: none | Ready"`) if `statusText` is empty.

## Theme

The `applyTheme()` function starts with `ImGui::StyleColorsDark()` as a base, then overrides specific colors:

| Color Slot | Value | Purpose |
|------------|-------|---------|
| `Text` | `(0.90, 0.90, 0.90, 1.00)` | Light gray text |
| `TextDisabled` | `(0.50, 0.50, 0.50, 1.00)` | Dimmed text |
| `WindowBg` | `(0.06, 0.06, 0.06, 1.00)` | Near-black background |
| `ChildBg` | `(0.06, 0.06, 0.06, 0.00)` | Transparent child bg |
| `Border` | `(0.20, 0.20, 0.20, 1.00)` | Subtle borders |
| `FrameBg` | `(0.16, 0.16, 0.16, 1.00)` | Input frame background |
| `FrameBgHovered` | `(0.26, 0.26, 0.26, 1.00)` | Hovered frame |
| `FrameBgActive` | `(0.26, 0.59, 0.98, 0.65)` | Blue highlight when active |
| `ScrollbarBg` | `(0.05, 0.05, 0.05, 0.54)` | Dark scrollbar background |
| `ScrollbarGrab` | `(0.34, 0.34, 0.34, 0.54)` | Scrollbar grab handle |

## Initialization & Shutdown

### `tuiInit()`
1. Calls `IMGUI_CHECKVERSION()` and `ImGui::CreateContext()`.
2. Applies dark theme via `applyTheme()`.
3. Initializes ncurses backend with mouse support enabled, active FPS at 60.0, idle FPS at 3.0 (CPU saving).
4. Initializes text renderer backend.
5. Returns `false` with error message on failure, cleaning up the ImGui context.

### `tuiShutdown()`
1. Shuts down text renderer (if screen is non-null).
2. Shuts down ncurses backend (if screen is non-null).
3. Destroys ImGui context.

## Build System

The `CMakeLists.txt` uses CMake 3.10+ with C++17:
- Brings in imtui as a subdirectory (`add_subdirectory(../vendor/imtui ...)`).
- Disables shared libraries, curl support, and imtui examples to match the `imtui.mak` build.
- Links the `llmfun_tui` executable against `imtui-ncurses` and `Threads::Threads`.
- No explicit `target_include_directories` needed — `imtui-ncurses` transitively provides the public include path.
