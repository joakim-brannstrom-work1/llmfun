// test_gui_window.cpp
//
// Standalone unit test for the GUI window-size persistence helpers
// (tui_gui_window.h): one "WxH" line, loaded with clamping into the
// supported range, saved best-effort.
//
// Compiles the helper TU directly and links only the standard library (no
// GLFW, no ImGui, no display). No test framework: CHECK(cond) prints each
// check and sets a fail flag; exits 0 if every check passes.
//
// Covers:
//   - missing file -> no stored size, output parameters untouched
//   - roundtrip and the exact on-disk bytes ("WxH\n")
//   - malformed/truncated lines, trailing garbage, oversized files
//   - non-positive and ERANGE values -> no stored size
//   - clamping into the supported range (including both boundaries)
//   - save-side guards: empty path, non-positive size, unwritable path;
//     a failed save leaves a previously stored size intact
//
// Run headless from the build dir:
//   ./test_gui_window

#include <cstdio>
#include <string>

#include "tui_gui_window.h"

using llmfun::tui::loadWindowSize;
using llmfun::tui::MaxWindowDimension;
using llmfun::tui::MinWindowHeight;
using llmfun::tui::MinWindowWidth;
using llmfun::tui::saveWindowSize;

static int g_failures = 0;

#define CHECK(cond)                                                                                \
    do {                                                                                           \
        const bool _ok = (cond);                                                                   \
        std::printf("%s %s\n", _ok ? "ok  " : "FAIL", #cond);                                      \
        if (!_ok) {                                                                                \
            ++g_failures;                                                                          \
        }                                                                                          \
    } while (0)

namespace {

const char* kPath = "test_gui_window.tmp";

void writeText(const std::string& text) {
    std::FILE* f = std::fopen(kPath, "wb");
    if (f == nullptr || std::fwrite(text.data(), 1, text.size(), f) != text.size()) {
        std::printf("FAIL cannot write scratch file %s\n", kPath);
        ++g_failures;
        return;
    }
    std::fclose(f);
}

std::string readText() {
    std::FILE* f = std::fopen(kPath, "rb");
    if (f == nullptr)
        return "<open failed>";
    std::string out;
    char buf[128];
    size_t n = 0;
    while ((n = std::fread(buf, 1, sizeof(buf), f)) > 0)
        out.append(buf, n);
    std::fclose(f);
    return out;
}

} // namespace

int main() {
    // --- missing file: no stored size, output parameters untouched --------
    std::remove(kPath);
    {
        int w = 42;
        int h = 43;
        CHECK(!loadWindowSize(kPath, w, h));
        CHECK(w == 42 && h == 43);
    }

    // --- roundtrip and the exact on-disk format ---------------------------
    CHECK(saveWindowSize(kPath, 1024, 768));
    CHECK(readText() == "1024x768\n");
    {
        int w = 0;
        int h = 0;
        CHECK(loadWindowSize(kPath, w, h));
        CHECK(w == 1024 && h == 768);
    }

    // --- accepted spellings -----------------------------------------------
    {
        const char* accepted[] = {"800x600\n", "800x600", "800x600 \n", "800X600"};
        for (const char* text : accepted) {
            writeText(text);
            int w = 0;
            int h = 0;
            const bool loaded = loadWindowSize(kPath, w, h);
            CHECK(loaded);
            CHECK(w == 800 && h == 600);
            if (!loaded || w != 800 || h != 600)
                std::printf("  (content was \"%s\")\n", text);
        }
    }

    // --- malformed content: no stored size, output parameters untouched ---
    {
        const char* malformed[] = {"",         "garbage",   "800",     "x600",
                                   "800x",     "800x600x1", "800,600", "800 x600",
                                   "-800x600", "800x-600",  "0x600",   "800x0"};
        for (const char* text : malformed) {
            writeText(text);
            int w = 7;
            int h = 8;
            const bool loaded = loadWindowSize(kPath, w, h);
            CHECK(!loaded);
            CHECK(w == 7 && h == 8);
            if (loaded)
                std::printf("  (content was \"%s\")\n", text);
        }
    }

    // --- oversized values are rejected, oversized files are not truncated --
    writeText("99999999999999999999x600");
    {
        int w = 7;
        int h = 8;
        CHECK(!loadWindowSize(kPath, w, h));
    }
    writeText("800x99999999999999999999");
    {
        int w = 7;
        int h = 8;
        CHECK(!loadWindowSize(kPath, w, h));
    }
    writeText(std::string(200, '9'));
    {
        int w = 7;
        int h = 8;
        CHECK(!loadWindowSize(kPath, w, h));
    }
    writeText(std::string("800x600") + std::string(100, 'z'));
    {
        int w = 7;
        int h = 8;
        CHECK(!loadWindowSize(kPath, w, h));
    }

    // --- clamping into the supported range --------------------------------
    {
        struct ClampCase {
            const char* text;
            int width;
            int height;
        };
        const ClampCase cases[] = {
            {"100x100", MinWindowWidth, MinWindowHeight},
            {"5000x100", 5000, MinWindowHeight},
            {"40000x5000", MaxWindowDimension, 5000},
            {"40000x40000", MaxWindowDimension, MaxWindowDimension},
            {"320x200", MinWindowWidth, MinWindowHeight},
            {"32767x32767", MaxWindowDimension, MaxWindowDimension},
        };
        for (const ClampCase& c : cases) {
            writeText(c.text);
            int w = 0;
            int h = 0;
            const bool loaded = loadWindowSize(kPath, w, h);
            CHECK(loaded);
            const bool ok = loaded && w == c.width && h == c.height;
            CHECK(ok);
            if (!ok)
                std::printf("  (content \"%s\" -> %dx%d, want %dx%d)\n", c.text, w, h, c.width,
                            c.height);
        }
    }

    // --- save-side guards -------------------------------------------------
    CHECK(!saveWindowSize("", 800, 600));
    CHECK(!saveWindowSize(kPath, 0, 600));
    CHECK(!saveWindowSize(kPath, 800, -1));
    // A failed save must not clobber a previously stored size.
    writeText("1024x768\n");
    CHECK(!saveWindowSize(kPath, 0, 0));
    CHECK(readText() == "1024x768\n");
    // Unwritable path: kPath is a file, so kPath + "/x" cannot be created.
    CHECK(!saveWindowSize(std::string(kPath) + "/x", 800, 600));

    std::remove(kPath);
    if (g_failures == 0) {
        std::printf("all checks passed\n");
        return 0;
    }
    std::printf("%d check(s) FAILED\n", g_failures);
    return 1;
}
