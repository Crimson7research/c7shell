#!/usr/bin/env bash
# Self-check for bin/c7shell-doctor. Run it directly: tests/test-doctor.sh
#
# The doctor inspects the live system, so the test builds a fake one: a stub
# PATH holding one dummy executable per required command, and a fake root tree
# (C7SHELL_ROOT) holding the files and QML module directories it looks for.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
doctor=$here/../bin/c7shell-doctor
mktmp

bin=$tmp/bin
root=$tmp/root
conf=$tmp/conf
mkdir -p "$bin" "$root" "$conf"

# The doctor itself needs these to run under a PATH with nothing else on it.
for helper in grep head date stat; do ln -s "$(command -v "$helper")" "$bin/$helper"; done

stub() { printf '#!/bin/sh\nexit 0\n' > "$bin/$1"; chmod +x "$bin/$1"; }

required_cmds=(hyprctl start-hyprland qs hypridle hyprlock hyprpaper hyprpicker grim
               wf-recorder wl-copy notify-send wpctl bluetoothctl nmcli systemctl
               c7-authd c7-askpass c7shell-session)
for cmd in "${required_cmds[@]}"; do stub "$cmd"; done
# Every python import the appmenu daemon needs is reported present.
stub python3

hyprland_version() {
  printf '#!/bin/sh\necho "Hyprland %s built from branch"\n' "$1" > "$bin/Hyprland"
  chmod +x "$bin/Hyprland"
}
hyprland_version 0.56.1

mkdir -p "$root/usr/lib/hyprpolkitagent" "$root/usr/lib" \
         "$root/usr/share/wayland-sessions" "$root/dev/dri"
# The update flow: its polkit action and the root half that action authorises.
mkdir -p "$root/usr/share/polkit-1/actions" "$root/usr/lib/c7shell"
: > "$root/usr/share/polkit-1/actions/io.crimson7.c7shell.policy"
: > "$root/usr/lib/c7shell/c7up-root"
: > "$root/usr/lib/hyprpolkitagent/hyprpolkitagent"
# The setuid helper every polkit agent -- ours included -- authenticates
# through. Shipped by polkit, not by us.
mkdir -p "$root/usr/lib/polkit-1"
: > "$root/usr/lib/polkit-1/polkit-agent-helper-1"
: > "$root/usr/lib/xdg-desktop-portal-hyprland"
# The Settings-portal backend, plus a gsettings that reports a preference
# already exported -- what a set-up machine looks like.
: > "$root/usr/lib/xdg-desktop-portal-gtk"
# The FileChooser backend the shipped portals.conf routes to.
: > "$root/usr/lib/xdg-desktop-portal-kde"
gsettings_scheme() {
  printf '#!/bin/sh\necho "%s"\n' "$1" > "$bin/gsettings"
  chmod +x "$bin/gsettings"
}
gsettings_scheme "'prefer-dark'"
: > "$root/usr/lib/pam_kwallet_init"
printf '[Desktop Entry]\nName=c7shell\nExec=start-hyprland\n' \
  > "$root/usr/share/wayland-sessions/c7shell.desktop"
: > "$root/dev/dri/card0"
: > "$root/dev/dri/renderD128"

mkdir -p "$root/usr/lib/qt6/plugins/platformthemes" "$root/usr/lib/qt6/plugins/styles"
: > "$root/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so"
: > "$root/usr/lib/qt6/plugins/styles/breeze6.so"
printf '[General]\nColorScheme=C7Shell\n' > "$conf/kdeglobals"

for mod in Quickshell Quickshell/Hyprland Quickshell/Io Quickshell/Wayland \
           Quickshell/Bluetooth Quickshell/Networking \
           Quickshell/Services/Pipewire Quickshell/Services/UPower \
           Quickshell/Services/SystemTray Quickshell/Services/Notifications \
           Quickshell/Services/Mpris \
           QtQuick/Effects QtQuick/Shapes C7; do
  mkdir -p "$root/usr/lib/qt6/qml/$mod"
  : > "$root/usr/lib/qt6/qml/$mod/qmldir"
done

mkdir -p "$conf/hypr" "$conf/quickshell/c7shell" "$tmp/share"
: > "$conf/hypr/hyprland.lua"
# Without this hyprlock will not start, which takes SUPER+L, the power menu's
# lock row and the idle lock with it -- see the lock screen cases below.
printf 'general {\n    screencopy_mode = 1\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"
# A shell.qml that draws the password prompt, and an autostart that has stopped
# starting hyprpolkitagent -- what a machine looks like after the config half of
# the upgrade has actually landed. The two cases where it has not are asserted
# further down.
printf 'import Quickshell\nScope { AuthWindow {} }\n' > "$conf/quickshell/c7shell/shell.qml"
mkdir -p "$conf/hypr/conf"
printf 'hl.exec_cmd("/usr/lib/pam_kwallet_init")\n' > "$conf/hypr/conf/autostart.lua"

run() {
  env -i PATH="$bin" HOME="$tmp" \
    C7SHELL_ROOT="$root" C7SHELL_SHARE="$tmp/share" XDG_CONFIG_HOME="$conf" \
    /usr/bin/bash "$doctor" "$@"
}

# a complete system passes
out=$(run 2>&1) || fail "a complete fake system did not pass:\n$out"
grep -q 'everything' <<<"$out" || fail "expected a clean summary, got:\n$out"

# an Hyprland older than the lua config requirement is a failure, by version
hyprland_version 0.55.0
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "old Hyprland should fail, got exit $rc"
grep -q '0.55.0 is too old' <<<"$out" || fail "no version complaint:\n$out"
hyprland_version 0.56.1

