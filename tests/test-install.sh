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

echo 'PASS: install'
