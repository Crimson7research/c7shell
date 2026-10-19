#!/usr/bin/env bash
# Self-check for bin/c7shell-bootstrap. Run it directly: tests/test-bootstrap.sh
#
# The bootstrap decides what to install from what it finds on the machine, so
# the test fakes the machine: stub pacman/lspci/systemctl on a PATH with
# nothing else on it, and read the plan back out of --dry-run. Every mutating
# command is logged by the stubs, so "changed nothing" is checked, not assumed.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
bootstrap=$here/../bin/c7shell-bootstrap
mktmp

bin=$tmp/bin
log=$tmp/ran.log
mkdir -p "$bin"

for helper in grep uname getent id sed cat sort; do ln -s "$(command -v "$helper")" "$bin/$helper"; done

cat > "$bin/pacman" <<'STUB'
#!/bin/sh
case $1 in
  -Qq)
    [ -n "$2" ] || { printf '%s\n' $STUB_INSTALLED; exit 0; }
    for p in $STUB_INSTALLED; do [ "$p" = "$2" ] && exit 0; done
    exit 1 ;;
  -Si)
    # A database refresh is what brings a new package into view.
    [ -e "$STUB_LOG.synced" ] && [ -n "$STUB_NEW_AFTER_SYNC" ] && exit 0
    for p in $STUB_UNKNOWN; do [ "$p" = "$2" ] && exit 1; done
    exit 0 ;;
  *) echo "pacman $*" >> "$STUB_LOG"; exit 0 ;;
esac
STUB

cat > "$bin/systemctl" <<'STUB'
#!/bin/sh
if [ "$1" = --user ] && [ -n "$STUB_NO_USER_MANAGER" ]; then
  echo 'Failed to connect to bus: No medium found' >&2; exit 1
fi
[ "$1" = list-unit-files ] && { [ -n "$STUB_NETCTL" ] && printf 'UNIT FILE STATE\nnetctl@home.service enabled\n'; exit 0; }
if [ "$1" = is-enabled ]; then
  for u in $STUB_ENABLED; do [ "$u" = "$2" ] && { echo enabled; exit 0; }; done
  echo disabled; exit 1
fi
echo "systemctl $*" >> "$STUB_LOG"
STUB

cat > "$bin/lspci" <<'STUB'
#!/bin/sh
printf '%s\n' "$STUB_LSPCI"
STUB

for s in pacman systemctl lspci; do chmod +x "$bin/$s"; done
# Present and working, so the bootstrap never tries to build an AUR helper in
# a test. --version is how the bootstrap decides that, so it must not log:
# every "--dry-run changed nothing" check reads that same log.
working_paru() { printf '#!/bin/sh\ncase $1 in --version) echo "paru v2.1.0"; exit 0 ;; esac\necho "paru $*" >> "$STUB_LOG"\n' > "$bin/paru"; chmod +x "$bin/paru"; }
working_paru
# root wrapper, so run_root has something to find in a non-dry run
# A refresh through it is what brings STUB_NEW_AFTER_SYNC packages into view.
# `tailscale set` is the one command it really runs, through the stub below:
# the operator one run names has to be the operator the next run finds, or
# running the bootstrap twice could not be tested at all.
printf '#!/bin/sh\necho "sudo $*" >> "$STUB_LOG"\ncase "$1 $2" in "pacman -Sy"*) : > "$STUB_LOG.synced" ;; "tailscale set"*) exec "$@" ;; esac\n' > "$bin/sudo"; chmod +x "$bin/sudo"

