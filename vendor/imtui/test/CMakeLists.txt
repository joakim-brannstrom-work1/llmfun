cmake_minimum_required(VERSION 3.10)
project(imtui_test VERSION 0.1.0 LANGUAGES CXX)

# This directory holds the imtui test sources and drivers. The C++ test
# binaries are CMake targets in llmfun/cpp_tui/CMakeLists.txt:
#   imtui_utf8_grid_test          (grid-invariant regression, test_utf8_grid.cpp)
#   imtui_ncurses_fold_redraw_test (PTY fold-row rewrite driver target)
# test_wcwidth.cpp is compiled standalone by build_test.py (no CMake target).
# This stub exists so the test directory stays a recognized CMake project.
# To build and run the tests: python3 build_test.py
