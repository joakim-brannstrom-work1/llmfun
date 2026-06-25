#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <algorithm>
#include <cctype>
#include <cfloat>
#include <cstdio>
#include <cstring>

namespace llmfun::tui {

// Named key codes for Ctrl shortcuts (ncurses raw key codes)
static constexpr int KEY_CTRL_D = 4;     // Ctrl+D exit
static constexpr int KEY_CTRL_L = 12;    // Ctrl+L clear output
static constexpr int KEY_CTRL_ENTER = 0; // Raw key code 0 (Ctrl+Enter / Ctrl+J in ncurses raw mod
static constexpr int KEY_TAB = 9;
// static constexpr int KEY_SHIFT_ENTER = 343; //

// Helper: check if string is whitespace-only
static bool isWhitespaceOnly(const std::string& s) {
    return std::all_of(s.begin(), s.end(), [](unsigned char c) { return std::isspace(c); });
}

// outputMutex protects: outputLines, statusText, inputBuf, submitReady, submitQuery.
// Main-thread-only (no lock needed): autoScroll, historyPos, draftBuf, inputHistory.

void tuiAddOutputLine(TuiState& state, const std::string& line) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.push_back(line);
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
    state.submitQuery.clear();
}

std::string tuiGetSubmitQuery(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.submitQuery;
}

// ─── Input Resize Callback (static, per-frame reuse) ─────────────────────────
// Fix: Extracted from lambda to avoid per-frame recreation. Matches imgui_stdlib pattern.
static int InputResizeCallback(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
        std::string* str = reinterpret_cast<std::string*>(data->UserData);
        str->resize(data->BufSize);
        data->Buf = str->data();
    }
    return 0;
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

    // mouseSupport=true, fps_active=60.0, fps_idle=3.0 (save CPU when idle)
    *screen = ImTui_ImplNcurses_Init(true, 60.0f, 3.0f);
    if (!*screen) {
        std::fprintf(stderr, "Failed to initialize ncurses terminal. Aborting.\n");
        ImGui::DestroyContext(); // clean up context on failure
        return false;
    }

    ImTui_ImplText_Init();
    return true;
}

void tuiShutdown(ImTui::TScreen* screen) {
    if (screen) {
        ImTui_ImplText_Shutdown();
        ImTui_ImplNcurses_Shutdown();
    }
    ImGui::DestroyContext();
}

void tuiNewFrame() {
    ImTui_ImplNcurses_NewFrame();
    ImTui_ImplText_NewFrame();
    ImGui::NewFrame();
}

void tuiRenderFrame(ImTui::TScreen* screen) {
    ImGui::Render();
    ImTui_ImplText_RenderDrawData(ImGui::GetDrawData(), screen);
    ImTui_ImplNcurses_DrawScreen();
}

// ─── Task 5: Render Function — Output Area ───────────────────────────────────

