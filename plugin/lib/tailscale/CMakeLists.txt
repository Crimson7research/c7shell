add_library(c7_tailscale STATIC
    Types.h
    StatusParser.h StatusParser.cpp
    PeerModel.h PeerModel.cpp
    LocalApiClient.h LocalApiClient.cpp)
# plugin/lib is the include root, so headers read "tailscale/Types.h".
target_include_directories(c7_tailscale PUBLIC ${PROJECT_SOURCE_DIR}/lib)
# Qt6::Network for QLocalSocket: the local API speaks HTTP over a Unix socket.
target_link_libraries(c7_tailscale PUBLIC Qt6::Core Qt6::Network)

c7_add_test(tst_statusparser SOURCES tests/tst_statusparser.cpp LIBS c7_tailscale)
c7_add_test(tst_peermodel SOURCES tests/tst_peermodel.cpp LIBS c7_tailscale)
c7_add_test(tst_localapiclient SOURCES tests/tst_localapiclient.cpp LIBS c7_tailscale)
# Captures of `tailscale status --json`, redacted; the tests read them from
# the source tree so they do not depend on where the build directory is.
foreach(t tst_statusparser tst_peermodel)
    target_compile_definitions(${t} PRIVATE
        C7_FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
endforeach()
