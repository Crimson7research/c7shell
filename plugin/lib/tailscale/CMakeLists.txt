add_library(c7_tailscale STATIC Types.h StatusParser.h StatusParser.cpp)
# plugin/lib is the include root, so headers read "tailscale/Types.h".
target_include_directories(c7_tailscale PUBLIC ${PROJECT_SOURCE_DIR}/lib)
target_link_libraries(c7_tailscale PUBLIC Qt6::Core)

c7_add_test(tst_statusparser SOURCES tests/tst_statusparser.cpp LIBS c7_tailscale)
# Captures of `tailscale status --json`, redacted; the test reads them from
# the source tree so it does not depend on where the build directory is.
target_compile_definitions(tst_statusparser PRIVATE
    C7_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
