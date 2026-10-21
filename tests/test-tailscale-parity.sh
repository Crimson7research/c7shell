#!/usr/bin/env bash
# The Tailscale parity harness passes its self-tests, and every scenario
# matches its declaration on #286's C7 at a38dbca in 50 consecutive runs.
# Run it directly: tests/test-tailscale-parity.sh
#
# Checks, in order:
#   1. the harness self-tests (harness_selftest) pass against the reference
#   2. every scenario under tests/fixtures/tailscale/scenarios/ matches its
#      cpp-286 declaration, 50 consecutive runs
# The reference build is not something the suite makes: it is
# plugin/tests/tailscale-parity/build-reference.sh's output, read from
# C7_QML_DIR or that script's cache. Skips, with the reason, without cargo
# or without that build. tests/test-fake-tailscaled.sh compiles the harness
# either way.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"

if ! command -v cargo >/dev/null; then
  echo 'SKIP: cargo is not on PATH (package: rust); the parity harness is not built'
  exit 0
fi

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha
qml=${C7_QML_DIR:-$cache/out/qml}
if [[ ! -f $qml/C7/qmldir ]]; then
  echo "SKIP: no reference build at $qml (run plugin/tests/tailscale-parity/build-reference.sh)"
  exit 0
fi

plugin=$repo/plugin
mktmp
log=$tmp/log
# run_logged WHAT CMD... -- run CMD into $log; on failure show the log, then fail.
run_logged() {
  local what=$1
  shift
  "$@" >"$log" 2>&1 && return 0
  cat "$log" >&2
  fail "$what failed (log above)"
}
# in_plugin CMD... -- run CMD in plugin/, with the reference chosen. Cargo
# reads .cargo/config.toml from the working directory.
in_plugin() { (cd "$plugin" && C7_IMPL=cpp-286 C7_QML_DIR=$qml "$@"); }

# 1. the harness self-tests ----------------------------------------------------
run_logged 'the harness self-tests' in_plugin cargo test --locked -q -p tailscale-parity --test harness_selftest
echo "PASS: the harness self-tests pass against $qml"

# 2. the scenarios, 50 consecutive runs ----------------------------------------
run_logged 'the scenarios, 50 runs' in_plugin env C7_REPEAT=50 \
  cargo test --locked -q -p tailscale-parity --test scenarios
grep -qE '^[0-9]+ scenarios matched their declarations on cpp-286 in 50 runs$' "$log" \
  || { cat "$log" >&2; fail "the scenarios run did not report 50 matching runs"; }
echo "PASS: $(grep -E 'scenarios matched' "$log")"