bool tuiRender(TuiState& state) {
    ImVec2 DisplaySize = ImGui::GetIO().DisplaySize;

    static constexpr float MIN_TERMINAL_WIDTH = 40.0f;
    static constexpr float MIN_TERMINAL_HEIGHT = 15.0f;

    if (DisplaySize.x < MIN_TERMINAL_WIDTH || DisplaySize.y < MIN_TERMINAL_HEIGHT) {
        ImGui::Begin("Error");
        ImGui::Text("Terminal too small! Minimum size: 40x15");
        ImGui::End();
        return true;
    }

    ImGuiIO& io = ImGui::GetIO();

    if (io.KeyCtrl &&
        (ImGui::IsKeyPressed(ImGui::GetKeyIndex(ImGuiKey_C)) || ImGui::IsKeyPressed(KEY_CTRL_D))) {
        return false;
    }
    if (ImGui::IsItemActive() && ImGui::IsKeyPressed(ImGuiKey_Escape)) {
        state.inputBuf.clear();
    }

    auto logFile = fopen("log.txt", "a");

    // Required: BeginChild calls must be nested inside a Begin/End block.
    // Without a parent window, BeginChild creates an implicit window whose
    // auto-positioning offsets the layout, making the TUI unusable.
    ImGuiWindowFlags parentFlags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
                                   ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                                   ImGuiWindowFlags_NoScrollWithMouse |
                                   ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoBackground;
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowSize(DisplaySize, ImGuiCond_Always);
    ImGui::Begin("##TuiRoot", nullptr, parentFlags);

    { // Output Area
        // Clamp height to avoid negative values on very small terminals
        ImVec2 outPos(0, 0);
        ImVec2 outSize(DisplaySize.x, std::max(1.0f, DisplaySize.y - 3));
        ImGui::SetCursorPos(outPos);
        ImGuiWindowFlags outFlags = ImGuiWindowFlags_HorizontalScrollbar;

        ImGui::BeginChild("llm_output", outSize, false, outFlags);

        std::vector<std::string> linesCopy(state.outputLines.begin(), state.outputLines.end());
        for (const auto& line : linesCopy) {
            ImGui::TextUnformatted(line.c_str());
        }

        ImGui::EndChild();
    }

    { // Input Area
        ImVec2 inputPos(0, DisplaySize.y - 3);
        ImVec2 inputSize(DisplaySize.x, 2);
        ImGui::SetCursorPos(inputPos);
        ImGuiWindowFlags inputFlags = ImGuiWindowFlags_None;

        ImGui::BeginChild("user_input", inputSize, false, inputFlags);

        // Compute available width in the current window/content region
        float availWidth = ImGui::GetContentRegionAvail().x;

        // Estimate button width (text + padding)
        float buttonWidth =
            ImGui::CalcTextSize("Send   ").x + ImGui::GetStyle().FramePadding.x * 2.0f;
        float spacing = ImGui::GetStyle().ItemSpacing.x;

        // Input field width = remaining space
        float inputWidth = availWidth - buttonWidth - spacing;
        if (inputWidth < 0.0f)
            inputWidth = 0.0f;

        // Height for exactly two lines of text (including frame padding)
        float lineHeight = ImGui::GetTextLineHeight();
        float framePaddingY = ImGui::GetStyle().FramePadding.y;
        float inputHeight = lineHeight * 2.0f + framePaddingY * 2.0f;

        if (state.isSubmitted) {
            ImGui::SetKeyboardFocusHere();
            state.isSubmitted = false;
        }
        ImGui::InputTextMultiline("##user_input", state.inputBuf.data(), state.inputBuf.size() + 1,
                                  ImVec2(inputWidth, inputHeight),
                                  ImGuiInputTextFlags_CallbackResize, InputResizeCallback,
                                  &state.inputBuf);
        // Manual Tab navigation because ImTui doesn't map Tab to ImGuiKey_Tab
        if (ImGui::IsItemActive() && ImGui::IsKeyPressed(KEY_TAB) && !ImGui::GetIO().KeyShift) {
            std::fprintf(logFile, "tab detected? yes\n");
        }

        ImGui::SameLine();
        state.isSubmitted =
            ImGui::InputText("llm_send", "Send", 4,
                             ImGuiInputTextFlags_ReadOnly | ImGuiInputTextFlags_EnterReturnsTrue);
        if (ImGui::IsItemHovered()) {
            ImGui::BeginTooltip();
            ImGui::Text("Press enter to send the query to the LLM for processing");
            ImGui::EndTooltip();
        }

        if (state.isSubmitted) {
            std::string query = state.inputBuf;
            state.submitReady = true;
            state.submitQuery = query;
            state.inputBuf.clear();
        }

        ImGui::EndChild();
    }

    { // Status line
        ImVec2 statusPos(0, DisplaySize.y - 1);
        ImVec2 statusSize(DisplaySize.x, 1);
        ImGui::SetCursorPos(statusPos);
        ImGuiWindowFlags statusFlags = ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize |
                                       ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar |
                                       ImGuiWindowFlags_NoScrollbar |
                                       ImGuiWindowFlags_NoScrollWithMouse;

        ImGui::BeginChild("status", statusSize, false, statusFlags);

        static constexpr std::string_view defaultStatus =
            "Context: 0/0 tokens | Model: none | Ready";

        if (state.statusText.empty()) {
            ImGui::TextUnformatted(defaultStatus.data());
        } else {
            ImGui::TextUnformatted(state.statusText.c_str());
        }

        ImGui::EndChild();
    }

    ImGui::End();

    state.outputLines.push_back("hello\n");

    fclose(logFile);

    return true;
}

} // namespace llmfun::tui
