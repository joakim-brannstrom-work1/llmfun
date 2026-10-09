// test_rich_markdown_text.cpp
//
// Headless rich-markdown text-mode smoke test for the imgui_rich_md
// migration. Drives a REAL llmfun::tui::TuiState through the real
// tuiRender() on the imtui TEXT backend — no ncurses, no terminal, no PTY
// (same harness pattern as test_tui_maxwidth) — with the real text-mode
// markdown profile (initMarkdownTextMode() BEFORE
// ImTui_ImplText_Init(), the 1.0f bake warm-up, no selection, hard/soft
// breaks, OnImage = nullptr), and pins the reference rendering:
//
//   Case A: the reference document (heading, inline emphasis/strong/code,
//           link, wrapping paragraph, list, quote, fenced code block). The
//           rows appear in top-to-bottom order (chrome-agnostic scan, NO
//           absolute indices); the two inline-formatted paragraphs
//           re-join byte-exactly to their source text (single spaces
//           between the wrapped rows); the long paragraph takes >=2 rows;
//           "Title One", the two list rows and "quote block" match the
//           trimmed row EXACTLY (the pinned rendered form is
//           "-item one" / "-item two" — bullet rendered directly
//           adjacent to the item text, no space; the markdown source
//           is "- item one");
//           the code block's right-aligned "Copy" button row (containment)
//           precedes the two code rows (the code block's child window
//           sizes over two passes — asserted only after >=2 frames).
//   Case B: the wide/emoji row reconstructs byte-exactly to
//           "part one part two café 中 文  🚀  done", and the row's cells
//           for U+4E2D, U+6587 and U+1F680 are present, each followed by a
//           blank/pad cell (2-cell glyphs, no overlap with the following
//           text).
//   Case C: the features document (table, MISSING image, mermaid, text)
//           renders without crashing; "Before." and "After." render; no "not loaded" /
//           "( Image" fallback text surfaces anywhere (the image
//           contributes no text row); table/mermaid art is NOT asserted
//           (accepted degradation).
//
// stderr is captured across ALL phases (init, every frame, teardown) and
// must contain NONE of: "call InitializeMarkdown first" (context missing),
// "font atlas is not built" (warm-up order broken), "rich_md: UploadRgba"
// (only surfaces with rich_md's DEFAULT OnImage; this profile
// sets OnImage = nullptr).
//
// Tripwire: this test FAILS if the warm-up recipe is reverted (init after
// the backend / no bakes -> the rich fonts resolve to the 16px bake and
// the spans render invisible/garbled) or if the LLMFUN imgui measurement
// patch is reverted (wrap/measure count font advances instead of cells ->
// the pinned wrapped rows stop matching).
//
// Row reconstruction: a row is the cells' code points (ch == 0 -> ' '),
// then "cleaned" — outer runs of whitespace and non-ASCII glyphs are
// stripped (repeatedly), because in the real TUI the rows carry UI chrome
// that shares the grid rows with the markdown content: the menu-bar row,
// the 8-column "Open" session strip (closed by white-box state setup for
// layout determinism), the framed tree node's border column, and the root
// window border. The cleaned row is the row's content text. Assertions
// scan top-to-bottom without pinning absolute indices.
//
// Debug: RICHMD_TEST_DEBUG=<path> makes the test dump every grid row
// (cleaned text + per-cell x:U+XXXX(w<chwidth>)) for each case to <path>.
//
// Exit codes: 0 = all cases pass; 1 = first assertion failure (the grid is
// dumped to the real stderr); 2 = environment error (init/display size).
//
// Headless (text backend only) — run from the build dir:
//   ./test_rich_markdown_text < /dev/null

#include "imtui/imtui.h" // imgui + ImTui_ImplText_* (imtui-impl-text.h)

#include "tui.h" // llmfun::tui: TuiState, tuiRender, markdown text-mode lifecycle

#include <clocale>
#include <cstdlib>
#include <cstring>
#include <string>

#include <stdio.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Reference documents — the exact contract of the pinned rendering.
// ---------------------------------------------------------------------------

