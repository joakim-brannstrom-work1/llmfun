#include "tui.h"

#include <cstdio>

using namespace llmfun::tui;

int main() {
    ImTui::TScreen* screen = nullptr;

    // Initialize TUI
    if (!tuiInit(&screen)) {
        std::fprintf(stderr, "Failed to initialize TUI. Check terminal compatibility.\n");
        return 1;
    }

    // Initialize state
    TuiState state;
    tuiSetStatusText(state, "Context: 0/0 tokens | Model: none | Ready");
    tuiAddOutputLine(state, "llmfun TUI - type your query below");
    tuiAddOutputLine(state, "");

    bool running = true;

    // Main event loop
    while (running) {
        // Begin frame
        tuiNewFrame();

        // Render TUI (returns false to exit)
        running = tuiRender(state);

        // Check for input submission
        if (tuiIsSubmitReady(state)) {
            std::string query = tuiGetSubmitQuery(state);
            tuiAddOutputLine(state, "> " + query);
            tuiAddOutputLine(state, "");
            tuiResetSubmit(state);
        }

        // End frame
        tuiRenderFrame(screen);
    }

    // Graceful shutdown
    tuiShutdown(screen);
    return 0;
}
