cmake_minimum_required(VERSION 3.10)
project(llmfun_tui VERSION 0.1.0 LANGUAGES CXX)

# C++17 for our sources (imtui uses C++11 internally, unaffected)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Align with imtui.mak: disable shared libs, disable curl, skip examples
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(IMTUI_SUPPORT_CURL OFF CACHE BOOL "" FORCE)
set(IMTUI_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)

# Bring in imtui as a subdirectory — builds imtui, imtui-ncurses, imgui-for-imtui
# imtui-ncurses transitively provides the PUBLIC include path, so no extra target_include_directories needed
add_subdirectory(../vendor/imtui ${CMAKE_BINARY_DIR}/imtui)

# Ensure pthreads are available
find_package(Threads REQUIRED)

# Main executable
add_executable(llmfun_tui
    main.cpp
    tui.cpp
)

target_link_libraries(llmfun_tui PRIVATE
    imtui-ncurses
    Threads::Threads
)
