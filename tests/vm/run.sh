#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# The VM setup test: a pushed c7shell branch, a fresh Arch VM, and the real
# greeter. See tests/vm/README.md and
# docs/superpowers/specs/2026-10-13-vm-setup-test-design.md.
#
# Exit 0 pass, 1 test failure, 2 harness or host problem.
set -euo pipefail

vm=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
: "${C7VT_CACHE:=$HOME/.cache/c7shell-vmtest}"
# shellcheck source=lib/wait.sh
. "$vm/lib/wait.sh"
# shellcheck source=lib/qmp.sh
. "$vm/lib/qmp.sh"
# shellcheck source=lib/screen.sh
. "$vm/lib/screen.sh"
# shellcheck source=lib/qemu.sh
. "$vm/lib/qemu.sh"

usage() {
  cat <<USAGE
usage: tests/vm/run.sh --branch <name> [--keep] [--rebuild-base]

Installs <name> onto a fresh archinstall VM, logs in through the greetd greeter, and
checks the session. <name> must be pushed to $repo_url: makepkg
builds from there, whatever the VM cloned. Results: \$C7VT_CACHE/results/<timestamp>-<branch>/.
USAGE
}

parse_args() {
  branch='' repo_url=https://github.com/Jonohas/c7shell.git keep=0 rebuild=0
  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --branch) branch=${2:?}; shift ;;
      --keep) keep=1 ;;
      --rebuild-base) rebuild=1 ;;
      *) echo "run.sh: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  [[ -n $branch ]] || { echo 'run.sh: --branch is required' >&2; exit 2; }
}

slug() { printf '%s' "${1//[^A-Za-z0-9._-]/-}"; }

# Evidence for a failed phase: the screen and the end of the serial log.
save_evidence() {
  [[ -S ${run:-}/qmp.sock ]] || return 0
  mkdir -p "$results/screens"
  qmp_screendump "$run/qmp.sock" "$results/screens/$1-fail.png" >/dev/null 2>&1 || true
  tail -n 200 "$run/serial.log" > "$results/$1-serial-tail.log" 2>/dev/null || true
}

# phase <name> <timeout> <function> -- the step runs in a child bash that
# gets every function through declare -f, so timeout can kill all of it.
phase() {
  local name=$1 limit=$2 fn=$3 start=$SECONDS
  local status=0
  timeout "$limit" bash -c "set -euo pipefail; $(declare -f); $fn" \
    > "$results/$name.log" 2>&1 || status=$?
  if ((status == 0)); then
    echo "$name $((SECONDS - start))s ok" >> "$results/summary.txt"
    return
  fi
  echo "$name $((SECONDS - start))s FAIL" >> "$results/summary.txt"
  echo "FAIL: $name" >> "$results/summary.txt"
  save_evidence "$name"
  # 2 is a harness or host problem (build-base.sh says so); 124, a timeout,
  # and everything else is a test failure.
  ((status == 2)) && exit 2
  exit 1
}

step_base() {
  # Two runs must not rebuild the base under each other's overlays.
  exec 9> "$C7VT_CACHE/base.lock"
  flock 9
  if ((rebuild)) || [[ ! -f $C7VT_CACHE/base.qcow2 ]] \
     || ! cmp -s "$vm/iso.version" "$C7VT_CACHE/base.iso.version" \
     || ! cmp -s "$vm/archinstall.json" "$C7VT_CACHE/base.archinstall.json"; then
    "$vm/build-base.sh"
  fi
}

step_install() {
  qemu-img create -q -f qcow2 -F qcow2 -b "$C7VT_CACHE/base.qcow2" "$run/disk.qcow2"
  vm_start "$run" "$run/disk.qcow2"
  wait_for 300 vm_ssh "$run" true
  # The script goes over as a file: piped into bash -s, anything in it that
  # reads stdin (a pacman prompt) would eat the script's next lines.
  remote_install_script "$branch" "$repo_url" | vm_ssh "$run" 'cat > c7vt-install.sh'
  vm_ssh "$run" bash c7vt-install.sh < /dev/null
}

