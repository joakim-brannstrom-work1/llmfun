#include "tui_api.h"
#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <set>

namespace llmfun::tui {

/* ------------------------------------------------------------------ */
/*  TuiScreen — concrete implementation of the opaque handle          */
/* ------------------------------------------------------------------ */

struct TuiScreen {
    ImTui::TScreen* screen;
};

/* ------------------------------------------------------------------ */
/*  String ownership tracking                                         */
/* ------------------------------------------------------------------ */

static std::mutex ownedMutex;
static std::set<const char*> ownedPointers;

static void cleanupOwnedStrings() {
    std::lock_guard<std::mutex> lock(ownedMutex);
    for (auto ptr : ownedPointers) {
        std::free(const_cast<char*>(ptr));
    }
    ownedPointers.clear();
}

static struct CleanupRegistrar {
    CleanupRegistrar() { std::atexit(cleanupOwnedStrings); }
} cleanupRegistrar;

String String_New(const char* cstr) {
    if (!cstr)
        return {nullptr, 0};
    return String_New(cstr, std::strlen(cstr));
}

String String_New(const char* data, size_t len) {
    if (!data)
        return {nullptr, 0};
    if (len == 0)
        return {nullptr, 0};
    /* +1 to guarantee null-termination for safe C-string interop */
    char* buf = static_cast<char*>(std::malloc(len + 1));
    if (!buf)
        return {nullptr, 0};
    std::memcpy(buf, data, len);
    buf[len] = '\0';
    {
        std::lock_guard<std::mutex> lock(ownedMutex);
        ownedPointers.insert(buf);
    }
    return {buf, len};
}

void String_Free(String s) {
    if (!s.data)
        return;
    std::lock_guard<std::mutex> lock(ownedMutex);
    auto it = ownedPointers.find(s.data);
    if (it != ownedPointers.end()) {
        ownedPointers.erase(it);
        std::free(const_cast<char*>(s.data));
    }
}

/* ------------------------------------------------------------------ */
/*  Thread-local error handling                                       */
/* ------------------------------------------------------------------ */

static thread_local char lastError[512];
static thread_local bool hasError = false;

static void setLastError(const char* msg) {
    if (msg) {
        std::strncpy(lastError, msg, sizeof(lastError) - 1);
        lastError[sizeof(lastError) - 1] = '\0';
    } else {
        lastError[0] = '\0';
    }
    hasError = true;
}

String tuiLastError() {
    if (!hasError)
        return {nullptr, 0};
    hasError = false; /* consume */
    return String_New(lastError);
}

/* ------------------------------------------------------------------ */
/*  Lifecycle                                                         */
/* ------------------------------------------------------------------ */

TuiScreen* tuiInit() {
    ImTui::TScreen* raw = nullptr;
    if (::llmfun::tui::tuiInit(&raw)) {
        return new TuiScreen{raw};
    }
    setLastError("Failed to initialize TUI terminal");
    return nullptr;
}

void tuiShutdown(TuiScreen* screen) {
    if (!screen)
        return;
    ::llmfun::tui::tuiShutdown(screen->screen);
    screen->screen = nullptr; /* prevent accidental reuse */
    delete screen;
}

TuiState* tuiCreateState() {
    try {
        return new TuiState();
    } catch (const std::bad_alloc&) {
        setLastError("Failed to allocate TUI state (out of memory)");
        return nullptr;
    }
}

void tuiDestroyState(TuiState* state) {
    if (!state)
        return;
    delete state;
}

/* ------------------------------------------------------------------ */
/*  Backend frame / render (main-thread only)                         */
/* ------------------------------------------------------------------ */

void tuiBackendNewFrame(TuiScreen* screen) {
    if (!screen)
        return;
    ImTui_ImplNcurses_NewFrame();
    ImTui_ImplText_NewFrame();
    ImGui::NewFrame();
}

void tuiBackendRender(TuiScreen* screen) {
    if (!screen)
        return;
    ImGui::Render();
    ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen->screen);
    ImTui_ImplNcurses_DrawScreen();
}

/* ------------------------------------------------------------------ */
/*  Rendering                                                         */
/* ------------------------------------------------------------------ */

bool tuiRender(TuiState* state) {
    if (!state)
        return false;
    return ::llmfun::tui::tuiRender(*state);
}

/* ------------------------------------------------------------------ */
/*  Output                                                            */
/* ------------------------------------------------------------------ */

void tuiAddOutputLine(TuiState* state, String line) {
    if (!state)
        return;
    std::string s(line.data ? line.data : "", line.len);
    ::llmfun::tui::tuiAddOutputLine(*state, s);
}

void tuiClearOutput(TuiState* state) {
    if (!state)
        return;
    ::llmfun::tui::tuiClearOutput(*state);
}

/* ------------------------------------------------------------------ */
/*  Status                                                            */
/* ------------------------------------------------------------------ */

void tuiSetStatusText(TuiState* state, String text) {
    if (!state)
        return;
    std::string s(text.data ? text.data : "", text.len);
    ::llmfun::tui::tuiSetStatusText(*state, s);
}

/* ------------------------------------------------------------------ */
/*  Input                                                             */
/* ------------------------------------------------------------------ */

String tuiGetInput(TuiState* state) {
    if (!state)
        return {nullptr, 0};
    std::string s = ::llmfun::tui::tuiGetInput(*state);
    return String_New(s.data(), s.size());
}

void tuiClearInput(TuiState* state) {
    if (!state)
        return;
    ::llmfun::tui::tuiClearInput(*state);
}

/* ------------------------------------------------------------------ */
/*  Submission                                                        */
/* ------------------------------------------------------------------ */

bool tuiIsSubmitReady(TuiState* state) {
    if (!state)
        return false;
    return ::llmfun::tui::tuiIsSubmitReady(*state);
}

void tuiResetSubmit(TuiState* state) {
    if (!state)
        return;
    ::llmfun::tui::tuiResetSubmit(*state);
}

String tuiGetSubmitQuery(TuiState* state) {
    if (!state)
        return {nullptr, 0};
    std::string s = ::llmfun::tui::tuiGetSubmitQuery(*state);
    return String_New(s.data(), s.size());
}

/* ------------------------------------------------------------------ */
/*  Auto-scroll                                                       */
/* ------------------------------------------------------------------ */

bool tuiGetAutoScroll(TuiState* state) {
    if (!state)
        return false;
    return state->autoScroll;
}

void tuiSetAutoScroll(TuiState* state, bool enabled) {
    if (!state)
        return;
    state->autoScroll = enabled;
}

} // namespace llmfun::tui
