#!/usr/bin/env bash
# Build and install the c7shell package.
#
# makepkg refuses to start when the base-devel build tools are absent
# ("Cannot find the fakeroot binary", "Cannot find the debugedit binary"),
# and it aborts before the PKGBUILD is ever read -- so the PKGBUILD itself
# cannot pull them in. This wrapper installs them first, then runs makepkg.
#
# On a bare Arch install there is more missing than build tools -- no GPU
# driver, no greeter, no pipewire, no fonts, no enabled services -- so it also
# runs c7shell-bootstrap, which puts that in place before the package is built.
#
# Afterwards it runs c7shell-doctor, which checks the things pacman cannot:
# the Hyprland version (the config is lua, 0.56+), the QML modules quickshell
# was built with, the GPU device, the appmenu daemon's python modules and
# whether the configs have reached ~/.config yet.
set -euo pipefail

# One representative command per base-devel package makepkg insists on.
# debugedit only ships in its own package, which is why a machine that has
# an older base-devel installed can still be missing it.
declare -A tools=(
  [fakeroot]=fakeroot
  [debugedit]=debugedit
  [make]=make
  [gcc]=gcc
  [patch]=patch
  [bsdtar]=libarchive
  [pkg-config]=pkgconf
)

usage() {
  cat <<USAGE
usage: ./install.sh [options] [makepkg options...]

Takes a bare Arch install to a working c7shell session:
  1. installs the base-devel tools makepkg needs (fakeroot, debugedit, ...)
  2. runs c7shell-bootstrap: GPU driver, SDDM, pipewire, fonts, services
  3. runs makepkg -sif to build and install the package
  4. runs c7shell-doctor to check the result and offer the optional programs

options (everything else is passed straight to makepkg):
  -n, --dry-run       show the bootstrap plan and stop, changing nothing
  -y, --yes           don't ask: applies the bootstrap plan, and every pacman
                      call (base-devel and the bootstrap's) runs without a prompt
      --no-bootstrap  skip step 2 entirely (already-configured machine)
  -h, --help          this text

env: C7SHELL_SKIP_DEPS=1    don't touch base-devel, just run makepkg
     C7SHELL_SKIP_DOCTOR=1  don't run the post-install c7shell-doctor check
     C7SHELL_SKIP_OPTIONAL=1  don't offer the optional packages
     C7SHELL_SKIP_BOOTSTRAP=1 same as --no-bootstrap
     C7SHELL_BRANCH=<name>  build that branch instead of main (makepkg clones
                            the branch, not the working tree you run this in)
USAGE
}

bootstrap_args=()
makepkg_args=()
# --yes means no prompt anywhere, including the base-devel install below,
# which runs before makepkg and so never sees makepkg's --noconfirm.
pacman_args=()
skip_bootstrap=${C7SHELL_SKIP_BOOTSTRAP:+1}
dry=0

while (($#)); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    -n|--dry-run) dry=1; bootstrap_args+=(--dry-run) ;;
    -y|--yes) bootstrap_args+=(--yes --noconfirm-pacman); pacman_args+=(--noconfirm) ;;
    --no-bootstrap) skip_bootstrap=1 ;;
    *) makepkg_args+=("$1") ;;
  esac
  shift
done

command -v makepkg >/dev/null || {
  echo "install.sh: no makepkg found -- this package builds on Arch-based systems only" >&2
  exit 1
}

if ((EUID == 0)); then
  echo "install.sh: run this as your own user; makepkg refuses to run as root" >&2
  exit 2
fi

as_root() {
  if command -v sudo >/dev/null; then sudo "$@"
  elif command -v doas >/dev/null; then doas "$@"
  else
    printf 'install.sh: need root to install %s, but neither sudo nor doas is present.\n' "$*" >&2
    printf '           run as root:  pacman -S --needed base-devel\n' >&2
    exit 1
  fi
}

