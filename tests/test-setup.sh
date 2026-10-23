#!/usr/bin/env bash
# Self-check for bin/c7shell-setup. Run it directly: tests/test-setup.sh
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
setup=$here/../bin/c7shell-setup
mktmp

export C7SHELL_SHARE=$tmp/share
export XDG_CONFIG_HOME=$tmp/conf
# c7shell-setup records its manifest under $XDG_STATE_HOME, falling back to
# $HOME/.local/state. Without these two this test wrote its FIXTURE manifest
# -- five lines of "v1" hashes -- straight into the real ~/.local/state/c7shell
# of whoever ran it. The next c7shell-upgrade on that machine then found a
# manifest that knew nothing about any real file, concluded every shipped file
# had been locally edited, and parked a .new beside each one. That is a config
# half one version and half another, which for QML fails the whole load.
# HOME as well as the state dir, so nothing here can reach a real home at all.
export C7SHELL_STATE=$tmp/state
export XDG_STATE_HOME=$tmp/xdg-state
export XDG_DATA_HOME=$tmp/data
export HOME=$tmp/home
mkdir -p "$HOME"
mkdir -p "$C7SHELL_SHARE"/{hypr,quickshell/c7shell,xdg-desktop-portal}
echo v1 > "$C7SHELL_SHARE/hypr/hyprland.lua"
echo v1 > "$C7SHELL_SHARE/quickshell/c7shell/shell.qml"
echo v1 > "$C7SHELL_SHARE/xdg-desktop-portal/hyprland-portals.conf"
printf 'custom_picker_binary = $HOME/.config/quickshell/c7shell/bin/x.sh\n' \
  > "$C7SHELL_SHARE/hypr/xdph.conf"
# stands in for scripts/c7shell-theme-export.py: writes kdeglobals where the
# real one does, from the same env var
mkdir -p "$C7SHELL_SHARE/quickshell/c7shell/scripts"
cat > "$C7SHELL_SHARE/quickshell/c7shell/scripts/c7shell-theme-export.py" <<'PYEOF'
import os
conf = os.environ["XDG_CONFIG_HOME"]
open(f"{conf}/kdeglobals", "w").write("[General]\nColorScheme=C7Shell\n")
open(f"{conf}/hypr/hyprlock-palette.conf", "w").write("$accent = rgb(0,0,0)\n")
PYEOF

# dry-run changes nothing
"$setup" --dry-run >/dev/null
[[ ! -e $XDG_CONFIG_HOME/kdeglobals ]] || fail '--dry-run exported the palette'
[[ ! -e $XDG_CONFIG_HOME/hypr ]] || fail '--dry-run created files'
[[ ! -e $XDG_CONFIG_HOME/arch-update ]] || fail '--dry-run wrote the arch-update config'
[[ ! -e $XDG_DATA_HOME/c7shell/scripts ]] || fail '--dry-run created the script dir'

# fresh install copies both parts
"$setup" >/dev/null
# arch-update elevates through polkit (run0) unless the user chose otherwise
au=$XDG_CONFIG_HOME/arch-update/arch-update.conf
grep -qx 'PrivilegeElevationCommand=run0' "$au" || fail "arch-update was not pointed at run0:\n$(cat "$au" 2>&1)"
"$setup" >/dev/null 2>&1 || true
(($(grep -c '^PrivilegeElevationCommand=' "$au") == 1)) || fail "a rerun added a second elevation line:\n$(cat "$au")"
printf '#AURHelper=paru\nPrivilegeElevationCommand=doas\n' > "$au"
"$setup" >/dev/null 2>&1 || true
grep -qx 'PrivilegeElevationCommand=doas' "$au" && ! grep -q run0 "$au" \
  || fail "an elevation command the user chose was overwritten:\n$(cat "$au")"
printf '#PrivilegeElevationCommand=sudo\n' > "$au"
"$setup" >/dev/null 2>&1 || true
grep -qx 'PrivilegeElevationCommand=run0' "$au" || fail "a commented-out default was taken as a choice:\n$(cat "$au")"

# sudo: one guarded source line per existing rc file, never twice, and no rc
# file created for a shell the user does not use
printf '# mine\n' > "$HOME/.zshrc"
"$setup" >/dev/null 2>&1 || true
"$setup" >/dev/null 2>&1 || true
(($(grep -c 'sudo-run0.sh' "$HOME/.zshrc") == 1)) || fail "the run0 sudo line is missing or doubled:\n$(cat "$HOME/.zshrc")"
grep -qx '# mine' "$HOME/.zshrc" || fail 'adding the sudo line lost what was in .zshrc'
[[ ! -e $HOME/.bashrc ]] || fail 'setup created a .bashrc nobody had'

