#!/usr/bin/env bash
# Runs inside the test VM, over SSH, as the logged-in user. Not sourced on
# the host. Exits non-zero on the first assertion that fails, saying which.
set -euo pipefail
XDG_RUNTIME_DIR=/run/user/$(id -u)
export XDG_RUNTIME_DIR
# The newest Hyprland instance directory is the session the greeter started.
sig=$(find "$XDG_RUNTIME_DIR/hypr" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null \
      | sort -rn | head -n1 | cut -d' ' -f2)
[[ -n $sig ]] || { echo 'assert: no Hyprland instance for this user'; exit 1; }
export HYPRLAND_INSTANCE_SIGNATURE=$sig
WAYLAND_DISPLAY=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' | head -n1)
export WAYLAND_DISPLAY

hyprctl version >/dev/null || { echo 'assert: hyprctl does not answer'; exit 1; }
pgrep -u "$(id -u)" -x "qs|quickshell" >/dev/null || { echo 'assert: quickshell is not running'; exit 1; }
hyprctl layers | grep -q 'namespace: c7shell-bar' \
  || { echo 'assert: the c7shell-bar layer is not mapped'; exit 1; }
c7shell-doctor || { echo 'assert: c7shell-doctor failed'; exit 1; }
if journalctl --user -b --no-pager | grep -E 'qrc:|\.qml:[0-9]+: '; then
  echo 'assert: QML errors in the user journal'; exit 1
fi

# The shell survives being killed outright: c7shell-session relaunches it, and
# with it the bar and c7-authd (the polkit agent is the shell's child).
# SIGKILL, because that is the case only the supervisor can handle -- on a
# SIGSEGV quickshell's own crash handler relaunches the shell inside the same
# process, but nothing in the process survives the OOM killer. The shell is
# the supervisor's direct child. The supervisor and c7-authd are
# scripts (bash, python3), so they are matched by command line; this file
# arrives on stdin, so -f cannot match itself.
sup=$(pgrep -u "$(id -u)" -f '/c7shell-session$' | head -1)
[[ -n $sup ]] || { echo 'assert: c7shell-session is not running'; exit 1; }
old=$(pgrep -P "$sup" | head -1)
old_authd=$(pgrep -u "$(id -u)" -f '/c7-authd$' | head -1)
[[ -n $old && -n $old_authd ]] || { echo 'assert: no shell or c7-authd under c7shell-session'; exit 1; }
kill -KILL "$old"
back=
for _ in $(seq 60); do
  sleep 1
  new=$(pgrep -P "$sup" | head -1)
  if [[ -n $new && $new != "$old" ]] && hyprctl layers | grep -q 'namespace: c7shell-bar' \
     && authd=$(pgrep -u "$(id -u)" -f '/c7-authd$' | head -1) \
     && [[ -n $authd && $authd != "$old_authd" ]]; then back=1; break; fi
done
[[ -n $back ]] || { echo 'assert: the shell did not come back after a crash'; exit 1; }
grim /tmp/c7vt-shot.png
