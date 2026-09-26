cmake_minimum_required(VERSION 3.21)

project(machine-env VERSION 0.2.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "machine-env currently supports Windows only")
endif()

add_executable(machine-env
    src/main.cpp
    src/machine.cpp
)

target_compile_features(machine-env PRIVATE cxx_std_17)
target_compile_definitions(machine-env PRIVATE UNICODE _UNICODE)
target_compile_options(machine-env PRIVATE
    $<$<CXX_COMPILER_ID:MSVC>:/W4 /EHsc /utf-8 /permissive->
)
target_link_libraries(machine-env PRIVATE winhttp advapi32 shell32)

set_target_properties(machine-env PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}"
)
