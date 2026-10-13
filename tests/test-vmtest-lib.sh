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

# --- screen ---------------------------------------------------------------
# Fixtures are drawn here rather than committed: three tiny images say more
# in one line each than three binary files would.
if command -v magick >/dev/null; then
  # shellcheck source=vm/lib/screen.sh
  . "$vm/lib/screen.sh"
  magick -size 200x200 xc:black "$tmp/black.png"
  magick -size 200x200 xc:gray12 -fill silver -draw 'rectangle 0,0 199,39' "$tmp/bar.png"

  if screen_not_uniform "$tmp/black.png"; then fail 'screen: a solid image is uniform'; fi
  screen_not_uniform "$tmp/bar.png" || fail 'screen: the bar image is not uniform'
  screen_bar_drawn "$tmp/bar.png" || fail 'screen: must see the bar'
  if screen_bar_drawn "$tmp/black.png"; then fail 'screen: no bar on a black screen'; fi
else
  echo 'SKIP: screen checks (magick not installed, package: imagemagick)'
fi

# --- qemu -----------------------------------------------------------------
printf '%s\n' '#!/bin/sh' "printf '%s\n' \"\$@\" > '$tmp/qemu.args'" > "$tmp/qemu"
chmod +x "$tmp/qemu"
export C7VT_QEMU=$tmp/qemu C7VT_OVMF=/fw/OVMF_CODE.fd C7VT_CACHE=$tmp/cache
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

# --- run.sh ---------------------------------------------------------------
"$vm/run.sh" -h >/dev/null || fail 'run.sh -h must exit 0'
set +e
"$vm/run.sh" >/dev/null 2>&1; [[ $? == 2 ]] || fail 'run.sh without --branch must exit 2'
"$vm/run.sh" --branch x --bogus >/dev/null 2>&1; [[ $? == 2 ]] || fail 'run.sh: an unknown option must exit 2'
set -e

# shellcheck source=vm/run.sh
C7VT_SOURCE_ONLY=1 . "$vm/run.sh"
[[ $(slug jv/feat:x) == jv-feat-x ]] || fail "slug: got $(slug jv/feat:x)"
parse_args --branch b --keep
[[ $branch == b && $keep == 1 && $rebuild == 0 ]] \
  || fail 'parse_args: wrong values'

results=$tmp/res; mkdir -p "$results"
ok_step() { true; }
phase demo 5 ok_step
grep -Eq '^demo [0-9]+s ok$' "$results/summary.txt" || fail 'phase: must log an ok line'
bad_step() { false; }
( phase broken 5 bad_step ) >/dev/null 2>&1 && fail 'phase: a failing step must exit'
grep -qx 'FAIL: broken' "$results/summary.txt" || fail 'phase: must log FAIL: <phase>'

# A step whose first command fails fails, even when its last succeeds.
early_fail() { false; true; }
( phase early 5 early_fail ) >/dev/null 2>&1 && fail 'phase: steps must run under set -e'

# A host problem inside a step (exit 2) stays exit 2; anything else is 1.
host_step() { exit 2; }
set +e; ( phase host 5 host_step ) >/dev/null 2>&1; s=$?; set -e
[[ $s == 2 ]] || fail "phase: a step's exit 2 must stay 2, got $s"

# finish must report PASS even when stopping the VM fails.
mkdir -p "$tmp/frun"; : > "$results/summary.txt"
vm_stop() { return 1; }
( run=$tmp/frun keep=1; true; finish ) >/dev/null 2>&1 || fail 'finish: a failed vm_stop must not fail a pass'
grep -qx PASS "$results/summary.txt" || fail 'finish: must write PASS'

# The branch and URL reach the VM's shell quoted, never spliced in.
script=$(remote_install_script "a';touch /x;'" 'u r')
grep -qF "git clone --branch a\\'\\;touch\\ /x\\;\\' u\\ r c7shell" <<<"$script" \
  || fail "remote_install_script: branch not quoted:\n$script"

# A QEMU that greets but never answers the command is a failure, and an
# event that mentions "error" is not.
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' "printf '%s\n' '{\"QMP\":{}}' '{\"return\":{}}'" > "$tmp/socat-mute"
chmod +x "$tmp/socat-mute"
if C7VT_SOCAT=$tmp/socat-mute qmp_quit "$tmp/sock" >/dev/null; then fail 'qmp: no reply to the command must fail'; fi
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' \
  "printf '%s\n' '{\"QMP\":{}}' '{\"return\":{}}' '{\"event\":\"X\",\"data\":{\"error\":1}}' '{\"return\":{}}'" > "$tmp/socat-ev"
chmod +x "$tmp/socat-ev"
C7VT_SOCAT=$tmp/socat-ev qmp_quit "$tmp/sock" >/dev/null || fail 'qmp: an event mentioning error must not fail'

echo 'PASS: vmtest-lib'