# a quickshell built without a module the shell imports is a failure
mv "$root/usr/lib/qt6/qml/Quickshell/Bluetooth" "$tmp/gone"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "missing QML module should fail, got exit $rc"
grep -q 'Quickshell.Bluetooth not available' <<<"$out" || fail "no QML complaint:\n$out"
mv "$tmp/gone" "$root/usr/lib/qt6/qml/Quickshell/Bluetooth"

# the C7 plugin is ours, so its absence names this package. A directory with no
# qmldir is not a module: an upgrade that removed the files but left the
# directory loads nothing either.
rm "$root/usr/lib/qt6/qml/C7/qmldir"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "missing C7 qmldir should fail, got exit $rc"
grep -q 'QML module C7 not available.*(package: c7shell)' <<<"$out" \
  || fail "no C7 complaint naming the c7shell package:\n$out"
: > "$root/usr/lib/qt6/qml/C7/qmldir"

# no DRM device: the compositor cannot start, and that is the black-screen case
rm "$root/dev/dri/card0"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "missing /dev/dri/card* should fail, got exit $rc"
grep -q 'no GPU driver' <<<"$out" || fail "no GPU complaint:\n$out"
: > "$root/dev/dri/card0"

# A virtual GPU whose ~/.config copy predates the llvmpipe fallback. This is
# the case that used to pass every check while the session came up empty, so
# it is worth pinning down in all four directions.
drm=$root/sys/class/drm/card0/device
mkdir -p "$drm"
env_lua=$conf/hypr/conf/environment.lua
mkdir -p "$(dirname -- "$env_lua")"

# vmwgfx is reproduced end to end, so an old copy there is a failure
printf 'DRIVER=vmwgfx\n' > "$drm/uevent"
printf 'hl.env("QT_QPA_PLATFORMTHEME", "kde")\n' > "$env_lua"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "vmwgfx with no llvmpipe fallback should fail, got exit $rc"
grep -q 'no llvmpipe fallback' <<<"$out" || fail "no fallback complaint:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" || fail "no upgrade hint:\n$out"

# ...and once c7shell-upgrade has parked the new version, say so instead
printf 'hl.env("LIBGL_ALWAYS_SOFTWARE", "1")\n' > "$env_lua.new"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "a parked .new does not make the live file work, got exit $rc"
grep -q 'already waiting' <<<"$out" || fail "no merge hint for the .new:\n$out"
rm -f "$env_lua.new"

# the fallback present is the fixed machine, and passes
printf 'hl.env("LIBGL_ALWAYS_SOFTWARE", "1")\n' > "$env_lua"
out=$(run 2>&1) || fail "vmwgfx with the fallback should pass:\n$out"
grep -q 'falls back to llvmpipe' <<<"$out" || fail "no llvmpipe ok line:\n$out"

# the other virtual GPUs are pre-empted, not confirmed broken: warn, don't fail
printf 'DRIVER=virtio_gpu\n' > "$drm/uevent"
printf 'hl.env("QT_QPA_PLATFORMTHEME", "kde")\n' > "$env_lua"
out=$(run 2>&1) || fail "virtio_gpu without the fallback should warn, not fail:\n$out"
grep -q 'no llvmpipe fallback' <<<"$out" || fail "no virtio_gpu warning:\n$out"

# The other half of what a virtual GPU breaks: hyprlock's dmabuf screen copy.
# The env fallback is in place throughout, so only the lock config is under test.
printf 'DRIVER=vmwgfx\n' > "$drm/uevent"
printf 'hl.env("LIBGL_ALWAYS_SOFTWARE", "1")\n' > "$env_lua"
out=$(run 2>&1) || fail "vmwgfx with screencopy_mode = 1 should pass:\n$out"
grep -q 'through shm' <<<"$out" || fail "no shm ok line:\n$out"

# ...and without it, hyprlock aborts on the copy: nothing locks at all
printf 'general {\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "vmwgfx with no screencopy_mode should fail, got exit $rc"
grep -q 'suspends unlocked' <<<"$out" || fail "the consequence was not spelled out:\n$out"

# a parked hyprlock.conf.new that has it changes the advice to "merge it"
printf 'general {\n    screencopy_mode = 1\n}\n' > "$conf/hypr/hyprlock.conf.new"
rc=0; out=$(run 2>&1) || rc=$?
grep -q 'already waiting in hyprlock.conf.new' <<<"$out" \
  || fail "the parked fix was not offered:\n$out"
rm -f "$conf/hypr/hyprlock.conf.new"
printf 'general {\n    screencopy_mode = 1\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"

# The third thing it breaks: hyprpaper SIGABRTs on the first wallpaper request,
# so conf/gpu.lua leaves it out of autostart and the shell paints instead. A
# ~/.config copy from before that has no gpu.lua, which is the whole check --
# the wallpaper setting on such a machine saves fine and does nothing.
out=$(run 2>&1) || fail "vmwgfx with no gpu.lua should warn, not fail:\n$out"
grep -q 'hyprpaper is autostarted' <<<"$out" || fail "the dead hyprpaper was not reported:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" || fail "no way to fix it given:\n$out"

: > "$conf/hypr/conf/gpu.lua"
out=$(run 2>&1) || fail "vmwgfx with gpu.lua should pass:\n$out"
grep -q 'the shell paints the wallpaper' <<<"$out" || fail "no wallpaper backend line:\n$out"

# a real GPU is none of this machine's business, even with the same old copy
printf 'DRIVER=amdgpu\n' > "$drm/uevent"
printf 'general {\n    screencopy_mode = 1\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"
out=$(run 2>&1) || fail "a real GPU should not be touched by the check:\n$out"
grep -q 'llvmpipe' <<<"$out" && fail "the check fired on a real GPU:\n$out"

rm -rf "$root/sys" "$conf/hypr/conf"

