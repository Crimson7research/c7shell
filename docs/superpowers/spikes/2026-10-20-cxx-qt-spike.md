# Spike report: cxx-qt for the C7 plugin (#288)

Part of epic #287. The plan is
`docs/superpowers/plans/2026-10-19-tailscale-rust-rewrite.md`.

cxx-qt 0.10 can carry the C7 plugin with no hand-written C++ and no CMake.
Fourteen of the fifteen checks pass. One failed: GNU ld cannot link the
plugin, so the build pins rust-lld.

The spike code is throwaway and never merges. It lives on branch
`spike/cxx-qt-288`, in `spike/cxx-qt/`. Its `README.md` says how to run each
check.

Host: Arch, Qt 6.12.0, cxx-qt 0.10.0, cargo 1.94.0.

## Results

Every pass below except 1b and 4b also passed 50 consecutive runs. A
separate review agent re-ran each one, read the code, and tried to refute it;
none was refuted. Checks 1b and 4b are manual procedures, run once each in
the test VM (see below).

| # | Check | Result |
|---|---|---|
| 1a | Cargo alone builds a QML module (`qmldir`, `.qmltypes`, one `.so`) that a QQmlEngine loads from its import path, and the load fails without it | Pass |
| 1b | Quickshell loads the module from its import path, as a plugin, not through Qt's linked-library fallback | Pass, in the test VM |
| 2 | A `#[qml_singleton]` and a `#[base = QAbstractListModel]` keep stable rows: insert, `dataChanged` and remove, never a reset, the same delegate objects | Pass |
| 3 | `cargo llvm-cov` measures the Rust behind the bridge when QML drives it | Pass, with the caveat below |
| 4a | tokio shuts down on destruction: 20 simulated reloads with callbacks in flight, no leaked thread, no late callback, no hang | Pass |
| 4b | The same under 20 real Quickshell reloads, soft and hard | Pass, in the test VM |
| 5 | A Rust test binary renders QML headless (`QT_QPA_PLATFORM=offscreen`) | Pass |
| 6 | That binary loads the C++ #286 `C7` plugin, alone and beside the Rust module in one engine | Pass |
| 7a | A singleton whose QML name differs from its Rust type (`QML_NAMED_ELEMENT`) | Pass |
| 7b | A `Q_ENUM` on the singleton, used as a property type | Pass |
| 7c | Models the singleton owns, exposed as `CONSTANT` properties, freed exactly once across reloads | Pass |
| 7d | `QDateTime` and `QStringList` properties | Pass |
| 7e | Two properties sharing one `NOTIFY`, and a signal derived from two other changes | Pass |
| 7f | The singleton delegates to a backend trait object, real or fake, chosen without C++ | Pass |
| 8 | One plugin-export mechanism that links with GNU ld, gold and lld | Fail |

Checks 7a to 7f cover the parts of #286's `TailscaleBackend.h` that checks 1
to 6 did not use.

## Findings that change the plan

- **The linker is pinned to rust-lld (check 8).** A Rust `cdylib` hides
  Qt's plugin entry points, `qt_plugin_instance` and
  `qt_plugin_query_metadata_v2`. A second linker version script exports
  them. GNU ld rejects it:

  ```
  /usr/bin/ld.bfd: anonymous version tag cannot be combined with other version tags
  ```

  `--dynamic-list` and `--export-dynamic-symbol` link, but export nothing.
  gold and rust-lld both work. The repository owner chose rust-lld on
  2026-10-20: `.cargo/config.toml` passes `-C link-arg=-fuse-ld=lld`, which
  resolves to the rust-lld that rustup ships. makepkg's `RUSTFLAGS` replaces
  that config, so `PKGBUILD` must append the same flag.
- **A missing export passes silently.** Without the entry points, Qt logs
  `Could not resolve 'qt_plugin_instance' function` and falls back to the
  library it already loaded, so check 1a still passes. The plugin's tests must
  assert that `nm -D` lists both symbols and that Qt reports
  `module "C7Spike" provided by plugin`, as check 8 does.
- **Branch coverage needs nightly (check 3).** Stable 1.94 rejects
  `--branch`: `the option `Z` is only accepted on the nightly compiler`.
  Line and region coverage work on stable. The repository owner chose on
  2026-10-20 to run only the coverage gate on a pinned, dated nightly.
- **Coverage needs its own staging.** The tests load the plugin through the
  import path, so plain `cargo llvm-cov` cannot see it. The spike's
  `coverage.sh` builds an instrumented plugin, stages it, runs the QML tests
  against it and then reports. Stable and nightly need separate target
  directories, or the report is corrupt.
- **Keep the bridge module declaration-only.** On nightly, cxx-qt thunks map
  to the bridge file. With all logic in plain modules beside it, the report
  excludes one file and counts only our code.
- **cxx-qt idioms the contracts need:**
  - A custom `NOTIFY = x` must name a signal declared with `#[qsignal]`.
  - A model property needs a custom `READ` that returns `*mut T`. Its type is
    the concrete model, not `QAbstractItemModel*`; QML treats both alike.
  - A model reaches `set_parent` only with `#[base = QObject]` on the
    `QAbstractListModel` extern type.
  - A snake_case Rust method or property needs `#[cxx_name]` or
    `cxx_name = "..."` for its camelCase QML name.
- **Test harness details.** QML `console` output reaches stderr only with
  `QT_FORCE_STDERR_LOGGING=1`. A test that feeds data before the offscreen
  window shows its first frame can find no delegate, so feeding waits for
  `frameSwapped`.

## Checks 1b and 4b in the test VM

They ran on 2026-10-20 in a VM booted from the VM setup test's base image
(`docs/vm-setup-test-operations.md`), after `pacman -Syu quickshell rustup
clang`: Quickshell 0.3.2, Qt 6.12.0, Rust 1.99.1. The spike was built there
with `cargo stage`, linked by `LLD 23.1.1`, and `nm -D` listed both entry
points. `qs` ran with `QT_QPA_PLATFORM=offscreen`, since the base image has
no Wayland session. Neither check opens a window.

- **1b.** `QML_IMPORT_PATH=$PWD/target/qml qs -p quickshell/load/shell.qml`,
  with `QT_LOGGING_RULES=qt.qml.import=true`, logged:

  ```
  qt.qml.import: module "C7Spike" provided by plugin "/home/c7test/s/spike/cxx-qt/target/qml/C7Spike/libC7Spike.so"
  qml: C7SPIKE 1b loaded, state=idle
  qml: C7SPIKE 1b PASS counter=1 state=a=1,b=0 rows=2
  ```

  `qs` then exited 0 by itself.
- **4b.** `quickshell/reload/shell.qml` ran once with `Quickshell.reload(false)`
  and once with `reload(true)`. Each run printed 21 generations and
  `C7SPIKE 4b PASS after 20 reloads`, and `qs` exited 0. In both runs every
  generation after the first reported `live=1 tokioThreads=1 threads=5
  late=0`; the first reported `threads=4`. The thread count stays flat, and
  no callback ran after its singleton was gone.

The full c7shell install in the VM failed first, for an unrelated reason:
the base image's package database is stale, and `install.sh` runs
`pacman -S` without `-y`, so pacman fetched `pkgconf-3.0.7-1` and every
mirror answered 404.

## To finish Phase 0

Merge the rule change in `docs/architecture.md` and `CLAUDE.md`.
