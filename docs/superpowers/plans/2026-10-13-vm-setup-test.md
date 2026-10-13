# VM Setup Test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command on a dedicated KVM laptop installs a named c7shell branch onto a fresh archinstall VM, logs in through the real SDDM greeter, and reports `PASS` or `FAIL: <phase>`.

**Architecture:** Plain bash under `tests/vm/`. Small sourced libraries (`lib/wait.sh`, `lib/qmp.sh`, `lib/screen.sh`, `lib/qemu.sh`) do one job each, and every external tool they call (`socat`, `qemu-system-x86_64`, the clock, `sleep`) is reachable through an environment override so `tests/test-vmtest-lib.sh` can fake it. `build-base.sh` makes a cached `base.qcow2` from the pinned Arch ISO plus a cloud-init seed that runs `archinstall --silent`; `run.sh` layers a throwaway overlay on it and drives the phases.

**Tech Stack:** bash 5, QEMU/KVM with OVMF, QMP over `socat`, Arch ISO cloud-init (NoCloud), archinstall, `xorriso`, ImageMagick (`magick`), OpenSSH.

**Spec:** `docs/superpowers/specs/2026-10-13-vm-setup-test-design.md`

## Global Constraints

- All harness files live in `tests/vm/`; nothing there matches `tests/*.sh`, so `PKGBUILD check()` never starts a VM.
- The only harness test in the normal suite is `tests/test-vmtest-lib.sh`; it must never start QEMU, need `/dev/kvm`, or touch the network.
- No bare `sleep` outside `lib/wait.sh`.
- Exit codes: `0` pass, `1` test failure, `2` harness or host problem.
- Cache root: `${C7VT_CACHE:-$HOME/.cache/c7shell-vmtest}`. Results: `$C7VT_CACHE/results/<timestamp>-<branch>/`.
- The `c7test` password is generated on the host, alphanumeric only, stored in `$C7VT_CACHE/c7test.password` mode 600, never committed.
- VM: 4 GB RAM, 4 vCPU, KVM, OVMF, virtio-gpu, user-mode networking with SSH forwarded to a free host port.
- Phase timeouts: base 1800 s, install 2700 s, greeter 180 s, login 120 s, each assertion 30 s.
- Clone URL default: `https://github.com/Jonohas/c7shell.git` (`--repo` overrides).
- Every script passes `shellcheck`.
- Tests source `tests/fixtures/harness.sh` and use its `fail` and `mktmp`, like every other test in `tests/`.

## Review Focus

- A branch name with a `/` (`jv/foo`): the results directory and overlay name must not create subdirectories; Task 5 tests the sanitising.
- Two runs at once on the laptop: each must get its own SSH port and QMP socket; Task 4 tests port selection skips a port in use.
- `socat` gets no reply because QEMU died: `qmp` must return non-zero, not hang; Task 2 tests a fake `socat` that exits 1.
- An uppercase or digit character in the password: `type_text` must send shift for uppercase and digit qcodes; Task 2 tests `aB3`.
- A screenshot that is all black (greeter not drawn yet): the "not uniform" check must reject it; Task 3 tests a solid image.

---

### Task 1: `lib/wait.sh` — deadline polling

**Files:**
- Create: `tests/vm/lib/wait.sh`
- Create: `tests/test-vmtest-lib.sh`

**Interfaces:**
- Produces: `wait_for <seconds> <command> [args…]` → returns 0 once the command succeeds, 1 after the deadline. Clock is `${C7VT_CLOCK:-date +%s}`, pause is `${C7VT_SLEEP:-sleep} ${C7VT_POLL:-2}`.

- [ ] **Step 1: Write the failing test**