// Case A: the reference document.
static const char* kDoc =
    "# Title One\n\n"
    "Paragraph with *emphasis* and **strong** and `inline code` and a "
    "[link](https://example.com).\n\n"
    "A longer paragraph that must wrap over several lines to show how wrapping behaves: the quick "
    "brown fox jumps over the lazy dog and runs and runs and runs and runs and runs until the line "
    "is definitely long enough to wrap twice.\n\n"
    "- item one\n- item two\n\n"
    "> a quote block\n\n"
    "```\ncode block line one\ncode block line two\n```\n";

// Case A: the two inline-formatted source sentences the rendered (possibly
// wrapped) rows must re-join to, byte-exactly.
static const char* kLinkParagraph =
    "Paragraph with emphasis and strong and inline code and a link.";
static const char* kLongParagraph =
    "A longer paragraph that must wrap over several lines to show how wrapping behaves: the quick "
    "brown fox jumps over the lazy dog and runs and runs and runs and runs and runs until the line "
    "is definitely long enough to wrap twice.";

// Case B: source text and the byte-exact pinned rendering (one space after
// the 2-cell CJK cells, two spaces on each side of the 2-cell emoji).
static const char* kWide = "part one part two cafe\u00e9 \u4e2d\u6587 \U0001F680 done";
static const char* kWideRow = "part one part two cafe\u00e9 \u4e2d \u6587  \U0001F680  done";

// Case C: the features document (table, MISSING image, mermaid, text).
static const char* kFeatures =
    "Before.\n\n"
    "| Left | Right |\n|:-----|------:|\n| a    | 1     |\n| b    | 2     |\n\n"
    "![alt](images/markdown_broken_image.png)\n\n"
    "```mermaid\ngraph TD\nA-->B\n```\n\n"
    "After.";

