#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <algorithm>
#include <cctype>
#include <cfloat>
#include <cstdio>
#include <cstring>
#include <string>

namespace llmfun::tui {

// Named key codes for Ctrl shortcuts (ncurses raw key codes)
static constexpr int KEY_CTRL_D = 4; // Ctrl+D exit

struct Log {
    FILE* logFile;

    template <typename... Args> void operator()(std::string format, Args&&... args) {
        if (logFile != nullptr) {
            std::fprintf(logFile, format.c_str(), std::forward<Args>(args)...);
        }
    }
};

bool isWhitespaceOnly(const std::string& s) {
    if (s.empty())
        return true;

    bool allTrue = true;
    for (auto c : s) {
        allTrue = allTrue && (std::isspace(c) || c == '\0');
    }
    return allTrue;
}

size_t countNewLines(const std::string& str) { return std::count(str.begin(), str.end(), '\n'); }

void tuiAddOutputLine(TuiState& state, const ChatMessage& msg) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.outputLines.push_back(msg);
    if (state.outputLines.size() > state.MAX_OUTPUT_LINES) {
        state.outputLines.pop_front();
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
    return state.userQuery.inputBuf;
}

void tuiClearInput(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.userQuery.inputBuf.clear();
}

bool tuiIsSubmitReady(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.userQuery.submitReady;
}

void tuiResetSubmit(TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    state.userQuery.submitReady = false;
    state.userQuery.submitQuery.clear();
}

std::string tuiGetSubmitQuery(const TuiState& state) {
    std::lock_guard<std::mutex> lock(state.outputMutex);
    return state.userQuery.submitQuery;
}

void ColoredSeparator(ImU32 color, float thickness = 1.0f, float spacing = 4.0f) {
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    ImVec2 start = ImGui::GetCursorScreenPos();
    ImVec2 end = ImVec2(start.x + ImGui::GetContentRegionAvail().x, start.y);
    draw_list->AddLine(start, end, color, thickness);
    ImGui::Dummy(ImVec2(0, spacing));
}

void applyTheme() {
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

int InputResizeCallback(ImGuiInputTextCallbackData* data) {
    if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
        std::string* str = reinterpret_cast<std::string*>(data->UserData);
        str->resize(data->BufSize);
        data->Buf = str->data();
    }
    return 0;
}

void renderTabChat(TuiState& state, Log& log) {
    ImVec2 DisplaySize = ImGui::GetIO().DisplaySize;
    const auto inputBufLines =
        std::min(20, std::max(2, static_cast<int>(countNewLines(state.userQuery.inputBuf))));

    auto outputArea = [&state, &inputBufLines, &DisplaySize]() {
        // Clamp height to avoid negative values on very small terminals
        ImVec2 outPos(0, 1.0f);
        ImVec2 outSize(DisplaySize.x, std::max(1.0f, DisplaySize.y - 3 - inputBufLines));
        ImGui::SetCursorPos(outPos);
        ImGuiWindowFlags outFlags = ImGuiWindowFlags_HorizontalScrollbar;

        ImGui::BeginChild("llm_output", outSize, false, outFlags);

        std::vector<ChatMessage> messages(state.outputLines.begin(), state.outputLines.end());
        for (size_t i = 0; i < messages.size(); ++i) {
            const auto flags = (i == messages.size() - 1) ? ImGuiTreeNodeFlags_DefaultOpen
                                                          : ImGuiTreeNodeFlags_None;
            if (ImGui::CollapsingHeader(messages[i].summary.c_str(), flags)) {
                ImGui::PushTextWrapPos(0.0f);
                ImGui::TextUnformatted(messages[i].text.c_str());
                ImGui::PopTextWrapPos();
            }
        }

        if (state.autoScroll) {
            ImGui::SetScrollHereY(1.0f);
        }

        // Auto-scroll detection: capture scroll state BEFORE EndChild so we
        // read the "output" child's actual scroll values.
        const float scrollY = ImGui::GetScrollY();
        const float scrollMax = ImGui::GetScrollMaxY();
        if (scrollMax > 0.0f) {
            state.autoScroll = (scrollY >= scrollMax - 1.0f);
        }

        ImGui::EndChild();
    };

    auto inputHistory = [&state = state.userQuery, &log](bool isPageUp, bool isPageDown) {
        if (state.inputHistory.empty()) {
            return;
        }

        // this code do not work until ImGui::ImGui::ClearActiveID() is available
        // if (!ImGui::IsItemActive() || state.inputHistory.empty()) {
        //     return;
        // }
        // auto& io = ImGui::GetIO();
        // const bool isPageUp = ImGui::IsItemActive() && io.KeysDown[io.KeyMap[ImGuiKey_PageUp]];
        // const bool isPageDown = ImGui::IsItemActive() &&
        // io.KeysDown[io.KeyMap[ImGuiKey_PageDown]];
        if (!(isPageUp || isPageDown)) {
            return;
        }

        bool setInput = false;
        if (isPageUp) {
            if (state.historyPos == -1) {
                // First press: save draft and push current input to history.
                state.draftBuf = state.inputBuf;
            }
            state.historyPos =
                std::min(state.historyPos + 1, static_cast<int>(state.inputHistory.size()) - 1);
            if (state.historyPos >= 0 && state.historyPos < state.inputHistory.size()) {
                setInput = true;
            }
        } else if (isPageDown && state.historyPos >= 0) {
            state.historyPos--;
            if (state.historyPos >= 0 && state.historyPos < state.inputHistory.size()) {
                setInput = true;
            } else {
                state.newInputBufString = state.draftBuf;
                state.draftBuf.clear();
            }
        }
        if (setInput) {
            log("query input: pos:%d %d\n", state.historyPos,
                state.inputHistory.size() - state.historyPos - 1);
            state.newInputBufString =
                state.inputHistory[state.inputHistory.size() - state.historyPos - 1];
            log("set query: %s\n", state.newInputBufString.c_str());
        }

        if (state.inputHistory.size() > state.MAX_HISTORY) {
            state.inputHistory.erase(state.inputHistory.begin());
        }
    };

    auto inputArea = [&state, &inputBufLines, &DisplaySize, &inputHistory, &log]() {
        ImVec2 inputPos(0, DisplaySize.y - 3 - inputBufLines);
        ImVec2 inputSize(DisplaySize.x, 2 + inputBufLines);
        ImGui::SetCursorPos(inputPos);

        ImGui::BeginChild("user_input", inputSize, false, ImGuiWindowFlags_None);

        // Estimate "button" width (text + padding)
        float buttonWidth =
            ImGui::CalcTextSize("Send   ").x + ImGui::GetStyle().FramePadding.x * 2.0f;

        // Input field width = remaining space
        float inputWidth =
            ImGui::GetContentRegionAvail().x - buttonWidth - ImGui::GetStyle().ItemSpacing.x;
        inputWidth = std::max(0.0f, inputWidth);

        // Height for text (including frame padding)
        float lineHeight = 1.0f + ImGui::GetTextLineHeight() * inputBufLines;
        float framePaddingY = ImGui::GetStyle().FramePadding.y;
        float inputHeight = lineHeight + framePaddingY * 2.0f;

        if (!state.userQuery.newInputBufString.empty()) {
            state.userQuery.inputBuf = state.userQuery.newInputBufString;
        }

        if (state.userQuery.isSubmitted) {
            state.userQuery.isSubmitted = false;
            ImGui::SetKeyboardFocusHere();
        }

        if (!state.userQuery.inputBuf.empty())
            log("before query: %s\n", state.userQuery.inputBuf.c_str());
        ImGui::InputTextMultiline(
            "##user_input", state.userQuery.inputBuf.data(), state.userQuery.inputBuf.size() + 1,
            ImVec2(inputWidth, inputHeight), ImGuiInputTextFlags_CallbackResize,
            InputResizeCallback, &state.userQuery.inputBuf);
        if (!state.userQuery.newInputBufString.empty()) {
            state.userQuery.newInputBufString.clear();
        }

        // inputHistory();

        ImGui::SameLine();
        ImGui::BeginGroup();
        static std::string buttonText("Send");
        // using an InputText field to simulate a button because otherwise
        // moving to the widget do not work with tab in imtui
        state.userQuery.isSubmitted =
            ImGui::InputText("##llm_send", const_cast<char*>(buttonText.c_str()), 4,
                             ImGuiInputTextFlags_ReadOnly | ImGuiInputTextFlags_EnterReturnsTrue);
        state.userQuery.isSubmitted = state.userQuery.isSubmitted || ImGui::IsItemActive();
        if (ImGui::IsItemHovered()) {
            ImGui::BeginTooltip();
            ImGui::Text("Send the query to the LLM for processing");
            ImGui::EndTooltip();
        }
        bool historyNext = ImGui::Button("Next");
        bool historyPrev = ImGui::Button("Prev");
        ImGui::EndGroup();

        inputHistory(historyNext, historyPrev);

        if (state.userQuery.isSubmitted) {
            std::string query = state.userQuery.inputBuf;
            // ImGui may insert a trailing for example when ctrl+enter.
            if (!query.empty() && query.back() == '\n') {
                query.pop_back();
            }
            if (!isWhitespaceOnly(query)) {
                state.userQuery.submitReady = true;
                state.userQuery.submitQuery = query;
                state.userQuery.inputHistory.push_back(query);
            }
            state.userQuery.inputBuf.clear();
            state.userQuery.historyPos = -1;
        }

        ImGui::EndChild();
    };

    auto statusLine = [&state, &DisplaySize]() {
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
    };

    outputArea();
    inputArea();
    statusLine();
}

void renderTabLog(TuiState& state, Log& log) {}

void renderMainWindow(TuiState& state, Log& log) {
    ImVec2 DisplaySize = ImGui::GetIO().DisplaySize;

    static int activeTab = 0;

    bool showChat{false};
    bool showLog{false};
    if (ImGui::BeginMenuBar()) {
        if (ImGui::BeginMenu("Tab")) {
            ImGui::MenuItem("Chat", nullptr, &showChat);
            ImGui::MenuItem("Log", nullptr, &showLog);
            ImGui::EndMenu();
        }
        ImGui::EndMenuBar();
    }
    if (showChat) {
        activeTab = 0;
    }
    if (showLog) {
        activeTab = 1;
    }

    switch (activeTab) {
    case 0:
        renderTabChat(state, log);
        break;
    case 1:
        renderTabLog(state, log);
        break;
    }
}

bool tuiRender(TuiState& state) {
    ImGui::GetIO().ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
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
        state.userQuery.inputBuf.clear();
    }
    if (ImGui::IsKeyPressed(ImGuiKey_End)) {
        state.autoScroll = true;
    }

    auto logFile = [&state]() {
        if (state.isLogActive)
            return fopen("llmfun_ui_log.txt", "a");
        return static_cast<FILE*>(nullptr);
    }();
    Log log{logFile};

    // Required: BeginChild calls must be nested inside a Begin/End block.
    // Without a parent window, BeginChild creates an implicit window whose
    // auto-positioning offsets the layout, making the TUI unusable.
    ImGuiWindowFlags parentFlags = ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoTitleBar |
                                   ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoScrollbar |
                                   ImGuiWindowFlags_NoScrollWithMouse |
                                   ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_MenuBar;
    static bool noClose = true;
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowSize(DisplaySize, ImGuiCond_Always);
    ImGui::Begin("##TuiRoot", &noClose, parentFlags);

    renderMainWindow(state, log);

    ImGui::End();

    if (logFile != nullptr)
        fclose(logFile);

    return true;
}

} // namespace llmfun::tui