```bash
#!/usr/bin/env bash
# Self-check for the VM setup test's libraries in tests/vm/lib. Run it
# directly: tests/test-vmtest-lib.sh
#
# The harness itself boots QEMU and takes most of an hour, so it never runs in
# this suite. What does run here is everything in it that decides something:
# deadlines, the QMP JSON it sends, the key map, the screenshot checks and the
# argument parsing. Each external tool is replaced by a fake on PATH or through
# the C7VT_* hooks, so nothing here needs /dev/kvm or the network.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
vm=$repo/tests/vm
mktmp

# A clock that advances 10 s every time it is read.
printf '%s\n' '#!/bin/sh' "n=\$(cat '$tmp/clock' 2>/dev/null || echo 0)" \
  "echo \$((n+10)) > '$tmp/clock'; echo \$n" > "$tmp/fakeclock"
chmod +x "$tmp/fakeclock"
export C7VT_CLOCK=$tmp/fakeclock C7VT_SLEEP=true

# shellcheck source=vm/lib/wait.sh
. "$vm/lib/wait.sh"

# --- wait_for -------------------------------------------------------------
rm -f "$tmp/clock"
wait_for 30 true || fail 'wait_for: an immediately true command must pass'

rm -f "$tmp/clock"
if wait_for 30 false; then fail 'wait_for: a never-true command must time out'; fi

# Succeeds on the third try, well inside the deadline.
rm -f "$tmp/clock" "$tmp/tries"
third() { n=$(cat "$tmp/tries" 2>/dev/null || echo 0); echo $((n+1)) > "$tmp/tries"; ((n >= 2)); }
wait_for 100 third || fail 'wait_for: must keep polling until the command succeeds'

echo 'PASS: vmtest-lib'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `chmod +x tests/test-vmtest-lib.sh && tests/test-vmtest-lib.sh`
Expected: fails with `No such file or directory` for `tests/vm/lib/wait.sh`.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Deadline polling for the VM setup test. Sourced, not executed.
#
# The only place in tests/vm that pauses: every "wait until the VM has
# done X" goes through wait_for, so every wait has a deadline and the
# test suite can run them instantly with a fake clock.

_vt_now() { ${C7VT_CLOCK:-date +%s}; }

# wait_for <seconds> <command> [args...]
wait_for() {
  local limit=$1; shift
  local deadline=$(( $(_vt_now) + limit ))
  until "$@"; do
    (( $(_vt_now) < deadline )) || return 1
    ${C7VT_SLEEP:-sleep} "${C7VT_POLL:-2}"
  done
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `tests/test-vmtest-lib.sh && shellcheck tests/vm/lib/wait.sh tests/test-vmtest-lib.sh`
Expected: `PASS: vmtest-lib`, no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add tests/vm/lib/wait.sh tests/test-vmtest-lib.sh
git commit -m "test(vm): deadline polling for the VM setup test"
```

---

### Task 2: `lib/qmp.sh` — QMP commands and typing

