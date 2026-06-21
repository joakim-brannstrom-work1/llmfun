#include "tui.h"

#include "imtui/imtui-impl-ncurses.h"
#include "imtui/imtui-impl-text.h"

#include <cstdio>

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
    // Note: ImTui_ImplNcurses_Shutdown() is global and does not take a screen
    // parameter (see imtui-impl-ncurses.h). The TScreen object is owned by the
    // ncurses backend and will be freed internally during shutdown.
    (void)screen; // Owned by ncurses backend; freed during ImTui_ImplNcurses_Shutdown()
    ImTui_ImplText_Shutdown();
    ImTui_ImplNcurses_Shutdown();
    ImGui::DestroyContext();
}

// ─── Task 5: Render Function — Output Area ───────────────────────────────────

bool tuiRender(TuiState& state) {
    ImVec2 DisplaySize = ImGui::GetIO().DisplaySize;

    // Minimum terminal size check
    if (DisplaySize.x < 40 || DisplaySize.y < 15) {
        ImGui::Begin("Error");
        ImGui::Text("Terminal too small! Minimum size: 40x15");
        ImGui::End();
        return true;
    }

    // Keyboard shortcuts (using modern KeyMods bitmask)
    ImGuiKeyMods mods = ImGui::GetIO().KeyMods;
    if ((mods & ImGuiMod_Ctrl) &&
        (ImGui::IsKeyPressed(ImGuiKey_C) || ImGui::IsKeyPressed(ImGuiKey_D))) {
        return false;
    }
    if ((mods & ImGuiMod_Ctrl) && ImGui::IsKeyPressed(ImGuiKey_L)) {
        if (!ImGui::IsAnyItemActive()) { // Only clear if no widget has focus
            tuiClearOutput(state);
        }
    }

    // End key: scroll output to bottom and re-enable auto-scroll
    if (ImGui::IsKeyPressed(ImGuiKey_End)) {
        state.autoScroll = true;
    }

    // ── Output Area ──────────────────────────────────────────────────────────
    // Clamp height to avoid negative values on very small terminals
    ImVec2 outPos(0, 0);
    ImVec2 outSize(DisplaySize.x, ImMax(1.0f, DisplaySize.y - 3));

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

    // ── Task 6: Input Area ───────────────────────────────────────────────────────
    ImVec2 inputPos(0, DisplaySize.y - 3);
    ImVec2 inputSize(DisplaySize.x, 2);

    ImGui::SetNextWindowPos(inputPos, ImGuiCond_Always);
    ImGui::SetNextWindowSize(inputSize, ImGuiCond_Always);

    ImGuiWindowFlags inputFlags = ImGuiWindowFlags_None;
    ImGui::BeginChild("input", inputSize, false, inputFlags);

    ImGuiInputTextFlags flags =
        ImGuiInputTextFlags_CallbackResize | ImGuiInputTextFlags_EnterReturnsTrue;

    bool submitted =
        ImGui::InputTextMultiline("##input", state.inputBuf.data(), state.inputBuf.size() + 1,
                                  ImVec2(-FLT_MIN, 0), flags, InputResizeCallback, &state.inputBuf);

    // All input state modifications are protected by outputMutex to prevent
    // data races with worker threads calling tuiGetInput/tuiClearInput etc.
    {
        std::lock_guard<std::mutex> lock(state.outputMutex);

        if (submitted) {
            state.submitReady = true;
        }

        // Escape clears the input buffer
        if (ImGui::IsItemActive() && ImGui::IsKeyPressed(ImGuiKey_Escape)) {
            state.inputBuf.clear();
        }

        // History navigation: Ctrl+Up/Ctrl+Down to avoid conflict with
        // InputTextMultiline's internal cursor movement.
        if (ImGui::IsItemActive() && ImGui::GetIO().KeyCtrl) {
            if (ImGui::IsKeyPressed(ImGuiKey_UpArrow)) {
                // Navigate backward in history
                if (state.historyPos == -1) {
                    // First press: save draft and push current input to history.
                    state.draftBuf = state.inputBuf;
                    if (state.inputHistory.empty() || state.inputHistory.back() != state.inputBuf) {
                        state.inputHistory.push_back(state.inputBuf);
                        if (state.inputHistory.size() > state.MAX_HISTORY) {
                            state.inputHistory.erase(state.inputHistory.begin());
                        }
                    }
                    // Point to the entry before the one we just saved (if any).
                    state.historyPos = static_cast<int>(state.inputHistory.size()) - 2;
                } else if (state.historyPos > 0) {
                    state.historyPos--;
                }
                if (state.historyPos >= 0) {
                    state.inputBuf = state.inputHistory[state.historyPos];
                }
            } else if (ImGui::IsKeyPressed(ImGuiKey_DownArrow)) {
                // Navigate forward in history
                if (state.historyPos >= 0) {
                    state.historyPos++;
                    if (static_cast<size_t>(state.historyPos) < state.inputHistory.size()) {
                        state.inputBuf = state.inputHistory[state.historyPos];
                    } else {
                        // Past the end: restore the saved draft and reset.
                        state.inputBuf = state.draftBuf;
                        state.historyPos = -1;
                    }
                }
            }
        }

        // When submitting, push the input to history if non-empty and not a
        // duplicate of the most recent entry.
        if (submitted && !state.inputBuf.empty()) {
            if (state.inputHistory.empty() || state.inputHistory.back() != state.inputBuf) {
                state.inputHistory.push_back(state.inputBuf);
                if (state.inputHistory.size() > state.MAX_HISTORY) {
                    state.inputHistory.erase(state.inputHistory.begin());
                }
            }
            state.historyPos = -1;
        }
    }

    ImGui::EndChild();

    // ── Task 7: Status Line ──────────────────────────────────────────────────
    ImVec2 statusPos(0, DisplaySize.y - 1);
    ImVec2 statusSize(DisplaySize.x, 1);

    ImGui::SetNextWindowPos(statusPos, ImGuiCond_Always);
    ImGui::SetNextWindowSize(statusSize, ImGuiCond_Always);

    ImGuiWindowFlags statusFlags = ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoResize |
                                   ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoTitleBar |
                                   ImGuiWindowFlags_NoScrollbar |
                                   ImGuiWindowFlags_NoScrollWithMouse;
    ImGui::BeginChild("status", statusSize, false, statusFlags);

    static constexpr std::string_view defaultStatus = "Context: 0/0 tokens | Model: none | Ready";

    if (state.statusText.empty()) {
        ImGui::TextUnformatted(defaultStatus);
    } else {
        ImGui::TextUnformatted(state.statusText.c_str());
    }

    ImGui::EndChild();

    return true;
}