# configs still in /usr/share: a failure normally, the next step with --setup-pending
mv "$conf/hypr" "$tmp/hypr-gone"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "missing ~/.config/hypr should fail, got exit $rc"
grep -q 'c7shell-setup' <<<"$out" || fail "no setup hint:\n$out"
out=$(run --setup-pending 2>&1) || fail "--setup-pending should not fail on a fresh install:\n$out"
grep -q 'next  ' <<<"$out" || fail "--setup-pending did not report the next step:\n$out"
mv "$tmp/hypr-gone" "$conf/hypr"

# a missing required command names the package that provides it
rm "$bin/grim"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "missing grim should fail, got exit $rc"
grep -q 'package: grim' <<<"$out" || fail "no package name for grim:\n$out"
stub grim

# optional programs only warn
rc=0; out=$(run 2>&1) || rc=$?
((rc == 0)) || fail "optional programs should not fail the check, got exit $rc"
grep -q 'warn  kitty' <<<"$out" || fail "kitty should warn, not fail:\n$out"

# --quiet prints problems only
rm "$bin/grim"
out=$(run --quiet 2>&1 || true)
grep -q 'FAIL  grim' <<<"$out" || fail "--quiet dropped the failure:\n$out"
! grep -q '  ok    ' <<<"$out" || fail "--quiet printed passing checks:\n$out"

stub grim     # the --quiet case above removed it; these cases want a clean pass
stub dolphin  # an app that benefits, which is what turns the theming checks on

# now that a Qt/KDE app is installed, the theming section reports
out=$(run 2>&1) || fail "the theming section should not be fatal:\n$out"
grep -q 'Qt/KDE apps present: dolphin' <<<"$out" || fail "dolphin did not turn the checks on:\n$out"

# no platform theme plugin: QT_QPA_PLATFORMTHEME=kde is inert and Qt apps look
# stock, which is a warning (the shell itself still runs) naming the package
mv "$root/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so" "$tmp/theme-gone"
out=$(run 2>&1) || fail "a missing platform theme plugin should not be fatal:\n$out"
grep -q 'KDEPlasmaPlatformTheme6.so missing' <<<"$out" || fail "the missing plugin was not reported:\n$out"
grep -q 'plasma-integration' <<<"$out" || fail "plasma-integration was not named:\n$out"
mv "$tmp/theme-gone" "$root/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so"

# kdeglobals without the exported scheme is reported with the command to seed it
mv "$conf/kdeglobals" "$tmp/kdeglobals-gone"
mkdir -p "$conf/quickshell/c7shell/scripts"
: > "$conf/quickshell/c7shell/scripts/c7shell-theme-export.py"
out=$(run 2>&1) || fail "an unexported palette should not be fatal:\n$out"
grep -q 'no C7Shell scheme yet' <<<"$out" || fail "the unexported palette was not reported:\n$out"
grep -q 'c7shell-theme-export.py' <<<"$out" || fail "no seed command given:\n$out"
mv "$tmp/kdeglobals-gone" "$conf/kdeglobals"

# without the gtk backend nothing answers the Settings portal, so every app that
# detects a theme picks light -- required, not cosmetic
mv "$root/usr/lib/xdg-desktop-portal-gtk" "$tmp/portal-gtk-gone"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "a missing Settings portal backend should fail, got exit $rc"
grep -q 'xdg-desktop-portal-gtk missing' <<<"$out" || fail "the missing backend was not reported:\n$out"
mv "$tmp/portal-gtk-gone" "$root/usr/lib/xdg-desktop-portal-gtk"

# without the kde backend the portal falls back to the gtk picker on its own,
# so the doctor warns instead of failing
mv "$root/usr/lib/xdg-desktop-portal-kde" "$tmp/portal-kde-gone"
out=$(run 2>&1) || fail "a missing FileChooser backend should warn, not fail:\n$out"
grep -q 'xdg-desktop-portal-kde missing' <<<"$out" || fail "the missing kde backend was not reported:\n$out"
mv "$tmp/portal-kde-gone" "$root/usr/lib/xdg-desktop-portal-kde"

# a portal that has been running since before the config was written is still
# routing FileChooser the old way, so every picker comes from gtk while the file
# on disk says kde -- the one failure here that looks like nothing is wrong
mkdir -p "$conf/xdg-desktop-portal"
: > "$conf/xdg-desktop-portal/hyprland-portals.conf"
portal_started() {
  printf '#!/bin/sh\nif [ "$2" = show ]; then echo "%s"; fi\nexit 0\n' "$1" > "$bin/systemctl"
  chmod +x "$bin/systemctl"
}
portal_started 'Fri 2020-01-01 00:00:00 CET'
out=$(run 2>&1) || fail "a stale portal should warn, not fail:\n$out"
grep -q 'started before the portal config was written' <<<"$out" \
  || fail "the stale portal was not reported:\n$out"
grep -q 'systemctl --user restart xdg-desktop-portal' <<<"$out" \
  || fail "no way to fix the stale portal given:\n$out"

# and a portal started after it is in force, so there is nothing to say
portal_started 'Fri 2099-01-01 00:00:00 CET'
out=$(run 2>&1) || fail "a fresh portal should pass:\n$out"
grep -q 'started before the portal config' <<<"$out" \
  && fail "a portal newer than its config was called stale:\n$out"
grep -q 'the running portal is newer than its config' <<<"$out" \
  || fail "a fresh portal was not reported:\n$out"

# a portal that has never run is started by its socket on demand; nothing to say
stub systemctl
out=$(run 2>&1) || fail "a portal that has not run should pass:\n$out"
grep -q 'the running portal' <<<"$out" \
  && fail "a portal that has never run was judged anyway:\n$out"
portal_started 'Fri 2099-01-01 00:00:00 CET'

