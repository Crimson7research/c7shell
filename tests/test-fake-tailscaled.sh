#!/usr/bin/env bash
# The Cargo workspace in plugin/ keeps its layout, and the fake tailscaled's
# own tests pass. Run it directly: tests/test-fake-tailscaled.sh
#
# Checks, in order:
#   1. plugin/Cargo.toml declares a [workspace]
#   2. cargo, run from plugin/, puts its target directory at <repo>/target,
#      outside plugin/ (tests/test-c7-plugin.sh check 1 fails on any ignored
#      file under plugin/)
#   3. plugin/.cargo/config.toml pins rust-lld
#   4. git ignores /target/ and no file under plugin/
#   5. a workspace build leaves no plugin/target behind
#   6. the fake crate's tests pass
#   7. they pass 50 consecutive runs
# Skips, with the reason, when cargo is not on PATH, the rule
# tests/test-c7-plugin.sh applies to cmake.
set -euo pipefail
shopt -s inherit_errexit

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"

if ! command -v cargo >/dev/null; then
  echo 'SKIP: cargo is not on PATH (package: rust); the fake tailscaled is not built'
  exit 0
fi

plugin=$repo/plugin
mktmp
log=$tmp/log
# run_logged WHAT CMD... -- run CMD into $log; on failure show the log, then fail.
run_logged() {
  local what=$1
  shift
  "$@" >"$log" 2>&1 && return 0
  cat "$log" >&2
  fail "$what failed (log above)"
}
# in_plugin CMD... -- run CMD with plugin/ as its working directory. Cargo reads
# .cargo/config.toml and rustup reads rust-toolchain.toml from the working
# directory, not from --manifest-path.
in_plugin() { (cd "$plugin" && "$@"); }

# 1. the workspace -------------------------------------------------------------
[[ -f $plugin/Cargo.toml ]] || fail "plugin/Cargo.toml is missing"
grep -qE '^\[workspace\]' "$plugin/Cargo.toml" || fail "plugin/Cargo.toml declares no [workspace]"
echo "PASS: plugin/Cargo.toml is a workspace"

# 2. the target directory ------------------------------------------------------
run_logged 'cargo metadata' in_plugin cargo metadata --locked --format-version 1 --no-deps
# Cargo joins target-dir to plugin/ without normalising it (plugin/../target),
# so the path is resolved before it is compared.
target=$(grep -o '"target_directory":"[^"]*"' "$log" | sed 's/^"target_directory":"//; s/"$//')
[[ -n $target ]] || fail "cargo metadata reported no target_directory"
[[ $(realpath -m -- "$target") == "$repo/target" ]] \
  || fail "cargo's target directory is $target, not $repo/target"
echo "PASS: cargo builds into $repo/target"

# 3. the linker pin ------------------------------------------------------------
grep -qF 'link-arg=-fuse-ld=lld' "$plugin/.cargo/config.toml" 2>/dev/null \
  || fail "plugin/.cargo/config.toml does not pin rust-lld (-fuse-ld=lld)"
echo "PASS: rust-lld is pinned"

# 4. ignore rules --------------------------------------------------------------
# ignored PATH... -- print the paths the repository's own rules ignore, with
# host git config shut out, as tests/test-c7-plugin.sh does.
ignored() {
  local rc=0
  printf '%s\n' "$@" \
    | GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      git -C "$repo" check-ignore --no-index --stdin || rc=$?
  ((rc <= 1)) || fail "git check-ignore exited $rc in $repo"
}
[[ -n $(ignored target/x) ]] || fail "git does not ignore /target/, cargo's target directory"
files=$(cd "$repo" && find plugin -type f)
mapfile -t files <<<"$files"
hits=$(ignored "${files[@]}")
[[ -z $hits ]] || fail "git ignores files under plugin/:\n$hits"
echo "PASS: /target/ is ignored, no file under plugin/ is"

# 5. no target directory inside plugin/ ----------------------------------------
run_logged 'cargo build' in_plugin cargo build --locked
[[ ! -e $plugin/target ]] || fail "a cargo build created plugin/target"
echo "PASS: a build leaves no plugin/target"

# 6. the fake's tests ----------------------------------------------------------
run_logged 'the fake tailscaled tests' in_plugin cargo test --locked -p fake-tailscaled
echo "PASS: the fake tailscaled's tests pass"

# 7. 50 consecutive runs -------------------------------------------------------
# Every Tailscale characterisation stands on the fake, so a flaky fake makes
# them all flaky. Built once, then run 50 times; the first failure stops it.
run_logged 'build the fake tailscaled tests' in_plugin cargo test --locked --no-run -p fake-tailscaled
for run in $(seq 1 50); do
  run_logged "the fake tailscaled tests, run $run of 50" in_plugin cargo test --locked -q -p fake-tailscaled
done
echo "PASS: the fake tailscaled's tests pass 50 consecutive runs"