if [[ -z ${C7SHELL_SKIP_DEPS:-} ]]; then
  missing=()
  for cmd in "${!tools[@]}"; do
    command -v "$cmd" >/dev/null || missing+=("${tools[$cmd]}")
  done

  if ((${#missing[@]})) && ((dry)); then
    # --dry-run changes nothing, base-devel included.
    printf 'missing build tools: %s\n' "${missing[*]}"
    printf '  would: pacman -S --needed base-devel %s\n' "${missing[*]}"
  elif ((${#missing[@]})); then
    printf 'missing build tools: %s\n' "${missing[*]}"
    echo 'installing base-devel (makepkg needs it before it will run)...'
    as_root pacman -S --needed ${pacman_args[@]+"${pacman_args[@]}"} base-devel
    # base-devel is a package group; on an incomplete install pacman may have
    # left the specific packages out, so name them explicitly as well.
    as_root pacman -S --needed ${pacman_args[@]+"${pacman_args[@]}"} -- "${missing[@]}"
  fi

  ((dry)) || for cmd in "${!tools[@]}"; do
    command -v "$cmd" >/dev/null || {
      printf 'install.sh: %s is still missing after installing base-devel\n' "$cmd" >&2
      exit 1
    }
  done
fi

if [[ -z ${skip_bootstrap:-} ]]; then
  # The checkout's own bootstrap first: an older one installed in /usr/bin
  # would ignore a fix in this tree, and may not know the flags passed below.
  bootstrap=${C7SHELL_BOOTSTRAP:-$(dirname -- "$0")/bin/c7shell-bootstrap}
  [[ -x $bootstrap ]] || bootstrap=$(command -v c7shell-bootstrap) \
    || { echo 'install.sh: no c7shell-bootstrap, neither in this checkout nor on PATH' >&2; exit 1; }
  rc=0
  "$bootstrap" ${bootstrap_args[@]+"${bootstrap_args[@]}"} || rc=$?
  # 3 is a declined plan: stop here rather than build a package for a machine
  # that has no driver, greeter or pipewire.
  if ((rc == 3)); then
    echo 'install.sh: the bootstrap plan was declined; nothing was built or installed.'
    exit 3
  fi
  ((rc == 0)) || exit "$rc"
  if ((dry)); then
    echo
    echo '--dry-run: stopping before makepkg. Re-run without --dry-run to apply.'
    exit 0
  fi
fi

# -f, always: makepkg does not build at all when a tarball for the pkgver it
# computes is already sitting in this directory -- it prints "A package has
# already been built, installing existing package..." and hands that file to
# pacman. Because the PKGBUILD sources a git branch and pkgver() bakes the
# commit into the version, the file it finds is often one an interrupted build
# left half-written, and pacman rejects it ("missing package metadata ...
# invalid or corrupted package") on every subsequent run, because the broken
# file keeps matching. Deciding whether a rebuild is worth doing belongs to
# c7shell-upgrade, which compares the installed commit against the branch --
# never to whatever happens to be lying in the build directory.
makepkg -sif ${makepkg_args[@]+"${makepkg_args[@]}"}

if [[ -z ${C7SHELL_SKIP_DOCTOR:-} ]]; then
  # Prefer the copy that was just installed; fall back to the tree we are in
  # so this still works when makepkg only built a package (e.g. with -f, no -i).
  doctor=$(command -v c7shell-doctor || echo "$(dirname -- "$0")/bin/c7shell-doctor")
  echo
  echo 'checking the runtime requirements...'
  # --optional lists the optional packages that are absent and lets you pick
  # which to add; it installs nothing unless you choose it, and says so and
  # moves on when there is no terminal to ask on.
  offer=()
  if [[ -z ${C7SHELL_SKIP_OPTIONAL:-} ]]; then offer=(--optional); fi
  # A missing requirement is worth a non-zero exit, but the package did build
  # and install -- say so rather than looking like the build failed.
  "$doctor" --setup-pending ${offer[@]+"${offer[@]}"} || {
    echo
    echo 'install.sh: the package installed, but the checks above did not all pass.' >&2
    exit 1
  }
fi

cat <<'MSG'

Next: copy the configs into your home directory (as your own user, not root):

    c7shell-setup

Then log out and pick the "c7shell" session, or run start-hyprland from a TTY.
Re-run c7shell-doctor at any time to re-check the requirements.
MSG
