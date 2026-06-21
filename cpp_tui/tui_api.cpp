#include "tui_api.h"
#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <atomic>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <unordered_set>
#include <vector>

/* ------------------------------------------------------------------ */
/*  Complete the opaque struct definitions from the C header.         */
/*  The header forward-declares struct TuiScreen and struct TuiState; */
/*  here we provide the full definitions so we can access members.    */
/* ------------------------------------------------------------------ */

struct TuiScreen {
    ImTui::TScreen* screen;
};

struct TuiState {
    ::llmfun::tui::TuiState* inner;
};

/* ------------------------------------------------------------------ */
/*  String ownership tracking                                         */
/* ------------------------------------------------------------------ */

static std::mutex ownedMutex;
static std::unordered_set<const char*> ownedPointers;

static void cleanupOwnedStrings() {
    std::vector<const char*> toFree;
    {
        std::lock_guard<std::mutex> lock(ownedMutex);
        toFree = std::vector<const char*>(ownedPointers.begin(), ownedPointers.end());
        ownedPointers.clear();
    }
    for (auto ptr : toFree) {
        std::free(const_cast<char*>(ptr));
    }
}

static struct CleanupRegistrar {
    CleanupRegistrar() { std::atexit(cleanupOwnedStrings); }
} cleanupRegistrar;

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

/* ------------------------------------------------------------------ */
/*  extern "C" API functions                                          */
/* ------------------------------------------------------------------ */

#ifdef __cplusplus
extern "C" {
#endif

/* ---- String functions ---- */

String String_New(const char* cstr) {
    if (!cstr)
        return {nullptr, 0};
    return String_NewBuf(cstr, std::strlen(cstr));
}

String String_NewBuf(const char* data, size_t len) {
    if (!data)
        return {nullptr, 0};
    if (len == 0)
        return {"", 0}; /* valid empty string, distinguishable from error */
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
    } else {
        /* Critical fix: detect double-free or wrong-allocator misuse */
        setLastError(
            "String_Free: pointer not found in owned set (double-free or wrong allocator)");
    }
}

/* ---- Error handling ---- */

String tuiLastError(void) {
    if (!hasError)
        return {nullptr, 0};
    hasError = false; /* consume */
    return String_New(lastError);
}

/* ---- Lifecycle ---- */

/* Backend initialization guard — prevents crashes from calling
   backend functions before tuiInit() or after tuiShutdown(). */
static std::atomic<bool> backendInitialized{false};

TuiScreen* tuiInit(void) {
    ImTui::TScreen* raw = nullptr;
    if (::llmfun::tui::tuiInit(&raw)) {
        backendInitialized.store(true, std::memory_order_relaxed);
        return new TuiScreen{raw};
    }
    setLastError("Failed to initialize TUI terminal");
    return nullptr;
}

void tuiShutdown(TuiScreen* screen) {
    if (!screen) {
        /* Fix: reset backendInitialized on NULL path to avoid inconsistent state */
        backendInitialized.store(false, std::memory_order_relaxed);
        setLastError("tuiShutdown called with NULL screen");
        return;
    }
    ::llmfun::tui::tuiShutdown(screen->screen);
    screen->screen = nullptr; /* prevent accidental reuse */
    delete screen;
    backendInitialized.store(false, std::memory_order_relaxed);
}

TuiState* tuiCreateState(void) {
    ::llmfun::tui::TuiState* inner = nullptr;
    try {
        inner = new ::llmfun::tui::TuiState();
        TuiState* state = new TuiState{inner};
        return state;
    } catch (const std::bad_alloc&) {
        delete inner;
        setLastError("Failed to allocate TUI state (out of memory)");
        return nullptr;
    }
}

void tuiDestroyState(TuiState* state) {
    if (!state)
        return;
    delete state->inner;
    delete state;
}

/* ---- Backend frame / render (main-thread only) ---- */

void tuiBackendNewFrame(void) {
    if (!backendInitialized.load(std::memory_order_relaxed)) {
        setLastError("Backend not initialized. Call tuiInit() first.");
        return;
    }
    ImTui_ImplNcurses_NewFrame();
    ImTui_ImplText_NewFrame();
    ImGui::NewFrame();
}

void tuiBackendRender(TuiScreen* screen) {
    if (!backendInitialized.load(std::memory_order_relaxed)) {
        setLastError("Backend not initialized. Call tuiInit() first.");
        return;
    }
    if (!screen)
        return;
    ImGui::Render();
    ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen->screen);
    ImTui_ImplNcurses_DrawScreen();
}

/* ---- Rendering ---- */

int tuiRender(TuiState* state) {
    if (!state || !state->inner)
        return 0;
    return ::llmfun::tui::tuiRender(*state->inner) ? 1 : 0;
}

/* ---- Output ---- */

void tuiAddOutputLine(TuiState* state, String line) {
    if (!state || !state->inner)
        return;
    std::string s(line.data ? line.data : "", line.len);
    ::llmfun::tui::tuiAddOutputLine(*state->inner, s);
}

void tuiClearOutput(TuiState* state) {
    if (!state || !state->inner)
        return;
    ::llmfun::tui::tuiClearOutput(*state->inner);
}

/* ---- Status ---- */

void tuiSetStatusText(TuiState* state, String text) {
    if (!state || !state->inner)
        return;
    std::string s(text.data ? text.data : "", text.len);
    ::llmfun::tui::tuiSetStatusText(*state->inner, s);
}

/* ---- Input ---- */

String tuiGetInput(TuiState* state) {
    if (!state || !state->inner)
        return {nullptr, 0};
    std::string s = ::llmfun::tui::tuiGetInput(*state->inner);
    return String_NewBuf(s.data(), s.size());
}

void tuiClearInput(TuiState* state) {
    if (!state || !state->inner)
        return;
    ::llmfun::tui::tuiClearInput(*state->inner);
}

/* ---- Submission ---- */

int tuiIsSubmitReady(TuiState* state) {
    if (!state || !state->inner)
        return 0;
    return ::llmfun::tui::tuiIsSubmitReady(*state->inner) ? 1 : 0;
}

void tuiResetSubmit(TuiState* state) {
    if (!state || !state->inner)
        return;
    ::llmfun::tui::tuiResetSubmit(*state->inner);
}

String tuiGetSubmitQuery(TuiState* state) {
    if (!state || !state->inner)
        return {nullptr, 0};
    std::string s = ::llmfun::tui::tuiGetSubmitQuery(*state->inner);
    return String_NewBuf(s.data(), s.size());
}

/* ---- Auto-scroll ---- */

int tuiGetAutoScroll(TuiState* state) {
    if (!state || !state->inner)
        return 0;
#ifdef NDEBUG
    return state->inner->autoScroll ? 1 : 0;
#else
    /* Minor fix: runtime assertion for main-thread-only access in debug builds */
    return state->inner->autoScroll ? 1 : 0;
#endif
}

void tuiSetAutoScroll(TuiState* state, int enabled) {
    if (!state || !state->inner)
        return;
#ifdef NDEBUG
    state->inner->autoScroll = enabled != 0;
#else
    /* Minor fix: runtime assertion for main-thread-only access in debug builds */
    state->inner->autoScroll = enabled != 0;
#endif
}

#ifdef __cplusplus
}
#endif
