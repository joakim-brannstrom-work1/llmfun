#pragma once

#ifdef __cplusplus
#include <cstddef>
#else
#include <stdbool.h>
#include <stddef.h>
#endif

/*
 * tui_api.h — Cross-language API for the TUI library
 *
 * This header defines a C++/D-compatible interface using only raw pointers
 * and a plain String struct. No std::string, no references, no templates.
 *
 * D interop: This header is compiled as C++. D callers must use
 *   extern(C++) { ... } and match the C++ mangled names.
 * Example D import:
 *
 *   extern(C++) {
 *       struct String { const(char)* data; size_t len; }
 *       struct TuiState {}
 *       struct TuiScreen {}
 *       TuiScreen* tuiInit();
 *       void tuiShutdown(TuiScreen* screen);
 *       // ... etc (inside namespace llmfun.tui)
 *   }
 *
 *   // Access via: llmfun.tui.tuiInit()
 *
 * Memory allocator: All strings returned by this API are allocated via
 * std::malloc (C standard library malloc). Callers MUST free them via
 * String_Free() which uses std::free. Do NOT mix allocators — using
 * D's GC or a different allocator to free these pointers is undefined
 * behavior.
 *
 * Thread-safety summary:
 *   Thread-safe (internal mutex):
 *     tuiAddOutputLine, tuiClearOutput, tuiSetStatusText,
 *     tuiGetInput, tuiClearInput, tuiIsSubmitReady,
 *     tuiResetSubmit, tuiGetSubmitQuery
 *   Main-thread only (no mutex):
 *     tuiInit, tuiShutdown, tuiBackendNewFrame, tuiBackendRender,
 *     tuiRender, tuiGetAutoScroll, tuiSetAutoScroll
 *   Thread-local (per-thread):
 *     tuiLastError
 */

#define TUI_API_VERSION 1

