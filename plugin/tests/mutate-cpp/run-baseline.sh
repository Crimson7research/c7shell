#!/usr/bin/env bash
# Runs the mutation baseline against #286's C++ at a38dbca (#310) and writes
# tests/fixtures/tailscale/mutation/baseline.json. Run it directly:
#   plugin/tests/mutate-cpp/run-baseline.sh [--workers N] [--only ID,...]
#
# It builds the reference (build-reference.sh), prepares N workers under
# ${C7_MUTATE_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/mutate-cpp/<sha>},
# each a copy of the reference tree built with all of #286's tests (once),
# builds the harness's scenario and corpus binaries, and runs mutate-cpp.
# A run resumes from the record; --only reruns the mutants named.
set -euo pipefail
shopt -s inherit_errexit

workers=4
only=()
while (($#)); do
  case $1 in
    --workers) workers=${2:?--workers needs a count}; shift 2 ;;
    --only) only=(--only "${2:?--only needs ids}"); shift 2 ;;
    *) printf 'usage: %s [--workers N] [--only ID,...]\n' "$0" >&2; exit 2 ;;
  esac
done
[[ $workers =~ ^[1-9][0-9]*$ ]] || { printf '%s: --workers needs a whole number of at least 1\n' "$0" >&2; exit 2; }

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
plugin=$(cd -- "$here/../.." && pwd)
repo=$(cd -- "$plugin/.." && pwd)
qml=$("$plugin/tests/tailscale-parity/build-reference.sh" | tail -1)
reference=$(cd -- "$qml/../.." && pwd)
work=${C7_MUTATE_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/mutate-cpp/$sha}

for ((i = 0; i < workers; i++)); do
  w=$work/w$i
  if [[ ! -f $w/out/.c7-built ]]; then
    rm -rf -- "$w"
    mkdir -p -- "$w"
    cp -a -- "$reference/tree" "$w/tree"
    cmake -S "$w/tree/plugin" -B "$w/out" -DCMAKE_BUILD_TYPE=Debug >&2
    cmake --build "$w/out" --parallel "$(nproc)" >&2
    touch "$w/out/.c7-built"
  fi
done

cd "$plugin"
# shellcheck source=../../../tests/fixtures/cargo-env.sh
. "$repo/tests/fixtures/cargo-env.sh"
cargo build --locked -q -p mutate-cpp
bins=$(cargo test --locked -p tailscale-parity --test scenarios --test corpus --no-run 2>&1)
scenarios=$(grep -oE '[^ (]*/deps/scenarios-[0-9a-f]+' <<<"$bins" | tail -1)
corpus=$(grep -oE '[^ (]*/deps/corpus-[0-9a-f]+' <<<"$bins" | tail -1)
[[ -x $scenarios && -x $corpus ]] || { printf '%s: no harness binaries in:\n%s\n' "$0" "$bins" >&2; exit 2; }

mkdir -p -- "$repo/tests/fixtures/tailscale/mutation"
exec "$plugin/../target/debug/mutate-cpp" run --reference "$reference" --work "$work" --workers "$workers" \
  --record "$repo/tests/fixtures/tailscale/mutation/baseline.json" --source "$sha" \
  --scenarios-bin "$scenarios" --corpus-bin "$corpus" "${only[@]}"
