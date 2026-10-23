#!/usr/bin/env bash
# The Tailscale parity harness passes its self-tests, and every scenario and
# view test matches its declaration on #286 at a38dbca in 50 consecutive
# runs.
# Run it directly: tests/test-tailscale-parity.sh
#
# Checks, in order:
#   1. the harness self-tests that need no reference pass: stub_selftest
#      against the QML-only stub C7, view_selftest against the stub views;
#      and the mutation tool's tests (#310), its committed baseline record
#      among them
#   2. every view test under tests/fixtures/tailscale/views/ matches its
#      cpp-286 declaration on #286's views, 50 consecutive runs
#   3. the harness self-tests against the reference (harness_selftest) pass
#   4. every scenario under tests/fixtures/tailscale/scenarios/ matches its
#      cpp-286 declaration, 50 consecutive runs
#   5. every parser corpus case under tests/fixtures/tailscale/corpus/
#      matches its cpp-286 declaration, 50 consecutive runs
# The reference is not something the suite makes: it is
# plugin/tests/tailscale-parity/build-reference.sh's output, read from
# C7_VIEWS_DIR and C7_QML_DIR or that script's cache. Skips, with the
# reason, without cargo; skips check 2 when C7_VIEWS_DIR is unset and the
# cache holds no views, and checks 3 to 5 when C7_QML_DIR is unset and the
# cache holds no build; fails when either is set but holds no reference,
# when a reference build has no views, and when the cache's tree is stale.
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
run_logged 'the view self-tests' in_plugin cargo test --locked -q -p tailscale-parity --test view_selftest
echo "PASS: the harness self-tests that need no reference pass on the stub"
run_logged 'the mutation tool tests' in_plugin cargo test --locked -q -p mutate-cpp
echo "PASS: the mutation tool's tests pass, and the baseline record holds every survivor's reason"

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha

# 2. the view tests, 50 consecutive runs ---------------------------------------
views=${C7_VIEWS_DIR:-$cache/tree/quickshell/c7shell}
if [[ -z ${C7_VIEWS_DIR:-} && -d $cache/tree ]]; then
  # A cache tree from before the views were extracted, or a partial one, is
  # stale: its stamp names every path extracted.
  stamp=$cache/tree/.c7-reference-sha
  [[ -f $stamp && $(<"$stamp") == "$sha plugin quickshell/c7shell" ]] \
    || fail "the reference tree at $cache/tree predates the views; run plugin/tests/tailscale-parity/build-reference.sh --views"
fi
if [[ -f $views/Modules/Popovers/TailscalePopover.qml ]]; then
  # C7_SCENARIOS is unset, as for the scenarios below.
  run_logged 'the view tests, 50 runs' in_plugin env -u C7_SCENARIOS C7_IMPL=cpp-286 C7_VIEWS_DIR="$views" \
    C7_REPEAT=50 cargo test --locked -q -p tailscale-parity --test views
  grep -qE '^[0-9]+ view tests matched their declarations on cpp-286 in 50 runs$' "$log" \
    || { cat "$log" >&2; fail "the view tests run did not report 50 matching runs"; }
  echo "PASS: $(grep -E 'view tests matched' "$log")"
else
  [[ -z ${C7_VIEWS_DIR:-} ]] || fail "C7_VIEWS_DIR=$C7_VIEWS_DIR holds no Modules/Popovers/TailscalePopover.qml"
  # A C++ reference build without its views would skip them and still pass.
  [[ ! -f ${C7_QML_DIR:-$cache/out/qml}/C7/qmldir ]] \
    || fail "the reference build has no views at $views; run plugin/tests/tailscale-parity/build-reference.sh --views"
  echo "SKIP: no reference views at $views (run plugin/tests/tailscale-parity/build-reference.sh --views)"
fi

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

# 3. the harness self-tests against the reference ------------------------------
run_logged 'the harness self-tests' in_reference cargo test --locked -q -p tailscale-parity --test harness_selftest
echo "PASS: the harness self-tests pass against $qml"

# 4. the scenarios, 50 consecutive runs ----------------------------------------
run_logged 'the scenarios, 50 runs' in_reference env C7_REPEAT=50 \
  cargo test --locked -q -p tailscale-parity --test scenarios
grep -qE '^[0-9]+ scenarios matched their declarations on cpp-286 in 50 runs$' "$log" \
  || { cat "$log" >&2; fail "the scenarios run did not report 50 matching runs"; }
echo "PASS: $(grep -E 'scenarios matched' "$log")"

# 5. the parser corpus, 50 consecutive runs -------------------------------------
run_logged 'the corpus, 50 runs' in_reference env C7_REPEAT=50 \
  cargo test --locked -q -p tailscale-parity --test corpus
grep -qE '^[0-9]+ corpus cases matched their declarations on cpp-286 in 50 runs$' "$log" \
  || { cat "$log" >&2; fail "the corpus run did not report 50 matching runs"; }
echo "PASS: $(grep -E 'corpus cases matched' "$log")"