# plan <lspci line> [args...] -> the dry-run plan
plan() {
  local pci=$1; shift
  : > "$log"
  env -i PATH="$bin" HOME="$tmp" USER=tester \
    C7SHELL_ROOT="${C7SHELL_ROOT:-$tmp/root}" \
    STUB_LOG="$log" STUB_LSPCI="$pci" \
    STUB_INSTALLED="${STUB_INSTALLED:-linux}" \
    STUB_UNKNOWN="${STUB_UNKNOWN:-}" STUB_ENABLED="${STUB_ENABLED:-}" \
    STUB_NEW_AFTER_SYNC= STUB_NO_USER_MANAGER= STUB_NETCTL="${STUB_NETCTL:-}" \
    STUB_TS_OPERATOR="${STUB_TS_OPERATOR:-}" STUB_TS_DOWN="${STUB_TS_DOWN:-}" \
    /usr/bin/bash "$bootstrap" --dry-run "$@" 2>&1
}

AMD='01:00.0 VGA compatible controller [0300]: Advanced Micro Devices, Inc. [AMD/ATI] Raphael [1002:164e]'
INTEL='00:02.0 VGA compatible controller [0300]: Intel Corporation Alder Lake-P GT2 [8086:46a6]'
NVIDIA='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation AD107M [GeForce RTX 4060 Max-Q] [10de:28e0]'
OLD_NVIDIA='01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP104 [GeForce GTX 1080] [10de:1b80]'
QEMU='00:01.0 VGA compatible controller [0300]: Red Hat, Inc. Virtio GPU [1af4:1050]'

# --- the things every machine needs ---------------------------------------
out=$(plan "$AMD")
for pkg in qt6-wayland xdg-utils polkit pipewire pipewire-pulse wireplumber \
           ttf-jetbrains-mono noto-fonts hicolor-icon-theme breeze-icons \
           greetd cage networkmanager bluez kitty dolphin ddcutil brightnessctl playerctl; do
  grep -q "\b$pkg\b" <<<"$out" || fail "$pkg is not in the plan:\n$out"
done
grep -q 'pipewire.socket' <<<"$out" || fail "the pipewire user units are not enabled:\n$out"
grep -q 'enable: .*greetd.service' <<<"$out" || fail "greetd.service is not enabled:\n$out"
grep -q 'enable: .*NetworkManager.service' <<<"$out" || fail "NetworkManager is not enabled:\n$out"
grep -q 'enable: .*bluetooth.service' <<<"$out" || fail "bluetooth is not enabled:\n$out"

# --dry-run really does nothing: no stub was asked to change anything
[[ ! -s $log ]] || fail "--dry-run ran something:\n$(cat "$log")"

# --- the Qt/KDE theming packages ride with dolphin, not on their own -------
# plasma-integration is useless without a QWidget app to theme, so it must not
# land on a machine that has none.
# grep the pacman line, not the whole plan: the note explaining the skip names
# the package too.
installs() { grep -E 'pacman -S --needed' <<<"$1"; }

out=$(plan "$AMD")
installs "$out" | grep -q '\bplasma-integration\b' \
  || fail "the extras include dolphin, so plasma-integration should come too:\n$out"

out=$(plan "$AMD" --no-extras)
installs "$out" | grep -q '\bplasma-integration\b' \
  && fail "--no-extras (no dolphin) still installed plasma-integration:\n$out"
installs "$out" | grep -q '\bbreeze\b' && fail "--no-extras still installed breeze:\n$out"
grep -q 'no Qt/KDE apps here' <<<"$out" || fail "skipping the theming packages was not explained:\n$out"

# a machine that already has dolphin gets them even with --no-extras
printf '#!/bin/sh\nexit 0\n' > "$bin/dolphin"; chmod +x "$bin/dolphin"
out=$(plan "$AMD" --no-extras)
installs "$out" | grep -q '\bplasma-integration\b' \
  || fail "an existing dolphin should pull in plasma-integration:\n$out"
rm "$bin/dolphin"

# --- per-vendor drivers ----------------------------------------------------
out=$(plan "$AMD")
grep -q 'GPU: amd' <<<"$out" || fail "amd not detected:\n$out"
grep -q '\bvulkan-radeon\b' <<<"$out" || fail "no radeon vulkan driver:\n$out"
grep -q 'nvidia' <<<"$out" && fail "amd plan pulled in nvidia:\n$out"

