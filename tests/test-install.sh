#!/usr/bin/env bash
# Self-check for install.sh. Run it directly: tests/test-install.sh
#
# install.sh's own job, before it hands over to the bootstrap and makepkg, is
# getting the base-devel tools in place. These checks build a machine that has
# none of them -- a PATH holding only stubs -- and assert on what install.sh
# asked sudo to run. Nothing here installs anything or needs root.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
mktmp

bin=$tmp/bin
mkdir -p "$bin"
# The real tools install.sh itself uses, and none of the base-devel ones.
for helper in bash dirname cat; do
  ln -sf "$(command -v "$helper")" "$bin/$helper"
done
stub() { printf '%s\n' '#!/bin/sh' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
# sudo records the command; it does not run it, so the tools stay missing and
# install.sh stops at its "still missing" check, which is where this test ends.
stub sudo "echo \"\$*\" >> '$tmp/sudo.log'"
stub makepkg 'exit 0'

run_install() {
  : > "$tmp/sudo.log"
  env -i PATH="$bin" HOME="$tmp" C7SHELL_SKIP_BOOTSTRAP=1 C7SHELL_SKIP_DOCTOR=1 \
    bash "$repo/install.sh" "$@" >/dev/null 2>&1 || true
}

# --- --yes reaches the base-devel install ---------------------------------
run_install --yes
grep -qx 'pacman -S --needed --noconfirm base-devel' "$tmp/sudo.log" \
  || fail "install.sh --yes: base-devel must install without a prompt; sudo got:\n$(cat "$tmp/sudo.log")"
grep -qE '^pacman -S --needed --noconfirm -- ' "$tmp/sudo.log" \
  || fail "install.sh --yes: the named build tools must install without a prompt; sudo got:\n$(cat "$tmp/sudo.log")"

# --- without --yes, pacman still asks -------------------------------------
run_install
grep -qx 'pacman -S --needed base-devel' "$tmp/sudo.log" \
  || fail "install.sh: without --yes, pacman must still ask; sudo got:\n$(cat "$tmp/sudo.log")"
if grep -q -- '--noconfirm' "$tmp/sudo.log"; then
  fail 'install.sh: --noconfirm without --yes'
fi

# --- --yes reaches the bootstrap's own pacman calls -----------------------
# With every build tool present, install.sh goes on to c7shell-bootstrap.
# The bootstrap's --yes only skips its plan prompt; its pacman calls ask
# unless it also gets --noconfirm-pacman.
for t in fakeroot debugedit make gcc patch bsdtar pkg-config; do stub "$t" 'exit 0'; done
stub c7shell-bootstrap "echo \"\$*\" > '$tmp/bootstrap.args'"
run_bootstrap() {
  rm -f "$tmp/bootstrap.args"
  env -i PATH="$bin" HOME="$tmp" C7SHELL_SKIP_DOCTOR=1 C7SHELL_BOOTSTRAP="$bin/c7shell-bootstrap" \
    bash "$repo/install.sh" "$@" >/dev/null 2>&1 || true
}
run_bootstrap --yes
grep -qx -- '--yes --noconfirm-pacman' "$tmp/bootstrap.args" \
  || fail "install.sh --yes: the bootstrap must get --noconfirm-pacman; got: $(cat "$tmp/bootstrap.args" 2>/dev/null)"
run_bootstrap
[[ $(cat "$tmp/bootstrap.args") == '' ]] || fail "install.sh: without --yes the bootstrap gets no flags; got: $(cat "$tmp/bootstrap.args")"

# --- --dry-run changes nothing, base-devel included ---------------------------
rm -f "$bin/fakeroot"
run_install --dry-run
[[ ! -s $tmp/sudo.log ]] || fail "install.sh --dry-run installed something:\n$(cat "$tmp/sudo.log")"
# ...and still gets as far as the bootstrap's own plan.
rm -f "$tmp/bootstrap.args"; rc=0
env -i PATH="$bin" HOME="$tmp" C7SHELL_SKIP_DOCTOR=1 C7SHELL_BOOTSTRAP="$bin/c7shell-bootstrap" \
  bash "$repo/install.sh" --dry-run >/dev/null 2>&1 || rc=$?
((rc == 0)) || fail "install.sh --dry-run with build tools missing exited $rc"
grep -q -- '--dry-run' "$tmp/bootstrap.args" 2>/dev/null || fail 'install.sh --dry-run never reached the bootstrap plan'
stub fakeroot 'exit 0'

# --- a declined bootstrap stops the install ---------------------------------
stub makepkg "echo makepkg >> '$tmp/makepkg.log'"
stub c7shell-bootstrap 'exit 3'
rm -f "$tmp/makepkg.log"; rc=0
env -i PATH="$bin" HOME="$tmp" C7SHELL_SKIP_DOCTOR=1 C7SHELL_BOOTSTRAP="$bin/c7shell-bootstrap" \
  bash "$repo/install.sh" >/dev/null 2>&1 || rc=$?
((rc == 3)) || fail "a declined bootstrap: install.sh exited $rc, not 3"
[[ ! -e $tmp/makepkg.log ]] || fail 'install.sh built the package after the bootstrap plan was declined'

# --- the checkout's bootstrap wins over an installed one -----------------------
# An older c7shell-bootstrap in /usr/bin would ignore fixes in this tree.
grep -q 'C7SHELL_BOOTSTRAP:-$(dirname -- "$0")/bin/c7shell-bootstrap' "$repo/install.sh" \
  || fail 'install.sh does not prefer the checkout'"'"'s own bootstrap'

echo 'PASS: install'
