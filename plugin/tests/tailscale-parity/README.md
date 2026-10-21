# tailscale-parity

The Phase 2 harness of the Tailscale rewrite (epic #287, issue #306). It loads
a `C7` module headless through QML, points its `Tailscale` singleton at the
in-process fake tailscaled (`plugin/lib/testing/fake-tailscaled`) through
`TS_SOCKET`, and runs the scenario files under
`tests/fixtures/tailscale/scenarios/`. The plan is
`docs/superpowers/plans/2026-10-21-phase2-harness.md`.

Run every cargo command from `plugin/`: cargo reads `.cargo/config.toml` (the
target directory and the rust-lld pin) from the working directory. From the
root, `cargo --manifest-path plugin/Cargo.toml` misses both and builds into
`plugin/target`, which git ignores and `tests/test-c7-plugin.sh` skips, but
without rust-lld.

## Build the reference

```sh
plugin/tests/tailscale-parity/build-reference.sh
```

It builds #286's `C7` at `a38dbca` with #286's own CMake, from that commit's
`plugin/` tree extracted with `git archive` under
`${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference/`, and prints
the directory to pass as `C7_QML_DIR` as its last line. A second run rebuilds
nothing. `C7_REFERENCE_CACHE` moves the cache. It only reads the repository:
it registers no worktree and fetches nothing. When the commit is missing it
fails and names the `git fetch` to run.

An earlier version registered a git worktree at
`<cache>/<sha>/src`. That record in the shared repository's
`.git/worktrees/` is no longer used; `git worktree remove --force
<cache>/<sha>/src` drops it with the directory.

## The gate is manual for now

`run.sh` is not part of `for t in tests/*.sh`: the reference build is not
something the suite makes. `tests/test-tailscale-parity.sh` runs the
harness self-tests and the scenarios when the reference build is already in
the cache (or `C7_QML_DIR` names one), and skips with the reason when it is
not. The 50-run gate (`run.sh --repeat 50`) and the parallel stress are run
by hand until a later PR wires the reference build into the suite.

## Run

```sh
plugin/tests/tailscale-parity/run.sh               # every scenario once against cpp-286
plugin/tests/tailscale-parity/run.sh --repeat 50   # 50 consecutive runs of each

qml=$(plugin/tests/tailscale-parity/build-reference.sh | tail -1)
cd plugin
C7_IMPL=cpp-286 C7_QML_DIR=$qml cargo test --locked -p tailscale-parity --test harness_selftest
C7_IMPL=cpp-286 C7_QML_DIR=$qml C7_SCENARIOS=http-01-request-line-and-host \
  cargo test --locked -p tailscale-parity --test scenarios
```

- `C7_IMPL` names the implementation (`cpp-286` or `rust`), and so its
  capabilities. `C7_QML_DIR` is the directory holding `C7/qmldir`.
- `C7_SCENARIOS` is a comma-separated list of scenario ids to run.
- `C7_REPEAT` runs each scenario that many times, stopping at the first
  mismatch with the run number.

Each scenario runs in its own child process (a respawn of the test binary)
with a cleared environment: the keep-list of
`plugin/lib/testing/testmain.cpp`, a private `HOME`, `XDG_*`, `TMPDIR` and an
empty `PATH`, dead bus addresses, `QT_QPA_PLATFORM=offscreen`, and
`TS_SOCKET` in the private root, where the fake listens. Nothing reaches the
host's tailscaled or buses.

## How a scenario is checked

The child starts the fake with the scenario's rules, loads `qml/driver.qml`
(which touches `Tailscale` and so constructs it), runs the steps and prints
one `C7-SCENARIO-RESULT <json>` line. The parent compares it with the
scenario's `on.<implementation>` declaration:

- `pass` matches when every expectation holds;
- `fail` matches when exactly the declared expectations fail, with exactly
  the declared actual values;
- `cannot-run` matches when the implementation lacks a capability the
  scenario needs, without starting the child's application.

A wait that is never reached, an unknown member, a failed precondition, a
request no rule matched, a crash or a missing result line is an error, and an
error never matches a declaration. A `fix` scenario can therefore never "fail
as expected" by timing out.

## Add a scenario

Write `tests/fixtures/tailscale/scenarios/<id>.json` in the format of the
plan's "Scenario format", with every requirement it covers in
`tests/fixtures/tailscale/evidence.json`. `cargo test -p fake-tailscaled
--test scenario_format --test evidence` validates it without Qt. Then run it
with `run.sh` and commit it with the result it has on `cpp-286`.

## Add an implementation

Add its name and capabilities to `IMPLEMENTATIONS` in
`plugin/lib/testing/fake-tailscaled/src/scenario.rs`, and an `on.<name>`
declaration to every scenario. Phase 3 does this for `rust`.

## The bridge

Rust cannot read a QML singleton's members through cxx-qt-lib, so the crate
registers a static QML module `C7Harness` with one singleton, `Probe`
(`src/probe.rs`). Rust emits `Probe.command(json)`; the driver runs it against
`Tailscale` and calls `Probe.reply(json)` before the emit returns. The driver
names no member: it counts every `*Changed` signal it finds on `Tailscale`,
so the same driver serves #286's contract and the rewrite's.

No Quickshell code is copied or adapted here.
