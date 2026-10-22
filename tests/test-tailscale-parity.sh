#!/usr/bin/env bash
# The Tailscale parity harness passes its self-tests, and every scenario
# matches its declaration on #286's C7 at a38dbca in 50 consecutive runs.
# Run it directly: tests/test-tailscale-parity.sh
#
# Checks, in order:
#   1. the harness self-tests that need no reference (stub_selftest) pass
#      against the QML-only stub C7
#   2. the harness self-tests against the reference (harness_selftest) pass
#   3. every scenario under tests/fixtures/tailscale/scenarios/ matches its
#      cpp-286 declaration, 50 consecutive runs
#   4. every parser corpus case under tests/fixtures/tailscale/corpus/
#      matches its cpp-286 declaration, 50 consecutive runs
# The reference build is not something the suite makes: it is
# plugin/tests/tailscale-parity/build-reference.sh's output, read from
# C7_QML_DIR or that script's cache. Skips, with the reason, without cargo;
# skips checks 2 to 4 when C7_QML_DIR is unset and the cache holds no build,
# and fails when C7_QML_DIR is set but holds no C7/qmldir.
# tests/test-fake-tailscaled.sh compiles the harness either way.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"

if ! command -v cargo >/dev/null; then
  echo 'SKIP: cargo is not on PATH (package: rust); the parity harness is not built'
  exit 0
fi

plugin=$repo/plugin
mktmp
# makepkg check() sets RUSTFLAGS and LTO flags the workspace cannot link with.
# shellcheck source=fixtures/cargo-env.sh
. "$repo/tests/fixtures/cargo-env.sh"
log=$tmp/log
# run_logged WHAT CMD... -- run CMD into $log; on failure show the log, then fail.
run_logged() {
  local what=$1
  shift
  "$@" >"$log" 2>&1 && return 0
  cat "$log" >&2
  fail "$what failed (log above)"
}
# in_plugin CMD... -- run CMD in plugin/. Cargo reads .cargo/config.toml from
# the working directory.
in_plugin() { (cd "$plugin" && "$@"); }

# 1. the stub self-tests -------------------------------------------------------
run_logged 'the stub self-tests' in_plugin cargo test --locked -q -p tailscale-parity --test stub_selftest
echo "PASS: the harness self-tests that need no reference pass on the stub"

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha
qml=${C7_QML_DIR:-$cache/out/qml}
if [[ ! -f $qml/C7/qmldir ]]; then
  # A directory named on purpose that holds no C7 is a mistake, not a
  # reference not built yet.
  [[ -z ${C7_QML_DIR:-} ]] || fail "C7_QML_DIR=$C7_QML_DIR holds no C7/qmldir"
  echo "SKIP: no reference build at $qml (run plugin/tests/tailscale-parity/build-reference.sh)"
  exit 0
fi
# in_reference CMD... -- in_plugin, with the reference chosen.
# C7_SCENARIOS is unset: a filter left exported while debugging would let
# the gate pass on a subset of the scenarios and cases.
in_reference() { in_plugin env -u C7_SCENARIOS C7_IMPL=cpp-286 C7_QML_DIR="$qml" "$@"; }

# 2. the harness self-tests against the reference ------------------------------
run_logged 'the harness self-tests' in_reference cargo test --locked -q -p tailscale-parity --test harness_selftest
echo "PASS: the harness self-tests pass against $qml"

# 3. the scenarios, 50 consecutive runs ----------------------------------------
run_logged 'the scenarios, 50 runs' in_reference env C7_REPEAT=50 \
  cargo test --locked -q -p tailscale-parity --test scenarios
grep -qE '^[0-9]+ scenarios matched their declarations on cpp-286 in 50 runs$' "$log" \
  || { cat "$log" >&2; fail "the scenarios run did not report 50 matching runs"; }
echo "PASS: $(grep -E 'scenarios matched' "$log")"

# 4. the parser corpus, 50 consecutive runs -------------------------------------
run_logged 'the corpus, 50 runs' in_reference env C7_REPEAT=50 \
  cargo test --locked -q -p tailscale-parity --test corpus
grep -qE '^[0-9]+ corpus cases matched their declarations on cpp-286 in 50 runs$' "$log" \
  || { cat "$log" >&2; fail "the corpus run did not report 50 matching runs"; }
echo "PASS: $(grep -E 'corpus cases matched' "$log")"
