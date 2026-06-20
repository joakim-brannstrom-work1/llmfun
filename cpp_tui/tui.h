#pragma once

#include <cstddef>
#include <mutex>
#include <string>
#include <vector>

#include "imtui/imtui.h"

struct TuiState {
    // Note: This struct is non-copyable and non-movable due to std::mutex.
    // Always pass by reference (TuiState&) to avoid accidental copies.

    // Bounded output display
    std::vector<std::string> outputLines;
    static constexpr size_t MAX_OUTPUT_LINES = 10000;

    // Auto-scroll flag
    bool autoScroll = true;

    // Dynamic input buffer
    std::string inputBuf;

    // Submission flag
    bool submitReady = false;

    // Input history
    std::vector<std::string> inputHistory;
    std::ptrdiff_t historyPos = -1;
    static constexpr size_t MAX_HISTORY = 500;

    // Status line text
    std::string statusText;

    // Thread safety for output
    std::mutex outputMutex;
};

/// Initialize terminal and create TScreen.
/// Returns true on success, false on failure.
bool tuiInit(ImTui::TScreen** screen);

/// Cleanup and restore terminal state.
void tuiShutdown(ImTui::TScreen* screen);

/// Render one frame. Returns false to exit.
bool tuiRender(TuiState& state);

/// Add an output line with FIFO eviction if bound exceeded.
void tuiAddOutputLine(TuiState& state, const std::string& line);

/// Clear all output lines.
void tuiClearOutput(TuiState& state);

/// Set the status line text.
void tuiSetStatusText(TuiState& state, const std::string& text);

/// Get the current input buffer content.
std::string tuiGetInput(const TuiState& state);

/// Clear the input buffer.
void tuiClearInput(TuiState& state);

/// Check if input is ready to be submitted.
bool tuiIsSubmitReady(const TuiState& state);

/// Reset the submission flag.
void tuiResetSubmit(TuiState& state);
