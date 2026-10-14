# Per-test fakes of the outside world: a private dbus-daemon, a fake Unix
# socket server, a fake program. Linked into tests only; never installed.

# Found now: under C7_TEST_MAIN a test's PATH holds no host programs.
find_program(C7_DBUS_DAEMON dbus-daemon REQUIRED)

# What FakeProgram puts on disk under the name of the program it stands in for.
add_executable(c7-fake-program fakeprogram_main.cpp)
target_include_directories(c7-fake-program PRIVATE ${PROJECT_SOURCE_DIR}/lib)
target_link_libraries(c7-fake-program PRIVATE Qt6::Core)

add_library(c7_testing STATIC
    privatebus.h privatebus.cpp
    fakeservice.h fakeservice.cpp
    fakesocketserver.h fakesocketserver.cpp
    fakeprogram.h fakeprogram.cpp
    testmain.h testmain.cpp
    wait.h
)
target_include_directories(c7_testing PUBLIC ${PROJECT_SOURCE_DIR}/lib)
target_link_libraries(c7_testing PUBLIC Qt6::Core Qt6::DBus Qt6::Network Qt6::Test)
target_compile_definitions(c7_testing PRIVATE
    C7_FAKE_PROGRAM_BIN="$<TARGET_FILE:c7-fake-program>"
    C7_DBUS_DAEMON="${C7_DBUS_DAEMON}")
add_dependencies(c7_testing c7-fake-program)

# A test that dies with a PrivateBus alive, for tst_privatebus.
add_executable(c7-privatebus-crash helpers/privatebus_crash.cpp)
target_link_libraries(c7-privatebus-crash PRIVATE c7_testing)

foreach(t privatebus fakeservice fakesocketserver fakeprogram wait isolation)
    c7_add_test(tst_${t} SOURCES tests/tst_${t}.cpp LABELS testing)
endforeach()
target_compile_definitions(tst_privatebus PRIVATE
    C7_PRIVATEBUS_CRASH_BIN="$<TARGET_FILE:c7-privatebus-crash>")
add_dependencies(tst_privatebus c7-privatebus-crash)