# the backend can only report what GSettings holds: unset is the state that left
# apps light, and it names how to set it
gsettings_scheme "'default'"
out=$(run 2>&1) || fail "an unset color-scheme should warn, not fail:\n$out"
grep -q 'no color-scheme preference set' <<<"$out" || fail "the unset preference was not reported:\n$out"
grep -q 'c7shell-theme-export.py' <<<"$out" || fail "no way to set it given:\n$out"
gsettings_scheme "'prefer-dark'"

# an install from before the launcher fix is spotted, and names the repair
printf '[Desktop Entry]\nName=c7shell\nExec=Hyprland\n' \
  > "$root/usr/share/wayland-sessions/c7shell.desktop"
out=$(run 2>&1) || fail "an old session entry should warn, not fail:\n$out"
grep -q 'execs Hyprland directly' <<<"$out" || fail "the old launcher was not noticed:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" || fail "no repair command named:\n$out"
printf '[Desktop Entry]\nName=c7shell\nExec=start-hyprland\n' \
  > "$root/usr/share/wayland-sessions/c7shell.desktop"
out=$(run --quiet 2>&1 || true)
grep -q 'execs Hyprland directly' <<<"$out" && fail "a current session entry still warned:\n$out"

# --- the lock screen -------------------------------------------------------
# hyprlock refuses to start without a config, and nothing in the session says
# so: the symptom is SUPER+L doing nothing and -- quietly -- the machine
# suspending unlocked, because hypridle's before_sleep_cmd fails the same way.
mv "$conf/hypr/hyprlock.conf" "$tmp/lock-gone"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "a missing hyprlock config should fail, got exit $rc:\n$out"
grep -q 'suspends unlocked' <<<"$out" || fail "the consequence was not spelled out:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" || fail "no way to get the config named:\n$out"

# The shipped copy changes the advice from "update the package" to "run upgrade,
# it adds the file"
mkdir -p "$tmp/share/hypr"
: > "$tmp/share/hypr/hyprlock.conf"
rc=0; out=$(run 2>&1) || rc=$?
grep -q 'adds it as a new file' <<<"$out" || fail "the shipped config was not offered:\n$out"
mv "$tmp/lock-gone" "$conf/hypr/hyprlock.conf"

# grace is a CLI flag in hyprlock 0.9, not a config key: in the file it is a
# config error that stops hyprlock starting, and on a before-sleep lock it would
# unlock the screen on resume.
printf 'general {\n    grace = 5\n    screencopy_mode = 1\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"
out=$(run 2>&1) || fail "a stray grace should warn, not fail:\n$out"
grep -q 'sets grace' <<<"$out" || fail "grace in the config was not reported:\n$out"
printf 'general {\n    screencopy_mode = 1\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"

# A newer hyprlock.conf parked beside an edited one. c7shell-upgrade reports
# this once, as it writes the file; on an install whose config predates the
# manifest every file is treated as edited, so the one message scrolls past in a
# crowd and the lock screen silently stays on the old design.
: > "$conf/hypr/hyprlock.conf.new"
out=$(run 2>&1) || fail "a parked hyprlock.conf.new should warn, not fail:\n$out"
grep -q 'hyprlock.conf.new' <<<"$out" || fail "the parked config was not reported:\n$out"
grep -q 'diff ' <<<"$out" || fail "no way to see what changed:\n$out"
rm -f "$conf/hypr/hyprlock.conf.new"

# The now-playing and status lines are a command on PATH. c7shell-upgrade
# --config-only refreshes the config without reinstalling the package, which
# leaves the config calling a binary that is not there -- and hyprlock draws an
# empty label rather than complaining.
printf 'label {\n    text = cmd[update:2000] c7shell-lock-info media\n}\n' \
  >> "$conf/hypr/hyprlock.conf"
out=$(run 2>&1) || fail "a missing c7shell-lock-info should warn, not fail:\n$out"
grep -q 'c7shell-lock-info, which is not installed' <<<"$out" \
  || fail "the missing helper was not reported:\n$out"
# ...and says nothing once it is on PATH, where the package puts it.
stub c7shell-lock-info
out=$(run 2>&1) || fail "an installed c7shell-lock-info should be silent:\n$out"
grep -q 'c7shell-lock-info, which is not installed' <<<"$out" \
  && fail "the helper is on PATH and still reported missing:\n$out"
rm -f "$bin/c7shell-lock-info"

# The exported palette is the only way the lock screen follows the accent, and
# nothing else in the session notices it is missing: the lock screen simply
# stays crimson.
printf 'source = $HOME/.config/hypr/hyprlock-palette.conf\n' \
  >> "$conf/hypr/hyprlock.conf"
out=$(run 2>&1) || fail "an unexported lock palette should warn, not fail:\n$out"
grep -q 'lock screen has no exported palette' <<<"$out" \
  || fail "the missing lock screen palette was not reported:\n$out"
: > "$conf/hypr/hyprlock-palette.conf"
out=$(run 2>&1) || fail "an exported lock palette should be silent:\n$out"
grep -q 'lock screen has no exported palette' <<<"$out" \
  && fail "the palette is there and still reported missing:\n$out"
rm -f "$conf/hypr/hyprlock-palette.conf"

# SUPER+L runs c7shell-lock, which ships with the package while the keybind
# ships with the config -- so --config-only leaves the bind calling a command
# that is not installed and nothing locks at all.
mkdir -p "$conf/hypr/conf"
printf 'hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("c7shell-lock"))\n' \
  > "$conf/hypr/conf/binds.lua"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "a missing c7shell-lock should fail, got exit $rc"
grep -q 'suspends unlocked' <<<"$out" || fail "the consequence was not spelled out:\n$out"
stub c7shell-lock
out=$(run 2>&1) || fail "an installed c7shell-lock should be silent:\n$out"
grep -q 'runs c7shell-lock, which is not installed' <<<"$out" \
  && fail "c7shell-lock is on PATH and still reported missing:\n$out"
