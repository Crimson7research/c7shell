#!/usr/bin/env bash
# Builds #286's C7 module at a38dbca, the C++ the Phase 2 scenarios
# characterise, and prints the directory to pass as C7_QML_DIR (the one
# holding C7/qmldir) as its last line. Run it directly:
#   plugin/tests/tailscale-parity/build-reference.sh [--views]
# With --views it builds nothing and prints the directory to pass as
# C7_VIEWS_DIR instead: that commit's quickshell/c7shell/, #286's views.
#
# The source is that commit's plugin/ and quickshell/c7shell/ trees,
# extracted with `git archive` into
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

views=0
case ${1-} in
  '') ;;
  --views) views=1 ;;
  *) printf 'usage: %s [--views]\n' "$0" >&2; exit 2 ;;
esac

git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null \
  || fail "commit $sha is not in $repo; run: git -C $repo fetch origin feat/tailscale-backend"

# The stamp names the commit and the paths the tree was extracted from, and
# is written last, so a tree without it is a partial extraction, and a tree
# of fewer paths an older one, and either is redone.
paths=(plugin quickshell/c7shell)
stamp=$cache/tree/.c7-reference-sha
if [[ ! -f $stamp || $(<"$stamp") != "$sha ${paths[*]}" ]]; then
  rm -rf -- "$cache/tree" "$cache/tree.partial"
  mkdir -p -- "$cache/tree.partial"
  git -C "$repo" archive --format=tar "$sha" "${paths[@]}" | tar -x -C "$cache/tree.partial"
  printf '%s\n' "$sha ${paths[*]}" >"$cache/tree.partial/.c7-reference-sha"
  mv -- "$cache/tree.partial" "$cache/tree"
fi

if ((views)); then
  [[ -f $cache/tree/quickshell/c7shell/Modules/Popovers/TailscalePopover.qml ]] \
    || fail "the tree holds no quickshell/c7shell/Modules/Popovers/TailscalePopover.qml"
  echo "$cache/tree/quickshell/c7shell"
  exit 0
fi

gen=()
if command -v ninja >/dev/null; then gen=(-G Ninja); fi
# compile_commands.json is what plugin/tests/mutate-cpp reads the sources
# with (#310); a build configured before it was exported is configured again.
if [[ ! -f $cache/out/CMakeCache.txt || ! -f $cache/out/compile_commands.json ]]; then
  cmake -S "$cache/tree/plugin" -B "$cache/out" "${gen[@]}" -DCMAKE_BUILD_TYPE=Debug \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON >&2
fi
cmake --build "$cache/out" --target c7 --parallel "$(nproc)" >&2

[[ -f $cache/out/qml/C7/qmldir ]] || fail "the build left no $cache/out/qml/C7/qmldir"
echo "$cache/out/qml"