out=$(plan "$INTEL")
grep -q 'GPU: intel' <<<"$out" || fail "intel not detected:\n$out"
grep -q '\bvulkan-intel\b' <<<"$out" || fail "no intel vulkan driver:\n$out"

out=$(plan "$NVIDIA")
grep -q 'GPU: nvidia' <<<"$out" || fail "nvidia not detected:\n$out"
grep -q '\bnvidia-open-dkms\b' <<<"$out" || fail "no nvidia-open-dkms:\n$out"
grep -q '\bnvidia-utils\b' <<<"$out" || fail "no nvidia-utils:\n$out"
# DKMS with no headers builds nothing and the next boot has no driver at all
grep -q '\blinux-headers\b' <<<"$out" || fail "no kernel headers for dkms:\n$out"
grep -q 'modprobe.d/c7shell-nvidia.conf' <<<"$out" || fail "no nvidia modeset file:\n$out"
grep -q 'modeset=1' <<<"$out" || fail "the nvidia file does not set modeset:\n$out"

# headers follow the kernels that are actually installed
STUB_INSTALLED='linux linux-lts' out=$(plan "$NVIDIA")
grep -q '\blinux-lts-headers\b' <<<"$out" || fail "no headers for linux-lts:\n$out"

# a pre-Turing card cannot use the open module, and silence there means a
# black screen after the next reboot
out=$(plan "$OLD_NVIDIA")
grep -q 'pre-Turing' <<<"$out" || fail "no warning for a pre-Turing nvidia card:\n$out"

out=$(plan "$QEMU")
grep -q 'GPU: virtual' <<<"$out" || fail "a virtual GPU was not recognised:\n$out"
grep -q '\bmesa\b' <<<"$out" || fail "no mesa for a virtual GPU:\n$out"

out=$(plan '')
grep -q 'no GPU was detected' <<<"$out" || fail "an empty lspci was not reported:\n$out"

out=$(plan "$NVIDIA" --no-drivers)
grep -q 'nvidia-open-dkms' <<<"$out" && fail "--no-drivers still installed a driver:\n$out"

# --- conflicts, which are the difference between working and no login -----
STUB_ENABLED='gdm.service' out=$(plan "$AMD")
grep -q 'gdm.service is already enabled' <<<"$out" || fail "an enabled gdm was not noticed:\n$out"
grep -q 'enable: .*greetd.service' <<<"$out" && fail "greetd was enabled alongside gdm:\n$out"

STUB_ENABLED='systemd-networkd.service' out=$(plan "$AMD")
grep -q 'not enabling NetworkManager' <<<"$out" || fail "systemd-networkd was not noticed:\n$out"
grep -q 'enable: .*NetworkManager.service' <<<"$out" && fail "NetworkManager enabled over systemd-networkd:\n$out"

# already-enabled units are not enabled again
STUB_ENABLED='greetd.service NetworkManager.service bluetooth.service' out=$(plan "$AMD")
grep -q 'no system units to enable' <<<"$out" || fail "re-enabled units that were already enabled:\n$out"

# --- the update flow's dependencies ----------------------------------------
# The bar's update badge is not an extra that degrades: without checkupdates
# there is no rootless dry run behind it and it can count nothing at all, so
# pacman-contrib has to be planned on a plain run with no flags.
out=$(plan "$AMD")
grep -q '\bpacman-contrib\b' <<<"$out" \
  || fail "pacman-contrib was not planned -- the update badge cannot count without it:\n$out"
# arch-update is what c7up shares its config and state directory with, and
# checkservices backs the post-update restart step. Both are AUR-only.
grep -qE 'from the AUR:.*\barch-update\b' <<<"$out" \
  || fail "arch-update was not planned from the AUR:\n$out"
grep -qE 'from the AUR:.*\bcheckservices\b' <<<"$out" \
  || fail "checkservices was not planned from the AUR:\n$out"