rm -f "$bin/c7shell-lock" "$conf/hypr/conf/binds.lua"
printf 'general {\n    ignore_empty_input = true\n}\n' > "$conf/hypr/hyprlock.conf"

# --- the greeter theme -----------------------------------------------------
# The theme QML comes with the package; the selection is a drop-in in
# /etc/sddm.conf.d that c7shell-bootstrap or c7shell-upgrade writes. Every
# state here is a warning: a machine may run another display manager and the
# session works regardless.
out=$(run 2>&1) || fail "an sddm-less machine should not fail:\n$out"
grep -q 'sddm is not installed' <<<"$out" || fail "no note about the unused theme:\n$out"

stub sddm   # sddm here, theme not: the package needs rebuilding
out=$(run 2>&1) || fail "a missing theme should not fail:\n$out"
grep -q 'themes/c7shell is not' <<<"$out" || fail "the missing theme was not reported:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" || fail "no repair command for the missing theme:\n$out"

mkdir -p "$root/usr/share/sddm/themes/c7shell" "$root/etc/sddm.conf.d" "$root/usr/bin"
: > "$root/usr/share/sddm/themes/c7shell/Main.qml"
theme_meta=$root/usr/share/sddm/themes/c7shell/metadata.desktop
printf '[SddmGreeterTheme]\nName=c7shell\nQtVersion=6\nMainScript=Main.qml\n' > "$theme_meta"
# The binary sddm derives from QtVersion, and an ldd that reports its libraries
# resolve -- what a machine that will actually show a login screen looks like.
: > "$root/usr/bin/sddm-greeter-qt6"; chmod +x "$root/usr/bin/sddm-greeter-qt6"
printf '#!/bin/sh\nexit 0\n' > "$bin/ldd"; chmod +x "$bin/ldd"
out=$(run 2>&1) || fail "an unselected theme should not fail:\n$out"
grep -q 'no sddm theme is selected' <<<"$out" || fail "the unselected theme was not reported:\n$out"

printf '[Theme]\nCurrent=breeze\n' > "$root/etc/sddm.conf"
out=$(run 2>&1) || fail "another theme should not fail:\n$out"
grep -q 'set to the "breeze" theme' <<<"$out" || fail "another theme was not reported:\n$out"

# Selected, but without the greeter environment the kernel and battery readouts
# are silently empty -- worth saying, since nothing else shows it.
printf '[Theme]\nCurrent=c7shell\n' > "$root/etc/sddm.conf.d/10-c7shell.conf"
rm -f "$root/etc/sddm.conf"
out=$(run 2>&1) || fail "a selected theme should not fail:\n$out"
grep -q 'uses the c7shell greeter theme' <<<"$out" || fail "the selection was not recognised:\n$out"
grep -q 'QML_XHR_ALLOW_FILE_READ' <<<"$out" || fail "the missing greeter env was not reported:\n$out"

printf '[Theme]\nCurrent=c7shell\n\n[General]\nGreeterEnvironment=QML_XHR_ALLOW_FILE_READ=1\n' \
  > "$root/etc/sddm.conf.d/10-c7shell.conf"
out=$(run 2>&1) || fail "a fully configured greeter should not fail:\n$out"
grep -q 'may read /proc' <<<"$out" || fail "the greeter env was not recognised:\n$out"
grep -q 'greeter binary sddm-greeter-qt6 runs' <<<"$out" || fail "the greeter binary was not checked:\n$out"

# The network pill's only source: nothing publishes the connection without it,
# and "my greeter shows no wifi" has no other explanation.
stub nmcli
out=$(run 2>&1) || fail "a missing dispatcher should not fail:\n$out"
grep -q 'greeter shows no network' <<<"$out" || fail "the missing dispatcher was not reported:\n$out"
mkdir -p "$root/usr/lib/NetworkManager/dispatcher.d"
: > "$root/usr/lib/NetworkManager/dispatcher.d/50-c7shell-greeter"
chmod +x "$root/usr/lib/NetworkManager/dispatcher.d/50-c7shell-greeter"
out=$(run 2>&1) || fail "a present dispatcher should not fail:\n$out"
grep -q 'greeter network readout' <<<"$out" || fail "the dispatcher was not recognised:\n$out"

# The black-screen case, and the reason this is checked at all: sddm builds the
# greeter path as sddm-greeter + (QtVersion ? "-qt<n>" : ""), so a theme that
# declares nothing gets handed to the Qt5 greeter -- present on Arch, but its
# Qt5 libraries are only an optdepend of sddm. It exits 127 and the login screen
# is black, with the reason only in sddm's journal. A failure, not a warning:
# this machine will not let anyone in.
printf '[SddmGreeterTheme]\nName=c7shell\nMainScript=Main.qml\n' > "$theme_meta"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "a greeter binary that is not installed should fail, got exit $rc:\n$out"
grep -q 'black screen' <<<"$out" || fail "the black screen was not predicted:\n$out"

# Same, for a binary that is there but cannot load its libraries
: > "$root/usr/bin/sddm-greeter"; chmod +x "$root/usr/bin/sddm-greeter"
printf '#!/bin/sh\necho "\tlibQt5Quick.so.5 => not found"\n' > "$bin/ldd"; chmod +x "$bin/ldd"
rc=0; out=$(run 2>&1) || rc=$?
((rc == 1)) || fail "an unloadable greeter binary should fail, got exit $rc:\n$out"
grep -q 'cannot start' <<<"$out" || fail "the unloadable binary was not reported:\n$out"
grep -q 'declares no QtVersion' <<<"$out" || fail "the missing QtVersion was not named:\n$out"

