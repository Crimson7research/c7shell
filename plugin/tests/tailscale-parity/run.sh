#!/usr/bin/env bash
# Runs the Tailscale scenarios and the parser corpus against #286's C7 at
# a38dbca, and the view tests against #286's views. Run it directly:
#   plugin/tests/tailscale-parity/run.sh [--repeat N]
# It builds the reference first (build-reference.sh, a no-op once built).
set -euo pipefail
shopt -s inherit_errexit

repeat=1
while (($#)); do
  case $1 in
    --repeat)
      repeat=${2:?--repeat needs a count}
      [[ $repeat =~ ^[1-9][0-9]*$ ]] || { printf '%s: --repeat needs a whole number of at least 1, not %q\n' "$0" "$repeat" >&2; exit 2; }
      shift 2 ;;
    *) printf 'usage: %s [--repeat N]\n' "$0" >&2; exit 2 ;;
  esac
done

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
qml=$("$here/build-reference.sh" | tail -1)
views=$("$here/build-reference.sh" --views | tail -1)
cd "$here/../.."
# shellcheck source=../../../tests/fixtures/cargo-env.sh
. "$here/../../../tests/fixtures/cargo-env.sh"
# Every scenario and case: a C7_SCENARIOS filter left exported would run a
# subset and still report success.
unset C7_SCENARIOS
C7_IMPL=cpp-286 C7_QML_DIR=$qml C7_REPEAT=$repeat cargo test --locked -q -p tailscale-parity --test scenarios
C7_IMPL=cpp-286 C7_QML_DIR=$qml C7_REPEAT=$repeat cargo test --locked -q -p tailscale-parity --test corpus
C7_IMPL=cpp-286 C7_VIEWS_DIR=$views C7_REPEAT=$repeat cargo test --locked -q -p tailscale-parity --test views