# paru: its Sudo goes through run0 too, and a new user paru.conf keeps the
# system file's options, since paru reads one or the other, never both
pc=$XDG_CONFIG_HOME/paru/paru.conf
# The runs above may have found a real paru on this machine's PATH.
rm -rf -- "$XDG_CONFIG_HOME/paru"
sysconf=$tmp/etc-paru.conf
printf '[options]\nC7TestMarker\n' > "$sysconf"
paru_bin=$tmp/paru-bin
mkdir -p "$paru_bin"; printf '#!/bin/sh\n' > "$paru_bin/paru"; chmod +x "$paru_bin/paru"
PATH=$paru_bin:$PATH C7SHELL_PARU_SYSCONF=$sysconf "$setup" >/dev/null 2>&1 || true
grep -qx 'Sudo = run0' "$pc" || fail "paru was not pointed at run0:\n$(cat "$pc" 2>&1)"
grep -qx 'C7TestMarker' "$pc" || fail "the new paru.conf dropped the system file's options:\n$(cat "$pc")"
PATH=$paru_bin:$PATH C7SHELL_PARU_SYSCONF=$sysconf "$setup" >/dev/null 2>&1 || true
(($(grep -c '^Sudo' "$pc") == 1)) || fail "a rerun added a second paru Sudo line:\n$(cat "$pc")"
# BottomUp lists AUR search results first, as Arch's own paru.conf does; a
# system file without it still gets it, once, and paru reads it as an option.
(($(grep -cx 'BottomUp' "$pc") == 1)) || fail "paru.conf lacks BottomUp, or has it twice:\n$(cat "$pc")"
[[ $(sed -n '/^\[/h; /^BottomUp$/{x;p;}' "$pc") == '[options]' ]] \
  || fail "BottomUp is outside [options]:\n$(cat "$pc")"