printf '[SddmGreeterTheme]\nName=c7shell\nQtVersion=6\nMainScript=Main.qml\n' > "$theme_meta"
printf '#!/bin/sh\nexit 0\n' > "$bin/ldd"; chmod +x "$bin/ldd"

# --- the optional-package picker -------------------------------------------
# It needs a terminal to prompt on, so drive it through a pty with `script`.
# pacman is a stub that records what it was asked to install.
log=$tmp/pacman.log
printf '#!/bin/sh\necho "$@" >> "%s"\n' "$log" > "$bin/pacman"
chmod +x "$bin/pacman"
printf '#!/bin/sh\nexec "$@"\n' > "$bin/sudo"   # run the command as ourselves
chmod +x "$bin/sudo"
for helper in script sed; do ln -s "$(command -v "$helper")" "$bin/$helper"; done

# Pin the offer list: dolphin present, kitty absent so 1) is kitty, and
# pam_kwallet_init removed so the one file-kind entry is offered too (last).
stub dolphin
rm "$root/usr/lib/pam_kwallet_init"

# pick <answer> -> what the picker asked pacman to install
pick() {
  : > "$log"
  env -i PATH="$bin" HOME="$tmp" TERM=dumb \
    C7SHELL_ROOT="$root" C7SHELL_SHARE="$tmp/share" XDG_CONFIG_HOME="$conf" \
    /usr/bin/script -qec "/usr/bin/bash $doctor --optional --quiet" /dev/null <<<"$1" \
    > "$tmp/pick.out" 2>&1 || true
  tr -d '\r' < "$log"
}

out=$(pick '')
[[ -z $out ]] || fail "an empty answer installed something: $out"
grep -q 'nothing selected' "$tmp/pick.out" || fail "empty answer not acknowledged:\n$(cat "$tmp/pick.out")"

out=$(pick 1)
[[ $out == '-S --needed -- kitty' ]] || fail "picking 1 should install kitty, got: $out"

out=$(pick '1 3')
[[ $out == '-S --needed -- kitty ddcutil' ]] || fail "picking '1 3' installed: $out"

out=$(pick '1-3')
[[ $out == '-S --needed -- kitty hyprlauncher ddcutil' ]] || fail "the range 1-3 installed: $out"

# a number covered twice is not an error and is not installed twice
out=$(pick '1 1-2')
[[ $out == '-S --needed -- kitty hyprlauncher' ]] || fail "duplicate selection installed: $out"

# dolphin alone would ignore the palette, so its companions come with it
rm "$bin/dolphin"
: > "$log"
out=$(pick 2)   # 1 = kitty, 2 = dolphin now that it is absent again
[[ $out == *dolphin* ]] || fail "picking dolphin did not install it: $out"
[[ $out == *plasma-integration*breeze*breeze-icons* ]] \
  || fail "dolphin's companions were not installed with it: $out"
grep -q 'plasma-integration breeze breeze-icons' "$tmp/pick.out" \
  || fail "the offer did not mention the companions:\n$(cat "$tmp/pick.out")"
# and they are not offered as entries of their own
grep -qE '^ +[0-9]+\) plasma-integration' "$tmp/pick.out" \
  && fail "plasma-integration was offered as its own entry:\n$(cat "$tmp/pick.out")"
stub dolphin

out=$(pick a)
[[ $out == *kitty*kwallet* ]] || fail "'a' should install every offered package, got: $out"

out=$(pick 99)
[[ -z $out ]] || fail "an out-of-range answer installed something: $out"
grep -q 'out of range' "$tmp/pick.out" || fail "no out-of-range complaint:\n$(cat "$tmp/pick.out")"

out=$(pick 'nope')
[[ -z $out ]] || fail "a non-numeric answer installed something: $out"
grep -q 'not a number' "$tmp/pick.out" || fail "no complaint about garbage input:\n$(cat "$tmp/pick.out")"

# A plugin missing while the app that needs it is installed has to be offered on
# its own: the companion route through the dolphin entry can never fire, because
# dolphin is not in the offer list at all. Kept last -- an extra entry here would
# renumber the picks asserted above.
mv "$root/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so" "$tmp/theme-gone2"
out=$(pick a)
[[ $out == *plasma-integration* ]] \
  || fail "a missing plugin was not offered where the app is already installed: $out"
grep -q 'plasma-integration' "$tmp/pick.out" \
  || fail "the offer did not list plasma-integration:\n$(cat "$tmp/pick.out")"
mv "$tmp/theme-gone2" "$root/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so"

# --- an AUR entry goes to the helper, never to pacman -----------------------
# `pacman -S arch-update` is not a slow path, it is "target not found": the
# package only exists in the AUR. So the picker has to split the selection, and
# the AUR half has to survive there being no helper at all.
pick ''   # re-render the menu so the entry can be found by number
arch_n=$(sed -n 's/^ *\([0-9]\{1,\}\)) arch-update .*/\1/p' "$tmp/pick.out" | head -1)
[[ -n $arch_n ]] || fail "arch-update was not offered:\n$(cat "$tmp/pick.out")"

# no helper installed: pacman is not asked, and the manual route is printed
out=$(pick "$arch_n")
[[ $out != *arch-update* ]] || fail "an AUR package was handed to pacman: $out"
grep -q 'no working AUR helper' "$tmp/pick.out" \
  || fail "the missing helper was not reported:\n$(cat "$tmp/pick.out")"
grep -q 'aur.archlinux.org/arch-update.git' "$tmp/pick.out" \
  || fail "no by-hand route for the skipped AUR package:\n$(cat "$tmp/pick.out")"

