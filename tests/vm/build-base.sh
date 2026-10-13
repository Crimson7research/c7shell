#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# Builds the known starting point for the VM setup test: the pinned Arch ISO,
# installed by archinstall from tests/vm/archinstall.json, with no desktop.
# Writes $C7VT_CACHE/base.qcow2. Exit 1 if the install fails, 2 on a host or
# download problem.
set -euo pipefail

vm=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${C7VT_CACHE:=$HOME/.cache/c7shell-vmtest}"
# shellcheck source=lib/wait.sh
. "$vm/lib/wait.sh"
# shellcheck source=lib/qmp.sh
. "$vm/lib/qmp.sh"
# shellcheck source=lib/qemu.sh
. "$vm/lib/qemu.sh"

ver=$(cat "$vm/iso.version")
name=archlinux-$ver-x86_64.iso
iso=$C7VT_CACHE/$name
mirror=https://geo.mirror.pkgbuild.com/iso/$ver

fetch_iso() {
  [[ -f $iso ]] && return 0
  curl -fL --retry 3 -o "$iso.part" "$mirror/$name"
  curl -fsSL -o "$C7VT_CACHE/sha256sums.txt" "$mirror/sha256sums.txt"
  curl -fsSL -o "$iso.sig" "$mirror/$name.sig"
  (cd "$C7VT_CACHE" && grep " $name\$" sha256sums.txt | sed "s| $name\$| $name.part|" | sha256sum -c --quiet -) \
    || { rm -f "$iso.part"; echo 'build-base: ISO checksum mismatch' >&2; exit 2; }
  pacman-key -v "$iso.sig" "$iso.part" 2>/dev/null \
    || { rm -f "$iso.part"; echo 'build-base: ISO signature does not verify' >&2; exit 2; }
  mv "$iso.part" "$iso"
}

make_secrets() {
  [[ -f $C7VT_CACHE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f "$C7VT_CACHE/id_ed25519"
  if [[ ! -f $C7VT_CACHE/c7test.password ]]; then
    (umask 077; tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20 > "$C7VT_CACHE/c7test.password")
  fi
}

# The NoCloud seed the ISO's cloud-init reads: the config with the host's key
# written in, and the creds, both base64 so YAML never parses the JSON.
make_seed() {
  local seed=$1 pub key_cmd cfg creds
  pub=$(cat "$C7VT_CACHE/id_ed25519.pub")
  key_cmd="printf '%s\n' '$pub' > /home/c7test/.ssh/authorized_keys && chown 1000:1000 /home/c7test/.ssh/authorized_keys && chmod 600 /home/c7test/.ssh/authorized_keys"
  cfg=$(jq --arg k "$key_cmd" '.custom_commands |= map(if . == "@AUTHORIZED_KEYS@" then $k else . end)' \
        "$vm/archinstall.json" | base64 -w0)
  creds=$(jq -n --arg p "$(cat "$C7VT_CACHE/c7test.password")" \
          '{"!root-password": $p, "users": [{"username": "c7test", "!password": $p, "sudo": true}]}' \
          | base64 -w0)
  mkdir -p "$seed/d"
  sed -e "s|@CONFIG@|$cfg|" -e "s|@CREDS@|$creds|" "$vm/cloud-init/user-data.in" > "$seed/d/user-data"
  cp "$vm/cloud-init/meta-data" "$seed/d/meta-data"
  xorriso -as mkisofs -quiet -V CIDATA -J -r -o "$seed/seed.iso" "$seed/d"
}

main() {
  [[ -w /dev/kvm ]] || { echo 'build-base: /dev/kvm is not usable' >&2; exit 2; }
  mkdir -p "$C7VT_CACHE"
  fetch_iso
  make_secrets
  local run; run=$(mktemp -d "$C7VT_CACHE/build.XXXXXX")
  # shellcheck disable=SC2064  # $run is expanded now, on purpose.
  trap "vm_stop '$run' >/dev/null 2>&1 || true; rm -rf -- '$run'" EXIT
  make_seed "$run"
  qemu-img create -q -f qcow2 "$run/base.qcow2" 30G
  vm_start "$run" "$run/base.qcow2" -cdrom "$iso" \
    -drive "file=$run/seed.iso,media=cdrom,readonly=on" -boot d
  wait_for 1800 _vt_gone "$run" || { echo 'build-base: install timed out' >&2; exit 1; }
  grep -q C7VT-INSTALL-OK "$run/serial.log" \
    || { tail -n 200 "$run/serial.log" >&2; echo 'build-base: archinstall failed' >&2; exit 1; }
  mv "$run/base.qcow2" "$C7VT_CACHE/base.qcow2"
  cp "$vm/iso.version" "$C7VT_CACHE/base.iso.version"
  cp "$vm/archinstall.json" "$C7VT_CACHE/base.archinstall.json"
}

main "$@"
