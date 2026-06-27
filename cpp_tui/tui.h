#pragma once

#include <cstddef>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include "imtui/imtui.h"

namespace llmfun::tui {

struct ChatMessage {
    std::string summary;
    std::string text;
};

struct UserQueryState {
    // Dynamic input buffer
    std::string inputBuf;

    // Submission flag
    bool submitReady = false;
    bool isSubmitted = true;
    std::string submitQuery;

    // Input history
    std::vector<std::string> inputHistory;
    int historyPos = -1;
    static constexpr size_t MAX_HISTORY = 500;
};

// Note: This struct is non-copyable and non-movable due to std::mutex.
// Always pass by reference (TuiState&) to avoid accidental copies.
struct TuiState {
    std::deque<ChatMessage> outputLines;
    static constexpr size_t MAX_OUTPUT_LINES = 10000;

    // Auto-scroll flag
    bool autoScroll = true;

    UserQueryState userQuery;

    // Status line text
    std::string statusText;

    // outputMutex protects: outputLines, statusText, inputBuf, submitReady, submitQuery
    // Main-thread-only (no lock needed): autoScroll, historyPos, draftBuf, inputHistory
    mutable std::mutex outputMutex;
};

/// Initialize terminal and create TScreen.
/// Returns true on success, false on failure.
bool tuiInit(ImTui::TScreen** screen);

/// Cleanup and restore terminal state.
void tuiShutdown(ImTui::TScreen* screen);

/// Backend frame wrappers — encapsulate imtui backend details.
/// Call tuiNewFrame() at the start of each frame and tuiRenderFrame() at the end.
void tuiNewFrame();

void tuiRenderFrame(ImTui::TScreen* screen);

/// Render one frame. Returns false to exit.
bool tuiRender(TuiState& state);

/// Add an output line with FIFO eviction if bound exceeded.
/// Thread-safe: acquires outputMutex.
void tuiAddOutputLine(TuiState& state, const ChatMessage& msg);

/// Clear all output lines.
/// Thread-safe: acquires outputMutex.
void tuiClearOutput(TuiState& state);

/// Set the status line text.
/// Thread-safe: acquires outputMutex.
void tuiSetStatusText(TuiState& state, const std::string& text);

/// Get the current input buffer content.
/// Thread-safe: acquires outputMutex.
std::string tuiGetInput(const TuiState& state);

/// Clear the input buffer.
/// Thread-safe: acquires outputMutex.
/// @deprecated Input is now cleared internally by tuiRender() on submission.
void tuiClearInput(TuiState& state);

/// Check if input is ready to be submitted.
/// Thread-safe: acquires outputMutex.
bool tuiIsSubmitReady(const TuiState& state);

/// Reset the submission flag.
/// Thread-safe: acquires outputMutex.
void tuiResetSubmit(TuiState& state);

/// Get the last submitted query (set by tuiRender on Enter press).
/// Returns the captured query text. Thread-safe (mutex-protected).
/// Distinction: tuiGetInput() returns the current editable buffer;
/// tuiGetSubmitQuery() returns the last submitted query (read-only snapshot).
std::string tuiGetSubmitQuery(const TuiState& state);
} // namespace llmfun::tui
