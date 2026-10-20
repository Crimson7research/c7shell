#!/usr/bin/env bash
# Check 3: line (and, on nightly, branch) coverage of the Rust inside the
# cxx-qt bridge, collected while QML drives it.
#
#   ./coverage.sh                         # stable: line + region coverage
#   TOOLCHAIN=+nightly BRANCH=--branch ./coverage.sh   # adds branch coverage
#   TESTS="check5_headless" ./coverage.sh # pick the QML-driven tests to run
#
# The tests load the plugin through the QML import path, not by linking it,
# so plain `cargo llvm-cov` cannot see it. Instead: export cargo-llvm-cov's
# environment, build and stage the instrumented cdylib, run the tests against
# that staged copy, then report. The instrumented .so writes its own .profraw
# at process exit; the report maps it through target/cov/debug/libc7spike.so,
# which is byte-identical to the staged libC7Spike.so.
set -euo pipefail
cd "$(dirname "$0")"

TOOLCHAIN=${TOOLCHAIN:-}
BRANCH=${BRANCH:-}
TESTS=${TESTS:-"check1a_load check2_stable_rows check4a_shutdown check5_headless"}
# cxx-qt glue that is not ours: the cxx-qt / cxx-qt-lib / cxx crates in
# ~/.cargo/registry. Generated C++ is never instrumented (only rustc emits
# coverage). On nightly, rustc also maps a few cxx-qt thunks to the
# declarations in bridge.rs, so bridge.rs (declarations only, no logic) is
# excluded too. cargo-llvm-cov already hides ~/.cargo/registry by default.
IGNORE=${IGNORE:-'(/\.cargo/registry/|/rustc/|/xtask/|/spike-tests/|c7spike/src/bridge\.rs$)'}

# One target dir per toolchain: cargo-llvm-cov reads every object under it,
# and stale objects from the other toolchain corrupt the report.
export CARGO_TARGET_DIR=$PWD/target/cov${TOOLCHAIN:+-${TOOLCHAIN#+}}
# shellcheck disable=SC2086
eval "$(cargo $TOOLCHAIN llvm-cov show-env --sh $BRANCH 2>/dev/null)"
cargo $TOOLCHAIN llvm-cov clean --workspace
cargo $TOOLCHAIN stage >/dev/null
export C7SPIKE_QML_DIR=$CARGO_TARGET_DIR/qml

for t in $TESTS; do
    cargo $TOOLCHAIN test -q -p spike-tests --test "$t"
done

# shellcheck disable=SC2086
cargo $TOOLCHAIN llvm-cov report $BRANCH --ignore-filename-regex "$IGNORE" "$@"