# a broken helper is no helper: it must not be run, only reported
paru_log=$tmp/paru.log
printf '#!/bin/sh\ncase $1 in --version) echo "paru: error while loading shared libraries: libalpm.so.16" >&2; exit 127 ;; esac\necho "$@" >> "%s"\n' \
  "$paru_log" > "$bin/paru"
chmod +x "$bin/paru"
: > "$paru_log"
out=$(pick "$arch_n")
[[ ! -s $paru_log ]] || fail "a broken helper was still used to install: $(cat "$paru_log")"
grep -q 'no working AUR helper' "$tmp/pick.out" \
  || fail "a broken helper was treated as usable:\n$(cat "$tmp/pick.out")"

# a working one gets the AUR package, and only the AUR package
printf '#!/bin/sh\ncase $1 in --version) echo "paru v2.1.0"; exit 0 ;; esac\necho "$@" >> "%s"\n' \
  "$paru_log" > "$bin/paru"
: > "$paru_log"
out=$(pick "$arch_n")
[[ $(tr -d '\r' < "$paru_log") == '-S --needed -- arch-update' ]] \
  || fail "paru was not asked for arch-update, got: $(cat "$paru_log")"
[[ -z $out ]] || fail "an AUR-only pick also ran pacman: $out"

# picking everything splits across both channels rather than failing either
: > "$paru_log"
out=$(pick a)
[[ $out == *kitty* ]] || fail "'a' did not install the repo packages: $out"
[[ $out != *arch-update* ]] || fail "'a' handed the AUR package to pacman: $out"
[[ $(tr -d '\r' < "$paru_log") == *arch-update* ]] \
  || fail "'a' did not install the AUR package: $(cat "$paru_log")"
rm -f "$bin/paru"

# present on PATH, and it is neither reported missing nor offered
stub arch-update
out=$(run --quiet 2>&1 || true)
grep -q 'arch-update not found' <<<"$out" \
  && fail "an installed arch-update was still reported missing:\n$out"
rm -f "$bin/arch-update"

: > "$log"   # the cases below assert on an empty log

# without a terminal the picker says so instead of hanging on a read
out=$(run --optional 2>&1 </dev/null || true)
grep -q 'no terminal to ask on' <<<"$out" || fail "no tty: expected a note, got:\n$out"
[[ ! -s $log ]] || fail "the picker installed something with no terminal: $(cat "$log")"

# and it never runs unless asked
: > "$log"
run --quiet >/dev/null 2>&1 || true
[[ ! -s $log ]] || fail "the picker ran without --optional: $(cat "$log")"

# --- a broken AUR helper is named, with the reason -------------------------
# `paru: libalpm.so.15 missing` names a library, never the pacman upgrade that
# removed it, so the fix (rebuild the source package) is not guessable from the
# error. An unusable helper is a warning, not a failure: the session runs fine.
printf '#!/bin/sh\necho "paru: error while loading shared libraries: libalpm.so.15: cannot open shared object file: No such file or directory" >&2\nexit 127\n' > "$bin/paru"
chmod +x "$bin/paru"
out=$(run 2>&1 || true)
grep -q 'paru is broken' <<<"$out" || fail "a broken paru was not reported:\n$out"
grep -q 'libalpm.so.15' <<<"$out" || fail "the reported error lost the library name:\n$out"
grep -q 'aur.archlinux.org/paru.git' <<<"$out" || fail "no fix was given for a broken paru:\n$out"
run >/dev/null 2>&1 || fail 'a broken AUR helper failed the doctor instead of warning'

printf '#!/bin/sh\ncase $1 in --version) echo "paru v2.1.0"; exit 0 ;; esac\n' > "$bin/paru"
out=$(run 2>&1 || true)
grep -q 'paru runs' <<<"$out" || fail "a working paru was not reported ok:\n$out"
rm -f "$bin/paru"


# --- an AUR-only package must be routed to the AUR helper -----------------
# The two lists are written by hand at opposite ends of the file, and getting
# them out of step is silent until someone picks the entry and pacman answers
# "target not found". checkservices shipped exactly that way for one commit.
aur_entries=$(sed -n '/^declare -A aur_only=(/,/^)/p' "$doctor" \
  | sed -n 's/^ *\[\([a-z0-9._-]\+\)\]=1.*/\1/p')
while IFS=: read -r _kind _target pkg _desc; do
  [[ -n $pkg ]] || continue
  # Not in the repos on this machine and not routed to the AUR = a pick that
  # cannot work. `pacman -Si` is the same question the picker's pacman -S asks.
  if ! pacman -Si "$pkg" >/dev/null 2>&1; then
    grep -qx "$pkg" <<<"$aur_entries" \
      || fail "optional_entries offers '$pkg', which pacman cannot resolve, but
  aur_only does not list it -- picking it would fail with 'target not found'"
  fi
done < <(sed -n '/^optional_entries=(/,/^)/p' "$doctor" \
  | sed -n 's/^ *"\(.*\)"$/\1/p')

# --- one package, one line in the picker ----------------------------------
# checkupdates and pacdiff are both pacman-contrib. Two entries for one package
# is correct in optional_entries -- they are different missing files with
# different reasons -- but two numbered LINES in the picker reads as two
# separate installs, and picking "the other one" would be a no-op.
dupes=$(sed -n '/^optional_entries=(/,/^)/p' "$doctor" \
  | sed -n 's/^ *"[a-z]*:[^:]*:\([^:]*\):.*/\1/p' | sort | uniq -d)
[[ -n $dupes ]] || fail 'no package is offered under two entries any more --
  drop this check, or it is silently testing nothing'
pick '' >/dev/null
for pkg in $dupes; do
  n=$(grep -cE "^ +[0-9]+\) $pkg " "$tmp/pick.out" || true)
  ((n == 1)) || fail "$pkg is offered on $n numbered lines, expected 1:\n$(cat "$tmp/pick.out")"
