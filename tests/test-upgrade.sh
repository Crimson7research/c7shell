#!/usr/bin/env bash
# Self-check for bin/c7shell-upgrade. Run it directly: tests/test-upgrade.sh
#
# Mostly the config half is exercised (--config-only): the package half rebuilds
# from git and installs with pacman, which a test has no business doing. The
# config half is the part that can lose your edits, so that is what is checked.
# The one exception is at the end, where the package half's plan is inspected
# under --dry-run: it never runs git or pacman there either.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
upgrade=$here/../bin/c7shell-upgrade
setup=$here/../bin/c7shell-setup
mktmp

export C7SHELL_SHARE=$tmp/share
export XDG_CONFIG_HOME=$tmp/conf
export C7SHELL_STATE=$tmp/state
export C7SHELL_ROOT=$tmp/root

ship() { mkdir -p -- "$(dirname -- "$C7SHELL_SHARE/$1")"; printf '%s\n' "$2" > "$C7SHELL_SHARE/$1"; }
local_is() { [[ $(cat "$XDG_CONFIG_HOME/$1") == "$2" ]] || fail "$1 should be '$2', is '$(cat "$XDG_CONFIG_HOME/$1")'"; }

# v1 ships, and c7shell-setup installs it and records the manifest
mkdir -p "$C7SHELL_SHARE"/{hypr,quickshell/c7shell,xdg-desktop-portal}
ship hypr/hyprland.lua 'v1 entry'
ship hypr/keep.lua 'v1 keep'
ship hypr/gone.lua 'v1 gone'
ship quickshell/c7shell/shell.qml 'v1 shell'
ship hypr/xdph.conf 'custom_picker_binary = $HOME/.config/quickshell/c7shell/bin/x.sh'
"$setup" >/dev/null
[[ -f $C7SHELL_STATE/manifest ]] || fail 'c7shell-setup wrote no manifest'
grep -q 'hypr/hyprland.lua' "$C7SHELL_STATE/manifest" || fail 'the manifest is missing a file it installed'

# nothing changed anywhere: the upgrade is a no-op
out=$("$upgrade" --config-only --no-doctor)
grep -q 'already match' <<<"$out" || fail "a no-op upgrade reported work:\n$out"

# the $HOME placeholder rewrite must not read as a local edit, ever
grep -q 'xdph' <<<"$out" && fail "xdph.conf was treated as changed:\n$out"

# --- v2 ships: one file changed, one added, one dropped -------------------
ship hypr/hyprland.lua 'v2 entry'
ship hypr/new.lua 'v2 new'
rm "$C7SHELL_SHARE/hypr/gone.lua"

# the user edited keep.lua, and never touched the rest
printf 'mine\n' > "$XDG_CONFIG_HOME/hypr/keep.lua"
ship hypr/keep.lua 'v2 keep'

# --dry-run first: says everything, changes nothing
before=$(find "$XDG_CONFIG_HOME" -type f | sort | xargs sha256sum)
out=$("$upgrade" --config-only --no-doctor --dry-run)
[[ $(find "$XDG_CONFIG_HOME" -type f | sort | xargs sha256sum) == "$before" ]] \
  || fail '--dry-run changed the configs'
grep -q 'update  hypr/hyprland.lua' <<<"$out" || fail "--dry-run did not plan the update:\n$out"
grep -q 'add     hypr/new.lua'      <<<"$out" || fail "--dry-run did not plan the add:\n$out"
grep -q 'remove  hypr/gone.lua'     <<<"$out" || fail "--dry-run did not plan the removal:\n$out"
grep -q 'kept    hypr/keep.lua'     <<<"$out" || fail "--dry-run did not plan to keep the edit:\n$out"

# now for real. exit 4 == there is something to merge
rc=0; out=$("$upgrade" --config-only --no-doctor) || rc=$?
((rc == 4)) || fail "expected exit 4 when a file needs merging, got $rc:\n$out"

# a file the user never touched is brought forward
local_is hypr/hyprland.lua 'v2 entry'
# a file the user edited is untouched, and the new version is parked beside it
local_is hypr/keep.lua 'mine'
local_is hypr/keep.lua.new 'v2 keep'
# a new file arrives
local_is hypr/new.lua 'v2 new'
# a file dropped upstream that the user never touched goes away
[[ ! -e $XDG_CONFIG_HOME/hypr/gone.lua ]] || fail 'a file dropped upstream was kept'
grep -q "$XDG_CONFIG_HOME/hypr/keep.lua" <<<"$out" || fail "the conflict was not listed:\n$out"

