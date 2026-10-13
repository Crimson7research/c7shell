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
  magick -size 200x200 xc:'#202020' -fill '#c0c0c0' -draw 'rectangle 0,0 199,39' "$tmp/bar.png"

  if screen_not_uniform "$tmp/black.png"; then fail 'screen: a solid image is uniform'; fi
  screen_not_uniform "$tmp/bar.png" || fail 'screen: the bar image is not uniform'
  screen_bar_drawn "$tmp/bar.png" || fail 'screen: must see the bar'
  if screen_bar_drawn "$tmp/black.png"; then fail 'screen: no bar on a black screen'; fi
else
  echo 'SKIP: screen checks (magick not installed, package: imagemagick)'
fi

echo 'PASS: vmtest-lib'