# ...but neither is worth failing an install over, so --no-aur still drops them
# and the repo half stays.
out=$(plan "$AMD" --no-aur)
grep -q '\barch-update\b' <<<"$out" && fail "--no-aur still planned arch-update:\n$out"
grep -q '\bpacman-contrib\b' <<<"$out" \
  || fail "--no-aur dropped pacman-contrib, which is a repo package:\n$out"

# --- opting out ------------------------------------------------------------
out=$(plan "$AMD" --no-greeter)
grep -q '\bgreetd\b' <<<"$out" && fail "--no-greeter still installed greetd:\n$out"
out=$(plan "$AMD" --no-extras)
grep -q '\bkitty\b' <<<"$out" && fail "--no-extras still installed kitty:\n$out"
out=$(plan "$AMD" --no-aur)
grep -q 'from the AUR' <<<"$out" && fail "--no-aur still planned AUR packages:\n$out"
out=$(plan "$AMD" --no-upgrade)
grep -q 'pacman -Syu' <<<"$out" && fail "--no-upgrade still upgraded:\n$out"
grep -q 'pacman -Sy\b' <<<"$out" && fail "--no-upgrade still refreshed the databases, a partial upgrade:\n$out"

# --- packages that are already there are not reinstalled ------------------
STUB_INSTALLED='linux kitty dolphin pipewire' out=$(plan "$AMD")
grep -qE 'pacman -S --needed .*\bkitty\b' <<<"$out" && fail "reinstalled a package that is present:\n$out"

# --- a package that no longer exists must not abort the whole install -----
STUB_UNKNOWN='breeze-icons' out=$(plan "$AMD")
grep -q 'not in the repos, skipping: breeze-icons' <<<"$out" || fail "an unknown package was not reported:\n$out"
grep -qE 'pacman -S --needed .*breeze-icons' <<<"$out" && fail "an unknown package was still passed to pacman:\n$out"

# --- without --yes, an answer of no changes nothing -----------------------
: > "$log"
out=$(env -i PATH="$bin" HOME="$tmp" USER=tester STUB_LOG="$log" STUB_LSPCI="$AMD" \
        STUB_INSTALLED=linux STUB_UNKNOWN= STUB_ENABLED= \
        /usr/bin/bash "$bootstrap" <<<'n' 2>&1) || true
grep -q 'aborted' <<<"$out" || fail "answering no did not abort:\n$out"
[[ ! -s $log ]] || fail "answering no still changed something:\n$(cat "$log")"

# --- and with --yes it goes ahead without asking --------------------------
: > "$log"
env -i PATH="$bin" HOME="$tmp" USER=tester STUB_LOG="$log" STUB_LSPCI="$AMD" \
  STUB_INSTALLED=linux STUB_UNKNOWN= STUB_ENABLED= \
  /usr/bin/bash "$bootstrap" --yes --no-aur </dev/null >/dev/null 2>&1 || true
grep -q 'pacman -Syu' "$log" || fail "--yes did not upgrade:\n$(cat "$log")"
grep -q 'systemctl enable' "$log" || fail "--yes did not enable the system units:\n$(cat "$log")"

# --- a helper that is installed but cannot run counts as no helper ---------
# paru links libalpm while asking only for `libalpm.so>=14`, so pacman leaves
# a paru in place that a pacman soname bump has already broken. Trusting the
# name alone would hand every AUR package to a binary that cannot start.
printf '#!/bin/sh\necho "paru: error while loading shared libraries: libalpm.so.15: cannot open shared object file: No such file or directory" >&2\nexit 127\n' > "$bin/paru"
chmod +x "$bin/paru"
out=$(plan "$AMD")
grep -q 'paru will be built' <<<"$out" || fail "a broken paru was treated as usable:\n$out"
grep -q 'does not run' <<<"$out" || fail "a broken paru was not reported:\n$out"
grep -q 'aur.archlinux.org/paru.git' <<<"$out" || fail "the source package is not what gets built:\n$out"
grep -q 'paru-bin' <<<"$out" && fail "paru-bin is prebuilt against one libalpm, it must not be used:\n$out"
working_paru
out=$(plan "$AMD")
grep -q 'already installed' <<<"$out" || fail "a working paru was rebuilt anyway:\n$out"

