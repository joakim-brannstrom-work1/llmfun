module llm.tui;

extern (C++,`ImTui`) {
    struct TScreen;
}

extern (C++,`llmfun`,`tui`) {
    struct String {
        char* data;
        size_t len;
    }

    struct TuiState;

    bool tuiInit(TScreen** screen);
    void tuiShutdown(TScreen* screen);
    bool tuiRender(TuiState* state);
    void tuiAddOutputLine(TuiState* state, String* line);
    void tuiClearInput(TuiState* state);
    void tuiSetStatusText(TuiState* state, String* text);

}