**Files:**
- Create: `tests/vm/lib/qmp.sh`
- Modify: `tests/test-vmtest-lib.sh` (append before the final `echo`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `qmp <socket> <json-command>` → sends `{"execute":"qmp_capabilities"}` then the command through `${C7VT_SOCAT:-socat}`; prints QEMU's replies; returns socat's status, or 1 if a reply holds `"error"`.
  - `qmp_screendump <socket> <png-path>`
  - `qmp_key <socket> <qcode> [<qcode>…]` → one `send-key` chord.
  - `qmp_type <socket> <text>` → one chord per character; `[a-z0-9]` only plus uppercase (sent as `shift`+lowercase); any other character returns 2.
  - `qmp_powerdown <socket>`, `qmp_quit <socket>`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-vmtest-lib.sh`, above `echo 'PASS: vmtest-lib'`:

```bash
# --- qmp ------------------------------------------------------------------
# A socat that records what it was sent and answers like QEMU does.
printf '%s\n' '#!/bin/sh' "cat >> '$tmp/qmp.sent'" \
  "printf '%s\n' '{\"QMP\":{}}' '{\"return\":{}}' '{\"return\":{}}'" > "$tmp/socat"
chmod +x "$tmp/socat"
export C7VT_SOCAT=$tmp/socat
# shellcheck source=vm/lib/qmp.sh
. "$vm/lib/qmp.sh"

: > "$tmp/qmp.sent"
qmp_screendump "$tmp/sock" /x/s.png >/dev/null || fail 'qmp_screendump: must succeed'
grep -qx '{"execute":"qmp_capabilities"}' "$tmp/qmp.sent" \
  || fail 'qmp: must negotiate capabilities first'
grep -qF '{"execute":"screendump","arguments":{"filename":"/x/s.png","format":"png"}}' "$tmp/qmp.sent" \
  || fail "qmp_screendump: wrong command:\n$(cat "$tmp/qmp.sent")"

: > "$tmp/qmp.sent"
qmp_type "$tmp/sock" aB3 >/dev/null || fail 'qmp_type: must type aB3'
grep -c '"send-key"' "$tmp/qmp.sent" | grep -qx 3 || fail 'qmp_type: one chord per character'
grep -qF '[{"type":"qcode","data":"a"}]' "$tmp/qmp.sent" || fail 'qmp_type: a'
grep -qF '[{"type":"qcode","data":"shift"},{"type":"qcode","data":"b"}]' "$tmp/qmp.sent" \
  || fail 'qmp_type: uppercase B must be shift+b'
grep -qF '[{"type":"qcode","data":"3"}]' "$tmp/qmp.sent" || fail 'qmp_type: digit 3'

if qmp_type "$tmp/sock" 'a!' >/dev/null 2>&1; then fail 'qmp_type: must refuse a symbol'; fi

# A QEMU that is gone: socat fails, and qmp must say so rather than hang.
printf '%s\n' '#!/bin/sh' 'exit 1' > "$tmp/socat-dead"; chmod +x "$tmp/socat-dead"
if C7VT_SOCAT=$tmp/socat-dead qmp_quit "$tmp/sock" >/dev/null 2>&1; then
  fail 'qmp: a failed socat must fail the command'
fi

# A reply carrying an error fails the command.
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
  "printf '%s\n' '{\"QMP\":{}}' '{\"return\":{}}' '{\"error\":{\"class\":\"GenericError\"}}'" > "$tmp/socat-err"
chmod +x "$tmp/socat-err"
if C7VT_SOCAT=$tmp/socat-err qmp_powerdown "$tmp/sock" >/dev/null; then
  fail 'qmp: an error reply must fail the command'
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/test-vmtest-lib.sh`
Expected: fails with `No such file or directory` for `tests/vm/lib/qmp.sh`.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# QMP, the QEMU machine protocol, over socat. Sourced, not executed.
#
# The harness uses QMP for what SSH cannot do: see the screen before anyone
# is logged in, type at the greeter, and power the VM off. Every command
# opens a fresh connection, so there is no session state to get wrong.

# qmp <socket> <json>
qmp() {
  local out
  out=$(printf '%s\n' '{"execute":"qmp_capabilities"}' "$2" \
        | ${C7VT_SOCAT:-socat} -t 5 - "UNIX-CONNECT:$1") || return 1
  printf '%s\n' "$out"
  ! grep -q '"error"' <<<"$out"
}

qmp_screendump() {
  qmp "$1" "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$2\",\"format\":\"png\"}}"
}

# qmp_key <socket> <qcode>... -- the qcodes are pressed together, as a chord.
qmp_key() {
  local sock=$1 keys='' k; shift
  for k; do keys+="${keys:+,}{\"type\":\"qcode\",\"data\":\"$k\"}"; done
  qmp "$sock" "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[$keys]}}"
}

# qmp_type <socket> <text> -- letters and digits only, which is all the
# generated password ever holds; anything else is refused, not guessed at.
qmp_type() {
  local sock=$1 text=$2 i c
  for ((i = 0; i < ${#text}; i++)); do
    c=${text:i:1}
    case $c in
      [a-z0-9]) qmp_key "$sock" "$c" ;;
      [A-Z]) qmp_key "$sock" shift "${c,,}" ;;
      *) echo "qmp_type: cannot type '$c'" >&2; return 2 ;;
    esac || return 1
  done
}

qmp_powerdown() { qmp "$1" '{"execute":"system_powerdown"}'; }
qmp_quit() { qmp "$1" '{"execute":"quit"}'; }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `tests/test-vmtest-lib.sh && shellcheck tests/vm/lib/qmp.sh tests/test-vmtest-lib.sh`
Expected: `PASS: vmtest-lib`, no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add tests/vm/lib/qmp.sh tests/test-vmtest-lib.sh
git commit -m "test(vm): QMP commands and greeter typing"
```

---

### Task 3: `lib/screen.sh` — screenshot checks

**Files:**
- Create: `tests/vm/lib/screen.sh`
- Modify: `tests/test-vmtest-lib.sh`

**Interfaces:**
- Produces:
  - `screen_not_uniform <png>` → 0 if the image's pixel standard deviation is above 0.01.
  - `screen_regions_differ <png> <geomA> <geomB>` → 0 if the mean colours of the two ImageMagick geometries (`WxH+X+Y`) differ by more than 0.05.
  - `screen_bar_drawn <png>` → `screen_regions_differ` on the top 40 px strip versus a 40 px strip at mid-height, full width.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-vmtest-lib.sh`:

```bash
# --- screen ---------------------------------------------------------------
# Fixtures are drawn here rather than committed: three tiny images say more
# in one line each than three binary files would.
if command -v magick >/dev/null; then
  # shellcheck source=vm/lib/screen.sh
  . "$vm/lib/screen.sh"
  magick -size 200x200 xc:black "$tmp/black.png"
  magick -size 200x200 xc:'#202020' -fill '#c0c0c0' -draw 'rectangle 0,0 199,39' "$tmp/bar.png"
  magick -size 200x200 gradient:navy-teal "$tmp/nobar.png"

  if screen_not_uniform "$tmp/black.png"; then fail 'screen: a solid image is uniform'; fi
  screen_not_uniform "$tmp/bar.png" || fail 'screen: the bar image is not uniform'
  screen_bar_drawn "$tmp/bar.png" || fail 'screen: must see the bar'
  if screen_bar_drawn "$tmp/black.png"; then fail 'screen: no bar on a black screen'; fi
else
  echo 'SKIP: screen checks (magick not installed, package: imagemagick)'
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/test-vmtest-lib.sh`
Expected: fails with `No such file or directory` for `tests/vm/lib/screen.sh`.

- [ ] **Step 3: Write the implementation**

```bash
#!/usr/bin/env bash
# Screenshot checks for the VM setup test. Sourced, not executed.
#
# Deliberately coarse: "something is drawn" and "the bar strip is not the
# wallpaper". A pixel-exact comparison would fail on every theme tweak.

_vt_mean() { magick "$1" ${2:+-crop "$2" +repage} -colorspace gray -format '%[fx:mean]' info:; }

screen_not_uniform() {
  local sd
  sd=$(magick "$1" -colorspace gray -format '%[fx:standard_deviation]' info:) || return 1
  awk -v s="$sd" 'BEGIN { exit !(s > 0.01) }'
}

screen_regions_differ() {
  local a b
  a=$(_vt_mean "$1" "$2") && b=$(_vt_mean "$1" "$3") || return 1
  awk -v a="$a" -v b="$b" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d > 0.05) }'
}