# --- the greeter -----------------------------------------------------------
# The greeter binary and its QML ship with the package; which greeter greetd
# runs is a write to /etc/greetd/config.toml, which only the bootstrap does.
greetd_conf='/etc/greetd/config.toml'

out=$(plan "$AMD")
grep -q "$greetd_conf" <<<"$out" || fail "the greetd config is not in the plan:\n$out"
grep -q 'c7shell-greeter' <<<"$out" || fail "the config does not run the c7shell greeter:\n$out"
# Without it the greeter's kernel/battery line is silently empty.
grep -q 'QML_XHR_ALLOW_FILE_READ=1' <<<"$out" \
  || fail "the config does not let the greeter read /proc:\n$out"
# cage is the compositor greetd runs the greeter inside; without it there is
# no login screen at all.
grep -q '\bcage\b' <<<"$out" || fail "cage is not in the plan:\n$out"
# The greeter redirects its stderr into /var/log/c7greeter.log as user
# `greeter`, and /var/log is root-owned -- so the file has to exist first.
# Without it the redirect fails before cage is exec'd, greetd sees a greeter
# that never created a session, and after five tries systemd gives up: a login
# screen that never draws, with the reason nowhere near the symptom.
# Match the install, not the path: the path also appears inside the config
# body as the redirect target, so grepping for it alone passes even with the
# creation removed -- which is exactly how this shipped broken the first time.
grep -qE 'would run \(root\): install .*/var/log/c7greeter.log' <<<"$out" \
  || fail "the greeter's log is not created, so greetd will not start:\n$out"
grep -qE 'would run \(root\): install .*-o greeter .*-g greeter .*/var/log/c7greeter.log' <<<"$out" \
  || fail "the greeter's log is not owned by greeter, so the redirect still fails:\n$out"

# --no-greeter-theme: greetd still installed and enabled, config left alone
out=$(plan "$AMD" --no-greeter-theme)
grep -q '\bgreetd\b' <<<"$out" || fail "--no-greeter-theme dropped greetd itself:\n$out"
grep -q "$greetd_conf" <<<"$out" && fail "--no-greeter-theme still wrote the config:\n$out"

# --no-greeter takes the config with it
out=$(plan "$AMD" --no-greeter)
grep -q "$greetd_conf" <<<"$out" && fail "--no-greeter still wrote the config:\n$out"

# Once greetd already runs our greeter there is nothing left to do
mkdir -p "$tmp/root/etc/greetd"
printf 'command = "cage -s -- /usr/bin/c7shell-greeter"\n' > "$tmp/root$greetd_conf"
out=$(plan "$AMD")
grep -q "$greetd_conf" <<<"$out" && fail "the config was rewritten when it was already correct:\n$out"
rm -rf "$tmp/root"

# Fingerprint: with fprintd installed, the vendor polkit service is copied to
# /etc with pam_fprintd in front of its first auth line -- and nothing happens
# without fprintd, with --no-fingerprint, or once the line is already there.
pam=/etc/pam.d/polkit-1
mkdir -p "$tmp/root/usr/lib/pam.d"
printf '#%%PAM-1.0\n\nauth       include      system-auth\naccount    include      system-auth\n' \
  > "$tmp/root/usr/lib/pam.d/polkit-1"
