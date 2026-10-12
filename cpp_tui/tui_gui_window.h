/// GUI window-size persistence: keeps the OS window size across restarts.
/// Dear ImGui does not manage the platform window, so the GUI backend
/// stores the size itself in a sibling of the imgui settings file.
#pragma once

#include <string>

namespace llmfun::tui {

// The restored size is clamped to this range: below the minimum the GUI is
// unusably small, and the maximum is a corrupt-file sanity bound.
constexpr int MinWindowWidth = 320;
constexpr int MinWindowHeight = 200;
constexpr int MaxWindowDimension = 32767;

/// Load the stored window size (one "WxH" line). false when the file is
/// missing or malformed (width/height are then left untouched); loaded
/// values are clamped into the supported range.
bool loadWindowSize(const std::string& path, int& width, int& height);

/// Store the window size as one "WxH" line, replacing any previous file.
/// false when the path is empty, the size is not positive, or the file
/// cannot be written (persistence is best-effort).
bool saveWindowSize(const std::string& path, int width, int height);

} // namespace llmfun::tui
