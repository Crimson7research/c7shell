#!/usr/bin/env bash
# The base image's cache key. Sourced, not executed.
#
# build-base.sh stores the key beside base.qcow2, and run.sh rebuilds the base
# when the key it computes no longer matches. The key covers every checked-in
# input that decides what the base contains -- the pinned ISO version, the
# archinstall config, the cloud-init seed, build-base.sh itself -- and the host
# firmware it boots. Left out: the ISO's bytes, which its version pins and
# fetch_iso verifies on download, and the SSH key and password that
# build-base.sh generates into the cache, which are not checked in.

# base_inputs_hash <vm-dir> -- the sha256 of those inputs. Fails when one is
# missing, the firmware included, rather than keying on its absence. The
# firmware is hashed by content, so another path to the same file is no change.
base_inputs_hash() {
  local vm=$1 sums
  sums=$(cd -- "$vm" && sha256sum -- iso.version archinstall.json \
           cloud-init/user-data.in cloud-init/meta-data build-base.sh) || return
  sums+=$'\n'$(sha256sum < "$(vm_ovmf)") || return
  sha256sum <<<"$sums" | cut -d' ' -f1
}

# base_stamp <vm-dir> <key> -- record what the base in $C7VT_CACHE was built
# from. The iso.version and archinstall.json copies are the stamps run.sh
# compared before #271; a checkout from before then still reads them, and so
# reuses this base instead of rebuilding it.
base_stamp() {
  echo "$2" > "$C7VT_CACHE/base.inputs"
  cp "$1/iso.version" "$C7VT_CACHE/base.iso.version"
  cp "$1/archinstall.json" "$C7VT_CACHE/base.archinstall.json"
}

# base_current <vm-dir> -- whether base.qcow2 was built from the inputs in
# <vm-dir>. A base.qcow2 newer than its key was rebuilt by a checkout from
# before #271, which writes no key, so the key no longer describes it.
# Exit 0 current, 1 stale, 2 when the inputs cannot be hashed.
base_current() {
  local key base=$C7VT_CACHE/base.qcow2 stamp=$C7VT_CACHE/base.inputs
  key=$(base_inputs_hash "$1") || return 2
  [[ -f $base && $stamp -nt $base && $(cat "$stamp") == "$key" ]]
}