out=$(plan "$AMD")
grep -q "$pam" <<<"$out" && fail "polkit's PAM stack was planned without fprintd installed:\n$out"
out=$(STUB_INSTALLED='linux fprintd' plan "$AMD")
grep -q "$pam" <<<"$out" || fail "fprintd is installed but polkit's PAM stack is not planned:\n$out"
grep -A3 "would write .*$pam" <<<"$out" | grep -q 'sufficient.*pam_fprintd.so' \
  || fail "the planned polkit-1 does not offer pam_fprintd:\n$out"
grep -A4 "would write .*$pam" <<<"$out" | grep -q 'include.*system-auth' \
  || fail "the planned polkit-1 lost the password stack:\n$out"
out=$(STUB_INSTALLED='linux fprintd' plan "$AMD" --no-fingerprint)
grep -q "$pam" <<<"$out" && fail "--no-fingerprint still planned polkit's PAM stack:\n$out"
mkdir -p "$tmp/root/etc/pam.d"
printf 'auth sufficient pam_fprintd.so\n' > "$tmp/root$pam"
out=$(STUB_INSTALLED='linux fprintd' plan "$AMD")
grep -q "$pam" <<<"$out" && fail "polkit-1 was rewritten when it already offers pam_fprintd:\n$out"
rm -rf "$tmp/root"

# yes <extra env...> -- <args...>: a real (stubbed) run with --yes, log kept.
yes_run() {
  : > "$log"; rm -f "$log.synced"
  local envs=()
  while [[ $1 != -- ]]; do envs+=("$1"); shift; done; shift
  env -i PATH="$bin" HOME="$tmp" STUB_LOG="$log" STUB_LSPCI="$AMD" \
    STUB_INSTALLED=linux STUB_UNKNOWN= STUB_ENABLED= ${envs[@]+"${envs[@]}"} \
    /usr/bin/bash "$bootstrap" --yes "$@" </dev/null 2>&1
}

# The sections above export STUB_* values of their own; start these from a
# clean machine.
export STUB_INSTALLED=linux STUB_UNKNOWN= STUB_ENABLED= STUB_NETCTL=

# --- declining is not success ---------------------------------------------
# install.sh goes on to build and install the package when the bootstrap exits
# 0, so a "no" -- or no terminal to ask on -- has to reach it as a refusal.
rc=0
out=$(env -i PATH="$bin" HOME="$tmp" USER=tester STUB_LOG="$log" STUB_LSPCI="$AMD" \
        STUB_INSTALLED=linux /usr/bin/bash "$bootstrap" <<<'n' 2>&1) || rc=$?
((rc == 3)) || fail "answering no exited $rc, not 3:\n$out"
rc=0
out=$(env -i PATH="$bin" HOME="$tmp" USER=tester STUB_LOG="$log" STUB_LSPCI="$AMD" \
        STUB_INSTALLED=linux /usr/bin/bash "$bootstrap" </dev/null 2>&1) || rc=$?
((rc == 3)) || fail "nothing to answer from and no --yes exited $rc, not 3:\n$out"
grep -q -- '--yes' <<<"$out" || fail "no terminal to ask on, and no hint about --yes:\n$out"

# --- --no-upgrade means no sync at all --------------------------------------
# pacman -Sy then -S is a partial upgrade, which Arch does not support.
out=$(yes_run -- --no-upgrade --no-aur)
grep -qE 'pacman -Sy( |$)' "$log" && fail "--no-upgrade still refreshed the databases (a partial upgrade):\n$(cat "$log")"
grep -q 'pacman -Syu' "$log" && fail "--no-upgrade upgraded:\n$(cat "$log")"

# --- a package the stale databases did not know is checked again ------------
out=$(yes_run STUB_UNKNOWN=breeze-icons STUB_NEW_AFTER_SYNC=1 -- --no-aur)
grep -qE 'pacman -S --needed .*breeze-icons' "$log" \
  || fail "a package found after the refresh was still left out:\n$(cat "$log")\n$out"