printf '[options]\n#BottomUp\n' > "$pc"
PATH=$paru_bin:$PATH C7SHELL_PARU_SYSCONF=$sysconf "$setup" >/dev/null 2>&1 || true
grep -qx 'BottomUp' "$pc" && fail "a BottomUp the user commented out was turned back on:\n$(cat "$pc")"
printf '[bin]\nSudo = doas\n' > "$pc"
PATH=$paru_bin:$PATH C7SHELL_PARU_SYSCONF=$sysconf "$setup" >/dev/null 2>&1 || true
grep -q run0 "$pc" && fail "a paru Sudo the user chose was overwritten:\n$(cat "$pc")"
[[ $(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua") == v1 ]] || fail 'hypr not installed'
[[ $(cat "$XDG_CONFIG_HOME/quickshell/c7shell/shell.qml") == v1 ]] || fail 'quickshell not installed'
[[ $(cat "$XDG_CONFIG_HOME/xdg-desktop-portal/hyprland-portals.conf") == v1 ]] || fail 'portal config not installed'

# the launcher's action-script directory exists, so there is somewhere to drop
# one -- the provider shows nothing and says nothing when it is missing
[[ -d $XDG_DATA_HOME/c7shell/scripts ]] || fail 'the launcher script dir was not created'

# the palette is seeded, so Qt apps match without touching a setting first
grep -q 'ColorScheme=C7Shell' "$XDG_CONFIG_HOME/kdeglobals" \
  || fail 'kdeglobals was not seeded from the shipped exporter'

# the shell lands in its own named subfolder, never over a sibling config
echo other > "$XDG_CONFIG_HOME/quickshell/notmine.qml"

# the $HOME placeholder in xdph.conf is rewritten to the real config path
grep -qF "$XDG_CONFIG_HOME/quickshell/c7shell/bin/x.sh" "$XDG_CONFIG_HOME/hypr/xdph.conf" \
  || fail 'xdph picker path not rewritten'

# second run without --force refuses, exit 3, leaves local edits alone
echo mine > "$XDG_CONFIG_HOME/hypr/hyprland.lua"
echo v2 > "$C7SHELL_SHARE/hypr/hyprland.lua"
rc=0; "$setup" >/dev/null 2>&1 || rc=$?
((rc == 3)) || fail "expected exit 3 on existing target, got $rc"
[[ $(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua") == mine ]] || fail 'clobbered an existing config without --force'

# --force replaces and keeps a backup holding the old content
echo mine > "$XDG_DATA_HOME/c7shell/scripts/mine.sh"
"$setup" --force >/dev/null
# the whole reason the scripts live outside the config tree: --force moves that
# tree aside, and a user's action scripts must not go with it
[[ $(cat "$XDG_DATA_HOME/c7shell/scripts/mine.sh") == mine ]] \
  || fail '--force lost a user action script'
[[ $(cat "$XDG_CONFIG_HOME/hypr/hyprland.lua") == v2 ]] || fail '--force did not update'
backup=$(echo "$XDG_CONFIG_HOME"/hypr.bak-*)
[[ -d $backup && $(cat "$backup/hyprland.lua") == mine ]] || fail 'backup missing or wrong'
[[ $(cat "$XDG_CONFIG_HOME/quickshell/notmine.qml") == other ]] \
  || fail '--force touched an unrelated quickshell config'

# missing share tree is an error, not a silent success
# (as a prefix on the command only -- `VAR=x rc=0` with no command to run is a
# plain assignment, and that line used to leave C7SHELL_SHARE pointing at a
# directory that does not exist for the whole rest of the file)
rc=0; C7SHELL_SHARE=$tmp/nope "$setup" >/dev/null 2>&1 || rc=$?
((rc == 1)) || fail "expected exit 1 for missing share dir, got $rc"


# --- an existing config still records a baseline --------------------------
# This is the case that broke a real machine. setup used to exit 3 the moment
# it skipped everything, BEFORE writing the manifest -- so the one situation
# that most needs a baseline (a config already there) was the only one that
# never got one. The next c7shell-upgrade then had nothing to compare against,
# treated every shipped file as locally edited, and parked a .new beside each
# one. That leaves a config half one version and half another, which for QML
# is not a cosmetic problem: imports resolve across the whole tree, so an old
# shell.qml next to a new module directory fails the entire load.
rm -rf "${C7SHELL_STATE:?}"
rc=0; out=$("$setup" 2>&1) || rc=$?
((rc == 3)) || fail "a second setup over an existing config should exit 3, got $rc:\n$out"
# Nothing was copied, so nothing may be claimed as ours -- guessing here is
# what would silently overwrite a real local edit on the next upgrade.
[[ -f $C7SHELL_STATE/manifest ]] \
  || fail "setup wrote no manifest at all when it skipped:\n$out"
[[ ! -s $C7SHELL_STATE/manifest ]] \
  || fail "setup claimed files it did not install:\n$(cat "$C7SHELL_STATE/manifest")"
# And it has to say what to do next, rather than one line on stderr that
# scrolls past.
grep -q -- '--force' <<<"$out" || fail "setup did not offer --force:\n$out"
grep -q 'c7shell-upgrade' <<<"$out" \
  || fail "setup did not point at the non-destructive way to update:\n$out"


# --- a rerun keeps the baseline it cannot rebuild ----------------------------
# A second setup skips every part, so it has nothing new to hash. It used to
# empty the manifest anyway, and the next upgrade then took every changed file
# for a local edit and parked a .new beside it: a config half old, half new.
rm -rf "${XDG_CONFIG_HOME:?}" "${C7SHELL_STATE:?}"
"$setup" >/dev/null 2>&1 || fail 'setup failed on a fresh config dir'
cp "$C7SHELL_STATE/manifest" "$tmp/manifest.first"
[[ -s $tmp/manifest.first ]] || fail 'a fresh setup recorded no manifest'
"$setup" >/dev/null 2>&1 || true
cmp -s "$tmp/manifest.first" "$C7SHELL_STATE/manifest" \
  || fail "a rerun lost the baseline:\n$(diff "$tmp/manifest.first" "$C7SHELL_STATE/manifest")"
# One part replaced: its rows are new, and the other parts keep theirs.
"$setup" --force >/dev/null 2>&1 || fail 'setup --force failed'
grep -q '^quickshell/c7shell/shell.qml	' "$C7SHELL_STATE/manifest" \
  || fail "--force dropped rows:\n$(cat "$C7SHELL_STATE/manifest")"
(($(grep -c '^hypr/hyprland.lua	' "$C7SHELL_STATE/manifest") == 1)) \
  || fail "--force duplicated rows:\n$(cat "$C7SHELL_STATE/manifest")"

# The exporter writes the lock palette into ~/.config/hypr. It is generated,
# not shipped, so claiming it would let an upgrade delete it as dropped upstream.
[[ -f $XDG_CONFIG_HOME/hypr/hyprlock-palette.conf ]] || fail 'the fixture exporter wrote no palette'
if grep -q '^hypr/hyprlock-palette.conf	' "$C7SHELL_STATE/manifest"; then
  fail 'setup claimed the generated lock palette as a shipped file'
fi

# --- odd config paths are data, not sed syntax ---------------------------------
odd=$tmp/odd'#and&'/conf
XDG_CONFIG_HOME=$odd C7SHELL_STATE=$tmp/odd-state "$setup" >/dev/null 2>&1 \
  || fail 'setup failed on a config path containing # or &'
grep -qxF "custom_picker_binary = $odd/quickshell/c7shell/bin/x.sh" "$odd/hypr/xdph.conf" \
  || fail "a # or & in the config path broke the xdph rewrite:\n$(cat "$odd/hypr/xdph.conf")"

# --- the sudo line survives a path with a space, and zsh's ZDOTDIR ------------
mkdir -p "$tmp/zdot"; : > "$tmp/zdot/.zshrc"
snip="$tmp/sn ip.sh"; echo 'true' > "$snip"
ZDOTDIR=$tmp/zdot C7SHELL_SUDO_SNIPPET=$snip "$setup" >/dev/null 2>&1 || true
grep -qF "c7shell: sudo asks" "$tmp/zdot/.zshrc" || fail 'setup ignored $ZDOTDIR/.zshrc'
(cd "$tmp" && bash -c ". '$tmp/zdot/.zshrc'") 2>/dev/null \
  || fail "the sudo source line does not survive a space:\n$(cat "$tmp/zdot/.zshrc")"

# --- part of it installed is not "Done" ---------------------------------------
# A stock or foreign hypr config with the c7shell shell beside it is not a
# c7shell session; setup must say which parts it left alone, and not exit 0.
part=$tmp/partial
mkdir -p "$part/conf/hypr"; echo 'mine' > "$part/conf/hypr/hyprland.lua"
rc=0; out=$(XDG_CONFIG_HOME=$part/conf C7SHELL_STATE=$part/state "$setup" 2>&1) || rc=$?
((rc == 4)) || fail "a partial install exited $rc, not 4:\n$out"
grep -q 'Done\.' <<<"$out" && fail "a partial install said Done:\n$out"
grep -q "$part/conf/hypr" <<<"$out" || fail "a partial install did not name the part it left alone:\n$out"
[[ -f $part/conf/quickshell/c7shell/shell.qml ]] || fail 'the parts that were free were not installed'

# --- Hyprland's own first-run stub is not a config to keep --------------------
auto=$tmp/autogen
mkdir -p "$auto/conf/hypr"
printf '# auto-generated\nautogenerated = 1\n' > "$auto/conf/hypr/hyprland.conf"
rc=0; out=$(XDG_CONFIG_HOME=$auto/conf C7SHELL_STATE=$auto/state "$setup" 2>&1) || rc=$?
((rc == 0)) || fail "Hyprland's autogenerated stub blocked the hypr part (exit $rc):\n$out"
[[ -f $auto/conf/hypr/hyprland.lua ]] || fail 'the hypr part was not installed over the autogenerated stub'
ls -d "$auto/conf/hypr.bak-"* >/dev/null 2>&1 || fail 'the autogenerated stub was not kept as a backup'
# A real config that happens to be called hyprland.conf is still left alone.
real=$tmp/realconf
mkdir -p "$real/conf/hypr"; printf 'monitor = ,preferred,auto,1\n' > "$real/conf/hypr/hyprland.conf"
rc=0; out=$(XDG_CONFIG_HOME=$real/conf C7SHELL_STATE=$real/state "$setup" 2>&1) || rc=$?
((rc == 4)) || fail "a hand-written hyprland.conf was replaced (exit $rc):\n$out"

# --- --uninstall removes what setup installed, and only that (#19) ----------
# Switching to another setup means getting c7shell's files out of the way
# without losing anything the user wrote. Unedited shipped files go; edited
# ones, files c7shell never shipped, and the .bak copies stay.
un=$tmp/uninstall
mkdir -p "$un/home" "$un/dotfiles" "$un/zdot"
# .bashrc is a dotfile manager's symlink, with a Latin-1 byte grep would call
# binary, and a sudo line of the user's own that only the marker tells apart.
printf '# caf\xe9\nalias please="sudo !!"\n' > "$un/dotfiles/bashrc"
ln -s ../dotfiles/bashrc "$un/home/.bashrc"
printf 'setopt autocd\n' > "$un/zdot/.zshrc"
cp "$un/dotfiles/bashrc" "$tmp/bashrc.orig"; cp "$un/zdot/.zshrc" "$tmp/zshrc.orig"
# gsettings is the host's dconf; a stub answers for it, as c7shell set it.
mkdir -p "$un/bin"; printf '#!/bin/sh\necho "'"'"'prefer-dark'"'"'"\n' > "$un/bin/gsettings"; chmod +x "$un/bin/gsettings"
export PATH="$un/bin:$PATH"
u() { HOME=$un/home ZDOTDIR=$un/zdot XDG_CONFIG_HOME=$un/conf C7SHELL_STATE=$un/state \
        C7SHELL_SUDO_SNIPPET=$tmp/sn.sh "$setup" "$@"; }
u >/dev/null 2>&1
grep -qF 'c7shell: sudo asks' "$un/home/.bashrc" || fail 'uninstall fixture: setup added no sudo line to .bashrc'
grep -qF 'c7shell: sudo asks' "$un/zdot/.zshrc" || fail 'uninstall fixture: setup added no sudo line to .zshrc'
mkdir -p "$un/conf/hypr.bak-1" "$un/conf/hypr/wallpapers"
echo edited > "$un/conf/quickshell/c7shell/shell.qml"
# Beside an edited file, a .new is what the user was told to merge.
echo merging > "$un/conf/quickshell/c7shell/shell.qml.new"
mkdir -p "$un/conf/quickshell/c7shell.bak-1" "$XDG_DATA_HOME/c7shell/scripts"
printf '[bin]\nSudo = run0\n\n[options]\nBottomUp\n' > "$un/conf/paru/paru.conf.keep"
echo v2 > "$un/conf/hypr/hyprland.lua.new"
echo mine > "$un/conf/hypr/monitors.lua"
# What the shell itself writes, and what an upgrade backs up per file: in no
# manifest, but they keep the part's directory alive, so they must be named.
echo '{}' > "$un/conf/hypr/displays-state.json"
echo old > "$un/conf/hypr/hyprland.lua.bak-20260101000000"
mkdir -p "$un/conf/gtk-3.0" "$un/conf/gtk-4.0"; printf '[Settings]\ngtk-application-prefer-dark-theme=1\n' > "$un/conf/gtk-3.0/settings.ini"
# A settings.ini without the export's key is somebody else's, not a leftover.
printf '[Settings]\ngtk-font-name=Sans 10\n' > "$un/conf/gtk-4.0/settings.ini"
# The portal part now lives in a dotfiles repo, reached through a symlink.
mv "$un/conf/xdg-desktop-portal" "$un/dotfiles/portal"
ln -s ../dotfiles/portal "$un/conf/xdg-desktop-portal"

# setup writes paru.conf only where paru is installed; this test must not
# depend on the machine it runs on.
rm -f "$un/conf/paru/paru.conf"; mv "$un/conf/paru/paru.conf.keep" "$un/conf/paru/paru.conf"

printf '[Mouse]\ncursorTheme=Bibata\n' > "$un/conf/kcminputrc"
cp "$un/conf/arch-update/arch-update.conf" "$tmp/au.orig"; cp "$un/conf/paru/paru.conf" "$tmp/pc.orig"

if u --uninstall --force >/dev/null 2>&1; then fail 'uninstall accepted --force'; fi

out=$(u --uninstall --dry-run 2>&1) || fail "uninstall --dry-run failed:\n$out"
[[ -f $un/conf/hypr/hyprland.lua && -f $un/conf/hypr/hyprland.lua.new && -f $un/state/manifest ]] \
  || fail "uninstall --dry-run removed files:\n$out"
grep -qF 'c7shell: sudo asks' "$un/home/.bashrc" || fail 'uninstall --dry-run edited .bashrc'
grep -q '^would remove' <<<"$out" || fail "uninstall --dry-run did not say would:\n$out"
grep -qF "hypr/hyprlock-palette.conf" <<<"$out" || fail "uninstall --dry-run did not preview the lock palette:\n$out"
# What the dry run would remove is not also what it says stays.
also=$(sed -n '/^Also still in the c7shell parts/,/^$/p' <<<"$out")
for f in hypr/hyprland.lua hypr/hyprlock-palette.conf; do
  grep -qxF "  $un/conf/$f" <<<"$also" && fail "uninstall --dry-run listed $f as both removed and left:\n$out"
done

out=$(u --uninstall 2>&1) || fail "uninstall failed:\n$out"
for gone in hypr/hyprland.lua hypr/hyprland.lua.new hypr/xdph.conf; do
  [[ ! -e $un/conf/$gone ]] || fail "uninstall left $gone:\n$out"
done
[[ -f $un/conf/quickshell/c7shell/shell.qml ]] || fail 'uninstall deleted an edited file'
grep -A1 'Kept, because you edited them' <<<"$out" | grep -qxF "  $un/conf/quickshell/c7shell/shell.qml" \
  || fail "uninstall did not name the edited file it kept:\n$out"
also=$(sed -n '/^Also still in the c7shell parts/,/^$/p' <<<"$out")
for f in hypr/monitors.lua hypr/displays-state.json hypr/hyprland.lua.bak-20260101000000; do
  grep -qxF "  $un/conf/$f" <<<"$also" || fail "uninstall did not list $f as still in a part:\n$out"
done
grep -qF 'shell.qml' <<<"$also" && fail "a file already listed as kept was listed twice:\n$out"
grep -qF "$un/conf/gtk-3.0/settings.ini   (the theme export writes to it)" <<<"$out" \
  || fail "uninstall did not list a file the theme export writes:\n$out"
grep -qF "$un/conf/gtk-4.0/settings.ini" <<<"$out" && fail "uninstall listed a settings.ini the export never wrote:\n$out"
grep -qF "$un/conf/kcminputrc   (the theme export writes to it)" <<<"$out" || fail "uninstall did not list kcminputrc:\n$out"
grep -qF "color-scheme setting, now 'prefer-dark'" <<<"$out" || fail "uninstall did not list the gsettings key:\n$out"
grep -qF "BottomUp in $un/conf/paru/paru.conf" <<<"$out" || fail "uninstall did not list paru's BottomUp:\n$out"
# Listed is all: the unmarked run0 lines are the user's to remove.
cmp -s "$un/conf/arch-update/arch-update.conf" "$tmp/au.orig" || fail 'uninstall changed arch-update.conf'
cmp -s "$un/conf/paru/paru.conf" "$tmp/pc.orig" || fail 'uninstall changed paru.conf'
[[ -f $un/conf/hypr/monitors.lua ]] || fail 'uninstall deleted a file c7shell never shipped'
[[ -d $un/conf/hypr/wallpapers ]] || fail 'uninstall deleted an empty directory the user made'
[[ -d $un/conf/hypr.bak-1 ]] || fail 'uninstall touched a backup'
grep -qF "$un/conf/hypr.bak-1" <<<"$out" || fail "uninstall did not list the backup it left:\n$out"
[[ -f $un/dotfiles/portal/hyprland-portals.conf ]] || fail 'uninstall deleted through a symlink into a dotfiles tree'
grep -qF "$un/conf/xdg-desktop-portal/hyprland-portals.conf" <<<"$out" \
  || fail "uninstall did not report the file it left behind a symlink:\n$out"
[[ -f $un/conf/arch-update/arch-update.conf ]] || fail 'uninstall deleted the user-owned arch-update config'
grep -q 'PrivilegeElevationCommand=run0' <<<"$out" || fail "uninstall did not mention the arch-update line it left:\n$out"
for left in 'Sudo = run0' "$un/conf/quickshell/c7shell.bak-1" "$XDG_DATA_HOME/c7shell/scripts" \
            "C7Shell colours in $un/conf/kdeglobals"; do
  grep -qF "$left" <<<"$out" || fail "uninstall did not list what it left: $left\n$out"
done
# The lock palette is c7shell's own, generated: left behind, it alone would
# keep ~/.config/hypr alive and the next setup would skip the hypr part.
[[ ! -e $un/conf/hypr/hyprlock-palette.conf ]] || fail 'uninstall left the generated lock palette'
[[ -f $un/conf/quickshell/c7shell/shell.qml.new ]] || fail 'uninstall deleted the .new beside an edited file'
grep -A1 'parked for you to merge' <<<"$out" | grep -qF "$un/conf/quickshell/c7shell/shell.qml.new" \
  || fail "uninstall did not list the kept .new as a version to merge:\n$out"
# The rc files come back byte for byte, through the symlink.
cmp -s "$un/dotfiles/bashrc" "$tmp/bashrc.orig" || fail "uninstall did not restore .bashrc:\n$(cat -A "$un/dotfiles/bashrc")"
cmp -s "$un/zdot/.zshrc" "$tmp/zshrc.orig" || fail "uninstall did not restore .zshrc:\n$(cat -A "$un/zdot/.zshrc")"
[[ -L $un/home/.bashrc ]] || fail 'uninstall replaced a symlinked .bashrc with a plain file'
# The rows of files that stay survive, so a later upgrade still knows them
# as edits; the rows of removed files go.
grep -q '^quickshell/c7shell/shell.qml'$'\t' "$un/state/manifest" || fail "uninstall dropped the row of a kept file"
grep -q '^xdg-desktop-portal/' "$un/state/manifest" || fail "uninstall dropped the rows behind a symlink"
grep -q '^hypr/hyprland.lua'$'\t' "$un/state/manifest" && fail "uninstall kept the row of a removed file"

# Directories the removals emptied go, up to the config dir itself.
rm -r "$un/conf/quickshell/c7shell/shell.qml" "$un/conf/quickshell/c7shell/shell.qml.new" "$un/conf/quickshell/c7shell.bak-1"
mkdir -p "$un/state"; printf 'quickshell/c7shell/x.qml\t%s\n' "$(printf 'x\n' | sha256sum | cut -d' ' -f1)" > "$un/state/manifest"
echo x > "$un/conf/quickshell/c7shell/x.qml"
u --uninstall >/dev/null 2>&1 || fail 'uninstall of the last file failed'
[[ ! -e $un/conf/quickshell ]] || fail "uninstall left the directories it emptied:\n$(find "$un/conf/quickshell")"
[[ ! -e $un/state/manifest ]] || fail 'uninstall kept a manifest with every row removed'
[[ -d $un/conf ]] || fail 'uninstall removed the config dir itself'

# An empty config dir is still the config dir: pruning stops below it.
lone=$tmp/lone; mkdir -p "$lone/conf/hypr" "$lone/state"; echo x > "$lone/conf/hypr/x.lua"
printf 'hypr/x.lua\t%s\n' "$(sha256sum < "$lone/conf/hypr/x.lua" | cut -d' ' -f1)" > "$lone/state/manifest"
HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 \
  || fail 'uninstall of a lone file failed'
[[ -d $lone/conf && ! -e $lone/conf/hypr ]] || fail 'uninstall pruned past, or short of, the config dir'

# The lock palette alone does not keep hypr/ alive, and through a symlinked
# hypr/ it is the user's file and stays.
mkdir -p "$lone/conf/hypr"; echo p > "$lone/conf/hypr/hyprlock-palette.conf"; printf 'hypr/gone\t0\n' > "$lone/state/manifest"
HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 || true
[[ ! -e $lone/conf/hypr ]] || fail 'uninstall left hypr/ behind with only the lock palette gone from it'
mkdir -p "$lone/dots/hypr"; echo p > "$lone/dots/hypr/hyprlock-palette.conf"; ln -s ../dots/hypr "$lone/conf/hypr"
HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 || true
[[ -f $lone/dots/hypr/hyprlock-palette.conf ]] || fail 'uninstall deleted a lock palette through a symlinked hypr/'
rm "$lone/conf/hypr"

# A manifest it cannot rewrite fails the run.
mkdir -p "$lone/conf/hypr"; echo x > "$lone/conf/hypr/k.lua"
printf 'hypr/k.lua\t0000\n' > "$lone/state/manifest"; chmod 555 "$lone/state"
rc=0; HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 || rc=$?
chmod 755 "$lone/state"; rm -r "$lone/conf/hypr"
((rc == 1)) || fail "a manifest uninstall could not rewrite did not exit 1 (got $rc)"

# An unreadable manifest stops the run: read as empty, it would be deleted.
mkdir -p "$lone/conf/hypr"; echo x > "$lone/conf/hypr/u.lua"
printf 'hypr/u.lua\t%s\n' "$(sha256sum < "$lone/conf/hypr/u.lua" | cut -d' ' -f1)" > "$lone/state/manifest"
chmod 000 "$lone/state/manifest"
rc=0; HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 || rc=$?
chmod 644 "$lone/state/manifest"
((rc == 1)) || fail "an unreadable manifest did not exit 1 (got $rc)"
[[ -s $lone/state/manifest && -f $lone/conf/hypr/u.lua ]] || fail 'uninstall acted on a manifest it could not read'
rm -r "$lone/conf/hypr"

# A row whose file is gone but whose .new is there keeps the .new.
mkdir -p "$lone/conf/hypr"; echo merged > "$lone/conf/hypr/y.lua.new"
printf 'hypr/y.lua\t0000\n' > "$lone/state/manifest"
out=$(HOME=$un/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall 2>&1)
[[ -f $lone/conf/hypr/y.lua.new ]] || fail "uninstall deleted a lone .new:\n$out"
[[ $out != *"$lone/conf/hypr/y.lua"$'\n'* ]] || fail "uninstall listed a missing file as kept:\n$out"

# An rc file without a final newline comes back without one; a read-only one
# is left whole, and the run says so with exit 1.
ro=$tmp/ro; mkdir -p "$ro/home"
printf 'a\n\n%s\nz' "[ -r x ] && . x   # c7shell: sudo asks through polkit (run0)" > "$ro/home/.bashrc"
chmod 640 "$ro/home/.bashrc"
printf 'hypr/none\t0\n' > "$lone/state/manifest"
HOME=$ro/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall >/dev/null 2>&1 \
  || fail 'uninstall failed on an rc file without a final newline'
[[ $(od -An -c "$ro/home/.bashrc" | tr -s ' ') == ' a \n z' ]] \
  || fail "uninstall did not restore an rc file without a final newline:\n$(od -c "$ro/home/.bashrc")"
[[ $(stat -c %a "$ro/home/.bashrc") == 640 ]] || fail "uninstall changed an rc file's mode to $(stat -c %a "$ro/home/.bashrc")"
printf 'a\n%s\n' "[ -r x ] && . x   # c7shell: sudo asks through polkit (run0)" > "$ro/home/.bashrc"
chmod 444 "$ro/home/.bashrc"; printf 'hypr/none\t0\n' > "$lone/state/manifest"
rc=0; out=$(HOME=$ro/home XDG_CONFIG_HOME=$lone/conf C7SHELL_STATE=$lone/state "$setup" --uninstall 2>&1) || rc=$?
((rc == 1)) || fail "a read-only rc file did not exit 1 (got $rc):\n$out"
grep -qF 'c7shell: sudo asks' "$ro/home/.bashrc" || fail 'uninstall changed a read-only rc file'
grep -qF "$ro/home/.bashrc" <<<"$out" || fail "uninstall did not name the rc file it could not edit:\n$out"
chmod 644 "$ro/home/.bashrc"

# A ../ row in a manifest never reaches outside the config dir.
echo keep > "$un/outside"
printf '../outside\t%s\n' "$(sha256sum < "$un/outside" | cut -d' ' -f1)" > "$un/state/manifest"
u --uninstall >/dev/null 2>&1 || true
[[ -f $un/outside ]] || fail 'uninstall followed a ../ row out of the config dir'
out=$(u --uninstall 2>&1) || true
grep -qF "a ../ in the manifest" <<<"$out" || fail "a ../ row was not labelled as one:\n$out"

grep -q '^\.\./outside' "$un/state/manifest" || fail 'uninstall dropped the row it refused to follow'

# No manifest -- an install older than it, a wiped ~/.local/state -- removes no
# config file, but still takes out the sudo line and lists what is left.
nm=$tmp/nomanifest; mkdir -p "$nm/home"
printf 'a\n\n%s\n' "[ -r x ] && . x   # c7shell: sudo asks through polkit (run0)" > "$nm/home/.bashrc"
out=$(HOME=$nm/home XDG_CONFIG_HOME=$un/conf C7SHELL_STATE=$tmp/never "$setup" --uninstall 2>&1) \
  || fail "uninstall with no install recorded failed:\n$out"
grep -q 'no install recorded' <<<"$out" || fail "uninstall with no install recorded did not say so:\n$out"
grep -qF 'c7shell: sudo asks' "$nm/home/.bashrc" && fail 'uninstall with no manifest left the sudo line'

# A manifest names no config dir, so a run against another one -- or with a
# part moved aside -- must keep the rows it found nothing for.
other=$tmp/otherconf; mkdir -p "$other/state"
printf 'hypr/hyprland.lua\t%s\n' "$(echo v1 | sha256sum | cut -d' ' -f1)" > "$other/state/manifest"
HOME=$nm/home XDG_CONFIG_HOME=$other/elsewhere C7SHELL_STATE=$other/state "$setup" --uninstall >/dev/null 2>&1 \
  || fail 'uninstall against an empty config dir failed'
grep -q '^hypr/hyprland.lua' "$other/state/manifest" || fail 'uninstall erased the rows of files it never saw'

# A file it cannot remove keeps its row and fails the run.
ro2=$tmp/rodir; mkdir -p "$ro2/conf/hypr" "$ro2/state"; echo v1 > "$ro2/conf/hypr/hyprland.lua"
printf 'hypr/hyprland.lua\t%s\n' "$(echo v1 | sha256sum | cut -d' ' -f1)" > "$ro2/state/manifest"
chmod 555 "$ro2/conf/hypr"
rc=0; out=$(HOME=$nm/home XDG_CONFIG_HOME=$ro2/conf C7SHELL_STATE=$ro2/state "$setup" --uninstall 2>&1) || rc=$?
chmod 755 "$ro2/conf/hypr"
((rc == 1)) || fail "a file uninstall could not remove did not exit 1 (got $rc):\n$out"
grep -q '^hypr/hyprland.lua' "$ro2/state/manifest" || fail 'uninstall dropped the row of a file it could not remove'
grep -q 'removed 0 ' <<<"$out" || fail "uninstall counted a file it could not remove:\n$out"

# --- and none of the above escaped into a real home -----------------------
# The isolation above is the whole reason this file cannot damage the machine
# it runs on; assert it rather than trusting it.
[[ -d $tmp/state || -d $tmp/xdg-state ]] \
  || fail 'setup wrote no state anywhere -- the isolation may be pointing at a real home'
while read -r stray; do
  fail "a test artefact escaped the sandbox: $stray"
done < <(find "$HOME" -name manifest -newer "$tmp" 2>/dev/null | grep -v "^$tmp" || true)

echo 'PASS: c7shell-setup'
