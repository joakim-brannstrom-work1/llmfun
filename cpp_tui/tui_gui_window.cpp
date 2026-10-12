/// GUI window-size persistence; see tui_gui_window.h.
#include "tui_gui_window.h"

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>

namespace llmfun::tui {

namespace {

// One "WxH" line is the whole format; parse strictly (digits, 'x', digits,
// trailing whitespace only) so a truncated or hand-edited file cannot poison
// the window size.
bool parseWindowSize(const char* text, long& width, long& height) {
    errno = 0;
    char* end = nullptr;
    const long w = std::strtol(text, &end, 10);
    if (end == text || errno == ERANGE || (*end != 'x' && *end != 'X'))
        return false;
    errno = 0;
    const char* digits = end + 1;
    const long h = std::strtol(digits, &end, 10);
    if (end == digits || errno == ERANGE)
        return false;
    while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n')
        ++end;
    if (*end != '\0')
        return false;
    width = w;
    height = h;
    return true;
}

} // namespace

bool loadWindowSize(const std::string& path, int& width, int& height) {
    if (path.empty())
        return false;
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr)
        return false;
    char buf[64];
    const size_t n = std::fread(buf, 1, sizeof(buf) - 1, f);
    std::fclose(f);
    buf[n] = '\0';

    long w = 0;
    long h = 0;
    if (!parseWindowSize(buf, w, h) || w < 1 || h < 1)
        return false;
    width = static_cast<int>(std::clamp(w, long{MinWindowWidth}, long{MaxWindowDimension}));
    height = static_cast<int>(std::clamp(h, long{MinWindowHeight}, long{MaxWindowDimension}));
    return true;
}

bool saveWindowSize(const std::string& path, int width, int height) {
    if (path.empty() || width < 1 || height < 1)
        return false;
    std::FILE* f = std::fopen(path.c_str(), "wt");
    if (f == nullptr)
        return false;
    const int written = std::fprintf(f, "%dx%d\n", width, height);
    std::fclose(f);
    return written > 0;
}

} // namespace llmfun::tui
