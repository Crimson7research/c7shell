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
#   4. git ignores /target/ and /plugin/target/ (where cargo builds when run
#      from the root with --manifest-path), and no other file under plugin/
#   5. a build of the whole workspace, every target, leaves no plugin/target
#      behind
#   5b. the same build passes under makepkg's environment: RUSTFLAGS set,
#      which replaces .cargo/config.toml's rustflags and with them the rust-lld
#      pin, and -flto=auto in CFLAGS, CXXFLAGS and LDFLAGS, which makes GCC
#      write cxx-qt's C++ as LTO objects ld.lld cannot read. PKGBUILD check()
#      runs this suite in exactly that environment.
#   6. the fake crate's tests pass
#   7. they pass 50 consecutive runs
# Skips, with the reason, when cargo is not on PATH.
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
# makepkg check() sets RUSTFLAGS and LTO flags the workspace cannot link with.
# shellcheck source=fixtures/cargo-env.sh
. "$repo/tests/fixtures/cargo-env.sh"
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
[[ -n $(ignored plugin/target/x) ]] \
  || fail "git does not ignore /plugin/target/, where cargo --manifest-path from the root builds"
files=$(cd "$repo" && find plugin -path plugin/target -prune -o -type f -print)
mapfile -t files <<<"$files"
hits=$(ignored "${files[@]}")
[[ -z $hits ]] || fail "git ignores files under plugin/:\n$hits"
echo "PASS: /target/ and /plugin/target/ are ignored, no other file under plugin/ is"

# 5. no target directory inside plugin/ ----------------------------------------
# The whole workspace and every target, so the parity harness, its tests and
# its scenarios runner compile here even where the reference build is absent.
run_logged 'cargo build' in_plugin cargo build --locked --workspace --all-targets
[[ ! -e $plugin/target ]] || fail "a cargo build created plugin/target"
echo "PASS: a build of the whole workspace leaves no plugin/target"

# 5b. the same build under makepkg's environment -------------------------------
# The values of /etc/makepkg.conf and /etc/makepkg.conf.d/rust.conf on Arch.
# Its own target directory, so a changed RUSTFLAGS does not rebuild the main
# one each run.
makepkg_env=(
  RUSTFLAGS='-C force-frame-pointers=yes'
  CFLAGS='-march=x86-64 -O2 -pipe -fno-plt -flto=auto'
  CXXFLAGS='-march=x86-64 -O2 -pipe -fno-plt -flto=auto -Wp,-D_GLIBCXX_ASSERTIONS'
  LDFLAGS='-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now -flto=auto'
  CARGO_TARGET_DIR="$repo/target/makepkg"
)
run_logged "cargo build under makepkg's environment" \
  env "${makepkg_env[@]}" bash -c '. "$1" && cd "$2" && cargo build --locked --workspace --all-targets' \
  _ "$repo/tests/fixtures/cargo-env.sh" "$plugin"
echo "PASS: the workspace builds under makepkg's RUSTFLAGS and LTO flags"

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
