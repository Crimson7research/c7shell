#!/usr/bin/env bash
# Self-check for PKGBUILD's package(). Run it directly: tests/test-packaging.sh
#
# Every program in bin/ has to be named in package() or it is simply not in the
# package -- and nothing else notices. The scripts are found by name on PATH
# (hyprlock.conf calls c7shell-lock-info, binds.lua calls c7shell-lock), so a
# missing install line produces no error anywhere: the config asks for a command
# that does not exist and the caller gets silence. That is how the lock screen
# shipped once with its keybind pointing at a binary the package never
# installed, which meant nothing locked at all.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
root=$repo
pkgbuild=$root/PKGBUILD

[[ -f $pkgbuild ]] || fail 'PKGBUILD is missing'

missing=()
for prog in "$root"/bin/*; do
  [[ -f $prog ]] || continue
  name=${prog##*/}
  # The literal install line, not just the name: a mention in a comment is not
  # a file in the package.
  grep -qF "install -Dm755 bin/$name " "$pkgbuild" || missing+=("$name")
done

if ((${#missing[@]})); then
  fail "package() never installs: ${missing[*]}
these are called by name on PATH, so the only symptom is the caller silently
doing nothing. Add an install -Dm755 line for each."
fi

# The reverse: a line naming a program that no longer exists fails the build
# outright, which is louder but still worth catching before makepkg does.
while read -r name; do
  [[ -f $root/bin/$name ]] || fail "package() installs bin/$name, which does not exist"
done < <(grep -oE 'install -Dm755 bin/[A-Za-z0-9._-]+' "$pkgbuild" | sed 's|.*bin/||')

# Executability travels into the package via install -m755, but a script that is
# not executable in the tree cannot be run from a checkout either -- and that is
# how the tests and c7shell-upgrade's own hooks invoke them.
for prog in "$root"/bin/*; do
  [[ -f $prog ]] || continue
  [[ -x $prog ]] || fail "bin/${prog##*/} is not executable"
done

# --------------------------------------------------------------------------
# A library a bin/ script sources is not a program, so the loop above does not
# see it -- and an uninstalled one is worse than a missing program: the source
# fails, `set -e` ends the run, and the user gets a line number instead of a
# reason. share/c7shell-sddm.sh is the first of these; the check is general so
# the second one cannot arrive unnoticed.
# --------------------------------------------------------------------------
while read -r lib; do
  grep -qE "install -Dm[0-9]+ share/$lib " "$pkgbuild" \
    || fail "bin/ sources share/$lib, which package() never installs.
An installed script would die on the source with no explanation of what is gone."
done < <(grep -hoE 'c7shell-[A-Za-z0-9._-]+\.sh' "$root"/bin/* | sort -u)

# And it has to land where the scripts look for it. The loader in each of them
# falls back to one hardcoded directory, so package() putting the file anywhere
# else is the same failure with an install line in front of it.
while read -r dir; do
  grep -qE "install -Dm[0-9]+ share/[A-Za-z0-9._-]+ \"\\\$pkgdir$dir/" "$pkgbuild" \
    || fail "the bin/ scripts fall back to $dir for their shared library, and
package() installs nothing there."
done < <(grep -hoE '_c7lib=/usr/lib/[A-Za-z0-9._-]+' "$root"/bin/* | sed 's/.*=//' | sort -u)

# --------------------------------------------------------------------------
# The C7 plugin. The shell imports C7, so a package without the module is a
# shell that fails to load, and a check() that lets a plugin test fail ships
# a module nobody tested. build(), check() and package() run here as makepkg
# runs them (sourced, under errexit), against stub cmake, ctest and lua that
# record each call -- arguments and DESTDIR -- and fail the one call that
# carries the word in STUB_FAIL.
# --------------------------------------------------------------------------
mktmp
fake=$tmp/fake
mkdir -p "$fake/bin" "$fake/src/c7shell/tests" "$fake/src/c7shell/hypr"
for tool in cmake ctest lua; do
  cat >"$fake/bin/$tool" <<STUB
#!/bin/sh
echo "$tool DESTDIR=\$DESTDIR \$* " >>"$fake/calls"
[ -n "\${STUB_FAIL:-}" ] && case " \$* " in *" \$STUB_FAIL "*) exit 1 ;; esac
exit 0
STUB
  chmod +x "$fake/bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' >"$fake/src/c7shell/tests/ok.sh"
chmod +x "$fake/src/c7shell/tests/ok.sh"

# run_fn FN TREE [VAR=VALUE...] -- run PKGBUILD's FN with TREE as the cloned
# source; sets `rc`, and keeps the output in $fake/log.
run_fn() {
  local fn=$1 tree=$2
  shift 2
  : >"$fake/calls"
  rm -rf "$fake/pkg" "$fake/srcdir" && mkdir -p "$fake/srcdir"
  ln -s "$tree" "$fake/srcdir/c7shell"
  rc=0
  env -u DESTDIR -u STUB_FAIL "$@" PATH="$fake/bin:$PATH" srcdir="$fake/srcdir" pkgdir="$fake/pkg" \
    bash -ec '. "$1"; "$2"' _ "$pkgbuild" "$fn" >"$fake/log" 2>&1 || rc=$?
}
# expect_ok WHAT -- the last run_fn succeeded, or show its output and fail.
expect_ok() { ((rc == 0)) || { cat "$fake/log" >&2; fail "$1 failed against stub tools (exit $rc)"; }; }
# called TOOL WORD... -- one recorded TOOL call carries every WORD, in any order.
called() {
  local tool=$1 line w
  shift
  while read -r line; do
    line=" $line "
    for w in "$@"; do [[ $line == *" $w "* ]] || continue 2; done
    return 0
  done < <(grep "^$tool " "$fake/calls")
  return 1
}
calls() { cat "$fake/calls"; }

(. "$pkgbuild"; ((${#arch[@]})) && [[ " ${arch[*]} " != *' any '* ]]) \
  || fail "PKGBUILD must name an arch other than any: the package carries a compiled C7 plugin"
# One entry for each tool build() runs: cmake, and ninja behind -G Ninja.
for dep in cmake ninja; do
  (. "$pkgbuild"; [[ " ${makedepends[*]} " == *" $dep "* ]]) \
    || fail "makedepends lacks $dep, which build() needs for the C7 plugin"
done

run_fn build "$fake/src/c7shell"
expect_ok 'build()'
# The prefix decides where package() puts the module; anything but /usr is a
# directory Qt never searches.
called cmake -S plugin -B build -G Ninja -DCMAKE_INSTALL_PREFIX=/usr \
  || fail "build() does not configure plugin/ into build/ with Ninja and prefix /usr:\n$(calls)"
called cmake --build build || fail "build() does not build the plugin:\n$(calls)"
for step in -S --build; do
  run_fn build "$fake/src/c7shell" STUB_FAIL=$step
  ((rc != 0)) || fail "build() passed while its cmake $step step failed"
done

run_fn check "$fake/src/c7shell"
expect_ok 'check()'
# --no-tests=error: a build directory with no tests registered is not a pass.
called ctest --test-dir build --no-tests=error \
  || fail "check() does not run the plugin's ctest suite with --no-tests=error:\n$(calls)"
run_fn check "$fake/src/c7shell" STUB_FAIL=--test-dir
((rc != 0)) || fail "check() passed while a plugin test failed"

# package() against the real tree: it installs the real files, and only cmake
# is a stub. The install has to land in the package, so DESTDIR is $pkgdir.
run_fn package "$root"
expect_ok 'package()'
called cmake "DESTDIR=$fake/pkg" --install build \
  || fail "package() never installs the C7 plugin into \$pkgdir:\n$(calls)"
run_fn package "$root" STUB_FAIL=--install
((rc != 0)) || fail "package() passed while the plugin install failed"

# check() runs this suite in the source tree before package() copies it, and a
# test that runs a .py script leaves a __pycache__ behind. That bytecode embeds
# the build's $srcdir (makepkg warns "Package contains reference to $srcdir")
# and c7shell-setup would copy it into every user's ~/.config. So run package()
# against a copy of the tree with a planted __pycache__ and require none of it
# to ship.
tree=$tmp/tree
mkdir -p "$tree"
git -C "$root" ls-files -z | (cd "$root" && xargs -0 cp --parents -t "$tree")
mkdir -p "$tree/quickshell/c7shell/scripts/__pycache__"
touch "$tree/quickshell/c7shell/scripts/__pycache__/planted.cpython-314.pyc"
run_fn package "$tree"
expect_ok 'package()'
leaked=$(find "$fake/pkg" -name __pycache__)
[[ -z $leaked ]] || fail "package() ships Python bytecode, which embeds \$srcdir:
${leaked//$fake\/pkg/}"

printf 'PASS: packaging (%s programs in bin/)\n' "$(find "$root/bin" -maxdepth 1 -type f | wc -l)"
