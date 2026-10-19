/// Shared TUI render widgets: button, separator, and a style-color guard.
/// Reusable ImGui render helpers shared by the sidebar and chat cluster.
#pragma once

#include <array>
#include <string>
#include <string_view>

#include "imtui/imtui.h"

#include "imgui/imgui_internal.h"

namespace llmfun::tui {

bool renderButton(const std::string& label, int width, bool active, ImVec4 colorActive);

// Per-TU private copy (internal linkage): each including translation unit gets
// its own `static` definition, so this adds no new exported symbol.
static void renderSeparator(const std::string& prefix, std::string_view ch, int n, bool disabled) {
    static std::array<char, 256> buf{};
    if (n > 255)
        n = 255;
    if (n < 0)
        n = 0;
    if (n > prefix.size())
        n -= prefix.size();
    for (int i = 0; i < n; i++) {
        buf[i] = ch[0];
    }
    buf[n] = 0;
    if (disabled) {
        ImGui::TextDisabled("%s%s", prefix.c_str(), buf.data());
    } else {
        ImGui::Text("%s%s", prefix.c_str(), buf.data());
    }
}

struct StyleColorGuard {
private:
    int count;

public:
    explicit StyleColorGuard(int n) : count(n) {}
    ~StyleColorGuard() { pop(); }

    void pop() {
        for (int i = 0; i < count; ++i) {
            ImGui::PopStyleColor();
        }
        count = 0;
    }

    StyleColorGuard(const StyleColorGuard&) = delete;
    StyleColorGuard& operator=(const StyleColorGuard&) = delete;
    StyleColorGuard(StyleColorGuard&&) = delete;
    StyleColorGuard& operator=(StyleColorGuard&&) = delete;
};

} // namespace llmfun::tui
