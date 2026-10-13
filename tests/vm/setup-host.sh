#!/usr/bin/env bash
# One-time setup of the test laptop for tests/vm/run.sh. Safe to re-run.
set -euo pipefail

sudo pacman -Syu --needed --noconfirm qemu-full edk2-ovmf socat openssh \
  libisoburn git imagemagick jq archlinux-keyring shellcheck

if ! id -nG | grep -qw kvm; then
  sudo usermod -aG kvm "$USER"
  echo "setup-host: added $USER to the kvm group; log out and back in, then re-run."
fi

[[ -e /dev/kvm ]] || {
  echo 'setup-host: no /dev/kvm -- enable VT-x or AMD-V in the firmware settings' >&2
  exit 2
}

mkdir -p "${C7VT_CACHE:-$HOME/.cache/c7shell-vmtest}"
echo 'setup-host: ready. Next: tests/vm/run.sh --branch main'