# --- running it again is idempotent, and still reports the pending merge ---
rc=0; out=$("$upgrade" --config-only --no-doctor) || rc=$?
((rc == 4)) || fail "the pending merge should still be reported, got $rc:\n$out"
grep -q 'updated 0' <<<"$out" || fail "re-ran an update that was already applied:\n$out"
local_is hypr/keep.lua 'mine'
local_is hypr/keep.lua.new 'v2 keep'

# once merged, the conflict is gone and the upgrade is clean again
printf 'v2 keep\n' > "$XDG_CONFIG_HOME/hypr/keep.lua"
rm "$XDG_CONFIG_HOME/hypr/keep.lua.new"
rc=0; out=$("$upgrade" --config-only --no-doctor) || rc=$?
((rc == 0)) || fail "expected a clean exit after merging, got $rc:\n$out"

# --- a file dropped upstream that the user DID edit is left alone ---------
printf 'v3 entry\n' > "$C7SHELL_SHARE/hypr/hyprland.lua"
printf 'my own file\n' > "$XDG_CONFIG_HOME/hypr/mine.lua"
out=$("$upgrade" --config-only --no-doctor 2>&1)
[[ -f $XDG_CONFIG_HOME/hypr/mine.lua ]] || fail 'deleted a file the package never shipped'
grep -q 'no longer shipped but differs' <<<"$out" || fail "an unknown local file was not reported:\n$out"

# --- an install from before the manifest existed keeps every difference ---
rm -f "$C7SHELL_STATE/manifest"
printf 'v4 entry\n' > "$C7SHELL_SHARE/hypr/hyprland.lua"
printf 'local edit\n' > "$XDG_CONFIG_HOME/hypr/shell-of-theseus.lua"
rc=0; out=$("$upgrade" --config-only --no-doctor 2>&1) || rc=$?
grep -q 'no manifest' <<<"$out" || fail "no note about the missing manifest:\n$out"
((rc == 4)) || fail "without a manifest every difference should be kept, got $rc:\n$out"
local_is hypr/hyprland.lua 'v3 entry'
local_is hypr/hyprland.lua.new 'v4 entry'

# ...and it says so loudly, because a config that is half one version and half
# another does not degrade: QML resolves imports across the whole tree, so an
# old shell.qml beside a new module directory fails the entire load and the
# desktop comes up with no bar at all.
grep -q 'part one' <<<"$out" || fail "a mixed config was not called out:\n$out"
grep -q 'take-shipped' <<<"$out" || fail "the way out of a mixed config was not offered:\n$out"

# --- a conflict stays a conflict, and never silently overwrites -----------
# With no manifest the divergent file is recorded under the SHIPPED hash --
# deliberately a hash it does not have. That looks redundant and is not: record
# the hash the file actually has and the next run concludes "untouched since we
# installed it" and overwrites a real local edit without asking.
rm -f "$XDG_CONFIG_HOME/hypr/hyprland.lua.new"
rc=0; out=$("$upgrade" --config-only --no-doctor 2>&1) || rc=$?
local_is hypr/hyprland.lua 'v3 entry'
[[ -e $XDG_CONFIG_HOME/hypr/hyprland.lua.new ]] \
  || fail "the second run silently overwrote a file it had flagged as divergent:\n$out"

# --- --take-shipped is the way out ----------------------------------------
# The usual case on a machine set up before the manifest existed: the files
# differ because they are old, not because anybody edited them.
rc=0; out=$("$upgrade" --config-only --no-doctor --take-shipped 2>&1) || rc=$?
local_is hypr/hyprland.lua 'v4 entry'
[[ -e $XDG_CONFIG_HOME/hypr/hyprland.lua.new ]] \
  && fail "--take-shipped left the .new behind:\n$out"
ls "$XDG_CONFIG_HOME"/hypr/hyprland.lua.bak-* >/dev/null 2>&1 \
  || fail "--take-shipped did not back the local file up:\n$out"
[[ $(cat "$XDG_CONFIG_HOME"/hypr/hyprland.lua.bak-*) == 'v3 entry' ]] \
  || fail '--take-shipped backed up the wrong content'
# And the next run is clean, because the manifest now matches reality.
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'configs already match' <<<"$out" \
  || fail "the run after --take-shipped was not clean:\n$out"