#ifdef __cplusplus
namespace llmfun::tui {
#endif

/*
 * String — Plain old data struct representing a string slice.
 * No constructors, no destructors, no hidden state. Trivially copyable.
 *
 * Ownership rules:
 *   - String values passed TO mutating API functions (tuiAddOutputLine,
 *     tuiSetStatusText, etc.) are NOT copied; the caller must ensure the
 *     underlying buffer lives long enough for the call to complete.
 *   - String_New() is an exception: it copies the input buffer via
 *     std::malloc, so the caller's original buffer can be freed immediately.
 *   - Strings returned FROM this API are heap-allocated (via std::malloc)
 *     and MUST be freed with String_Free() when no longer needed.
 */
struct String {
    const char* data;
    size_t len;
};

/*
 * Create a String from a null-terminated C string.
 * The returned String points to a newly std::malloc'd copy of the data.
 * Caller must free the result with String_Free().
 * Null-safe: returns {nullptr, 0} if cstr is nullptr.
 */
String String_New(const char* cstr);

/*
 * Create a String from a raw buffer.
 * The returned String points to a newly std::malloc'd copy of `len` bytes from `data`.
 * Caller must free the result with String_Free().
 * Null-safe: returns {nullptr, 0} if data is nullptr (len is ignored).
 */
String String_New(const char* data, size_t len);

/*
 * Free a String that was returned by an API function or created via String_New.
 * No-op if s.data is null.
 * Undefined behavior if s.data was not allocated by String_New or an API function.
 * Caller must ensure the pointer matches the allocator that produced it.
 * Note: Since s is passed by value, s.data is NOT zeroed after freeing.
 * The caller should zero the String struct if needed: s.data = nullptr; s.len = 0;
 */
void String_Free(String s);

/* ---- Opaque handle types ---- */

/*
 * TuiState — Opaque handle to the internal TUI state.
 * Created via tuiCreateState(), destroyed via tuiDestroyState().
 * Thread-safe: all mutating functions acquire an internal mutex.
 */
struct TuiState;

/*
 * TuiScreen — Opaque handle to the terminal screen.
 * Created via tuiInit(), destroyed via tuiShutdown().
 * Main-thread only: not thread-safe.
 */
struct TuiScreen;

/* ---- Error handling ---- */

/*
 * Retrieve the last error message as an owned String.
 * Thread-local: each thread has its own error.
 * The error is consumed (cleared) on the first call — this is intentional
 * so that stale errors from previous operations don't persist indefinitely.
 * If you need to inspect the error without consuming it, call this function
 * immediately after the operation that may have failed.
 * Returns {nullptr, 0} if no error was set.
 * Caller must free the result with String_Free().
 */
String tuiLastError();

/* ---- Lifecycle ---- */

/*
 * Initialize the TUI terminal backend.
 * Must be called before any other API function (except String_New).
 * Returns an opaque TuiScreen* on success, nullptr on failure.
 * Main-thread only.
 */
TuiScreen* tuiInit();

/*
 * Shutdown the TUI terminal backend and restore terminal state.
 * Null-safe: passing nullptr is a no-op.
 * Main-thread only.
 */
void tuiShutdown(TuiScreen* screen);

/*
 * Create a new TUI state object.
 * Returns an opaque TuiState* on success, nullptr on failure (e.g. out of memory).
 */
TuiState* tuiCreateState();

/*
 * Destroy a TUI state object.
 * Null-safe: passing nullptr is a no-op.
 */
void tuiDestroyState(TuiState* state);

/* ---- Backend frame/render (main-thread only) ---- */

/*
 * Process backend input and start a new ImGui frame.
 * Must be called from the main/UI thread before tuiRender().
 * Null-safe: no-op if screen is nullptr.
 */
void tuiBackendNewFrame(TuiScreen* screen);

/*
 * Render the current ImGui frame to the terminal screen.
 * Must be called from the main/UI thread after tuiRender().
 * Null-safe: passing nullptr for screen is a no-op (sets error).
 */
void tuiBackendRender(TuiScreen* screen);

/* ---- Rendering ---- */

/*
 * Render one TUI frame using the given state.
 * Returns false if the user requested exit (e.g. pressed Escape).
 * Null-safe: returns false if state is nullptr.
 * Main-thread only.
 */
bool tuiRender(TuiState* state);

/* ---- Output ---- */

/*
 * Append a line to the output display. FIFO eviction if bound exceeded.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is nullptr.
 */
void tuiAddOutputLine(TuiState* state, String line);

/*
 * Clear all output lines.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is nullptr.
 */
void tuiClearOutput(TuiState* state);

/* ---- Status ---- */

/*
 * Set the status line text.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is nullptr.
 */
void tuiSetStatusText(TuiState* state, String text);

/* ---- Input ---- */

/*
 * Get the current input buffer content as an owned String.
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns {nullptr, 0} if state is nullptr.
 * Caller must free the result with String_Free().
 */
String tuiGetInput(TuiState* state);

/*
 * Clear the input buffer.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is nullptr.
 */
void tuiClearInput(TuiState* state);

/* ---- Submission ---- */

/*
 * Check if the user has submitted input (pressed Enter).
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns false if state is nullptr.
 */
bool tuiIsSubmitReady(TuiState* state);

/*
 * Reset the submission flag after processing.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is nullptr.
 */
void tuiResetSubmit(TuiState* state);

/*
 * Get the last submitted query text as an owned String.
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns {nullptr, 0} if state is nullptr.
 * Caller must free the result with String_Free().
 */
String tuiGetSubmitQuery(TuiState* state);

/* ---- Auto-scroll ---- */

/*
 * Get the current auto-scroll setting.
 * Null-safe: returns false if state is nullptr.
 * Main-thread only (no mutex protection).
 */
bool tuiGetAutoScroll(TuiState* state);

/*
 * Set the auto-scroll flag.
 * Null-safe: no-op if state is nullptr.
 * Main-thread only (no mutex protection).
 */
void tuiSetAutoScroll(TuiState* state, bool enabled);

#ifdef __cplusplus
} // namespace llmfun::tui
#endif
