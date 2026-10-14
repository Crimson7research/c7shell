cmake_minimum_required(VERSION 3.21)
project(c7 VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# The libraries are static and linked into the QML plugin, a shared module.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# No RUNPATH in the installed plugin: it needs only system Qt libraries.
set(CMAKE_SKIP_INSTALL_RPATH ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core DBus Network Qml Test)
qt_standard_project_setup(REQUIRES 6.5)

# Every QML module lands under one directory, so a test imports from it alone.
set(QT_QML_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/qml)

enable_testing()

# c7_add_test(NAME SOURCES src... [LIBS lib...] [LABELS label...]) -- one QtTest
# executable, linked against the test kit, registered with CTest. Its main is
# C7_TEST_MAIN, which cuts it off from the host's buses and directories.
function(c7_add_test name)
    cmake_parse_arguments(T "" "" "SOURCES;LIBS;LABELS" ${ARGN})
    add_executable(${name} ${T_SOURCES})
    target_link_libraries(${name} PRIVATE c7_testing ${T_LIBS})
    add_test(NAME ${name} COMMAND ${name})
    if(T_LABELS)
        set_tests_properties(${name} PROPERTIES LABELS "${T_LABELS}")
    endif()
endfunction()

# The test kit first: every other library's tests link it.
add_subdirectory(lib/testing)
# Plain C++ libraries: Qt Core, Network and DBus only, never QML.
add_subdirectory(lib/core)

# The C7 QML module: contracts in src/contracts/, backends in src/backends/.
# The backing target is the plugin, so one library in qml/C7/ is the whole
# module.
qt_add_qml_module(c7
    URI C7
    VERSION 1.0
    PLUGIN_TARGET c7
    SOURCES src/build.h
)
# The generated type registration includes each header by its bare name.
target_include_directories(c7 PRIVATE src)
target_link_libraries(c7 PRIVATE c7_core)

# Installed where Qt finds every system QML module, /usr/lib/qt6/qml/C7 on Arch.
set(c7_qml_dir ${QT6_INSTALL_QML}/C7)
install(TARGETS c7 LIBRARY DESTINATION ${c7_qml_dir})
install(FILES ${QT_QML_OUTPUT_DIRECTORY}/C7/qmldir ${QT_QML_OUTPUT_DIRECTORY}/C7/c7.qmltypes
    DESTINATION ${c7_qml_dir})

add_subdirectory(tests)
