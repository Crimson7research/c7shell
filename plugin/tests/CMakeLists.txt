c7_add_test(tst_module SOURCES tst_module.cpp LIBS c7_core Qt6::Qml LABELS testing)
target_compile_definitions(tst_module PRIVATE C7_QML_IMPORT_PATH="${QT_QML_OUTPUT_DIRECTORY}")
# The test loads the plugin at run time, so it has to be built first.
add_dependencies(tst_module c7)
# Pinned, so an import path in the caller's environment (makepkg passes its
# own through) cannot choose which copy of C7 this test loads.
set_tests_properties(tst_module PROPERTIES
    ENVIRONMENT "C7_QML_IMPORT_PATH=${QT_QML_OUTPUT_DIRECTORY}")

# The contract itself, driven through a TailscaleBackend * holding the fake
# backend. The two headers are listed so AUTOMOC sees them: they belong to the
# QML module's sources, but the fake is deliberately not one of them, which is
# what keeps it out of what `cmake --install` ships.
c7_add_test(tst_tailscalebackend
    SOURCES tst_tailscalebackend.cpp
            ${PROJECT_SOURCE_DIR}/src/contracts/TailscaleBackend.h
            ${PROJECT_SOURCE_DIR}/src/backends/tailscale/FakeTailscaleBackend.h
    LIBS c7_tailscale Qt6::Qml
    LABELS testing)
target_include_directories(tst_tailscalebackend PRIVATE ${PROJECT_SOURCE_DIR}/src)
