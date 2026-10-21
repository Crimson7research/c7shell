#!/usr/bin/env bash
# Builds #286's C7 module at a38dbca, the C++ the Phase 2 scenarios
# characterise, and prints the directory to pass as C7_QML_DIR (the one
# holding C7/qmldir) as its last line. Run it directly:
#   plugin/tests/tailscale-parity/build-reference.sh
#
# The source is a detached git worktree of this repository at that commit,
# under ${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/<sha>,
# built there with #286's own CMake. A second run rebuilds only what changed.
# It never touches another checkout of #286.
set -euo pipefail
shopt -s inherit_errexit

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha

fail() { printf 'build-reference: %s\n' "$1" >&2; exit 2; }

if ! git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null; then
  git -C "$repo" fetch --quiet origin feat/tailscale-backend >&2 || true
  git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
    || fail "commit $sha is not in $repo, and fetching origin feat/tailscale-backend did not bring it"
fi

mkdir -p -- "$(dirname -- "$cache")"
if [[ ! -e $cache/src/.git ]]; then
  # --force: a worktree registered at this path whose directory was removed
  # is taken over rather than refused. Nothing else is pruned, so other
  # checkouts' worktree records are left alone.
  git -C "$repo" worktree add --quiet --force --detach "$cache/src" "$sha" >&2
fi
[[ $(git -C "$cache/src" rev-parse HEAD) == "$sha" ]] || fail "$cache/src is not at $sha"
[[ -z $(git -C "$cache/src" status --porcelain) ]] || fail "$cache/src has local changes"

gen=()
if command -v ninja >/dev/null; then gen=(-G Ninja); fi
if [[ ! -f $cache/build/CMakeCache.txt ]]; then
  cmake -S "$cache/src/plugin" -B "$cache/build" "${gen[@]}" -DCMAKE_BUILD_TYPE=Debug >&2
fi
cmake --build "$cache/build" --target c7 --parallel "$(nproc)" >&2

[[ -f $cache/build/qml/C7/qmldir ]] || fail "the build left no $cache/build/qml/C7/qmldir"
echo "$cache/build/qml"