namespace {

ImTui::TScreen g_screen;
char g_case = '0';
int g_frames = 0;

// A dup of the REAL stderr (captured at main entry): fail() diagnostics
// must reach the terminal even while fd 2 is redirected into the capture
// pipe; g_errOut is the FILE* view of that fd.
int g_realErr = -1;
FILE* g_errOut = nullptr;
std::string g_capturedErr;              // filled when the capture stops
size_t g_dbgLines = 0, g_dbgGroups = 0; // fail() diagnostics (last frame)
void dumpGrid(FILE* f) {
    // Full grid dump (ch 0 printed as '.'), plus the cleaned rows (the
    // content text — keeps the wide glyphs, strips the chrome).
    ::fprintf(f, "grid (%dx%d):\n", g_screen.nx, g_screen.ny);
    for (int y = 0; y < g_screen.ny; ++y) {
        std::string line;
        for (int x = 0; x < g_screen.nx; ++x) {
            unsigned c = g_screen.data[y * g_screen.nx + x].ch;
            line.push_back((c >= 32 && c < 127) ? char(c) : '.');
        }
        ::fprintf(f, "%2d |%s|\n", y, line.c_str());
    }
}

void fail(const std::string& what) {
    ::fprintf(g_errOut, "FAIL [case %c @ frame %d]: %s\n", g_case, g_frames, what.c_str());
    ::fprintf(g_errOut, "debug: outputLines=%zu renderGroups=%zu\n", g_dbgLines, g_dbgGroups);
    dumpGrid(g_errOut);
    if (!g_capturedErr.empty()) {
        ::fprintf(g_errOut, "captured stderr so far:\n%s\n", g_capturedErr.c_str());
    }
    std::exit(1);
}

void expect(bool cond, const std::string& what) {
    if (!cond)
        fail(what);
}

// Append code point cp to s as UTF-8.
void appendUtf8(std::string& s, uint32_t cp) {
    if (cp < 0x80) {
        s.push_back(char(cp));
    } else if (cp < 0x800) {
        s.push_back(char(0xC0 | (cp >> 6)));
        s.push_back(char(0x80 | (cp & 63)));
    } else if (cp < 0x10000) {
        s.push_back(char(0xE0 | (cp >> 12)));
        s.push_back(char(0x80 | ((cp >> 6) & 63)));
        s.push_back(char(0x80 | (cp & 63)));
    } else {
        s.push_back(char(0xF0 | (cp >> 18)));
        s.push_back(char(0x80 | ((cp >> 12) & 63)));
        s.push_back(char(0x80 | ((cp >> 6) & 63)));
        s.push_back(char(0x80 | (cp & 63)));
    }
}

// Reconstruct row y: each cell's code point (ch == 0 -> ' '); ch2 is
// ignored (folding is off in this profile, so ch2 is always 0 here).
std::string rowRaw(int y) {
    std::string s;
    for (int x = 0; x < g_screen.nx; ++x) {
        uint32_t ch = g_screen.data[y * g_screen.nx + x].ch;
        if (ch == 0)
            s.push_back(' ');
        else
            appendUtf8(s, ch);
    }
    return s;
}

int utf8SeqLen(unsigned char lead) {
    return lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1;
}

bool isRowSpace(unsigned char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

// The row's content text: strip outer runs of whitespace and non-ASCII
// glyphs (window / tree-node border cells quantized to one cell), repeated
// until stable — e.g. "  |  code line  |  " -> "code line".
std::string cleanRow(int y) {
    std::string s = rowRaw(y);
    size_t a = 0, b = s.size();
    bool changed = true;
    while (changed) {
        changed = false;
        while (a < b && isRowSpace((unsigned char)s[a])) {
            ++a;
            changed = true;
        }
        if (a < b && (unsigned char)s[a] >= 0x80) {
            a += (size_t)utf8SeqLen((unsigned char)s[a]);
            changed = true;
        }
        while (b > a && isRowSpace((unsigned char)s[b - 1])) {
            --b;
            changed = true;
        }
        if (b > a && (unsigned char)s[b - 1] >= 0x80) {
            size_t st = b;
            while (st > a && ((unsigned char)s[st - 1] & 0xC0) == 0x80)
                --st;
            b = st;
            changed = true;
        }
    }
    return s.substr(a, b - a);
}

// First row y >= from whose content contains sub; -1 if none.
int findRow(const std::string& sub, int from) {
    for (int y = from; y < g_screen.ny; ++y)
        if (cleanRow(y).find(sub) != std::string::npos)
            return y;
    return -1;
}
// First row y >= from whose trimmed content equals row exactly; -1 if none.
int findRowExact(const std::string& row, int from) {
    for (int y = from; y < g_screen.ny; ++y)
        if (cleanRow(y) == row)
            return y;
    return -1;
}

// Walk the consecutive non-blank rows from startY and re-join them to
// expected (the source sentence): each row must be the next un-consumed
// (space-skip) prefix run of expected. Sets outEndRow to the first row
// after the sentence, *outMatched to the matched byte count, and returns
// the row count. Stops at the first row that does not continue the
// sentence (or a blank row once started).
int joinSentence(int startY, const std::string& expected, int& outEndRow, size_t* outMatched) {
    int y = startY;
    while (y < g_screen.ny && cleanRow(y).empty())
        ++y; // chrome/blank rows before the sentence
    size_t cur = 0;
    int rows = 0;
    for (; y < g_screen.ny; ++y) {
        std::string row = cleanRow(y);
        if (row.empty())
            break; // the paragraph's rows are consecutive non-blank
        size_t k = cur;
        while (k < expected.size() && expected[k] == ' ')
            ++k;
        if (k == expected.size())
            break;
        if (k + row.size() <= expected.size() && expected.compare(k, row.size(), row) == 0) {
            cur = k + row.size();
            ++rows;
        } else {
            break; // this row does not continue the sentence
        }
    }
    outEndRow = y;
    if (outMatched)
        *outMatched = cur;
    return rows;
}

// Run exactly one frame on the text backend (same pipeline as
// test_tui_maxwidth): NewFrame pair, the app render (owns EndFrame), then
// the draw data into the TScreen grid.
void frame(llmfun::tui::TuiState& state) {
    ImGui::GetIO().DeltaTime = 1.0f / 60.0f;
    ImTui_ImplText_NewFrame();
    ImGui::NewFrame();
    if (!llmfun::tui::tuiRender(state))
        fail("tuiRender returned false (quit)");
    ImGui::Render();
    ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), &g_screen);
    g_dbgLines = state.chat.outputLines.size();
    g_dbgGroups = state.chat.renderGroups.size();
    ++g_frames;
}

