#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/*
 * tui_api.h — Pure C API header for the TUI library
 *
 * This header defines a C-compatible interface using only raw pointers
 * and a plain String struct. No C++ strings, no references, no templates,
 * no C++ namespaces, no function overloading.
 *
 * D interop: D callers import this header directly via extern(C):
 *
 *   extern(C) {
 *       struct String { const(char)* data; size_t len; }
 *       struct TuiState {}
 *       struct TuiScreen {}
 *       TuiScreen* tuiInit();
 *       void tuiShutdown(TuiScreen* screen);
 *       // ... etc
 *   }
 *
 * Memory allocator: All strings returned by this API are allocated via
 * malloc (C standard library). Callers MUST free them via String_Free()
 * which uses free(). Do NOT mix allocators — using D's GC or a different
 * allocator to free these pointers is undefined behavior.
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

/*
 * String — Plain old data struct representing a string slice.
 * No constructors, no destructors, no hidden state. Trivially copyable.
 *
 * Ownership rules:
 *   - String values passed TO mutating API functions (tuiAddOutputLine,
 *     tuiSetStatusText, etc.) are NOT copied; the caller must ensure the
 *     underlying buffer lives long enough for the call to complete.
 *   - String_New() is an exception: it copies the input buffer via
 *     malloc, so the caller's original buffer can be freed immediately.
 *   - Strings returned FROM this API are heap-allocated (via malloc)
 *     and MUST be freed with String_Free() when no longer needed.
 */
typedef struct String {
    const char* data;
    size_t len;
} String;

/*
 * Create a String from a null-terminated C string.
 * The returned String points to a newly malloc'd copy of the data.
 * Caller must free the result with String_Free().
 * Null-safe: returns {NULL, 0} if cstr is NULL.
 * Thread-safe: yes.
 */
String String_New(const char* cstr);

/*
 * Create a String from a raw buffer (non-null-terminated).
 * The returned String points to a newly malloc'd copy of `len` bytes from `data`.
 * Caller must free the result with String_Free().
 * Null-safe: returns {NULL, 0} if data is NULL (len is ignored).
 * Thread-safe: yes.
 */
String String_NewBuf(const char* data, size_t len);

/*
 * Free a String that was returned by an API function or created via String_New / String_NewBuf.
 * No-op if s.data is NULL.
 * Undefined behavior if s.data was not allocated by String_New, String_NewBuf, or an API function.
 * Caller must ensure the pointer matches the allocator that produced it.
 * Note: Since s is passed by value, s.data is NOT zeroed after freeing.
 * The caller should zero the String struct if needed: s.data = NULL; s.len = 0;
 * Thread-safe: yes.
 */
void String_Free(String s);

/* ---- Opaque handle types ---- */

/*
 * TuiState — Opaque handle to the internal TUI state.
 * Created via tuiCreateState(), destroyed via tuiDestroyState().
 * Thread-safe: all mutating functions acquire an internal mutex.
 */
typedef struct TuiState TuiState;

/*
 * TuiScreen — Opaque handle to the terminal screen.
 * Created via tuiInit(), destroyed via tuiShutdown().
 * Main-thread only: not thread-safe.
 */
typedef struct TuiScreen TuiScreen;

/* ---- Error handling ---- */

/*
 * Retrieve the last error message as an owned String.
 * Thread-local: each thread has its own error.
 * The error is consumed (cleared) on the first call — this is intentional
 * so that stale errors from previous operations don't persist indefinitely.
 * If you need to inspect the error without consuming it, call this function
 * immediately after the operation that may have failed.
 * Returns {NULL, 0} if no error was set.
 * Caller must free the result with String_Free().
 * Thread-safe: thread-local storage, no mutex needed.
 */
String tuiLastError(void);

/* ---- Lifecycle ---- */

/*
 * Initialize the TUI terminal backend.
 * Must be called before any other API function (except String_New / String_NewBuf).
 * Returns an opaque TuiScreen* on success, NULL on failure.
 * Main-thread only.
 */
TuiScreen* tuiInit(void);

/*
 * Shutdown the TUI terminal backend and restore terminal state.
 * Null-safe: passing NULL is a no-op.
 * Main-thread only.
 */
void tuiShutdown(TuiScreen* screen);

/*
 * Create a new TUI state object.
 * Returns an opaque TuiState* on success, NULL on failure (e.g. out of memory).
 * Thread-safe: yes.
 */
TuiState* tuiCreateState(void);

/*
 * Destroy a TUI state object.
 * Null-safe: passing NULL is a no-op.
 * Thread-safe: yes.
 */
void tuiDestroyState(TuiState* state);

/* ---- Backend frame/render (main-thread only) ---- */

/*
 * Process backend input and start a new ImGui frame.
 * Must be called from the main/UI thread before tuiRender().
 * Null-safe: no-op if screen is NULL.
 * Main-thread only.
 */
void tuiBackendNewFrame(void);

/*
 * Render the current ImGui frame to the terminal screen.
 * Must be called from the main/UI thread after tuiRender().
 * Null-safe: passing NULL for screen is a no-op (sets error).
 * Main-thread only.
 */
void tuiBackendRender(TuiScreen* screen);

/* ---- Rendering ---- */

/*
 * Render one TUI frame using the given state.
 * Returns 0 if the user requested exit (e.g. pressed Escape), 1 otherwise.
 * Null-safe: returns 0 if state is NULL.
 * Main-thread only.
 */
int tuiRender(TuiState* state);

/* ---- Output ---- */

/*
 * Append a line to the output display. FIFO eviction if bound exceeded.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is NULL.
 */
void tuiAddOutputLine(TuiState* state, String line);

/*
 * Clear all output lines.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is NULL.
 */
void tuiClearOutput(TuiState* state);

/* ---- Status ---- */

/*
 * Set the status line text.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is NULL.
 */
void tuiSetStatusText(TuiState* state, String text);

/* ---- Input ---- */

/*
 * Get the current input buffer content as an owned String.
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns {NULL, 0} if state is NULL.
 * Caller must free the result with String_Free().
 */
String tuiGetInput(TuiState* state);

/*
 * Clear the input buffer.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is NULL.
 */
void tuiClearInput(TuiState* state);

/* ---- Submission ---- */

/*
 * Check if the user has submitted input (pressed Enter).
 * Returns 1 if ready, 0 otherwise.
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns 0 if state is NULL.
 */
int tuiIsSubmitReady(TuiState* state);

/*
 * Reset the submission flag after processing.
 * Thread-safe: acquires internal mutex.
 * Null-safe: no-op if state is NULL.
 */
void tuiResetSubmit(TuiState* state);

/*
 * Get the last submitted query text as an owned String.
 * Thread-safe: acquires internal mutex.
 * Null-safe: returns {NULL, 0} if state is NULL.
 * Caller must free the result with String_Free().
 */
String tuiGetSubmitQuery(TuiState* state);

/* ---- Auto-scroll ---- */

/*
 * Get the current auto-scroll setting.
 * Returns 1 if enabled, 0 if disabled.
 * Null-safe: returns 0 if state is NULL.
 * Main-thread only (no mutex protection).
 */
int tuiGetAutoScroll(TuiState* state);

/*
 * Set the auto-scroll flag.
 * Pass 1 to enable, 0 to disable.
 * Null-safe: no-op if state is NULL.
 * Main-thread only (no mutex protection).
 */
void tuiSetAutoScroll(TuiState* state, int enabled);

#ifdef __cplusplus
}
#endif