# --- the hand-over marker -------------------------------------------------
# The package half replaces this script, so any step after it belongs to the
# version just installed. c7shell-upgrade compares upgrade_revision on disk with
# its own and hands over when it grew -- which only works while the marker stays
# on one line, exactly as the sed in it expects.
rev=$(sed -n 's/^upgrade_revision=\([0-9]\+\)$/\1/p' "$upgrade" | head -1)
[[ -n $rev ]] || fail 'upgrade_revision is not a bare "upgrade_revision=<n>" line; the hand-over cannot read it'
grep -q 'C7SHELL_HANDOVER=1 exec' "$upgrade" || fail 'the hand-over to the newly installed script is gone'

# --- the greeter ----------------------------------------------------------
# The greeter binary and its QML ride along with the package, but which greeter
# greetd runs is a line in /etc/greetd/config.toml that no package may write --
# so an install from before the greeter existed has the files and not the
# config. Closing that gap is what this step is for.
greetd_conf=$tmp/root/etc/greetd/config.toml

# A machine without the greeter installed is left alone entirely
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'c7shell-greeter is not installed' <<<"$out" \
  || fail "a machine without the greeter was not reported:\n$out"
[[ -e $greetd_conf ]] && fail 'wrote a greetd config without the greeter installed'

# From here on the greeter is present
mkdir -p "$tmp/root/usr/bin" "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/root/usr/bin/c7shell-greeter"
chmod +x "$tmp/root/usr/bin/c7shell-greeter"

out=$("$upgrade" --config-only --no-doctor --dry-run 2>&1)
grep -q "would write $greetd_conf" <<<"$out" || fail "--dry-run did not plan the config:\n$out"
[[ -e $greetd_conf ]] && fail '--dry-run wrote the config'

# For real, with a stub in front of the real sudo: a test must never reach for
# root, and must never sit on a password prompt either.
printf '#!/bin/sh\nexec "$@"\n' > "$tmp/bin/sudo"; chmod +x "$tmp/bin/sudo"
export PATH="$tmp/bin:$PATH"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'pointing greetd at the c7shell greeter' <<<"$out" \
  || fail "the config was not written:\n$out"
[[ -f $greetd_conf ]] || fail "the greetd config was not written:\n$out"
grep -q 'c7shell-greeter' "$greetd_conf" \
  || fail "the config does not run our greeter:\n$(cat "$greetd_conf")"
grep -q 'QML_XHR_ALLOW_FILE_READ=1' "$greetd_conf" \
  || fail "the config does not let the greeter read /proc:\n$(cat "$greetd_conf")"

# Once ours is in place there is nothing to do, and --no-greeter says nothing
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'already runs the c7shell greeter' <<<"$out" \
  || fail "an applied config was not recognised:\n$out"
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
grep -qE '^ *greeter$' <<<"$out" && fail "--no-greeter still touched the greeter:\n$out"

# greetd's own package ships a config running agreety on a text console. That
# one is ours to replace; a greeter somebody chose is not.
printf '[default_session]\ncommand = "agreety --cmd /bin/sh"\nuser = "greeter"\n' > "$greetd_conf"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'c7shell-greeter' "$greetd_conf" \
  || fail "the stock agreety config was not replaced:\n$out"
printf '[default_session]\ncommand = "tuigreet --cmd Hyprland"\nuser = "greeter"\n' > "$greetd_conf"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'greetd runs another greeter' <<<"$out" \
  || fail "a deliberate greeter was not reported:\n$out"
grep -q 'tuigreet' "$greetd_conf" || fail "a deliberate greeter config was overwritten:\n$(cat "$greetd_conf")"
rm -f "$greetd_conf"
"$upgrade" --config-only --no-doctor >/dev/null 2>&1 || true

# A machine set up when c7shell used sddm moves to greetd -- enabled for the
# next boot, never started under the running session. Any other display
# manager was somebody's choice and is only advised about.
dm_link=$tmp/root/etc/systemd/system/display-manager.service
mkdir -p "${dm_link%/*}"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$tmp/systemctl.log" > "$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"

: > "$tmp/systemctl.log"
ln -sf /usr/lib/systemd/system/sddm.service "$dm_link"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'switching the display manager from sddm to greetd' <<<"$out" \
  || fail "a machine on sddm was not switched:\n$out"
grep -qx 'disable sddm.service' "$tmp/systemctl.log" \
  || fail "sddm was not disabled:\n$(cat "$tmp/systemctl.log")"
grep -qx 'enable greetd.service' "$tmp/systemctl.log" \
  || fail "greetd was not enabled:\n$(cat "$tmp/systemctl.log")"
