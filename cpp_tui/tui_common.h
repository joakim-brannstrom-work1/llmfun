/// Shared TUI core utilities: logging, whitespace test, and multiline text.
/// Used by both the session sidebar and the chat render cluster.
#pragma once

#include <cstddef>
#include <cstdio>
#include <string>
#include <string_view>
#include <utility>

#include "imtui/imtui.h"

#include "imgui/imgui_internal.h"

namespace llmfun::tui {

struct Log {
    FILE* logFile;

    template <typename... Args> void operator()(std::string format, Args&&... args) {
        if (logFile != nullptr) {
            if constexpr (sizeof...(Args) == 0) {
                std::fputs(format.c_str(), logFile);
            } else {
                std::fprintf(logFile, format.c_str(), std::forward<Args>(args)...);
            }
        }
    }
};

bool isWhitespaceOnly(const std::string& s);

void textUnformattedMultiline(std::string_view text);

} // namespace llmfun::tui