# --- building paru needs git and base-devel ----------------------------------
rm -f "$bin/paru"
out=$(plan "$AMD")
installs "$out" | grep -q '\bgit\b' || fail "paru is built from git, but git is not in the plan:\n$out"
installs "$out" | grep -q '\bbase-devel\b' || fail "paru is built with makepkg, but base-devel is not in the plan:\n$out"
working_paru

# --- no user manager is not the end of the run ------------------------------
out=$(yes_run STUB_NO_USER_MANAGER=1 --)
grep -q '^paru ' "$log" || fail "a missing user manager stopped the run before the AUR step:\n$out"
grep -qi 'user services' <<<"$out" || fail "the skipped user units were not mentioned:\n$out"

# --- no USER in the environment ---------------------------------------------
rm -f "$bin/getent"; printf '#!/bin/sh\n[ "$1" = group ] && [ "$2" = rfkill ] && { echo rfkill:x:1:; exit 0; }; exit 2\n' > "$bin/getent"
printf '#!/bin/sh\ncase "$1" in -un) echo tester ;; -nG) echo tester ;; *) echo 1000 ;; esac\n' > "$bin/id.stub"
mv "$bin/id" "$bin/id.real"; mv "$bin/id.stub" "$bin/id"; chmod +x "$bin/getent" "$bin/id"
out=$(yes_run -- --no-aur)
grep -q 'gpasswd -a tester rfkill' "$log" || fail "with no USER set the group step failed:\n$out"
rm -f "$bin/getent" "$bin/id"; mv "$bin/id.real" "$bin/id"; ln -s "$(command -v getent)" "$bin/getent"

# --- another network daemon keeps NetworkManager off ------------------------
out=$(STUB_ENABLED=dhcpcd.service plan "$AMD")
grep -q 'enable: .*NetworkManager.service' <<<"$out" && fail "NetworkManager was enabled beside dhcpcd:\n$out"
out=$(STUB_NETCTL=1 plan "$AMD")
grep -q 'enable: .*NetworkManager.service' <<<"$out" && fail "NetworkManager was enabled beside a netctl profile:\n$out"

# --- DKMS gets headers for every installed kernel, not just the stock four ---
mkdir -p "$tmp/root/usr/lib/modules/6.17.1-cachyos"
echo linux-cachyos > "$tmp/root/usr/lib/modules/6.17.1-cachyos/pkgbase"
out=$(plan "$NVIDIA")
installs "$out" | grep -q '\blinux-cachyos-headers\b' || fail "a custom kernel got no headers for DKMS:\n$out"
rm -rf "$tmp/root"

# --- the tailscale operator -------------------------------------------------
# tailscaled authorises its local API by peer credentials and ships no polkit
# actions, so the shell's tailscale panel can change nothing until the desktop
# user is named its operator -- a privileged write, which is why it is here.
# Everything below answers out of a stub: no check may reach a real tailscaled
# or run a real `tailscale set`.

# No client on this machine: the operator step has nothing to ask and has to
# pass in silence rather than as a warning.
#
# It asserts on the operator, not on the word "tailscale". Whether the client
# is planned for installation is a packaging question that this step does not
# answer and must not be coupled to -- an assertion of silence about the whole
# subject breaks the moment tailscale becomes a depends=.
out=$(plan "$AMD")
grep -qi operator <<<"$out" && fail "no tailscale client here, yet the operator was touched:\n$out"
grep -qi 'naming the tailscale operator' <<<"$out" && fail "the operator step ran with no client installed:\n$out"

cat > "$bin/tailscale" <<'STUB'
#!/bin/sh
# The operator this stub reports is the one a previous `set` left behind, so
# two runs in a row see what a real machine would.
state=$STUB_LOG.operator
case "$1 $2" in
  'debug prefs')
    [ -n "$STUB_TS_DOWN" ] && { echo 'failed to connect to local tailscaled' >&2; exit 1; }
    op=$STUB_TS_OPERATOR
    [ -f "$state" ] && op=$(cat "$state")
    # OperatorUser is omitempty in tailscaled's prefs: unset is an absent key,
    # not an empty string.
    printf '{\n\t"WantRunning": true'
    [ -n "$op" ] && printf ',\n\t"OperatorUser": "%s"' "$op"
    printf '\n}\n' ;;
  *)
    echo "tailscale $*" >> "$STUB_LOG"
    case $2 in --operator=*) printf '%s\n' "${2#--operator=}" > "$state" ;; esac ;;