grep -qE 'start|--now' "$tmp/systemctl.log" \
  && fail "the display manager was started mid-upgrade:\n$(cat "$tmp/systemctl.log")"

: > "$tmp/systemctl.log"
"$upgrade" --config-only --no-doctor --dry-run >/dev/null 2>&1 || true
[[ -s $tmp/systemctl.log ]] && fail "--dry-run ran systemctl:\n$(cat "$tmp/systemctl.log")"

: > "$tmp/systemctl.log"
ln -sf /usr/lib/systemd/system/gdm.service "$dm_link"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'the display manager is gdm -- left alone' <<<"$out" \
  || fail "a machine on gdm was not left alone:\n$out"
[[ -s $tmp/systemctl.log ]] && fail "gdm was touched:\n$(cat "$tmp/systemctl.log")"

ln -sf /usr/lib/systemd/system/greetd.service "$dm_link"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
[[ -s $tmp/systemctl.log ]] && fail "a machine already on greetd was touched:\n$(cat "$tmp/systemctl.log")"

# No display manager at all: greetd is set up, the same as on a fresh machine.
rm -f "$dm_link"
out=$("$upgrade" --config-only --no-doctor 2>&1) || true
grep -q 'no display manager is enabled -- enabling greetd' <<<"$out" \
  || fail "a machine without a display manager was not given greetd:\n$out"
grep -qx 'enable greetd.service' "$tmp/systemctl.log" \
  || fail "greetd was not enabled:\n$(cat "$tmp/systemctl.log")"

# --- the real tree, upgraded from a version that predates a feature --------
# Everything above runs on a synthetic three-file tree, which proves the merge
# rules but not that THIS repository's files reach an existing install. A shell
# component that ships but never lands is a bar with a missing pill and no
# error anywhere, so the shipped tree itself is walked here.
#
# The now-playing surfaces (design 15b) are the case in hand: several new QML
# files, several new icons, and a hyprlock.conf that grew a second label
# calling a verb the old c7shell-lock-info did not have.
real_share=$tmp/real-share
real_conf=$tmp/real-conf
mkdir -p "$real_share"
cp -a "$here/../hypr" "$here/../quickshell" "$here/../xdg-desktop-portal" "$real_share/"

# What the media surfaces added. Removing them from the shipped tree is what
# makes the install below an install of the version before them.
media_files=(
  quickshell/c7shell/Services/MprisService.qml
  quickshell/c7shell/Modules/Bar/MediaPill.qml
  quickshell/c7shell/Modules/Popovers/MediaPopover.qml
  quickshell/c7shell/Assets/icons/play.svg
  quickshell/c7shell/Assets/icons/pause.svg
  quickshell/c7shell/Assets/icons/skip-back.svg
  quickshell/c7shell/Assets/icons/skip-forward.svg
  quickshell/c7shell/Assets/icons/shuffle.svg
  quickshell/c7shell/Assets/icons/repeat.svg
  quickshell/c7shell/Assets/icons/repeat-1.svg
  quickshell/c7shell/Assets/icons/music.svg
)
for f in "${media_files[@]}"; do
  [[ -e $real_share/$f ]] || fail "tests/test-upgrade.sh names $f, which this tree does not ship"
done

# Install the older version, manifest and all, exactly as a machine set up
# before the feature would have it.
old_share=$tmp/old-share
cp -a "$real_share" "$old_share"
for f in "${media_files[@]}"; do rm -f "$old_share/$f"; done
# The old lock screen had one media label; the new one has two.
sed -i '/c7shell-lock-info media-source/d' "$old_share/hypr/hyprlock.conf"

# Output swallowed unless it fails: setup runs the shipped theme export, which
# needs a running Hyprland and says so on a machine that has none. That is not
# this test's business and it is not a failure.
C7SHELL_SHARE=$old_share XDG_CONFIG_HOME=$real_conf C7SHELL_STATE=$tmp/real-state \
  "$setup" >"$tmp/setup.log" 2>&1 \
  || fail "c7shell-setup could not install the shipped tree:\n$(cat "$tmp/setup.log")"
[[ -e $real_conf/quickshell/c7shell/Services/MprisService.qml ]] \
  && fail 'the staged "old" install already has the media service'

# Now the current tree ships, and the upgrade has to carry every one of those
# files across without being asked.
out=$(C7SHELL_SHARE=$real_share XDG_CONFIG_HOME=$real_conf C7SHELL_STATE=$tmp/real-state \
        "$upgrade" --config-only --no-doctor --no-greeter 2>&1) \
  || fail "upgrading a real install from before the media surfaces failed:\n$out"

