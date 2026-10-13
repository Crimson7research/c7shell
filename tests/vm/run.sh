#!/usr/bin/env bash
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
usage: tests/vm/run.sh --branch <name> [--repo <url>] [--keep] [--rebuild-base]

Installs <name> onto a fresh archinstall VM, logs in through SDDM, and
checks the session. Results: \$C7VT_CACHE/results/<timestamp>-<branch>/.
USAGE
}

parse_args() {
  branch='' repo_url=https://github.com/Jonohas/c7shell.git keep=0 rebuild=0
  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --branch) branch=${2:?}; shift ;;
      --repo) repo_url=${2:?}; shift ;;
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
  if timeout "$limit" bash -c "$(declare -f); $fn" > "$results/$name.log" 2>&1; then
    echo "$name $((SECONDS - start))s ok" >> "$results/summary.txt"
  else
    echo "$name $((SECONDS - start))s FAIL" >> "$results/summary.txt"
    echo "FAIL: $name" >> "$results/summary.txt"
    save_evidence "$name"
    exit 1
  fi
}

step_base() {
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
  vm_ssh "$run" bash -s <<REMOTE
set -euo pipefail
git clone --branch '$branch' '$repo_url' c7shell
cd c7shell
git rev-parse HEAD > ~/c7vt-commit
C7SHELL_BRANCH='$branch' C7SHELL_SKIP_OPTIONAL=1 ./install.sh --yes --noconfirm
c7shell-setup
REMOTE
}

_vt_gone_ssh() { ! vm_ssh "$run" true 2>/dev/null; }

_greeter_up() {
  vm_ssh "$run" systemctl is-active --quiet sddm \
    && qmp_screendump "$run/qmp.sock" "$results/screens/greeter.png" >/dev/null \
    && screen_not_uniform "$results/screens/greeter.png"
}

step_greeter() {
  vm_ssh "$run" sudo systemctl reboot || true
  wait_for 60 _vt_gone_ssh
  wait_for 170 _greeter_up
}

_session_up() { vm_ssh "$run" 'pgrep -u c7test -x quickshell' >/dev/null; }

step_login() {
  qmp_type "$run/qmp.sock" "$(cat "$C7VT_CACHE/c7test.password")" >/dev/null
  qmp_key "$run/qmp.sock" ret >/dev/null
  wait_for 110 _session_up
}

step_assert() {
  timeout 30 vm_ssh "$run" bash -s < "$vm/lib/session.sh"
  vm_ssh "$run" cat /tmp/c7vt-shot.png > "$results/screens/session.png"
  screen_bar_drawn "$results/screens/session.png" || { echo 'assert: no bar drawn'; exit 1; }
}

finish() {
  local status=$?
  [[ -n ${run:-} ]] && vm_stop "$run" >/dev/null 2>&1
  if ((status == 0)); then
    echo PASS >> "$results/summary.txt"
    ((keep)) || rm -rf -- "$run"
  fi
  cat "$results/summary.txt"
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
  phase base 1800 step_base
  phase install 2700 step_install
  vm_ssh "$run" cat c7vt-commit | sed 's/^/commit /' >> "$results/summary.txt"
  phase greeter 180 step_greeter
  phase login 120 step_login
  phase assert 60 step_assert
}

[[ -n ${C7VT_SOURCE_ONLY:-} ]] || main "$@"
