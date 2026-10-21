#!/usr/bin/env bash
# The C7 plugin's layout holds. Run it directly: tests/test-c7-plugin.sh
#
# Two checks, neither of which builds anything:
#   1. git ignores no file under plugin/ (makepkg's unanchored `src/` once did),
#      so a clean clone has every file the build reads
#   2. plugin/ holds no hand-written C++: the plugin is Rust, and the C++ glue
#      cxx-qt generates is build output under plugin/target
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"

plugin=$repo/plugin
[[ -f $plugin/Cargo.toml ]] || fail "plugin/Cargo.toml is missing"

# 1. ignore rules --------------------------------------------------------------
# ignored PATH... -- print the paths the repository's own rules ignore. Host git
# config is shut out, so a personal excludesFile cannot fail or pass this.
ignored() {
  local rc=0
  printf '%s\n' "$@" \
    | GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -C "$repo" check-ignore --no-index --stdin || rc=$?
  ((rc <= 1)) || fail "git check-ignore exited $rc in $repo"
}

# Not process substitution: errexit cannot see a failing find inside one.
# plugin/target is cargo's output when it runs from the root with
# --manifest-path (see .gitignore), not a source.
files=$(cd "$repo" && find plugin -path plugin/target -prune -o -type f -print)
mapfile -t files <<<"$files"
hits=$(ignored "${files[@]}" plugin/src/x.rs plugin/lib/x/src/lib.rs plugin/tests/x.rs)
[[ -z $hits ]] || fail "git ignores plugin sources, so a clean clone lacks them:\n$hits"
echo "PASS: plugin sources are not ignored"

# 2. no hand-written C++ -------------------------------------------------------
# cpp_files DIR -- print every C++ source or header under DIR, outside target/.
cpp_files() {
  find "$1" -path "$1/target" -prune -o -type f \
    \( -iname '*.cpp' -o -iname '*.cc' -o -iname '*.cxx' \
       -o -iname '*.h' -o -iname '*.hh' -o -iname '*.hpp' -o -iname '*.hxx' \) -print
}

# The check must see each thing it forbids, or an empty result proves nothing.
mktmp
for f in a.cpp b.h c.hpp d.cc e.cxx f.hh g.hxx H.CPP; do
  rm -rf "$tmp/p" && mkdir -p "$tmp/p/lib/x" "$tmp/p/target"
  : >"$tmp/p/lib/x/$f"
  [[ -n $(cpp_files "$tmp/p") ]] || fail "the C++ check missed: $f"
done
rm -rf "$tmp/p" && mkdir -p "$tmp/p/target/cxxbridge"
: >"$tmp/p/target/cxxbridge/gen.cpp"
[[ -z $(cpp_files "$tmp/p") ]] || fail "the C++ check flagged cargo's generated glue under target/"

hits=$(cpp_files "$plugin")
[[ -z $hits ]] || fail "plugin/ must hold no hand-written C++:\n$hits"
echo "PASS: plugin/ holds no hand-written C++"