for f in "${media_files[@]}"; do
  [[ -e $real_conf/$f ]] \
    || fail "c7shell-upgrade did not install $f -- the bar would come up without its media pill:\n$out"
  cmp -s "$real_share/$f" "$real_conf/$f" \
    || fail "$f landed but does not match the shipped version"
done

# The lock screen's second label, and the verb it calls. The label ships in
# hyprlock.conf (the config half) and the verb in c7shell-lock-info (the
# package half), so this is the one place in the feature where the two halves
# of an upgrade have to agree.
grep -q 'c7shell-lock-info media-source' "$real_conf/hypr/hyprlock.conf" \
  || fail 'the upgraded hyprlock.conf did not gain the media-source label'
"$here/../bin/c7shell-lock-info" media-source >/dev/null 2>&1 \
  || fail 'hyprlock.conf calls c7shell-lock-info media-source but the script does not accept it'

# And the shell has to actually reach the new files: a component nobody imports
# is only reachable by accident of directory adjacency.
grep -q 'MediaPopover' "$real_conf/quickshell/c7shell/shell.qml" \
  || fail 'the upgraded shell.qml does not instantiate MediaPopover'
grep -q 'MediaPill' "$real_conf/quickshell/c7shell/Modules/Bar/Bar.qml" \
  || fail 'the upgraded Bar.qml does not place MediaPill'

# --- generated files and setup's own rewrites survive an upgrade --------------
# Each check runs in its own tree, with setup laying it down the way it would on
# a real machine.
fresh() {
  export C7SHELL_SHARE=$tmp/$1/share XDG_CONFIG_HOME=$tmp/$1/conf C7SHELL_STATE=$tmp/$1/state
  mkdir -p "$C7SHELL_SHARE"/{hypr,quickshell/c7shell,xdg-desktop-portal}
  ship quickshell/c7shell/shell.qml 'v1 shell'
}
saved=("$C7SHELL_SHARE" "$XDG_CONFIG_HOME" "$C7SHELL_STATE")

# The lock palette is written by the theme exporter, never shipped. An install
# whose manifest claimed it (every setup before this fix) must keep it.
fresh palette
ship hypr/hyprland.lua 'v1'
"$setup" >/dev/null
printf '$accent = rgb(1,2,3)\n' > "$XDG_CONFIG_HOME/hypr/hyprlock-palette.conf"
printf 'hypr/hyprlock-palette.conf\t%s\n' "$(sha256sum < "$XDG_CONFIG_HOME/hypr/hyprlock-palette.conf" | cut -d' ' -f1)" \
  >> "$C7SHELL_STATE/manifest"
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
[[ -f $XDG_CONFIG_HOME/hypr/hyprlock-palette.conf ]] \
  || fail "the upgrade deleted the generated lock palette:\n$out"

# Setup points hyprlock.conf at the real palette when the config dir is not
# ~/.config. The upgrade must compare against the same rewrite, or it "updates"
# the file back to a path that does not exist.
fresh lockpath
ship hypr/hyprlock.conf 'source = $HOME/.config/hypr/hyprlock-palette.conf'
"$setup" >/dev/null
want="source = $XDG_CONFIG_HOME/hypr/hyprlock-palette.conf"
local_is hypr/hyprlock.conf "$want"
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
grep -q 'hyprlock.conf' <<<"$out" && fail "the rewritten hyprlock.conf read as changed:\n$out"
local_is hypr/hyprlock.conf "$want"

# Shipped files are written whole: through a temp file and a rename, keeping the
# shipped mode, and never leaving the temp file behind.
fresh atomic
ship hypr/hyprland.lua 'v1'
"$setup" >/dev/null
inode=$(stat -c %i "$XDG_CONFIG_HOME/hypr/hyprland.lua")
ship hypr/hyprland.lua 'v2'
ship quickshell/c7shell/bin/run.sh '#!/bin/sh'
chmod +x "$C7SHELL_SHARE/quickshell/c7shell/bin/run.sh"
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
local_is hypr/hyprland.lua 'v2'
# A new inode is a rename; writing in place keeps the old one.
[[ $(stat -c %i "$XDG_CONFIG_HOME/hypr/hyprland.lua") != "$inode" ]] \
  || fail 'hyprland.lua was rewritten in place, not renamed into place'
