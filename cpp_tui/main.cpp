#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <cstdio>

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
        ImTui_ImplNcurses_NewFrame();
        ImTui_ImplText_NewFrame();
        ImGui::NewFrame();

        // Render TUI (returns false to exit)
        running = tuiRender(state);

        // Check for input submission
        if (tuiIsSubmitReady(state)) {
            std::string query = tuiGetInput(state);
            tuiAddOutputLine(state, "> " + query);
            tuiAddOutputLine(state, "");
            tuiClearInput(state);
            tuiResetSubmit(state);
        }

        // End frame
        ImGui::Render();
        ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen);
        ImTui_ImplNcurses_DrawScreen();
    }

    // Graceful shutdown
    tuiShutdown(screen);
    return 0;
}