done


# --- the merge tool is a "any one of these" check -------------------------
# The update wizard's "merge..." works with meld, kdiff3, nvim -d, vim -d or
# whatever $DIFFPROG names. Nagging somebody who already has vim to install
# meld is how a checklist teaches people to ignore it.
out=$(run --quiet 2>&1 || true)
grep -q 'no merge tool' <<<"$out" \
  || fail "a machine with no merge tool at all was not warned:\n$out"

stub vim
out=$(run --quiet 2>&1 || true)
grep -q 'no merge tool' <<<"$out" \
  && fail "vim is a merge tool (vim -d), but the doctor still asked for one:\n$out"
rm -f "$bin/vim"

# $DIFFPROG is the user's own answer and counts too, even if the program it
# names is not one we would have picked.
out=$(env -i PATH="$bin" HOME="$tmp" DIFFPROG=my-own-thing \
        C7SHELL_ROOT="$root" C7SHELL_SHARE="$tmp/share" XDG_CONFIG_HOME="$conf" \
        /usr/bin/bash "$doctor" --quiet 2>&1 || true)
grep -q 'no merge tool' <<<"$out" \
  && fail "DIFFPROG was set but the doctor still asked for a merge tool:\n$out"

# --- the password prompt's own dependencies -------------------------------
# A missing Polkit typelib is the failure that looks like nothing at all:
# c7-authd exits at startup, the shell retries and falls back, and the prompt
# that appears is hyprpolkitagent's. So it has to be a FAIL with a package
# named, not a warning buried in the optional list.
python_probe() {
  # Stands in for python3. $1 is the exit status the typelib import gets.
  printf '#!/bin/sh\ncat >/dev/null\nexit %s\n' "$1" > "$bin/python3"
  chmod +x "$bin/python3"
}

python_probe 0
out=$(run --quiet 2>&1 || true)
grep -q 'PolkitAgent typelibs' <<<"$out" \
  && fail "a working typelib import was still reported as a problem:\n$out"

python_probe 1
out=$(run --quiet 2>&1 || true)
grep -q 'Polkit/PolkitAgent GObject typelibs are missing' <<<"$out" \
  || fail "a machine that cannot import PolkitAgent was not told:\n$out"
# And it has to name what to install, or the report is a dead end.
grep -q 'python-gobject' <<<"$out" \
  || fail "the typelib failure named no package to install:\n$out"
python_probe 0

# The setuid helper is polkit's, not ours, and every agent authenticates
# through it -- including the fallback, so losing it breaks both paths at once.
mv "$root/usr/lib/polkit-1/polkit-agent-helper-1" "$tmp/helper.away"
out=$(run --quiet 2>&1 || true)
grep -q 'polkit-agent-helper-1' <<<"$out" \
  || fail "the missing setuid PAM helper was not reported:\n$out"
mv "$tmp/helper.away" "$root/usr/lib/polkit-1/polkit-agent-helper-1"

# The sudo.conf line is advice, never an edit: /etc/sudo.conf belongs to the
# sudo package. The doctor prints it and stops there.
out=$(run --quiet 2>&1 || true)
grep -q 'Path askpass /usr/bin/c7-askpass' <<<"$out" \
  || fail "the doctor never says how to route terminal sudo through the prompt:\n$out"
mkdir -p "$root/etc"
printf 'Path askpass /usr/bin/c7-askpass\n' > "$root/etc/sudo.conf"
out=$(run --quiet 2>&1 || true)
grep -q 'Path askpass /usr/bin/c7-askpass' <<<"$out" \
  && fail "the doctor still suggested a sudo.conf line that is already there:\n$out"
rm -f "$root/etc/sudo.conf"

# --- the half-upgraded machine ---------------------------------------------
# c7shell-upgrade installs the package and refreshes ~/.config as two separate
# halves, and the second one deliberately does not overwrite a file you edited.
# So a machine can end up with c7-authd installed and a shell.qml that never
# instantiates AuthWindow: the shell registers as the polkit agent and then
# draws nothing for it, which leaves pkexec waiting on a window that does not
# exist. Worse than not being the agent at all, and silent.
printf 'import Quickshell\nScope { Bar {} }\n' > "$conf/quickshell/c7shell/shell.qml"
out=$(run --quiet 2>&1 || true)
grep -q 'no AuthWindow' <<<"$out" \
  || fail "a config too old to draw the password prompt was not reported:\n$out"
grep -q 'c7shell-upgrade --config-only' <<<"$out" \
  || fail "the stale-config report does not say how to fix it:\n$out"
printf 'import Quickshell\nScope { AuthWindow {} }\n' > "$conf/quickshell/c7shell/shell.qml"
out=$(run --quiet 2>&1 || true)
grep -q 'no AuthWindow' <<<"$out" \
  && fail "a config that does draw the prompt was still reported as stale:\n$out"

# The other half of the same split: autostart.lua still launching the old
# agent. Not broken -- two agents simply cannot both hold the registration --
# so a note, not a failure.
printf 'hl.exec_cmd("/usr/lib/pam_kwallet_init & /usr/lib/hyprpolkitagent/hyprpolkitagent")\n' \
  > "$conf/hypr/conf/autostart.lua"
out=$(run --quiet 2>&1 || true)
grep -q 'still starts hyprpolkitagent' <<<"$out" \
  || fail "an autostart still launching the old agent was not mentioned:\n$out"
grep -q 'FAIL.*hyprpolkitagent' <<<"$out" \
  && fail "still starting the old agent was reported as a failure; it is not:\n$out"
printf 'hl.exec_cmd("/usr/lib/pam_kwallet_init")\n' > "$conf/hypr/conf/autostart.lua"

echo 'PASS: c7shell-doctor'