[[ -x $XDG_CONFIG_HOME/quickshell/c7shell/bin/run.sh ]] || fail "an added script lost its exec bit:\n$out"
leftover=$(find "$XDG_CONFIG_HOME" "$C7SHELL_STATE" -name '*.tmp.*')
[[ -z $leftover ]] || fail "temp files left behind:\n$leftover"

# A symlinked config (stow, chezmoi) is updated at its target and stays a link.
fresh symlink
ship hypr/hyprland.lua 'v1'
"$setup" >/dev/null
mkdir -p "$tmp/dotfiles"
mv "$XDG_CONFIG_HOME/hypr/hyprland.lua" "$tmp/dotfiles/hyprland.lua"
ln -s "$tmp/dotfiles/hyprland.lua" "$XDG_CONFIG_HOME/hypr/hyprland.lua"
ship hypr/hyprland.lua 'v2'
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
[[ -L $XDG_CONFIG_HOME/hypr/hyprland.lua ]] || fail "the upgrade replaced a symlinked config with a plain file:\n$out"
[[ $(cat "$tmp/dotfiles/hyprland.lua") == v2 ]] || fail "the symlink's target was not updated:\n$out"
# An edited symlinked config taken over with --take-shipped keeps a real backup
# of the edit: a backup that is just another link would follow the target to
# the shipped bytes.
printf 'mine\n' > "$tmp/dotfiles/hyprland.lua"
ship hypr/hyprland.lua 'v3'
out=$("$upgrade" --config-only --no-doctor --no-greeter --take-shipped 2>&1) || true
bak=$(find "$XDG_CONFIG_HOME/hypr" -name 'hyprland.lua.bak-*' | head -1)
[[ -n $bak && ! -L $bak && $(cat "$bak") == mine ]] \
  || fail "the backup of an edited symlinked config lost the edit:\n$out\n$(ls -l "$XDG_CONFIG_HOME/hypr")"
[[ $(cat "$tmp/dotfiles/hyprland.lua") == v3 ]] || fail "--take-shipped did not reach the symlink's target:\n$out"

export C7SHELL_SHARE=${saved[0]} XDG_CONFIG_HOME=${saved[1]} C7SHELL_STATE=${saved[2]}

# --- the shell restart --------------------------------------------------
# A change under quickshell/ leaves the running shell half-migrated, so the
# upgrade restarts it. The instance is matched by config path: this test tree
# is a temporary $XDG_CONFIG_HOME that no quickshell is running, and the
# developer's own shell -- which very much is running -- must survive the suite.
# A qs that runs nothing, so this does not depend on whether the machine
# running the suite has quickshell installed: without one on PATH the step is
# skipped and never says anything.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/qs"; chmod +x "$tmp/bin/qs"
ship quickshell/c7shell/shell.qml 'v9 shell'
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
grep -q 'update  quickshell/c7shell/shell.qml' <<<"$out" || fail "the shell file was not updated:\n$out"
grep -q 'restarted onto the new config' <<<"$out" \
  && fail "restarted a shell that is not running this config:\n$out"
# Nothing to restart is still worth a line, with the command in it. The other
# way to reach this state is a shell that already died on the half-copied tree,
# and then this message is all that stands between the user and a bare desktop.
grep -q 'nothing to restart' <<<"$out" || fail "the absent shell went unmentioned:\n$out"
grep -qF 'setsid qs -c c7shell -d -n' <<<"$out" \
  || fail "said to restart the shell without saying how:\n$out"

# A hypr-only change has nothing to restart for either, whatever is running.
ship hypr/hyprland.lua 'v9 entry'
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
grep -q 'restarting the shell' <<<"$out" && fail "a hypr-only change looked at the shell:\n$out"

# With a quickshell that does claim this tree, the restart is kill-then-relaunch
# and the relaunch is detached, so it has to outlive the upgrade that started
# it. The stub records both halves and stops reporting the instance once it is
# killed, which is also what the wait loop is reading.
export QS_STUB=$tmp/qs-stub
mkdir -p "$QS_STUB"
# The stub speaks the real `qs list --all` block format: the exit request now
# goes to a pid, and the instance it names has to be the one whose *own* block
# carries our config path. Both pids are above every kernel's pid_max, so a run
# that matches them wrong cannot signal a real process on this machine.
cat > "$tmp/bin/qs" <<'QS'
#!/bin/sh
# Two instances, and only the second is ours.
report() {
  printf 'Instance notmine:\n  Process ID: 4194305\n  Config path: %s\n' \
    "$XDG_CONFIG_HOME/quickshell/other/shell.qml"
  printf 'Instance stubinst:\n  Process ID: 4194304\n  Config path: %s\n' \
    "$XDG_CONFIG_HOME/quickshell/c7shell/shell.qml"
}
case "$1 $2" in
  # Listed until killed, and listed again once relaunched: the step waits for
  # the instance to go away and then for it to come back.
  'list --all')
    if [ ! -e "$QS_STUB/killed" ] || [ -e "$QS_STUB/launched" ]; then report; fi ;;
  'kill --pid') printf '%s\n' "$3" >> "$QS_STUB/killed" ;;
  '-c c7shell') printf '%s\n' "$*" > "$QS_STUB/launched" ;;