// Fresh case setup: clear the output, close the session panel (white-box
// state setup — the 30-column open panel would share grid rows 1-3 with
// the markdown content; the closed 8-column "Open" strip keeps the layout
// deterministic), re-arm the simulated 80x24 terminal, add ONE assistant
// message with the case document.
void setupCase(llmfun::tui::TuiState& state, const char* doc) {
    llmfun::tui::tuiClearOutput(state);
    state.sessionPanel.panelOpen = false;
    ImGui::GetIO().DisplaySize = ImVec2(80.0f, 24.0f);
    llmfun::tui::ChatMessage m;
    m.summary = "Assistant";
    m.text = doc;
    m.type = llmfun::tui::ChatMessageType::Assistant;
    // Monotonic id exactly like the C API (tuiAddChatMessage): buildRenderGroups
    // caches on (first,last) message ids with a (0,0) sentinel, so an id-0
    // message would be treated as "unchanged" and never grouped.
    m.id = state.chat.outputLineNextId++;
    llmfun::tui::tuiAddOutputLine(state, m);
}

// Optional per-case grid dump for debugging pinned values: set
// RICHMD_TEST_DEBUG to a file path.
void debugDump(llmfun::tui::TuiState& state, const char* phase) {
    const char* path = std::getenv("RICHMD_TEST_DEBUG");
    if (!path || !*path)
        return;
    FILE* f = ::fopen(path, std::strcmp(phase, "A") == 0 ? "w" : "a");
    if (!f)
        return;
    ::fprintf(f, "=== case %s (%dx%d, frame %d) outputLines=%zu renderGroups=%zu ===\n", phase,
              g_screen.nx, g_screen.ny, g_frames, state.chat.outputLines.size(),
              state.chat.renderGroups.size());
    for (int y = 0; y < g_screen.ny; ++y) {
        std::string cells;
        for (int x = 0; x < g_screen.nx; ++x) {
            const ImTui::TCell& c = g_screen.data[y * g_screen.nx + x];
            if (c.ch == 0 || c.ch == ' ')
                continue;
            char tmp[64];
            ::snprintf(tmp, sizeof tmp, "%d:U+%04X(w%u) ", x, c.ch, c.chwidth);
            cells += tmp;
        }
        ::fprintf(f, "%2d |%s| cells: %s\n", y, cleanRow(y).c_str(), cells.c_str());
    }
    ::fclose(f);
}

// stderr capture: redirect fd 2 into a pipe around all render phases; the
// captured text is returned on stop().
struct ErrCapture {
    int saved = -1;
    int pipeR = -1;
    bool active = false;

    void start() {
        ::fflush(stderr);
        ::fflush(g_errOut);
        int fds[2];
        saved = ::dup(2);
        bool piped = ::pipe(fds) == 0;
        if (saved < 0 || !piped || ::dup2(fds[1], 2) != 2) {
            // Close everything opened so far so a partial failure leaks nothing.
            if (saved >= 0)
                ::close(saved);
            if (piped) {
                ::close(fds[0]);
                ::close(fds[1]);
            }
            return;
        }
        ::close(fds[1]);
        pipeR = fds[0];
        active = true;
    }

    void stop(std::string& out) {
        if (!active)
            return;
        active = false;
        ::fflush(stderr); // buffered libc writes -> the pipe
        ::close(2);
        std::string s;
        char buf[4096];
        ssize_t n;
        while ((n = ::read(pipeR, buf, sizeof buf)) > 0)
            s.append(buf, (size_t)n);
        ::close(pipeR);
        pipeR = -1;
        ::dup2(saved, 2);
        ::close(saved);
        saved = -1;
        out.swap(s);
    }
};

// Harness init/shutdown: mirror the real app's tuiInit order exactly —
// context, then the text-mode markdown profile (fonts + 1-cell warm-up
// bakes) BEFORE the text backend init, because ImTui_ImplText_Init() builds
// and locks the font atlas (a later GetFontBaked() would resolve the 16px
// bake instead of the exact 1-cell bake), then theme, then pin the default
// font by name.
void harnessInit(llmfun::tui::TuiState& state) {
    std::setlocale(LC_ALL, "");
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;
    llmfun::tui::initMarkdownTextMode(state); // BEFORE the text backend init
    ImTui_ImplText_Init();
    llmfun::tui::applyTheme();
    llmfun::tui::finishMarkdownTextMode(state);
    ImGui::GetIO().DisplaySize = ImVec2(80.0f, 24.0f);
}

