#!/usr/bin/env bash
# Starting, stopping and reaching the test VM. Sourced, not executed.
#
# One run directory per VM holds everything that identifies it -- the QMP
# socket, the serial log, the pid and the forwarded SSH port -- so two runs
# on one laptop never share anything.

: "${C7VT_CACHE:=$HOME/.cache/c7shell-vmtest}"

_vt_port_used() { ss -Hltn "sport = :$1" 2>/dev/null | grep -q .; }

vm_free_port() {
  local p=${1:-2222}
  while ${C7VT_PORTCHECK:-_vt_port_used} "$p"; do ((p++)); done
  echo "$p"
}

# vm_start <dir> <disk> [extra qemu args...]
#
# virtio-vga without GL: with virtio-vga-gl and egl-headless, QMP screendump
# answers "no surface", and the greeter and session checks need screendump.
# The guest renders in software (llvmpipe) as a result.
vm_start() {
  local dir=$1 disk=$2 port status=0; shift 2
  # Between the free-port check and QEMU binding the port, another run
  # could pick the same one; the lock covers both, and -daemonize returns
  # only once the port is bound.
  mkdir -p "$C7VT_CACHE"
  exec {lock}> "$C7VT_CACHE/port.lock"
  flock "$lock"
  port=$(vm_free_port)
  echo "$port" > "$dir/ssh.port"
  ${C7VT_QEMU:-qemu-system-x86_64} \
    -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
    -drive "if=pflash,format=raw,readonly=on,file=${C7VT_OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -device virtio-vga -display none \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22" \
    -qmp "unix:$dir/qmp.sock,server=on,wait=off" \
    -serial "file:$dir/serial.log" \
    -pidfile "$dir/qemu.pid" -daemonize \
    "$@" {lock}>&- || status=$?
  exec {lock}>&-
  return "$status"
}

_vt_gone() { ! kill -0 "$(cat "$1/qemu.pid" 2>/dev/null)" 2>/dev/null; }

vm_stop() {
  qmp_quit "$1/qmp.sock" >/dev/null 2>&1 || true
  wait_for 30 _vt_gone "$1"
}

vm_ssh() {
  local dir=$1; shift
  ssh -p "$(cat "$dir/ssh.port")" -i "$C7VT_CACHE/id_ed25519" \
      -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      c7test@127.0.0.1 "$@"
}