# The install script the VM runs. Git allows ' $ ; in branch names, so both
# values are %q-quoted rather than spliced into quotes.
remote_install_script() {
  local b u
  printf -v b %q "$1"; printf -v u %q "$2"
  cat <<REMOTE
set -euo pipefail
git clone --branch $b $u c7shell
cd c7shell
C7SHELL_BRANCH=$b C7SHELL_SKIP_OPTIONAL=1 ./install.sh --yes --noconfirm
c7shell-setup
pacman -Q c7shell > ~/c7vt-commit
REMOTE
}

# A reboot is seen by the kernel's boot id changing, not by SSH going quiet:
# under load the VM can drop and regain SSH between two polls, or keep it for
# most of a minute while units stop, and either way "SSH is gone" never holds.
_boot_id() { vm_ssh "$run" cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
_rebooted() { local id; id=$(_boot_id) && [[ -n $id && $id != "$1" ]]; }

_greeter_up() {
  # greetd stays active between restarts of a greeter that keeps dying, so
  # the greeter process itself is what says a login screen is up.
  vm_ssh "$run" 'systemctl is-active --quiet greetd && pgrep -u greeter -x c7shell-greeter' >/dev/null \
    && qmp_screendump "$run/qmp.sock" "$results/screens/greeter.png" >/dev/null \
    && screen_not_uniform "$results/screens/greeter.png"
}

step_greeter() {
  local before; before=$(_boot_id) || true
  [[ -n $before ]] || { echo 'greeter: no boot id before the reboot'; exit 1; }
  vm_ssh "$run" sudo systemctl reboot || true
  wait_for 150 _rebooted "$before"
  wait_for 170 _greeter_up
}

_session_up() { vm_ssh "$run" 'pgrep -u c7test -x "qs|quickshell"' >/dev/null; }

step_login() {
  qmp_type "$run/qmp.sock" "$(cat "$C7VT_CACHE/c7test.password")" >/dev/null
  qmp_key "$run/qmp.sock" ret >/dev/null
  wait_for 110 _session_up
}

step_assert() {
  vm_ssh "$run" bash -s < "$vm/lib/session.sh"
  vm_ssh "$run" cat /tmp/c7vt-shot.png > "$results/screens/session.png"
  screen_not_uniform "$results/screens/session.png" || { echo 'assert: the session screen is blank'; exit 1; }
}

finish() {
  local status=$?
  if [[ -n ${run:-} ]] && ! vm_stop "$run" >/dev/null 2>&1; then
    kill "$(cat "$run/qemu.pid" 2>/dev/null)" 2>/dev/null || true
  fi
  # PASS needs main to have reached its end, not just a zero status: a run
  # stopped from outside (systemctl stop, Ctrl-C) can exit 0 before the last
  # phase.
  if ((status == 0)) && [[ -n ${completed:-} ]]; then
    echo PASS >> "$results/summary.txt"
    ((keep)) || rm -rf -- "$run"
  elif ! grep -q '^FAIL: ' "$results/summary.txt"; then
    echo 'FAIL: interrupted' >> "$results/summary.txt"
    status=2
  fi
  cat "$results/summary.txt"
  exit "$status"
}

main() {
  parse_args "$@"
  [[ -w /dev/kvm ]] || { echo 'run.sh: /dev/kvm is not usable; run tests/vm/setup-host.sh' >&2; exit 2; }
  local stamp; stamp=$(date +%Y%m%d-%H%M%S)
  results=$C7VT_CACHE/results/$stamp-$(slug "$branch")
  run=$C7VT_CACHE/runs/$stamp-$(slug "$branch")
  mkdir -p "$results/screens" "$run"
  export run results branch repo_url vm C7VT_CACHE rebuild
  printf 'branch %s\nrepo %s\niso %s\n' "$branch" "$repo_url" "$(cat "$vm/iso.version")" \
    > "$results/summary.txt"
  trap finish EXIT
  trap 'exit 2' INT TERM HUP
  phase base 1800 step_base
  phase install 2700 step_install
  vm_ssh "$run" cat c7vt-commit | sed 's/^/package /' >> "$results/summary.txt"
  phase greeter 360 step_greeter
  phase login 120 step_login
  phase assert 150 step_assert
  completed=1
}

[[ -n ${C7VT_SOURCE_ONLY:-} ]] || main "$@"