void harnessShutdown(llmfun::tui::TuiState& state) {
    llmfun::tui::destroyMarkdown(state);
    ImTui_ImplText_Shutdown();
    ImGui::DestroyContext();
}

// ---------------------------------------------------------------------------
// Cases (assertions on the LAST of >=2 frames: the code block's child
// window sizes over two passes).
// ---------------------------------------------------------------------------

void caseA(llmfun::tui::TuiState& state) {
    g_case = 'A';
    setupCase(state, kDoc);
    for (int i = 0; i < 4; ++i)
        frame(state);

    // The rows in top-to-bottom order (chrome-agnostic, no indices).
    int y = findRowExact("Title One", 0);
    expect(y >= 0, "case A: 'Title One' row not found");

    int end = 0;
    size_t matched = 0;
    joinSentence(y + 1, kLinkParagraph, end, &matched);
    expect(matched == std::strlen(kLinkParagraph),
           "case A: link paragraph rows do not rejoin byte-exactly to the source text");

    int rows = joinSentence(end, kLongParagraph, end, &matched);
    expect(rows >= 2, "case A: long paragraph must wrap to >=2 rows");
    expect(matched == std::strlen(kLongParagraph),
           "case A: long paragraph rows do not rejoin byte-exactly to the source text");

    // The rendered (trimmed) form is pinned as "-item one" / "-item two" —
    // the bullet marker renders directly adjacent to the item text (no
    // space); the source markdown is "- item one".
    int y1 = findRowExact("-item one", end);
    expect(y1 >= 0, "case A: 'item one' list row not found");
    int y2 = findRowExact("-item two", y1 + 1);
    expect(y2 >= 0, "case A: 'item two' list row not found");
    int y3 = findRowExact("quote block", y2 + 1);
    expect(y3 >= 0, "case A: 'quote block' row not found");
    int y4 = findRow("Copy", y3 + 1);
    expect(y4 >= 0, "case A: code-block 'Copy' button row not found");
    int y5 = findRow("code block line one", y4);
    expect(y5 >= 0, "case A: 'code block line one' row not found");
    int y6 = findRow("code block line two", y5 + 1);
    expect(y6 >= 0, "case A: 'code block line two' row not found");

    debugDump(state, "A");
}

void caseB(llmfun::tui::TuiState& state) {
    g_case = 'B';
    setupCase(state, kWide);
    for (int i = 0; i < 4; ++i)
        frame(state);

    // The pinned row, byte-exact.
    int y = -1;
    for (int yy = 0; yy < g_screen.ny; ++yy)
        if (cleanRow(yy) == kWideRow) {
            y = yy;
            break;
        }
    expect(y >= 0, "case B: pinned wide row 'part one part two cafe'+'\\u00e9' ... not found "
                   "byte-exact (see grid dump)");

    // Cell check: the wide glyphs are present (once each) and each is
    // followed by a blank/pad cell — the 2-cell span must not overlap the
    // following text (the next non-blank cell is >= 2 columns away).
    int nU4E2D = 0, nU6587 = 0, nU1F680 = 0;
    for (int x = 0; x < g_screen.nx; ++x) {
        const ImTui::TCell& c = g_screen.data[y * g_screen.nx + x];
        if (c.ch == 0x4E2D)
            ++nU4E2D;
        else if (c.ch == 0x6587)
            ++nU6587;
        else if (c.ch == 0x1F680)
            ++nU1F680;
    }
    expect(nU4E2D == 1 && nU6587 == 1 && nU1F680 == 1,
           "case B: each wide glyph (U+4E2D, U+6587, U+1F680) must appear exactly once");
    for (int x = 0; x < g_screen.nx; ++x) {
        const ImTui::TCell& c = g_screen.data[y * g_screen.nx + x];
        if (c.ch != 0x4E2D && c.ch != 0x6587 && c.ch != 0x1F680)
            continue;
        expect(c.chwidth >= 1 && c.chwidth <= 2,
               "case B: wide glyph cell must carry a sane chwidth (1 or 2)");
        expect(x + 1 < g_screen.nx, "case B: wide glyph cell must not be the last column");
        const ImTui::TCell& next = g_screen.data[y * g_screen.nx + x + 1];
        expect(next.ch == 0 || next.ch == ' ',
               "case B: wide glyph must be followed by a blank/pad cell (no overlap)");
    }

    debugDump(state, "B");
}