esac
QS
chmod +x "$tmp/bin/qs"

ship quickshell/c7shell/shell.qml 'v10 shell'
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
grep -q 'restarting the shell' <<<"$out" || fail "the shell was not restarted:\n$out"
[[ $(cat "$QS_STUB/killed") == 4194304 ]] \
  || fail "the exit request went to an instance on another config: $(cat "$QS_STUB/killed")"
grep -q -- '-d' "$QS_STUB/launched" 2>/dev/null \
  || fail "the shell was killed and not relaunched: $(cat "$QS_STUB/launched" 2>/dev/null)"
grep -q 'restarted onto the new config' <<<"$out" || fail "the restart went unconfirmed:\n$out"

# --dry-run plans the restart and does not perform it
rm -f "$QS_STUB/killed" "$QS_STUB/launched"
ship quickshell/c7shell/shell.qml 'v11 shell'
out=$("$upgrade" --config-only --no-doctor --no-greeter --dry-run 2>&1) || true
grep -q 'would restart the quickshell instance' <<<"$out" || fail "--dry-run did not plan the restart:\n$out"
[[ -e $QS_STUB/killed ]] && fail '--dry-run killed the running shell'

# --- leftover packages in the build cache ---------------------------------
# makepkg installs an existing tarball instead of building when one matches the
# pkgver it computes, so a half-written file from an interrupted build makes
# every later run fail in pacman with "invalid or corrupted package" -- forever,
# because the broken file keeps matching. The package half drops what cannot be
# read before makepkg looks. Only the plan is checked here: building for real
# clones from git and installs with pacman, which a test has no business doing.
export C7SHELL_CACHE=$tmp/cache
pkgdir_=$C7SHELL_CACHE/src
mkdir -p "$pkgdir_/.git"
: > "$pkgdir_/c7shell-0.1.0.r1.gempty-1-any.pkg.tar.zst"
printf 'not a package at all\n' > "$pkgdir_/c7shell-0.1.0.r2.gtrunc-1-any.pkg.tar.zst"
good=$pkgdir_/c7shell-0.1.0.r3.ggood-1-any.pkg.tar.zst
( cd "$tmp" && printf 'x\n' > payload && bsdtar --zstd -cf "$good" payload )
: > "$good.sig"

out=$("$upgrade" --package-only --no-doctor --force --dry-run 2>&1)
grep -q 'gempty' <<<"$out" || fail "a zero-length leftover package was not dropped:\n$out"
grep -q 'gtrunc' <<<"$out" || fail "an unreadable leftover package was not dropped:\n$out"
grep -q 'ggood'  <<<"$out" && fail "a readable package was dropped:\n$out"
[[ -e $pkgdir_/c7shell-0.1.0.r1.gempty-1-any.pkg.tar.zst ]] \
  || fail '--dry-run deleted a package file'
grep -q 'install.sh --no-bootstrap -f' <<<"$out" \
  || fail "the build does not force a rebuild, so a stale tarball is reinstalled:\n$out"

# ...and install.sh must force it too, for the runs that do not come through
# c7shell-upgrade at all.
grep -qE '^makepkg .*-[a-z]*f' "$here/../install.sh" \
  || fail 'install.sh does not pass -f to makepkg'