esac
STUB
chmod +x "$bin/tailscale"
# id -un is how the bootstrap works out who logs in, here and for the groups.
printf '#!/bin/sh\ncase "$1" in -un|-nG) echo tester ;; *) echo 1000 ;; esac\n' > "$bin/id.stub"
mv "$bin/id" "$bin/id.real"; mv "$bin/id.stub" "$bin/id"; chmod +x "$bin/id"

# A client with no daemon answering is the same no-op.
out=$(STUB_TS_DOWN=1 plan "$AMD")
grep -qi operator <<<"$out" && fail "tailscaled is not running, yet the operator was touched:\n$out"

# No operator yet: name the user who logs in -- and not $USER, which is root
# when the bootstrap is reached through sudo and would leave the desktop user
# exactly as locked out as it was.
rm -f "$log.operator"
out=$(env -i PATH="$bin" HOME="$tmp" USER=root C7SHELL_ROOT="$tmp/root" \
        STUB_LOG="$log" STUB_LSPCI="$AMD" STUB_INSTALLED=linux \
        STUB_UNKNOWN= STUB_ENABLED= STUB_TS_OPERATOR= STUB_TS_DOWN= \
        /usr/bin/bash "$bootstrap" --dry-run 2>&1)
grep -q 'operator=root' <<<"$out" && fail "USER=root made root the tailscale operator:\n$out"
grep -q 'would run (root): tailscale set --operator=tester' <<<"$out" \
  || fail "the desktop user was not named as the operator:\n$out"

# ...and it is asked AFTER the services step. Naming the operator is a question
# put to a running daemon, and on a first install tailscaled is started by that
# very step: asked before it, a fresh machine answers "no daemon", the operator
# stays unset, and the panel is read-only until this script is run again.
svc_at=$(grep -n '== enabling system services' <<<"$out" | head -1 | cut -d: -f1)
op_at=$(grep -n '== naming the tailscale operator' <<<"$out" | head -1 | cut -d: -f1)
[[ -n $svc_at && -n $op_at ]] \
  || fail "expected both the services step and the operator step in the plan:\n$out"
((svc_at < op_at)) \
  || fail "the operator was named at line $op_at, before the services step at line $svc_at -- on a first install tailscaled is not answering yet:\n$out"

# ...and a real (stubbed) run does it, once. The second run finds the operator
# already named and must not write, which is also what keeps it from prompting
# for a password on a machine that is already configured.
out=$(yes_run -- --no-aur --no-upgrade)
grep -q 'sudo tailscale set --operator=tester' "$log" \
  || fail "a machine with no operator did not get one:\n$(cat "$log")\n$out"
out=$(yes_run -- --no-aur --no-upgrade)
grep -q 'tailscale set' "$log" \
  && fail "the second run named the operator again:\n$(cat "$log")\n$out"
grep -q 'already the operator: tester' <<<"$out" || fail "the operator already in place was not reported:\n$out"

# Someone else's operator is their deliberate configuration, not ours to take.
rm -f "$log.operator"
out=$(yes_run STUB_TS_OPERATOR=other-user -- --no-aur --no-upgrade)
grep -q 'tailscale set' "$log" \
  && fail "another user's operator was overwritten:\n$(cat "$log")\n$out"
grep -q 'operator is "other-user", not you' <<<"$out" || fail "an operator set to someone else was not reported:\n$out"

rm -f "$bin/tailscale" "$bin/id" "$log.operator"; mv "$bin/id.real" "$bin/id"

echo 'PASS: c7shell-bootstrap'