screen_bar_drawn() {
  local w h
  read -r w h < <(magick "$1" -format '%w %h' info:) || return 1
  screen_regions_differ "$1" "${w}x40+0+0" "${w}x40+0+$((h / 2))"
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `tests/test-vmtest-lib.sh && shellcheck tests/vm/lib/screen.sh`
Expected: `PASS: vmtest-lib`.

- [ ] **Step 5: Commit**

```bash
git add tests/vm/lib/screen.sh tests/test-vmtest-lib.sh
git commit -m "test(vm): coarse screenshot checks"
```

---

### Task 4: `lib/qemu.sh` — start and stop a VM

**Files:**
- Create: `tests/vm/lib/qemu.sh`
- Modify: `tests/test-vmtest-lib.sh`

**Interfaces:**
- Consumes: `qmp_quit` (Task 2), `wait_for` (Task 1).
- Produces:
  - `vm_free_port [start]` → prints the first TCP port from `start` (default 2222) that `${C7VT_PORTCHECK:-_vt_port_used}` reports free.
  - `vm_start <dir> <disk.qcow2> [extra qemu args…]` → starts QEMU daemonized via `${C7VT_QEMU:-qemu-system-x86_64}`; writes `<dir>/qmp.sock`, `<dir>/serial.log`, `<dir>/qemu.pid`, `<dir>/ssh.port`.
  - `vm_stop <dir>` → `qmp_quit`, then waits up to 30 s for the pid to go.
  - `vm_ssh <dir> <command…>` → `ssh` as `c7test` to `127.0.0.1:$(cat <dir>/ssh.port)` with `$C7VT_CACHE/id_ed25519`, `BatchMode=yes`, `StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-vmtest-lib.sh`:

```bash
# --- qemu -----------------------------------------------------------------
printf '%s\n' '#!/bin/sh' "printf '%s\n' \"\$@\" > '$tmp/qemu.args'" > "$tmp/qemu"
chmod +x "$tmp/qemu"
export C7VT_QEMU=$tmp/qemu C7VT_OVMF=/fw/OVMF_CODE.fd
# Port 2222 is taken, 2223 is free.
export C7VT_PORTCHECK=port_taken
port_taken() { [[ $1 == 2222 ]]; }
# shellcheck source=vm/lib/qemu.sh
. "$vm/lib/qemu.sh"

[[ $(vm_free_port) == 2223 ]] || fail 'vm_free_port: must skip a port in use'

mkdir -p "$tmp/run"
vm_start "$tmp/run" "$tmp/disk.qcow2" -cdrom /x.iso
a=$(cat "$tmp/qemu.args")
for want in -enable-kvm -daemonize "hostfwd=tcp:127.0.0.1:2223-:22" \
            "unix:$tmp/run/qmp.sock,server=on,wait=off" "file:$tmp/run/serial.log" \
            "if=pflash,format=raw,readonly=on,file=/fw/OVMF_CODE.fd" -cdrom /x.iso; do
  grep -qF -- "$want" <<<"$a" || fail "vm_start: missing $want in\n$a"
done
grep -qx 2223 "$tmp/run/ssh.port" || fail 'vm_start: must record the ssh port'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/test-vmtest-lib.sh`
Expected: fails with `No such file or directory` for `tests/vm/lib/qemu.sh`.

- [ ] **Step 3: Write the implementation**

```bash
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
vm_start() {
  local dir=$1 disk=$2 port; shift 2
  port=$(vm_free_port)
  echo "$port" > "$dir/ssh.port"
  ${C7VT_QEMU:-qemu-system-x86_64} \
    -enable-kvm -machine q35 -cpu host -smp 4 -m 4096 \
    -drive "if=pflash,format=raw,readonly=on,file=${C7VT_OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}" \
    -drive "file=$disk,if=virtio,format=qcow2" \
    -device virtio-vga-gl -display egl-headless \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$port-:22" \
    -qmp "unix:$dir/qmp.sock,server=on,wait=off" \
    -serial "file:$dir/serial.log" \
    -pidfile "$dir/qemu.pid" -daemonize \
    "$@"
}

_vt_gone() { ! kill -0 "$(cat "$1/qemu.pid" 2>/dev/null)" 2>/dev/null; }

vm_stop() {
  qmp_quit "$1/qmp.sock" >/dev/null 2>&1 || true
  wait_for 30 _vt_gone "$1"
}

vm_ssh() {
  local dir=$1; shift
  ssh -p "$(cat "$dir/ssh.port")" -i "$C7VT_CACHE/id_ed25519" \
      -o BatchMode=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      c7test@127.0.0.1 "$@"
}
```

Note: the OVMF *vars* file is not needed. OVMF boots from the default boot order without persisting variables, and archinstall writes a removable-path bootloader (`EFI/BOOT/BOOTX64.EFI`) when `"bootloader": "Systemd-boot"` with `uki: false`. Task 6 verifies this on the first real boot.

- [ ] **Step 4: Run it to verify it passes**

Run: `tests/test-vmtest-lib.sh && shellcheck tests/vm/lib/qemu.sh`
Expected: `PASS: vmtest-lib`.

- [ ] **Step 5: Commit**

```bash
git add tests/vm/lib/qemu.sh tests/test-vmtest-lib.sh
git commit -m "test(vm): start, stop and reach the test VM"
```

---

### Task 5: `run.sh` — arguments, phases, report

**Files:**
- Create: `tests/vm/run.sh`
- Create: `tests/vm/lib/session.sh` (the remote assertion script, piped over SSH)
- Modify: `tests/test-vmtest-lib.sh`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces:
  - CLI: `run.sh --branch <name> [--repo <url>] [--keep] [--rebuild-base]`; `-h` prints usage and exits 0; a missing `--branch` or unknown option exits 2.
  - When sourced with `C7VT_SOURCE_ONLY=1`, defines `parse_args`, `slug`, `phase`, and exits nothing.
  - `slug <branch>` → branch with every character outside `[A-Za-z0-9._-]` replaced by `-`.
  - `phase <name> <timeout> <function>` → runs the function under `timeout`, appends `<name> <seconds>s ok|FAIL` to `$results/summary.txt`; on failure saves evidence and exits 1.

- [ ] **Step 1: Write the failing test**

Append to `tests/test-vmtest-lib.sh`:

```bash
# --- run.sh ---------------------------------------------------------------
"$vm/run.sh" -h >/dev/null || fail 'run.sh -h must exit 0'
set +e
"$vm/run.sh" >/dev/null 2>&1; [[ $? == 2 ]] || fail 'run.sh without --branch must exit 2'
"$vm/run.sh" --branch x --bogus >/dev/null 2>&1; [[ $? == 2 ]] || fail 'run.sh: an unknown option must exit 2'
set -e

# shellcheck source=vm/run.sh
C7VT_SOURCE_ONLY=1 . "$vm/run.sh"
[[ $(slug jv/feat:x) == jv-feat-x ]] || fail "slug: got $(slug jv/feat:x)"
parse_args --branch b --keep --repo r
[[ $branch == b && $keep == 1 && $repo_url == r && $rebuild == 0 ]] \
  || fail 'parse_args: wrong values'

results=$tmp/res; mkdir -p "$results"
ok_step() { true; }
phase demo 5 ok_step
grep -Eq '^demo [0-9]+s ok$' "$results/summary.txt" || fail 'phase: must log an ok line'
bad_step() { false; }
( phase broken 5 bad_step ) >/dev/null 2>&1 && fail 'phase: a failing step must exit'
grep -qx 'FAIL: broken' "$results/summary.txt" || fail 'phase: must log FAIL: <phase>'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `tests/test-vmtest-lib.sh`
Expected: fails with `No such file or directory` for `tests/vm/run.sh`.

- [ ] **Step 3: Write `tests/vm/lib/session.sh`**

This runs inside the VM as `c7test`, piped in with `vm_ssh "$dir" bash -s`. It finds the logged-in session's environment, runs the assertions, and writes a screenshot to `/tmp/c7vt-shot.png`.

```bash
#!/usr/bin/env bash
# Runs inside the test VM, over SSH, as the logged-in user. Not sourced on
# the host. Exits non-zero on the first assertion that fails, saying which.
set -euo pipefail
export XDG_RUNTIME_DIR=/run/user/$(id -u)
sig=$(ls -t "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -n1)
[[ -n $sig ]] || { echo 'assert: no Hyprland instance for this user'; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE=$sig
export WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls wayland-* | grep -v lock | head -n1)

hyprctl version >/dev/null || { echo 'assert: hyprctl does not answer'; exit 1; }
pgrep -u "$(id -u)" -x quickshell >/dev/null || { echo 'assert: quickshell is not running'; exit 1; }
c7shell-doctor || { echo 'assert: c7shell-doctor failed'; exit 1; }
if journalctl --user -b --no-pager | grep -E 'qrc:|\.qml:[0-9]+: '; then
  echo 'assert: QML errors in the user journal'; exit 1
fi
grim /tmp/c7vt-shot.png
```

- [ ] **Step 4: Write `tests/vm/run.sh`**

```bash
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

_vt_gone_ssh() { ! vm_ssh "$run" true 2>/dev/null; }

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
```

`phase` runs the step in a child `bash` that gets every function through `declare -f`, so `timeout` can kill it; `main` exports the variables the steps read. Exit code 2 for a missing `build-base.sh` prerequisite comes from `build-base.sh` itself (Task 6), and `phase` turns any non-zero into exit 1; a host problem found before the first phase exits 2 directly.

- [ ] **Step 5: Run the tests**

Run: `chmod +x tests/vm/run.sh && tests/test-vmtest-lib.sh && shellcheck -x tests/vm/run.sh tests/vm/lib/session.sh`
Expected: `PASS: vmtest-lib`, no shellcheck output.

- [ ] **Step 6: Commit**

```bash
git add tests/vm/run.sh tests/vm/lib/session.sh tests/test-vmtest-lib.sh
git commit -m "test(vm): run.sh drives install, greeter login and session checks"
```

---

### Task 6: `build-base.sh` and the known starting point

**Files:**
- Create: `tests/vm/build-base.sh`
- Create: `tests/vm/iso.version`
- Create: `tests/vm/archinstall.json`
- Create: `tests/vm/cloud-init/user-data.in`
- Create: `tests/vm/cloud-init/meta-data`

**Interfaces:**
- Consumes: `vm_start`, `vm_stop`, `wait_for`, `_vt_gone` (Tasks 1, 4).
- Produces: `$C7VT_CACHE/base.qcow2`, `base.iso.version`, `base.archinstall.json`, `c7test.password`, `id_ed25519`(`.pub`). Exit 2 on a checksum or signature mismatch.

- [ ] **Step 1: Write `tests/vm/iso.version`**

```
2026.10.01
```

- [ ] **Step 2: Write `tests/vm/archinstall.json`**

```json
{
  "archinstall-language": "English",
  "bootloader": "Systemd-boot",
  "uki": false,
  "disk_config": {
    "config_type": "default_layout",
    "device_modifications": [],
    "_comment": "build-base.sh replaces this with the default layout on /dev/vda"
  },
  "hostname": "c7test",
  "kernels": ["linux"],
  "locale_config": { "kb_layout": "us", "sys_enc": "UTF-8", "sys_lang": "en_US" },
  "mirror_config": { "mirror_regions": {} },
  "network_config": { "type": "nm" },
  "packages": ["openssh", "git", "sudo"],
  "profile_config": { "profile": { "main": "Minimal" } },
  "services": ["sshd"],
  "swap": true,
  "timezone": "UTC",
  "ntp": true,
  "custom_commands": [
    "install -d -m 700 -o 1000 -g 1000 /home/c7test/.ssh",
    "@AUTHORIZED_KEYS@",
    "echo 'c7test ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/c7test",
    "chmod 440 /etc/sudoers.d/c7test"
  ]
}
```

- [ ] **Step 3: Check the config against the archinstall on the ISO**

archinstall's JSON keys change between releases. Boot the pinned ISO once by hand (`qemu-system-x86_64 -enable-kvm -m 4096 -cdrom archlinux-2026.10.01-x86_64.iso`), run `archinstall --config /path/archinstall.json --dry-run`, and fix any key it rejects. Replace the `disk_config` placeholder with the `disk_config` block the dry run writes to `/var/log/archinstall/user_configuration.json` after choosing "Use a best-effort default partition layout" on `/dev/vda`, ext4. Commit the corrected file.

- [ ] **Step 4: Write `tests/vm/cloud-init/user-data.in`**

`@CONFIG@` and `@CREDS@` are filled in by `build-base.sh`, base64-encoded so YAML never sees the JSON. The SSH key does not go through user-data: archinstall formats the target first, so `build-base.sh` writes the key into the config's `custom_commands` instead (Step 5).


```yaml
#cloud-config
write_files:
  - path: /root/archinstall.json
    encoding: b64
    content: @CONFIG@
  - path: /root/creds.json
    encoding: b64
    permissions: '0600'
    content: @CREDS@
runcmd:
  - [ bash, -c, "archinstall --config /root/archinstall.json --creds /root/creds.json --silent > /dev/ttyS0 2>&1 && echo C7VT-INSTALL-OK > /dev/ttyS0 || echo C7VT-INSTALL-FAILED > /dev/ttyS0" ]
  - [ poweroff ]
```

In `archinstall.json` (Step 2), replace the second custom command with the placeholder `"@AUTHORIZED_KEYS@"`. `build-base.sh` swaps it for a command that writes the host's public key to `/home/c7test/.ssh/authorized_keys`.

`tests/vm/cloud-init/meta-data`:

```yaml
instance-id: c7vt-base
local-hostname: archiso
```

- [ ] **Step 5: Write `tests/vm/build-base.sh`**

```bash
#!/usr/bin/env bash
# Builds the known starting point for the VM setup test: the pinned Arch ISO,
# installed by archinstall from tests/vm/archinstall.json, with no desktop.
# Writes $C7VT_CACHE/base.qcow2. Exit 2 on a host or download problem.
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
iso=$C7VT_CACHE/archlinux-$ver-x86_64.iso
mirror=https://geo.mirror.pkgbuild.com/iso/$ver
mkdir -p "$C7VT_CACHE"

fetch_iso() {
  [[ -f $iso ]] && return 0
  curl -fL --retry 3 -o "$iso.part" "$mirror/archlinux-$ver-x86_64.iso"
  curl -fsSL -o "$C7VT_CACHE/sha256sums.txt" "$mirror/sha256sums.txt"
  curl -fsSL -o "$iso.sig" "$mirror/archlinux-$ver-x86_64.iso.sig"
  (cd "$C7VT_CACHE" && mv "$iso.part" "$iso" \
     && grep " archlinux-$ver-x86_64.iso\$" sha256sums.txt | sha256sum -c -) \
    || { rm -f "$iso"; echo 'build-base: ISO checksum mismatch' >&2; exit 2; }
  pacman-key -v "$iso.sig" "$iso" 2>/dev/null \
    || { rm -f "$iso"; echo 'build-base: ISO signature does not verify' >&2; exit 2; }
}

make_secrets() {
  [[ -f $C7VT_CACHE/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N '' -f "$C7VT_CACHE/id_ed25519"
  if [[ ! -f $C7VT_CACHE/c7test.password ]]; then
    (umask 077; tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 20 > "$C7VT_CACHE/c7test.password")
  fi
}

make_seed() {
  local seed=$1 pub key_cmd cfg creds
  pub=$(cat "$C7VT_CACHE/id_ed25519.pub")
  key_cmd="printf '%s\n' '$pub' > /home/c7test/.ssh/authorized_keys && chown 1000:1000 /home/c7test/.ssh/authorized_keys && chmod 600 /home/c7test/.ssh/authorized_keys"
  cfg=$(jq --arg k "$key_cmd" '.custom_commands |= map(if . == "@AUTHORIZED_KEYS@" then $k else . end)' \
        "$vm/archinstall.json" | base64 -w0)
  creds=$(jq -n --arg p "$(cat "$C7VT_CACHE/c7test.password")" \
          '{"root_enc_password": $p, "users": [{"username": "c7test", "!password": $p, "sudo": true}]}' \
          | base64 -w0)
  mkdir -p "$seed/d"
  sed -e "s|@CONFIG@|$cfg|" -e "s|@CREDS@|$creds|" "$vm/cloud-init/user-data.in" > "$seed/d/user-data"
  cp "$vm/cloud-init/meta-data" "$seed/d/meta-data"
  xorriso -as mkisofs -quiet -V CIDATA -J -r -o "$seed/seed.iso" "$seed/d"
}

_vt_stopped() { _vt_gone "$1"; }

main() {
  [[ -w /dev/kvm ]] || { echo 'build-base: /dev/kvm is not usable' >&2; exit 2; }
  fetch_iso
  make_secrets
  local run; run=$(mktemp -d "$C7VT_CACHE/build.XXXXXX")
  trap 'vm_stop "$run" >/dev/null 2>&1 || true; rm -rf -- "$run"' EXIT
  make_seed "$run"
  qemu-img create -q -f qcow2 "$run/base.qcow2" 30G
  vm_start "$run" "$run/base.qcow2" -cdrom "$iso" -drive "file=$run/seed.iso,media=cdrom,readonly=on" -boot d
  wait_for 1800 _vt_stopped "$run" || { echo 'build-base: install timed out' >&2; exit 1; }
  grep -q C7VT-INSTALL-OK "$run/serial.log" \
    || { tail -n 200 "$run/serial.log" >&2; echo 'build-base: archinstall failed' >&2; exit 1; }
  mv "$run/base.qcow2" "$C7VT_CACHE/base.qcow2"
  cp "$vm/iso.version" "$C7VT_CACHE/base.iso.version"
  cp "$vm/archinstall.json" "$C7VT_CACHE/base.archinstall.json"
}

main "$@"
```

`pacman-key -v` needs the Arch keyring on the laptop, which an Arch host has. The archinstall `creds.json` key names (`!password`, `root_enc_password`) must match the archinstall on the pinned ISO; Step 3's dry run checks them too.

- [ ] **Step 6: Build the base image on the laptop**

Run: `C7VT_POLL=10 tests/vm/build-base.sh`
Expected: exits 0 within 30 minutes; `~/.cache/c7shell-vmtest/base.qcow2` exists. Then boot an overlay and check SSH as `c7test` with `sudo -n true`. If OVMF does not find the bootloader, change `vm_start` to also pass a writable copy of `OVMF_VARS.4m.fd` as a second pflash drive, and re-run.

- [ ] **Step 7: Commit**

```bash
chmod +x tests/vm/build-base.sh
shellcheck -x tests/vm/build-base.sh
git add tests/vm/build-base.sh tests/vm/iso.version tests/vm/archinstall.json tests/vm/cloud-init
git commit -m "test(vm): build the archinstall base image from the pinned ISO"
```

---

### Task 7: `setup-host.sh` and README

**Files:**
- Create: `tests/vm/setup-host.sh`
- Create: `tests/vm/README.md`

**Interfaces:**
- Produces: an idempotent laptop setup; exit 2 if KVM is unavailable after setup.

- [ ] **Step 1: Write `tests/vm/setup-host.sh`**

```bash
#!/usr/bin/env bash
# One-time setup of the test laptop for tests/vm/run.sh. Safe to re-run.
set -euo pipefail

sudo pacman -S --needed --noconfirm qemu-full edk2-ovmf socat openssh \
  libisoburn git imagemagick jq archlinux-keyring

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
```

- [ ] **Step 2: Write `tests/vm/README.md`**

````markdown
# VM setup test

Installs a pushed c7shell branch onto a fresh, non-graphical Arch VM, logs in
through the real SDDM greeter, and checks the session. It runs on a dedicated
KVM machine, never in `tests/*.sh`.

Design: `docs/superpowers/specs/2026-10-13-vm-setup-test-design.md`.

## Set up the test machine

You need Arch with VT-x or AMD-V enabled, 16 GB RAM (8 GB minimum), and about
40 GB free disk.

```bash
tests/vm/setup-host.sh
```

## Run a test

```bash
tests/vm/run.sh --branch main
```

The first run builds the base image (up to 30 minutes). Later runs reuse it
until `iso.version` or `archinstall.json` changes, or you pass
`--rebuild-base`.

Results go to `~/.cache/c7shell-vmtest/results/<timestamp>-<branch>/`:
`summary.txt` ends in `PASS` or `FAIL: <phase>`. A failed run keeps its VM
disk in `~/.cache/c7shell-vmtest/runs/`; `--keep` keeps it after a pass too.

Exit codes: `0` pass, `1` test failure, `2` harness or host problem.

## Known gap

The VM uses virtio-gpu, so the NVIDIA and Intel driver paths of
`c7shell-bootstrap` are not exercised.
````

- [ ] **Step 3: Check and commit**

```bash
chmod +x tests/vm/setup-host.sh
shellcheck tests/vm/setup-host.sh
git add tests/vm/setup-host.sh tests/vm/README.md
git commit -m "test(vm): test-host setup script and README"
```

---

### Task 8: End-to-end proof on the laptop

**Files:** none new, unless a fix is needed.

- [ ] **Step 1: Run the full suite on the dev machine**

Run: `for t in tests/*.sh; do "$t"; done`
Expected: every test passes, including `PASS: vmtest-lib`, and no VM starts.

- [ ] **Step 2: Positive run on the laptop**

Run: `tests/vm/run.sh --branch main`
Expected: exit 0; `summary.txt` lists base, install, greeter, login and assert as `ok` and ends in `PASS`; `screens/session.png` shows the bar.

- [ ] **Step 3: Negative run on the laptop**

Push a throwaway branch where `bin/c7shell-setup` starts with `exit 1`.

Run: `tests/vm/run.sh --branch <throwaway>`
Expected: exit 1, `summary.txt` ends in `FAIL: install` (the remote script runs `c7shell-setup` under `set -e`). Delete the throwaway branch afterwards.

- [ ] **Step 4: Update graphify and commit any fixes**

```bash
graphify update .
git add -A tests/vm tests/test-vmtest-lib.sh
git commit -m "test(vm): fixes from the first end-to-end runs"
```
