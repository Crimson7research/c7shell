# cxx-qt spike (#288)

Throwaway code. It checks that a Rust-only, Cargo-only QML module can stand in
for the C++ Tailscale backend (epic #287) on this host: Qt 6.12, cxx-qt 0.10,
cargo 1.94. Nothing here is hand-written C++, and there is no CMake. All the
C++ comes from `cxx-qt-build` and lands in `target/`.

## Layout

| Path | What it is |
|---|---|
| `c7spike/` | The plugin crate (`cdylib`). URI `C7Spike`: the `Spike` singleton (`#[qml_singleton]`) and the `PeerModel` list model (`#[base = QAbstractListModel]`). |
| `c7spike/src/peers.rs` | Pure logic: it parses `a=1,b=0` and diffs two peer lists into row operations. Unit-tested without Qt. |
| `c7spike/src/peer_model.rs` | Applies the diff with `beginInsertRows`, `beginRemoveRows` and `dataChanged`. It never calls `beginResetModel`. |
| `c7spike/src/spike.rs` | The singleton. It owns a tokio runtime with one worker thread, named `c7spike-tokio`. A task reads lines from a Unix socket and sends the results back to the Qt thread with `CxxQtThread::queue`. `Drop` shuts the runtime down. |
| `c7spike/src/contract.rs` | Round 2: the `Contract` singleton (Rust type `ContractObject`). It exercises the Qt features of #286's `TailscaleBackend` contract (checks 7a to 7f). |
| `c7spike/src/backend.rs` | The `ContractBackend` trait, the real `TokioBackend` (socket + tokio task, thread `c7contract-rt`) and the `FakeBackend` (no threads). `C7SPIKE_CONTRACT_BACKEND=fake` selects the fake when the singleton is constructed. |
| `c7spike/src/snapshot.rs` | Pure logic: parses one `key=value;...` snapshot line and computes `exitNodeBlocked`. Unit-tested without Qt. |
| `c7spike/build.rs` | `CxxQtBuilder` with `QmlModule::plugin_type(PluginType::Dynamic)`, plus one linker version script (see "The one trick" below). |
| `.cargo/config.toml` | The `cargo stage` alias, and the rust-lld linker pin (check 8). |
| `xtask/` | `cargo stage`: builds the cdylib and lays out `target/qml/C7Spike/` the way a system QML module is installed. |
| `spike-tests/` | A separate crate that does **not** depend on `c7spike`. It finds the module only through the QML import path. Each check is its own process (`harness = false`), so `QGuiApplication` lives on the main thread. |
| `quickshell/` | The `shell.qml` files a person runs once Quickshell is installed (checks 1b and 4b). |

## Build and run

```sh
cd spike/cxx-qt
cargo stage                 # -> target/qml/C7Spike/{qmldir,plugin.qmltypes,libC7Spike.so}
cargo test                  # unit tests + checks 1a, 2, 4a, 5, 7a-7f, 8
```

Run `cargo stage` again after any change to `c7spike/`. The tests load the
staged `.so`, not the copy that `cargo test` rebuilds. If the module is
somewhere else, set `C7SPIKE_QML_DIR=/path/containing/C7Spike` to point the
tests at it.

You can run a single check like this:

```sh
cargo test -p spike-tests --test check1a_load
cargo test -p spike-tests --test check2_stable_rows
cargo test -p spike-tests --test check4a_shutdown
cargo test -p spike-tests --test check5_headless
cargo test -p spike-tests --test check7a_named_singleton
cargo test -p spike-tests --test check7b_enum
cargo test -p spike-tests --test check7c_owned_model
cargo test -p spike-tests --test check7c_lifetime
cargo test -p spike-tests --test check7d_types
cargo test -p spike-tests --test check7e_shared_notify
cargo test -p spike-tests --test check7f_backend_swap
cargo test -p spike-tests --test check8_plugin_entry
cargo test -p c7spike                       # 7 pure-Rust unit tests (diff, parser, tokio paused time)
```

Check 6 loads the C++ #286 `C7` module (a parity baseline) next to `C7Spike`.
Build #286 with its own CMake, outside this spike, and point the test at it.
Without `C7_286_QML_DIR` it prints a SKIP reason and exits 0:

```sh
cmake -S <c7shell-286>/plugin -B <build-286> && cmake --build <build-286> -j
C7_286_QML_DIR=<build-286>/qml cargo test -p spike-tests --test check6_parity_286
```

The test sets `TS_SOCKET` to a path nothing listens on, the same isolation
#286's `C7_TEST_MAIN` uses, so no real tailscaled is reached.

To run each check 50 times in a row:

```sh
for t in check1a_load check2_stable_rows check4a_shutdown check5_headless; do
  p=0; for i in $(seq 1 50); do timeout 120 cargo test -q -p spike-tests --test $t >/dev/null 2>&1 && p=$((p+1)); done
  echo "$t: $p/50"
done
```

You can also check it with Qt's own tool, without the Rust harness:
`QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qml -I target/qml some.qml`.

## How the checks work

The tests never sleep. Each wait is a loop of non-blocking `processEvents()`
calls, capped at `MAX_ITERATIONS`. The QML under test makes its own
assertions. It prints `ok`/`FAIL` lines and calls `Qt.exit(failures)`. The
Rust side picks that code up from `QQmlEngine::exit`, and a load error shows
up as `objectCreationFailed`. QML `console.*` output only reaches stderr
because the harness sets `QT_FORCE_STDERR_LOGGING=1`. Without it, Qt on this
host logs to journald.

- **1a** `check1a_load`
  - It asserts that the staged directory holds exactly `qmldir`, one
    `.qmltypes` and one `.so`.
  - It copies that directory to `target/tmp/`, then removes the copy and
    loads `load.qml`. The load must fail with `module "C7Spike" is not
    installed`. This negative case runs before the plugin has ever been
    loaded into the process.
  - It restores the copy and loads `load.qml` again. This time
    `import C7Spike` must resolve and the singleton checks must pass:
    - the read-only `state` and `counter` properties and their NOTIFY signals;
    - the `feed()` Q_INVOKABLE;
    - a round trip through tokio.
  - It asserts that no other import path in the engine contains `C7Spike`.
  - It does **not** prove that Qt used the plugin entry points. A library
    that exports neither still passes, through Qt's "linked library"
    fallback. Check 8 covers that.
- **2** `check2_stable_rows` (`rows.qml`)
  - A `ListView` sits on a `PeerModel`. Every update takes the real path:
    `Spike.feed` → socket → tokio → `queue` → diff.
  - The first feed waits for the window's first `frameSwapped`. Without that
    gate, 1 run in about 119 got a null delegate: tokio answered before the
    offscreen window was exposed.
  - After each update the test asserts the exact model signal sequence and
    that no `modelAboutToBeReset`/`modelReset` fired.
  - Updates and the expected result of each:

    | Update | Model signals | Delegate assertions |
    |---|---|---|
    | `a` → `a,b` | `rowsInserted(1,1)` only | the delegate object for `a` is identical (`===`) and was never destroyed |
    | `a` online → offline | `dataChanged(0,0)` | same delegate for `a`, which now shows `online=false` |
    | remove `a` | `rowsRemoved(0,0)` | the delegate for `b` survives |
- **4a** `check4a_shutdown` (`stress.qml`, `final.qml`)
  - It simulates a Quickshell reload 20 times in one process: create an
    engine, load, feed 50 lines, then destroy the engine as soon as the first
    callback has run, so the other callbacks are still in flight.
  - Per cycle, it reads `/proc/self/task/*/comm` and asserts:
    - one `c7spike-tokio` thread while the engine is alive;
    - none after the drop;
    - the drop takes less than 5 s.
  - It asserts that the total thread count never grows past the count after
    the first reload.
  - A last engine then reads the process-wide counters that the plugin library
    keeps. The library stays loaded between engines. The checks:
    - `lateCallbacks == 0`: no callback ran after its singleton was destroyed;
    - exactly one live runtime;
    - every callback attempt either ran or was dropped without running, so
      none leaked;
    - at least one posted callback was discarded at destruction, which shows
      the race actually happened.
- **5** `check5_headless` (`headless.qml`)
  - `headless_app()` sets `QT_QPA_PLATFORM=offscreen` before it constructs
    `QGuiApplication`.
  - A `Window` with a `ListView` over `PeerModel` has to render two frames
    (`frameSwapped`). The test asserts that:
    - `Qt.platform.pluginName == "offscreen"`;
    - a scene graph API is active (it reports `GraphicsInfo.api == 1`,
      Software, the scene graph's software adaptation);
    - the delegate for the third row exists.

## Round 2: the #286 contract's Qt features (checks 7a to 7f)

#286's `TailscaleBackend.h` uses Qt features that round 1 did not touch. The
`Contract` singleton in `contract.rs` uses each of them, through cxx-qt
attributes only. All QML assertions run in a `StepRunner` (`qml/StepRunner.qml`).
Each step does three things:

1. It feeds one snapshot line to `Contract.feed()`, which hands it to the
   selected backend (tokio by default).
2. It waits for `revisionChanged`, which the singleton emits last after it
   applies a snapshot.
3. It runs that step's checks.

There are no timers.

| Check | How cxx-qt expresses it | What the QML asserts |
|---|---|---|
| **7a** `check7a_named_singleton` (`contract_named.qml`) | `#[qml_element = "Contract"] #[qml_singleton]` on `type ContractObject`. It generates `QML_NAMED_ELEMENT(Contract)` + `QML_SINGLETON` | `Contract` resolves to the singleton. `ContractObject` is not a QML name. The object's class is `ContractObject`. A second object sees the same instance. The Rust side also asserts that qmltypes exports `C7Spike/Contract 1.0` for `ContractObject`. |
| **7b** `check7b_enum` (`contract_enum.qml`) | `#[qenum(ContractObject)] enum State {...}`. It generates `enum class State` + `Q_ENUM(State)` inside the class. Property: `#[qproperty(State, state, READ, NOTIFY)]` | `Contract.NoState`..`Contract.Running` are 0..5, and `Contract.State.Running` works too. `state === Contract.Running` after an update. A binding on that comparison flips both ways. `stateChanged` fires once per change and not when the value did not move. |
| **7c** `check7c_owned_model` (`contract_model.qml`) | `#[qproperty(*mut PeerModel, peers, READ = peers_model, CONSTANT)]`. The singleton creates both models in `Default` through cxx-qt-lib's `rust::cxxqtlib1::make_unique<T>()` template, bound with `fn make_unique() -> UniquePtr<PeerModel>` the same way cxx-qt-lib binds it for `QPainter`. It holds them in `UniquePtr` fields and also parents them to itself in `initialize()` (`#[base = QObject]` on the `QAbstractListModel` extern type supplies the upcast). | `ListView { model: Contract.peers }` keeps its delegates through insert, `dataChanged` and remove. The updates come from tokio. The exact row signals arrive, with no reset. Each read returns the same object. There is no `peersChanged`. The parent is the singleton. The model survives `gc()`. `exitNodes`, the second owned model, also works. QML never creates or attaches a model. |
| **7c** `check7c_lifetime` (`contract_reload.qml`, `contract_final.qml`) | The C++ class is `ContractObject : public QObject, private CxxQtType<ContractRust>`. So the Rust struct, and with it the `UniquePtr`s, drops before `~QObject`. Deleting a child unregisters it from its parent, so nothing is deleted twice. | The round-1 reload loop runs 20 times with 50 snapshots in flight. A last engine then asserts `createdModels == 42` (2 per singleton) and `liveModels == 2`: every earlier model was destroyed exactly once. There is no crash, no backend thread is left, and the thread count does not grow. |
| **7d** `check7d_types` (`contract_types.qml`) | `#[qproperty(QDateTime, key_expiry, cxx_name = "keyExpiry", READ, NOTIFY)]` and `#[qproperty(QStringList, issues, ...)]` | `keyExpiry instanceof Date` and `getTime() === 1767225600000` (ISO `2026-01-01T00:00:00.000Z`). An invalid QDateTime reads as an invalid Date (`NaN`). `issues.length`, `issues[i]`, `join` and `indexOf` all work. Bindings re-evaluate, and each signal fires once. |
| **7e** `check7e_shared_notify` (`contract_signals.qml`) | Shared NOTIFY: declare `#[qsignal] fn issues_changed`, then `#[qproperty(QStringList, issues, READ, NOTIFY = issues_changed)]` and `#[qproperty(i32, issue_count, READ = issue_count, NOTIFY = issues_changed)]`, the second with a custom READ getter. Derived signal: `initialize()` connects `on_exit_node_active_changed` / `on_exit_node_online_changed` to emit `exit_node_blocked_changed` (an `exitNodeBlocked` property with `READ = exit_node_blocked, NOTIFY = exit_node_blocked_changed`). | One `issuesChanged` per update. Bindings to both `issues` and `issueCount` update on it, and there is no `issueCountChanged`. `exitNodeBlocked` follows active/online. Its binding updates. One `exitNodeBlockedChanged` fires per input that moved, and the value is already stored when the signal fires. |
| **7f** `check7f_backend_swap` (`contract_swap.qml`) | `ContractRust { driver: Box<dyn ContractBackend>, ... }`. `Default` calls `backend::from_env()`, which reads `C7SPIKE_CONTRACT_BACKEND`. No C++ is involved. | The test reruns itself twice: once with the env var unset (`--expect-backend=tokio`) and once with it set to `fake`. The same QML asserts `Contract.backend` and the backend thread count (1 vs 0) and drives the same snapshots through either backend. A negative control (expect `fake` with the env var unset) must fail, and does. |

Each 7x check passed **50/50** consecutive runs, twice:

- once against the gold-linked `.so`;
- again after the rust-lld pin (check 8), against the rust-lld-linked `.so`,
  together with `check8_plugin_entry` and `check1a_load` (also 50/50 each).

Both times the `.so`'s sha256 matched before and after the runs. Check 6,
the #286 parity check, still passes with the pin.

Mutation sanity:
- Removing one of the two `exitNodeBlockedChanged` connections fails 7e with 4
  failed checks.
- Leaking `peers` (forget the `UniquePtr`, no parent) fails 7c-lifetime with
  `PeerModels created 42 live 22`.
- With the parent kept, forgetting the `UniquePtr` still passes, because
  `~QObject` deletes the child. The parent link alone is enough to free the
  model.

Notes for Phase 1:

- A custom `NOTIFY = x` must name a signal declared with `#[qsignal]`. That
  is why `issues` also uses the declared `issues_changed` instead of an
  auto-generated one.
- A pointer property needs a custom READ that returns `*mut T`. cxx accepts a
  raw pointer return value in a safe fn.
- `PeerModel` only upcasts to its declared base. Add `#[base = QObject]` to the
  `QAbstractListModel` extern type to reach `QObjectExt::set_parent`.
- `#[qproperty(*mut PeerModel, ...)]` types the property as the concrete
  `PeerModel*`, not `QAbstractItemModel*`. QML treats both as a model.

## Checks that need Quickshell (PENDING)

Quickshell is not installed on the spike host. After `sudo pacman -S quickshell`:

**1b: Quickshell loads the module from its import path**

```sh
cd spike/cxx-qt && cargo stage
QML_IMPORT_PATH=$PWD/target/qml qs -p quickshell/load/shell.qml
```

It passes when the log contains
`C7SPIKE 1b PASS counter=1 state=a=1,b=0 rows=2` and `qs` then exits by
itself. A `module "C7Spike" is not installed` error, or a `FAIL` line, means
it failed.

**4b: tokio shutdown under real Quickshell reloads**

```sh
cd spike/cxx-qt && cargo stage
QML_IMPORT_PATH=$PWD/target/qml qs -p quickshell/reload/shell.qml
```

The shell calls `Quickshell.reload(false)` 20 times. It prints one
`C7SPIKE 4b gen=N live=… tokioThreads=… threads=… late=…` line per
generation, then `C7SPIKE 4b PASS after 20 reloads` and exits. To pass:

- the final line is `PASS`, which means `live=1`, `tokioThreads=1` and
  `late=0` in the last generation;
- `threads=` does not keep climbing from gen 2 to gen 21;
- `qs` does not crash or hang.

To also try a hard reload, change `reload(false)` to `reload(true)` and run
it again.

## The one trick: exporting the plugin entry points

A Rust `cdylib` exports only symbols that Rust defines. rustc's version script
ends in `local: *`, and `--gc-sections` then drops what is left. The plugin's
two entry points, `qt_plugin_instance` and `qt_plugin_query_metadata_v2`, are
C++ that moc generates, so they were simply missing from the library:
`nm -D` showed neither of them, and Qt cannot load such a library as a
plugin. `c7spike/build.rs` passes a second version script, generated into
`OUT_DIR`, with `cargo::rustc-cdylib-link-arg`, which keeps those two symbols
global. It is a linker input, not C++.

### Check 8: which linkers honour it, and proof that Qt uses it

**check1a alone does not prove the trick works.** If the entry points are
missing, the steps are:

1. `QPluginLoader` fails with `QLibraryPrivate::loadPlugin failed on ".../libC7Spike.so" : "Could not resolve 'qt_plugin_instance' function"`.
2. By then `dlopen` has already run the library's static initialisers. They
   register the types and an embedded `:/qt/qml/C7Spike/qmldir`.
3. QML falls back to `module "C7Spike" provided by linked library "" ;
   optional plugin not loaded`, and every QML check still passes.

That fallback relies on the failed plugin load leaving the library mapped,
so the loader never instantiates the plugin.

`check8_plugin_entry` closes the gap. It asserts three things:

- `nm -D --defined-only` lists both entry points as `T`.
- A child run with `QT_LOGGING_RULES=qt.qml.import=true;qt.core.plugin.loader=true`
  logs `module "C7Spike" provided by plugin ".../libC7Spike.so"`.
- The log has neither `Could not resolve 'qt_plugin_instance'` nor
  `C7Spike" provided by linked library`.

Matrix: each cell was built with `RUSTFLAGS="-C link-arg=-fuse-ld=<ld>"` into
`target/link-<ld>/`, staged, then run through check1a and check8 via
`C7SPIKE_QML_DIR`. The linker is confirmed by `readelf -p .comment`
(`Linker: LLD 21.1.8`) and, for gold, by cargo's "gold linker is deprecated"
warning.

| export mechanism (build.rs) | ld.bfd | gold | rust-lld |
|---|---|---|---|
| anonymous version script `{ global: ...; };` (what build.rs uses) | **link fails**: `/usr/bin/ld.bfd: anonymous version tag cannot be combined with other version tags` | exported, check8 PASS | exported, check8 PASS |
| named version script `C7SPIKE_1.0 { global: ...; };` | **link fails**, same message | exported as `@@C7SPIKE_1.0`, check8 PASS | exported as `@@C7SPIKE_1.0`, check8 PASS |
| `-Wl,--dynamic-list=<file>` | links, **not exported**, check8 FAIL | not exported, FAIL | not exported, FAIL |
| `-Wl,--export-dynamic-symbol=<sym>` | links, **not exported**, check8 FAIL | not exported, FAIL | not exported, FAIL |
| nothing | links, not exported, check8 FAIL | not exported, FAIL | not exported, FAIL |

In every row, check1a passed, including the rows where nothing was exported.

Why bfd cannot be fixed with a flag:

- rustc always passes its own anonymous version script for a cdylib
  (`{ global: <Rust exports>; local: *; };`).
- bfd allows at most one anonymous version node, and no named node next to
  it.
- `--dynamic-list` and `--export-dynamic-symbol` only change symbol binding.
  They cannot override `local: *`.
- Stable rustc has no option to drop or extend its script.

One untested way out: make the entry points Rust-defined, so that rustc's own
script exports them. That means using `PluginType::Static` (which compiles
the moc output with `QT_STATICPLUGIN`, so it emits `qt_static_plugin_C7Spike_plugin()`)
and writing `#[no_mangle]` Rust wrappers that forward to it. That copies the
`QStaticPlugin`/`QPluginMetaData` ABI by hand, so it was not pursued.

**Decision: pin the linker.** `.cargo/config.toml` sets
`[target.x86_64-unknown-linux-gnu] rustflags = ["-C", "link-arg=-fuse-ld=lld"]`.
rustc already passes `-B<sysroot>/lib/rustlib/x86_64-unknown-linux-gnu/bin/gcc-ld`,
so the `-fuse-ld=lld` it adds resolves to the rust-lld that rustup ships.
No system package is needed. Because a `-fuse-ld` is now present,
qt-build-utils no longer adds `-fuse-ld=gold`.

With the pin, plain `cargo stage && cargo test` produces a library tagged
`Linker: LLD 21.1.8`. `nm -D` shows `T qt_plugin_instance` and
`T qt_plugin_query_metadata_v2`, and every check passes.

Caveat: a `RUSTFLAGS` environment variable replaces config `rustflags`
entirely. Under RUSTFLAGS that do not mention `-fuse-ld`, such as makepkg's,
qt-build-utils falls back to gold, which also works. Explicitly forcing
`-fuse-ld=bfd` still fails at link time, loudly rather than silently.

The cxx-qt-build docs warn that dynamic plugins expect "a certain file
layout" that only CXX-Qt-CMake produces. `cargo stage` produces that layout
instead: it copies the generated `qmldir` and `plugin.qmltypes` and renames
`libc7spike.so` to `libC7Spike.so` to match `plugin C7Spike` in the qmldir.

## Check 3: coverage through the bridge

`./coverage.sh` builds an instrumented plugin with `cargo llvm-cov show-env`,
stages it into `target/cov/qml`, runs the QML-driven tests against it
(`C7SPIKE_QML_DIR`) and prints the report. Plain `cargo llvm-cov` is not
enough: the tests load the plugin through the QML import path, so it must be
staged from the instrumented build first.

- Line and region coverage work on stable.
- Branch coverage needs nightly: `TOOLCHAIN=+nightly BRANCH=--branch ./coverage.sh`
  (stable rejects `-Z coverage-options=branch`). Match arms are not counted
  as branches, only `if`/`while`/`let ... else`.
- Glue: cxx-qt's `static_assertions` closures land in `~/.cargo/registry`
  (hidden by cargo-llvm-cov's default filter). On nightly, a few cxx-qt thunks
  are mapped to `c7spike/src/bridge.rs`, so the script excludes that file too.
  Generated C++ is not instrumented.
- `cargo mutants` cannot run the QML tests yet: its copy of the tree has no
  staged plugin, so `spike-tests` panic and every mutant is "caught" falsely.
