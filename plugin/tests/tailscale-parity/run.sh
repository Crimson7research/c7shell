#!/usr/bin/env bash
# Runs the Tailscale scenarios against #286's C7 at a38dbca. Run it directly:
#   plugin/tests/tailscale-parity/run.sh [--repeat N]
# It builds the reference first (build-reference.sh, a no-op once built).
set -euo pipefail
shopt -s inherit_errexit

repeat=1
while (($#)); do
  case $1 in
    --repeat) repeat=${2:?--repeat needs a count}; shift 2 ;;
    *) printf 'usage: %s [--repeat N]\n' "$0" >&2; exit 2 ;;
  esac
done

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
qml=$("$here/build-reference.sh" | tail -1)
cd "$here/../.."
C7_IMPL=cpp-286 C7_QML_DIR=$qml C7_REPEAT=$repeat cargo test --locked -q -p tailscale-parity --test scenarios
