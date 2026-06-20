#include "tui.h"

// All functions below acquire state.outputMutex for thread safety.
// outputMutex protects: outputLines, statusText, inputBuf, submitReady.

void tuiAddOutputLine(TuiState& state, const std::string& line) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.push_back(line);
    // Since we add exactly one line, an if suffices.
    if (state.outputLines.size() > state.MAX_OUTPUT_LINES) {
        state.outputLines.pop_front(); // O(1) with deque
    }
}

void tuiClearOutput(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.clear();
}

void tuiSetStatusText(TuiState& state, const std::string& text) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.statusText = text;
}

std::string tuiGetInput(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.inputBuf;
}

void tuiClearInput(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.inputBuf.clear();
}

bool tuiIsSubmitReady(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.submitReady;
}

void tuiResetSubmit(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.submitReady = false;
}
