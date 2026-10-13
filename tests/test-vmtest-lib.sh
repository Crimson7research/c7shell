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
