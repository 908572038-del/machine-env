cmake_minimum_required(VERSION 3.21)

project(machine-env-cpp VERSION 0.4.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "machine-env-cpp currently supports Windows only")
endif()

add_executable(machine-env-cpp
    src/main.cpp
    src/machine.cpp
)

# project(... VERSION ...) is the only place the version is written. Generating a
# header from it means --version, the fingerprint, the installer's uninstall
# entry and the release tag cannot drift apart -- a release that reports the
# previous version is a claim about the machine that is simply wrong.
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/src/version.hpp.in"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/version.hpp"
    @ONLY)
target_include_directories(machine-env-cpp PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/generated")

target_compile_features(machine-env-cpp PRIVATE cxx_std_20)
target_compile_definitions(machine-env-cpp PRIVATE UNICODE _UNICODE)
target_compile_options(machine-env-cpp PRIVATE
    # /Zc:__cplusplus makes __cplusplus report the real language version instead
    # of MSVC's long-standing 199711L, so a feature test in the source cannot
    # silently answer about C++98.
    $<$<CXX_COMPILER_ID:MSVC>:/W4 /EHsc /utf-8 /permissive- /Zc:__cplusplus>
)
target_link_libraries(machine-env-cpp PRIVATE winhttp advapi32 shell32)

# C++20 is a requirement, not a preference: the code uses <format>, <span>,
# <bit> and concepts directly. A toolset without them fails to compile, which is
# the honest outcome -- silently falling back to a C++17 spelling would mean two
# code paths, one of which nothing would be testing.
#
# MSVC only reports __cplusplus correctly with /Zc:__cplusplus; without it a
# feature test in the source answers about C++98.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set_target_properties(machine-env-cpp PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)
