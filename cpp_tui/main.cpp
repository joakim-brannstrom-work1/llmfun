#include "tui_api.h"

#include <cstdio>
#include <cstring>
#include <string>

/* Helper: build a String from a null-terminated C string literal. */
static inline String makeStr(const char* s) { return String{s, std::strlen(s)}; }

int main() {
    TuiScreen* screen = nullptr;

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

    TuiState* state = tuiCreateState();
    if (!state) {
        std::fprintf(stderr, "Failed to create TUI state.\n");
        tuiShutdown(screen);
        return 1;
    }

    tuiSetStatusText(state, makeStr("Context: 0/0 tokens | Model: none | Ready"));
    tuiAddOutputLine(state, makeStr("llmfun TUI - type your query below"));
    tuiAddOutputLine(state, String{"", 0});

    while (true) {
        tuiBackendNewFrame();

        if (tuiRender(state) == 0)
            break;

        if (tuiIsSubmitReady(state) != 0) {
            String query = tuiGetSubmitQuery(state);
            if (query.data && query.len > 0) {
                std::string display("> ");
                display.append(query.data, query.len);
                tuiAddOutputLine(state, String{display.c_str(), display.size()});
            }
            tuiAddOutputLine(state, String{"", 0});
            String_Free(query);
            tuiResetSubmit(state);
        }

        tuiBackendRender(screen);
    }

    tuiDestroyState(state);
    tuiShutdown(screen);
    return 0;
}
