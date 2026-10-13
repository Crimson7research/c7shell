#!/usr/bin/env bash
# Self-check for bin/c7shell-session, the supervisor that keeps the shell
# running. Run it directly: tests/test-session.sh
#
# qs, notify-send and sleep are stubs on a PATH of our own, so nothing here
# starts a shell or waits in real time.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
session=$here/../bin/c7shell-session
mktmp

bin=$tmp/bin
mkdir -p "$bin" "$tmp/run" "$tmp/conf"
for helper in bash cat date flock grep mkdir; do ln -s "$(command -v "$helper")" "$bin/$helper"; done
printf '#!/bin/sh\nexit 0\n' > "$bin/sleep"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notified"\n' "$tmp" > "$bin/notify-send"
chmod +x "$bin/sleep" "$bin/notify-send"
: > "$tmp/run/wayland-1"   # stands in for the compositor's socket

# qs: `list --all` reports nothing running; a launch appends to a log and
# exits with the next code from $tmp/codes (one per line), or 0 when used up.
cat > "$bin/qs" <<QS
#!/bin/sh
case "\$1" in list) exit 0 ;; esac
echo "\$*" >> "$tmp/launches"
code=\$(head -1 "$tmp/codes" 2>/dev/null); sed -i 1d "$tmp/codes" 2>/dev/null
[ -n "\$code" ] || { rm -f "$tmp/run/wayland-1"; exit 0; }
exit "\$code"
QS
chmod +x "$bin/qs"; ln -s "$(command -v sed)" "$bin/sed"; ln -s "$(command -v head)" "$bin/head"; ln -s "$(command -v rm)" "$bin/rm"

run() {
  env -i PATH="$bin" HOME="$tmp" XDG_CONFIG_HOME="$tmp/conf" XDG_RUNTIME_DIR="$tmp/run" \
    WAYLAND_DISPLAY=wayland-1 bash "$session" 2>&1
}

# --- a crash is followed by a fresh shell ---------------------------------
# Two crashes, then a shell that runs until the session ends (the stub removes
# the compositor socket on its last exit). Three launches, no notification.
printf '139\n134\n' > "$tmp/codes"; rm -f "$tmp/launches" "$tmp/notified"
out=$(run) || fail "the supervisor failed on a session that ended normally:\n$out"
(($(wc -l < "$tmp/launches") == 3)) || fail "expected 3 launches, got:\n$(cat "$tmp/launches")"
grep -qx -- '-c c7shell -n' "$tmp/launches" || fail "wrong launch command:\n$(cat "$tmp/launches")"
[[ ! -e $tmp/notified ]] || fail "notified on crashes it recovered from:\n$(cat "$tmp/notified")"

# --- a crash loop gives up, and says so -----------------------------------
# A config that fails to load exits at once, every time. Relaunching it
# forever only burns the CPU; after a handful in a minute the supervisor
# stops and tells the person why the bar is gone.
: > "$tmp/run/wayland-1"
printf '1\n%.0s' {1..20} > "$tmp/codes"; rm -f "$tmp/launches" "$tmp/notified"
rc=0; out=$(run) || rc=$?
((rc != 0)) || fail 'a crash loop ended with exit 0'
(($(wc -l < "$tmp/launches") <= 6)) || fail "kept relaunching a shell that never stays up: $(wc -l < "$tmp/launches") launches"
grep -q 'qs -c c7shell' "$tmp/notified" 2>/dev/null || fail "gave up without telling the person how to see the error:\n$(cat "$tmp/notified" 2>&1)"

# --- the session is over: no relaunch -------------------------------------
rm -f "$tmp/run/wayland-1" "$tmp/launches"; printf '139\n' > "$tmp/codes"
out=$(run) || fail "the supervisor failed when the session was already gone:\n$out"
[[ ! -e $tmp/launches ]] || fail 'launched a shell with no compositor to draw on'

# --- only one supervisor per session --------------------------------------
: > "$tmp/run/wayland-1"; rm -f "$tmp/launches"; printf '139\n' > "$tmp/codes"
exec 9>"$tmp/run/c7shell-session.lock"; flock -n 9
out=$(run) || fail "a second supervisor failed instead of stepping aside:\n$out"
[[ ! -e $tmp/launches ]] || fail 'a second supervisor launched a second shell'
exec 9>&-

# --- a shell someone else started is waited on, not duplicated -------------
# c7shell-upgrade relaunches the shell itself. While that one runs, the
# supervisor must not start another (the -n launch would just exit, and count
# as a crash).
rm -f "$tmp/launches"; : > "$tmp/run/wayland-1"
cat > "$bin/qs" <<QS
#!/bin/sh
case "\$1" in
  list) n=\$(cat "$tmp/listed" 2>/dev/null || echo 0)
        if [ "\$n" -lt 2 ]; then echo \$((n+1)) > "$tmp/listed"
          printf 'Instance x:\n  Config path: %s\n' "$tmp/conf/quickshell/c7shell/shell.qml"; fi
        exit 0 ;;
esac
echo "\$*" >> "$tmp/launches"; rm -f "$tmp/run/wayland-1"; exit 0
QS
out=$(run) || fail "failed while another shell was running:\n$out"
(($(wc -l < "$tmp/launches") == 1)) || fail "expected one launch after the other shell went away, got:\n$(cat "$tmp/launches" 2>&1)"

# --- autostart uses it -----------------------------------------------------
grep -q 'c7shell-session' "$here/../hypr/conf/autostart.lua" || fail 'autostart does not start the shell through c7shell-session'
grep -q 'qs -c c7shell -d' "$here/../hypr/conf/autostart.lua" && fail 'autostart still starts an unsupervised shell'
grep -q 'bin/c7shell-session' "$here/../PKGBUILD" || fail 'PKGBUILD does not install c7shell-session'

echo 'PASS: c7shell-session'