void caseC(llmfun::tui::TuiState& state) {
    g_case = 'C';
    setupCase(state, kFeatures);
    for (int i = 0; i < 4; ++i)
        frame(state);

    // "Before." renders immediately above the (unasserted) table art; both
    // text rows pin exact trimmed equality.
    int yb = findRowExact("Before.", 0);
    expect(yb >= 0, "case C: 'Before.' row not found (document crashed or truncated?)");
    int y = findRowExact("After.", 0);
    expect(y >= 0, "case C: 'After.' row not found (document crashed or truncated?)");

    // The missing image must contribute no fallback text row anywhere.
    for (int yy = 0; yy < g_screen.ny; ++yy) {
        std::string row = rowRaw(yy);
        expect(row.find("not loaded") == std::string::npos,
               "case C: image fallback text 'not loaded' surfaced on the grid");
        expect(row.find("( Image") == std::string::npos,
               "case C: image fallback text '( Image' surfaced on the grid");
    }

    debugDump(state, "C");
}

} // namespace

int main() {
    // Diagnostics channel that survives the stderr capture below.
    g_realErr = ::dup(2);
    if (g_realErr < 0) {
        ::fprintf(stderr, "env error: dup(2) failed\n");
        return 2;
    }
    g_errOut = ::fdopen(g_realErr, "w");
    if (!g_errOut) {
        ::fprintf(stderr, "env error: fdopen(dup(2)) failed\n");
        ::close(g_realErr);
        return 2;
    }
    ::setvbuf(g_errOut, nullptr, _IONBF, 0);

    // Core state, driven through the C++ core API with the real text-mode
    // markdown profile; no chat sessions (panel closed for layout
    // determinism), no input, no timing.
    llmfun::tui::TuiState state;
    state.iniFilename = ""; // no ini persistence

    ErrCapture cap;
    cap.start();
    // A failed capture (dup/pipe) must not let the clean-stderr contract
    // below degrade into a trivially-passing no-op.
    expect(cap.active, "stderr capture could not be started (env error)");

    harnessInit(state);
    // The TScreen grid is resized by the first ImTui_ImplText_RenderDrawData
    // from the current DisplaySize (80x24); render one warm-up frame (empty
    // state) before checking the size.
    frame(state);
    if (g_screen.nx != 80 || g_screen.ny != 24) {
        ::fprintf(g_errOut, "unexpected display size %dx%d (want 80x24)\n", g_screen.nx,
                  g_screen.ny);
        dumpGrid(g_errOut);
        cap.stop(g_capturedErr);
        harnessShutdown(state);
        return 2;
    }

    caseA(state);
    caseB(state);
    caseC(state);

    harnessShutdown(state);
    cap.stop(g_capturedErr);

    // Clean-stderr contract (the three tripwire signatures).
    expect(g_capturedErr.find("call InitializeMarkdown first") == std::string::npos,
           "stderr: 'call InitializeMarkdown first' — the markdown context is missing");
    expect(g_capturedErr.find("font atlas is not built") == std::string::npos,
           "stderr: 'font atlas is not built' — the warm-up order is broken");
    expect(g_capturedErr.find("rich_md: UploadRgba") == std::string::npos,
           "stderr: 'rich_md: UploadRgba' — an image upload was attempted (OnImage must be "
           "nullptr in this profile)");

    ::fprintf(g_errOut, "OK test_rich_markdown_text (frames=%d, captured stderr %zu bytes%s)\n",
              g_frames, g_capturedErr.size(), g_capturedErr.empty() ? "" : " — see dump above");
    return 0;
}
