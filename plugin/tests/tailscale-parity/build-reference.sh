#!/usr/bin/env bash
# Builds #286's C7 module at a38dbca, the C++ the Phase 2 scenarios
# characterise, and prints the directory to pass as C7_QML_DIR (the one
# holding C7/qmldir) as its last line. Run it directly:
#   plugin/tests/tailscale-parity/build-reference.sh
#
# The source is that commit's plugin/ tree, extracted with `git archive` into
# ${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/<sha>/tree,
# and built there with #286's own CMake. A second run rebuilds only what
# changed. It only reads the repository: no worktree is registered and
# nothing is fetched, so nothing is written to its .git. It never touches
# another checkout of #286.
set -euo pipefail
shopt -s inherit_errexit

sha=a38dbcae841a1134514f68cba8f5b98d4efddb68
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha

fail() { printf 'build-reference: %s\n' "$1" >&2; exit 2; }

git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
  || fail "commit $sha is not in $repo; run: git -C $repo fetch origin feat/tailscale-backend"

# The stamp names the commit the tree was extracted from, and is written
# last, so a tree without it is a partial extraction and is redone.
stamp=$cache/tree/.c7-reference-sha
if [[ ! -f $stamp || $(<"$stamp") != "$sha" ]]; then
  rm -rf -- "$cache/tree" "$cache/tree.partial"
  mkdir -p -- "$cache/tree.partial"
  git -C "$repo" archive --format=tar "$sha" plugin | tar -x -C "$cache/tree.partial"
  printf '%s\n' "$sha" >"$cache/tree.partial/.c7-reference-sha"
  mv -- "$cache/tree.partial" "$cache/tree"
fi

gen=()
if command -v ninja >/dev/null; then gen=(-G Ninja); fi
if [[ ! -f $cache/out/CMakeCache.txt ]]; then
  cmake -S "$cache/tree/plugin" -B "$cache/out" "${gen[@]}" -DCMAKE_BUILD_TYPE=Debug >&2
fi
cmake --build "$cache/out" --target c7 --parallel "$(nproc)" >&2

[[ -f $cache/out/qml/C7/qmldir ]] || fail "the build left no $cache/out/qml/C7/qmldir"
echo "$cache/out/qml"
