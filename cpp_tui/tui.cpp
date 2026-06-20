#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

// All functions below acquire state.outputMutex for thread safety.
// outputMutex protects: outputLines, statusText, inputBuf, submitReady.

void tuiAddOutputLine(TuiState& state, const std::string& line) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.push_back(line);
    // Since we add exactly one line, an if suffices.
    if (state.outputLines.size() > state.MAX_OUTPUT_LINES) {
        state.outputLines.pop_front(); // O(1) with deque
    }
}

void tuiClearOutput(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.clear();
}

void tuiSetStatusText(TuiState& state, const std::string& text) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.statusText = text;
}

std::string tuiGetInput(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.inputBuf;
}

void tuiClearInput(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.inputBuf.clear();
}

bool tuiIsSubmitReady(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.submitReady;
}

void tuiResetSubmit(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.submitReady = false;
}

// ─── Task 4: Theme Application ───────────────────────────────────────────────

static void applyTheme() {
    // Start with StyleColorsDark as a consistent base for all ~35 color slots,
    // then override the specific colors that differ from the defaults.
    ImGui::StyleColorsDark();

    ImVec4* colors = ImGui::GetStyle().Colors;
    colors[ImGuiCol_Text] = ImVec4(0.90f, 0.90f, 0.90f, 1.00f);
    colors[ImGuiCol_TextDisabled] = ImVec4(0.50f, 0.50f, 0.50f, 1.00f);
    colors[ImGuiCol_WindowBg] = ImVec4(0.06f, 0.06f, 0.06f, 1.00f);
    colors[ImGuiCol_ChildBg] = ImVec4(0.06f, 0.06f, 0.06f, 0.00f);
    colors[ImGuiCol_Border] = ImVec4(0.20f, 0.20f, 0.20f, 1.00f);
    colors[ImGuiCol_FrameBg] = ImVec4(0.16f, 0.16f, 0.16f, 1.00f);
    colors[ImGuiCol_FrameBgHovered] = ImVec4(0.26f, 0.26f, 0.26f, 1.00f);
    colors[ImGuiCol_FrameBgActive] = ImVec4(0.26f, 0.59f, 0.98f, 0.65f);
    colors[ImGuiCol_ScrollbarBg] = ImVec4(0.05f, 0.05f, 0.05f, 0.54f);
    colors[ImGuiCol_ScrollbarGrab] = ImVec4(0.34f, 0.34f, 0.34f, 0.54f);
}

// ─── Init / Shutdown ─────────────────────────────────────────────────────────

bool tuiInit(ImTui::TScreen** screen) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    applyTheme();

    *screen = ImTui_ImplNcurses_Init(true);
    if (!*screen)
        return false;

    ImTui_ImplText_Init();
    return true;
}

void tuiShutdown(ImTui::TScreen* screen) {
    // Note: ImTui_ImplNcurses_Shutdown() is global and does not take a screen
    // parameter (see imtui-impl-ncurses.h). The TScreen object is owned by the
    // ncurses backend and will be freed internally during shutdown.
    (void)screen;
    ImTui_ImplText_Shutdown();
    ImTui_ImplNcurses_Shutdown();
    ImGui::DestroyContext();
}

// ─── Task 5: Render Function — Output Area ───────────────────────────────────

bool tuiRender(TuiState& state) {
    // Exit condition: Ctrl+Escape to quit
    if (ImGui::GetIO().KeyCtrl && ImGui::IsKeyPressed(ImGuiKey_Escape)) {
        return false;
    }

    ImVec2 DisplaySize = ImGui::GetIO().DisplaySize;

    // ── Output Area ──────────────────────────────────────────────────────────
    // Clamp height to avoid negative values on very small terminals
    ImVec2 outPos(0, 0);
    ImVec2 outSize(DisplaySize.x, ImMax(1.0f, DisplaySize.y - 4));

    ImGui::SetNextWindowPos(outPos, ImGuiCond_Always);
    ImGui::SetNextWindowSize(outSize, ImGuiCond_Always);

    ImGuiWindowFlags outFlags = ImGuiWindowFlags_HorizontalScrollbar;
    ImGui::BeginChild("output", outSize, false, outFlags);

    // Copy lines under lock, then render without holding the mutex.
    // This minimizes lock duration and eliminates deadlock risk from
    // ImGui internals calling back into the TUI API.
    std::vector<std::string> linesCopy;
    {
        std::lock_guard<std::mutex> lock(state.outputMutex);
        linesCopy = std::vector<std::string>(state.outputLines.begin(), state.outputLines.end());
    }

    for (const auto& line : linesCopy) {
        ImGui::TextUnformatted(line.c_str());
    }

    // Auto-scroll management (must stay inside child scope)
    if (state.autoScroll) {
        ImGui::SetScrollHereY(1.0f);
    }

    // Auto-scroll detection: capture scroll state BEFORE EndChild
    // so we read the "output" child's actual scroll values.
    float scrollY = ImGui::GetScrollY();
    float scrollMax = ImGui::GetScrollMax().y;
    if (scrollMax > 0.0f) {
        state.autoScroll = (scrollY >= scrollMax - 1.0f);
    }

    ImGui::EndChild();

    return true;
}
