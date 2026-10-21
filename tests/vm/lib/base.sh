#!/usr/bin/env bash
# The base image's cache key. Sourced, not executed.
#
# build-base.sh stores the key beside base.qcow2, and run.sh rebuilds the base
# when the key it computes no longer matches. Every input that decides what
# the base contains is in it: the pinned ISO version, the archinstall config,
# the cloud-init seed, build-base.sh itself, and the host firmware it boots.
# The ISO itself is not hashed: its version pins it, and fetch_iso verifies
# a fresh download.

# base_inputs_hash <vm-dir> -- the sha256 of those inputs. Fails when one is
# missing, the firmware included, rather than keying on its absence.
base_inputs_hash() {
  local vm=$1 sums
  sums=$(cd -- "$vm" && sha256sum -- iso.version archinstall.json \
           cloud-init/user-data.in cloud-init/meta-data build-base.sh) || return
  sums+=$'\n'$(sha256sum -- "$(vm_ovmf)") || return
  sha256sum <<<"$sums" | cut -d' ' -f1
}
