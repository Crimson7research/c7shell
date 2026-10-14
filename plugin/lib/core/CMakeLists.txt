add_library(c7_core STATIC version.h version.cpp)
# plugin/lib is the include root, so headers read "core/version.h" and two
# libraries' same-named headers never clash.
target_include_directories(c7_core PUBLIC ${PROJECT_SOURCE_DIR}/lib)
target_link_libraries(c7_core PUBLIC Qt6::Core)
target_compile_definitions(c7_core PRIVATE C7_VERSION="${PROJECT_VERSION}")

c7_add_test(tst_version SOURCES tests/tst_version.cpp LIBS c7_core)
target_compile_definitions(tst_version PRIVATE C7_EXPECTED_VERSION="${PROJECT_VERSION}")