# A shell that takes its windows down on `qs kill` and then wedges on the way
# out is the case that left a machine with no shell at all: the instance stayed
# listed, so the relaunch (--no-duplicate) was skipped, and the desktop it had
# already stopped drawing never came back. The ask has to escalate to the
# process.
rm -f "$QS_STUB"/*
cat > "$tmp/bin/qs" <<'QS'
#!/bin/sh
case "$1 $2" in
  'list --all')
    pid=$(cat "$QS_STUB/pid" 2>/dev/null) || exit 0
    { [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; } || exit 0
    printf 'Instance stub:\n  Process ID: %s\n  Config path: %s\n' \
      "$pid" "$XDG_CONFIG_HOME/quickshell/c7shell/shell.qml"
    ;;
  # Asked, and ignored: the process stays alive and the instance stays listed.
  'kill --pid') printf '%s\n' "$3" > "$QS_STUB/asked" ;;
  '-c c7shell')
    printf '%s\n' "$*" > "$QS_STUB/launched"
    sleep 60 & printf '%s\n' "$!" > "$QS_STUB/pid"
    ;;
esac
QS
chmod +x "$tmp/bin/qs"
sleep 60 & wedged_pid=$!
printf '%s\n' "$wedged_pid" > "$QS_STUB/pid"

ship quickshell/c7shell/shell.qml 'v12 shell'
out=$("$upgrade" --config-only --no-doctor --no-greeter 2>&1) || true
[[ $(cat "$QS_STUB/asked" 2>/dev/null) == "$wedged_pid" ]] \
  || fail "the wedged shell was never asked to exit by pid:\n$out"
kill -0 "$wedged_pid" 2>/dev/null \
  && fail "the wedged shell was left running and the desktop left with no bar:\n$out"
grep -q -- '-d' "$QS_STUB/launched" 2>/dev/null \
  || fail "no shell was relaunched after the wedged one was signalled:\n$out"
grep -q 'restarted onto the new config' <<<"$out" \
  || fail "the restart did not confirm that the new shell came up:\n$out"
kill "$(cat "$QS_STUB/pid")" 2>/dev/null || true

# And a relaunch that does not come up is said out loud rather than reported as
# a restart: "restarted" is the line the user acts on by walking away.
rm -f "$QS_STUB"/*
cat > "$tmp/bin/qs" <<'QS'
#!/bin/sh
case "$1 $2" in
  'list --all')
    [ -e "$QS_STUB/killed" ] || printf 'Instance stub:\n  Process ID: 4194304\n  Config path: %s\n' \
      "$XDG_CONFIG_HOME/quickshell/c7shell/shell.qml" ;;
  'kill --pid') printf '%s\n' "$3" > "$QS_STUB/killed" ;;
  '-c c7shell') printf '%s\n' "$*" > "$QS_STUB/launched" ;;   # and never comes up
esac
QS
chmod +x "$tmp/bin/qs"
ship quickshell/c7shell/shell.qml 'v13 shell'
rc=0
out=$(C7SHELL_WAIT_TICKS=3 "$upgrade" --config-only --no-doctor --no-greeter 2>&1) || rc=$?
grep -q 'did not come up on the new config' <<<"$out" \
  || fail "a relaunch that never came up was reported as a restart:\n$out"
grep -q 'qs -c c7shell' <<<"$out" || fail "did not say how to see the load error:\n$out"
# The exit status carries it too. A desktop with no bar on it is the one
# outcome of this command that must not look like success to whatever ran it.
((rc == 1)) || fail "a shell that never came back exited $rc, not 1:\n$out"

# And the shell that stays listed even after SIGKILL. The relaunch is
# --no-duplicate, so it must not be attempted beside the corpse -- and this is
# the branch that used to end at "restart it yourself" with no command in it.
rm -f "$QS_STUB"/*
cat > "$tmp/bin/qs" <<'QS'
#!/bin/sh
case "$1 $2" in
  # Never goes away, whatever is sent to it. 4194304 is above pid_max, so the
  # signals the step escalates to cannot land on anything real.
  'list --all') printf 'Instance stub:\n  Process ID: 4194304\n  Config path: %s\n' \
                  "$XDG_CONFIG_HOME/quickshell/c7shell/shell.qml" ;;
  'kill --pid') printf '%s\n' "$3" > "$QS_STUB/killed" ;;
  '-c c7shell') printf '%s\n' "$*" > "$QS_STUB/launched" ;;
esac
QS
chmod +x "$tmp/bin/qs"
ship quickshell/c7shell/shell.qml 'v14 shell'
rc=0
out=$(C7SHELL_WAIT_TICKS=2 "$upgrade" --config-only --no-doctor --no-greeter 2>&1) || rc=$?
grep -qF 'setsid qs -c c7shell -d -n' <<<"$out" \
  || fail "said to restart the shell without saying how:\n$out"
[[ ! -e $QS_STUB/launched ]] || fail 'launched a second shell beside one that never exited'
((rc == 1)) || fail "a desktop left with no bar exited $rc, not 1:\n$out"

echo 'PASS: c7shell-upgrade'

