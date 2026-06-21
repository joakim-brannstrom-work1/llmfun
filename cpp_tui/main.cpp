#include "tui_api.h"

#include <cstdio>
#include <cstring>
#include <string>

/* Helper: build a String from a null-terminated C string literal. */
static inline String makeStr(const char* s) { return String{s, std::strlen(s)}; }

int main() {
    TuiScreen* screen = nullptr;

    /* Initialize TUI */
    screen = tuiInit();
    if (!screen) {
        std::fprintf(stderr, "Failed to initialize TUI. Check terminal compatibility.\n");
        String err = tuiLastError();
        if (err.data && err.len > 0) {
            std::fprintf(stderr, "Error: %.*s\n", (int)err.len, err.data);
            String_Free(err);
        }
        return 1;
    }

    /* Initialize state */
    TuiState* state = tuiCreateState();
    if (!state) {
        std::fprintf(stderr, "Failed to create TUI state.\n");
        tuiShutdown(screen);
        return 1;
    }

    tuiSetStatusText(state, makeStr("Context: 0/0 tokens | Model: none | Ready"));
    tuiAddOutputLine(state, makeStr("llmfun TUI - type your query below"));
    tuiAddOutputLine(state, String{"", 0});

    /* Main event loop */
    while (true) {
        /* Begin frame */
        tuiBackendNewFrame();

        /* Render TUI (returns 0 to exit) — break immediately */
        if (tuiRender(state) == 0)
            break;

        /* Check for input submission */
        if (tuiIsSubmitReady(state) != 0) {
            String query = tuiGetSubmitQuery(state);
            if (query.data && query.len > 0) {
                /* Build "> query" via std::string to avoid fixed-size buffer */
                std::string display("> ");
                display.append(query.data, query.len);
                tuiAddOutputLine(state, String{display.c_str(), display.size()});
            }
            tuiAddOutputLine(state, String{"", 0});
            String_Free(query);
            tuiResetSubmit(state);
        }

        /* End frame */
        tuiBackendRender(screen);
    }

    /* Graceful shutdown */
    tuiDestroyState(state);
    tuiShutdown(screen);
    return 0;
}
