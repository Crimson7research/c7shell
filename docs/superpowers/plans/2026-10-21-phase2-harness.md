# Plan: Phase 2, PR 1 (#306): fake tailscaled, scenario format and harness

Status: implemented on `feat/fake-tailscaled-306` (2026-10-21), for #306, the
first of the five Phase 2 PRs (#306 to #310) of epic #287. Parent issue:
#290. "Implementation notes" at the end records where the work departed
from this plan, and why.

Inputs, read before starting:

- `docs/superpowers/plans/2026-10-19-tailscale-rust-rewrite.md`, Phase 2 and
  the Decisions table (the "Split by evidence" row of 2026-10-21 is binding
  here).
- `docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md`: "How to
  read this document" (barriers, paused time, setup is not acceptance),
  R-FAKE-01 to R-FAKE-07, R-HTTP-01 and R-HTTP-09.
- `docs/superpowers/specs/2026-10-19-tailscale-rust-traceability.md`, Table B.
- `docs/architecture.md`, "Rules for the C7 plugin".
- The cxx-qt spike in `/home/joren/git/c7shell-spike/spike/cxx-qt`: README,
  `spike-tests/src/lib.rs` (headless `QGuiApplication`, bounded event-loop
  waits, respawn per check) and check 6 (loading #286's `C7` with
  `TS_SOCKET` set).
- The #286 reference, read-only, at `/home/joren/git/c7shell-286` (commit
  `a38dbca`). Never modify it.

## Goal

Land the test infrastructure every later Phase 2 PR uses, and prove it end to
end with exactly two scenarios:

1. A Cargo workspace at `plugin/Cargo.toml`, the first Rust in `plugin/`,
   that leaves the CMake build on `main` untouched and green.
2. A fake `tailscaled` in Rust, as a library and as a standalone binary,
   whose own tests cover R-FAKE-01 to R-FAKE-07.
3. A scenario file format and a machine-readable evidence classification of
   all 154 requirement IDs.
4. A Rust harness that builds #286's `C7` module from `a38dbca`, loads it
   headless, points it at the fake through `TS_SOCKET`, and runs scenarios.
   The same harness runs Phase 3's Rust module later, chosen by an
   import-path variable.
5. One `parity` scenario (R-HTTP-01) that passes on `a38dbca`, and one `fix`
   scenario (R-HTTP-09) that fails there for its stated reason, each in 50
   consecutive runs.

Out of scope: every other characterisation test (#307 to #309), the parser
corpus (#307), the mutation baseline (#310), the explicit-advance test clock
and every core-crate test hook (Phase 3), porting the C++ test kit
(Phase 2b), and any change to `PKGBUILD`.

## Decisions this plan makes

Each one is a choice the owner did not make. Reviewers check the reasoning.

| # | Decision | Why |
|---|---|---|
| P1 | **The harness runs the fake in-process**, on its own threads, controlled through its Rust API. | The harness is already a Rust process that hosts Qt (spike check 6), and #286's `QLocalSocket` client runs on the Qt thread, so the fake's threads never share the event loop the harness pumps. A barrier reads the fake's state under the fake's lock, with no IPC delay between "the fake recorded it" and "the test saw it". The fake's lifetime is the test's, so no orphan process or stale socket survives a failed run (R-FAKE-06's removal on drop). A failure is one Rust panic with context, not two logs. |
| P2 | **The standalone binary is controlled by JSON lines on stdin, answered on stdout**, not by a second socket. | A test that spawns the binary owns its pipes, so nothing else can reach the control channel and nothing needs a second path in the private directory. End of stdin means the parent has gone, so the binary shuts down and removes its socket, the same lifetime rule as in-process. One request line, one answer line, so a client written in any language (shell with `coproc`, a later Phase 3 tool, #310's mutation script) needs no framing code. Both control surfaces are thin layers over one `Fake` core, and one test runs the same script through both and compares the records. |
| P3 | **Scenario files are JSON.** | tailscaled's bodies are JSON, so a status or prefs body sits in a scenario as a JSON value, not as an escaped string. The plan already fixes the parser corpus as JSON (Phase 2 item 3), so one parser (`serde_json`) reads both and the fake crate needs no second format crate. JSON has no comments, so each scenario carries a `clauses` list in prose, and bytes that are not UTF-8 use `{"hex": "..."}`. |
| P4 | **One crate, `fake-tailscaled`, under `plugin/lib/testing/fake-tailscaled/`**, holds the fake, its binary, the scenario format and the evidence loader. The harness is a second crate, `tailscale-parity`, under `plugin/tests/tailscale-parity/`. | The owner's layout puts "the fake tailscaled and harness kit" in one crate under `plugin/lib/testing/`. Architecture says a `plugin/lib/` crate has no Qt, so everything that needs cxx-qt (the QML bridge, the runner) lives in the `plugin/tests/` crate. The scenario format is plain data with no Qt in it, so its tests run in the fake crate and count toward its line coverage. |
| P5 | **Toolchain: `plugin/rust-toolchain.toml` names the `stable` channel with `llvm-tools-preview`, and the workspace sets `rust-version = "1.94"`.** | An exact stable pin would drift from Arch's `rust` package that `PKGBUILD` will use in Phase 2b. `rust-version` is a hard floor cargo checks, set to the version the spike proved. The dated nightly is only for branch coverage (Decisions, 2026-10-20) and comes in a later PR. |
| P6 | **cxx-qt, cxx-qt-lib and cxx-qt-build are pinned `=0.10.0`**, the version the spike's `Cargo.lock` resolved. `cxx` is pinned to the spike's `=1.0.205`. Other crates are locked by the committed `plugin/Cargo.lock`. | Architecture: "Pin cxx-qt to an exact version." |
| P7 | **Rust reads and drives the contract through a small QML bridge**, a cxx-qt `Probe` singleton in a harness-only QML module `C7Harness`, and a generic `driver.qml`. Rust emits `Probe.command(json)`, the driver's handler runs it against `Tailscale` and calls `Probe.reply(json)` before the emit returns. | cxx-qt-lib exposes no generic `QObject::property` or `invokeMethod`, so Rust cannot read a QML singleton's members directly. A signal with a direct connection runs the QML handler on the same thread before `emit` returns, so a read is synchronous and needs no wait. The driver hard-codes no member: it connects every `*Changed` signal it finds on `Tailscale` and reads members by name, so the same driver serves #286's 24 properties and the rewrite's 29. |
| P8 | **One child process per scenario.** The test binary is `harness = false`; its parent mode respawns itself once per scenario with a cleared environment, a private root and `TS_SOCKET` set by `Command::env`. | `TS_SOCKET` is read when the singleton is constructed, and `std::env::set_var` is unsafe once threads exist. A fresh process per scenario gives each one a fresh singleton, its own socket path, and no state from an earlier scenario. A crash in the module under test fails one scenario, not the run. This is the spike's `respawn` pattern. |
| P9 | **Implementations are named, with a capability set.** `C7_IMPL` is `cpp-286` or `rust`; `C7_QML_DIR` is the directory holding `C7/qmldir`. `cpp-286` has no capabilities. Capabilities are `clock`, `retry-hook`, `idle-barrier`, `read-barrier` and `clock-hook`. | A scenario is implementation-neutral: it names the capabilities it needs, and the runner refuses to run one whose needs the implementation lacks unless the scenario declares `cannot-run` for it. That makes the split by evidence mechanical. Phase 3 adds the `rust` capabilities; how the harness reaches the core crate's hooks inside a loaded plugin is Phase 3's decision. |
| P10 | **The fix scenario is R-HTTP-09's PATCH clause**, not a whole requirement. | It is the defect the issue names (an error body, 403 with a body), it runs on `a38dbca` with no clock, no hook and no added member, and its failure there is a value at one observable (`writeError`), never a timeout. See "The two scenarios". |

### How this plan reads the split-by-evidence decision (owner to confirm)

The decision says a requirement whose acceptance needs paused time, an
injected timing, a test hook or a decided member #286 lacks is not
`harness-on-cpp`. Read whole-requirement, almost nothing qualifies. Nearly
every acceptance reads its values "after the read barrier", and the read
barrier is itself a core-crate test hook (decision 12). Also, most criteria
have one or two timed clauses beside several untimed ones. This plan reads
it **per clause**:

- A clause can run on `a38dbca` when it needs no clock advance, no injected
  timing, no core-crate hook and no member #286 lacks. Its observable must
  be a contract member #286 has or the fake's records, and the harness must
  reach it by a positive wait: a value it waits for, a signal count it waits
  for, or a fake report it waits for.
- A clause whose barrier is the read barrier still runs on `a38dbca` when
  its outcome is positive and observable. The harness waits for the outcome
  itself, then takes the client barrier and the fake barrier, which the fake
  provides. A negative ("no failure", "nothing yet") or an exact count
  where more could still arrive does need the read barrier, so that clause
  cannot run there.
- A requirement with at least one clause that runs is `harness-on-cpp`. Each
  of its other clauses is listed under `deferred`, with its own class.

This is how the task's own examples (R-HTTP-01 and R-HTTP-09, both
`harness-on-cpp`) come out. The owner confirms or rejects this reading in
the #306 review. If it is rejected, the evidence file changes and the two
scenarios do not (both run only clauses with no clock and no hook).

## Global constraints

- Test first. Each behaviour's failing test is committed before the code that
  makes it pass, and `git log` shows it. Commit messages are conventional
  (`test(fake-tailscaled): ...`, `feat(fake-tailscaled): ...`,
  `test(tailscale-parity): ...`, `feat(tailscale-parity): ...`,
  `build(plugin): ...`), each ending with a blank line and `Refs #306`.
- Stage explicit paths only. Never run `git add -A`, `git add .` or
  `git commit -a`. Other sessions edit sibling checkouts.
- No sleeps in tests. A wait is either bounded event-loop pumping (the
  spike's `wait_until`, capped by an iteration count) or a condition-variable
  wait on the fake's state. The only use of time is a **failure bound**
  (`FAILURE_BOUND`, 10 s) on fake waits and on test-client reads. It turns a
  hang into a failure. A passing test never reaches it, and no test asserts
  on elapsed time.
- No host state. No real tailscaled, no host bus, no host runtime directory.
  Sockets are only in per-test private directories (mode 0700 under
  `std::env::temp_dir()`, kept short for the 108-byte `sun_path` limit).
  `TS_SOCKET` is always set by the test. A scenario child runs with a
  cleared environment: private `HOME`, `XDG_*` and `TMPDIR`, and the same
  keep-list as `plugin/lib/testing/testmain.cpp`, read there for the list,
  never copied.
- No sudo. Nothing is written outside `/home/joren/git/c7shell-306` except
  cargo's caches (`~/.cargo`) and the reference-build cache
  (`${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference/`). The
  reference source is extracted there with `git archive`, so nothing is
  written to the repository's `.git` (see "Implementation notes").
- Every cargo command runs with its working directory in `plugin/`
  (`cd plugin && cargo ...`, or `(cd "$repo/plugin" && cargo ...)` in a
  script), never `cargo --manifest-path plugin/Cargo.toml` from the root.
  Cargo finds `.cargo/config.toml` and rustup finds `rust-toolchain.toml`
  from the working directory, not from the manifest. From the root, the
  rust-lld pin is lost and `target/` lands inside `plugin/`.
- `tests/test-c7-plugin.sh`, `tests/test-native-boundary.sh` and
  `tests/test-native-boundary-selftest.sh` pass after every commit that
  touches `plugin/`, `tests/` or `.gitignore`.
- No hand-written `.cpp`, `.h` or `.hpp`. cxx-qt's generated glue lands in
  the target directory and is never committed.
- Quickshell is never read for this PR. The PR description states "No
  Quickshell code copied or adapted."

## File map

| Path | Responsibility |
|---|---|
| `.gitignore` | Adds `/target/`, the Cargo target directory at the repository root. |
| `plugin/Cargo.toml` | The workspace: members `lib/testing/fake-tailscaled` and `tests/tailscale-parity`; `default-members` is the fake crate alone; `[workspace.package]` (edition 2021, MIT, `publish = false`, `rust-version = "1.94"`); `[workspace.dependencies]` with cxx-qt pins (P6), `serde` (derive), `serde_json`. |
| `plugin/Cargo.lock` | Committed lock file. |
| `plugin/.cargo/config.toml` | `[build] target-dir = "../target"` (resolved against `plugin/`, so the repository root's `/target/`). `[target.x86_64-unknown-linux-gnu] rustflags = ["-C", "link-arg=-fuse-ld=lld"]`, with the spike's comment on why GNU ld fails and that `RUSTFLAGS` replaces this list. |
| `plugin/rust-toolchain.toml` | `channel = "stable"`, `components = ["llvm-tools-preview"]`, `profile = "minimal"` (P5). |
| `plugin/lib/testing/fake-tailscaled/Cargo.toml` | Package `fake-tailscaled`: `[lib]` `fake_tailscaled` and `[[bin]]` `fake-tailscaled`. Depends on `serde` and `serde_json` only. No Qt, no cxx-qt, no tokio. |
| `.../fake-tailscaled/src/lib.rs` | Re-exports; crate docs naming R-FAKE-01 to R-FAKE-07 and where each is tested. |
| `.../fake-tailscaled/src/server.rs` | The socket server core: bind and refuse (R-FAKE-05), accept, per-client reader threads, framing on a delimiter with `Content-Length` bodies (R-FAKE-01), handler and keep-open or close-after-reply, push, hold and complete (R-FAKE-02), close one client (R-FAKE-03), reports (R-FAKE-07), drop (R-FAKE-06). The semantics of `plugin/lib/testing/fakesocketserver.{h,cpp}` on `a38dbca`, re-implemented in Rust from the requirements, not translated. |
| `.../fake-tailscaled/src/request.rs` | `Request`: client id, sequence number, `raw` bytes (head, delimiter, body, exactly as received), `recorded` (#286's shape: head only for a request without a body, the whole message with one), and parsed method, target, version, headers and body. |
| `.../fake-tailscaled/src/reply.rs` | The HTTP reply builder: status line or raw override, headers, body; framing `content-length`, a declared wrong length, `chunked` with chosen chunk sizes, extensions, trailers or a missing final chunk, or `none`; split points with await labels; then close, keep open or stream. Pure functions from a `ReplySpec` to bytes and split points. |
| `.../fake-tailscaled/src/script.rs` | `Script`: ordered rules (method, exact target or path, `times`), each with a `ReplySpec`, `hold` or `stream`. Unmatched requests get `404` and are flagged, so a runner can fail on a surprise request. |
| `.../fake-tailscaled/src/bytes.rs` | `Bytes`, the JSON encoding of byte strings: a JSON string (UTF-8), `{"hex": "..."}`, or (bodies only) `{"json": value}`, serialised compactly. |
| `.../fake-tailscaled/src/control.rs` | The JSON-lines control protocol (P2): command and answer types, and `serve(fake, stdin, stdout)`. |
| `.../fake-tailscaled/src/bin/fake-tailscaled.rs` | `fake-tailscaled --socket PATH [--script FILE]`: start, print one `listening` or `not-listening` event line, serve control until end of stdin, drop. Exit 0 on clean end, 2 when it cannot listen. |
| `.../fake-tailscaled/src/scenario.rs` | The scenario format (see "Scenario format"): `serde` types with `deny_unknown_fields`, the loader, and validation that needs no Qt. |
| `.../fake-tailscaled/src/evidence.rs` | The evidence file's types and loader, and the checks of it against the spec and Table B. |
| `.../fake-tailscaled/tests/support/mod.rs` | `TestDir` (a private 0700 directory, removed on drop) and `Client` (a `UnixStream` with `read_exactly`, `read_until_closed` and `FAILURE_BOUND` as its read timeout). |
| `.../fake-tailscaled/tests/socket_server.rs` | R-FAKE-01, R-FAKE-02, R-FAKE-03 (the fake's half), R-FAKE-05, R-FAKE-06 (one test per ported `tst_fakesocketserver.cpp` function) and R-FAKE-07. Every test is named `r_fake_0N_...`. |
| `.../fake-tailscaled/tests/http_replies.rs` | Byte-exact output of every reply form a scenario can script, read by a raw test client. |
| `.../fake-tailscaled/tests/binary.rs` | The standalone binary: start, refusal, every control command, end-of-stdin shutdown, and the equivalence of in-process and binary records for one script. |
| `.../fake-tailscaled/tests/scenario_format.rs` | Format validation, accepted and rejected inline cases, and "every file under `tests/fixtures/tailscale/scenarios/` validates". |
| `.../fake-tailscaled/tests/evidence.rs` | The evidence file against the spec's 154 headings and Table B; every R-FAKE requirement has `r_fake_0N_` tests; every scenario agrees with the evidence file. |
| `plugin/tests/tailscale-parity/Cargo.toml` | Package `tailscale-parity`: depends on `fake-tailscaled`, `cxx`, `cxx-qt`, `cxx-qt-lib` (features `qt_gui`, `qt_qml`), `serde_json`; build-depends on `cxx-qt-build`. `[[test]]` targets `stub_selftest`, `harness_selftest` and `scenarios`, all `harness = false`. |
| `plugin/tests/tailscale-parity/build.rs` | `CxxQtBuilder` with a QML module `C7Harness` holding the `Probe` bridge. |
| `plugin/tests/tailscale-parity/src/lib.rs` | Headless app, bounded `wait_until` and `pump` (from the spike's pattern), engine loading with only the chosen import paths. |
| `plugin/tests/tailscale-parity/src/probe.rs` | The cxx-qt bridge (P7): `Probe` singleton, `command` signal, `reply` and `ready` invokables, a thread-local handle to the live instance. Declarations plus a few lines of glue only. |
| `plugin/tests/tailscale-parity/src/contract.rs` | `Contract`: `read(name)`, `enum_value(key)`, `call(name, args)`, `signal_count(name)`, `members()`, each one synchronous `Probe` round trip returning JSON. |
| `plugin/tests/tailscale-parity/src/implementation.rs` | `Implementation { name, qml_dir, capabilities }` from `C7_IMPL` and `C7_QML_DIR`; refuses an unknown name or a directory without `C7/qmldir`, with a message naming `build-reference.sh`. |
| `plugin/tests/tailscale-parity/src/runner.rs` | Runs one scenario's steps against a `Contract` and a `Fake`; produces an `Outcome`; compares it with the scenario's declaration for the implementation. |
| `plugin/tests/tailscale-parity/src/child.rs` | Parent mode (list scenarios, make private roots, respawn with a cleared environment, read the child's result line, repeat `C7_REPEAT` times) and child mode (start the fake, the app, the engine and the driver, then run). |
| `plugin/tests/tailscale-parity/qml/driver.qml` | The generic driver (P7). |
| `plugin/tests/tailscale-parity/selftest/qml/C7/qmldir`, `.../Tailscale.qml` | A QML-only stub `C7` module with a `Tailscale` singleton of a few properties and setters, used only to test the runner without #286. It does no I/O. |
| `plugin/tests/tailscale-parity/selftest/scenarios/*.json` | Runner self-test scenarios (pass, declared fail, unexpected pass, wrong actual, wait never reached, precondition failed, cannot-run, needs not declared). They are not requirement scenarios, and the evidence checks ignore them. |
| `plugin/tests/tailscale-parity/tests/stub_selftest.rs` | Bring-up checks and the runner self-tests against the stub: no reference build needed. |
| `plugin/tests/tailscale-parity/tests/harness_selftest.rs` | The checks against #286's C7: the module read from Rust, an unmatched request, the request expectations' failures. |
| `plugin/tests/tailscale-parity/tests/support/mod.rs` | What both self-test binaries share. |
| `plugin/tests/tailscale-parity/tests/scenarios.rs` | Runs `tests/fixtures/tailscale/scenarios/*.json` against `C7_IMPL`. |
| `plugin/tests/tailscale-parity/build-reference.sh` | Builds #286's `C7` from `a38dbca` into the cache with #286's own CMake; prints the `C7_QML_DIR` as its last line. |
| `plugin/tests/tailscale-parity/run.sh` | `build-reference.sh`, then the `scenarios` test against `cpp-286`; `--repeat N`. |
| `plugin/tests/tailscale-parity/README.md` | How to build the reference, run the scenarios, add a scenario and add an implementation. |
| `tests/fixtures/tailscale/evidence.json` | The classification of all 154 requirement IDs. |
| `tests/fixtures/tailscale/scenarios/http-01-request-line-and-host.json` | The parity scenario. |
| `tests/fixtures/tailscale/scenarios/http-09-error-body-in-write-error.json` | The fix scenario. |
| `tests/test-fake-tailscaled.sh` | The suite entry `PKGBUILD check()` runs: workspace layout guards, the fake crate's tests, then 50 consecutive runs of them. Skips, with its reason printed, only when `cargo` is not on `PATH`, the same rule `tests/test-c7-plugin.sh` applies to `cmake`. |

## Evidence classes and the classification rule

`tests/fixtures/tailscale/evidence.json`:

```json
{
  "format": 1,
  "source": "a38dbcae841a1134514f68cba8f5b98d4efddb68",
  "decided": "2026-10-21",
  "requirements": [
    {
      "id": "R-HTTP-01", "tag": "parity", "class": "harness-on-cpp",
      "deferred": [
        { "clause": "exactly one request after the read and fake barriers",
          "class": "cpp-suite", "needs": ["read-barrier"],
          "tests": ["plugin/lib/tailscale/tests/tst_localapiclient.cpp::sendsAHostHeaderTailscaledAccepts"] }
      ]
    },
    {
      "id": "R-CONN-07", "tag": "parity", "class": "cpp-suite",
      "needs": ["clock", "retry-hook"],
      "tests": ["plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp::theRetryCurveDoublesAndCapsAtThirtySeconds"]
    },
    {
      "id": "R-CONN-13", "tag": "fix", "class": "phase3-only",
      "needs": ["clock", "idle-barrier"],
      "reason": "cannot run on C++: the 30 s probe is counted on the explicit-advance clock after the idle barrier, and #286 has neither"
    }
  ]
}
```

Classes:

| Class | Meaning | Evidence on `a38dbca` |
|---|---|---|
| `harness-on-cpp` | At least one acceptance clause runs on `a38dbca` through QML, under the per-clause reading above. This covers backend halves through the `C7` module and, from #309 on, view halves through #286's views and the QML stand-in. The layout barrier is harness-side, not a core-crate hook. | A scenario: `parity` passes, `fix` fails for its stated reason. |
| `cpp-suite` | A `parity` requirement with no clause that runs there, whose C++ evidence is #286's own suite. | The #286 test functions Table B maps to it (`file::function`, or `file:line` for a shell check row), which pass on `a38dbca`. Its Rust test is written in Phase 3. |
| `phase3-only` | A `fix`, `new` or `kit` requirement with no clause that runs there, or a `parity` one Table B gives no #286 test. | None: recorded as "cannot run on C++", with the reason. Its test is written in Phase 3. |
| `fake-self` | R-FAKE-01 to R-FAKE-07 (not R-FAKE-04). They specify the fake itself. | The fake crate's own `r_fake_0N_` tests, in this PR. A backend clause inside one (R-FAKE-03's held PATCH) is listed under `deferred`. |
| `none` | `withdrawn` and `follow-up` requirements. | Not gated. |

The procedure, applied in order to each requirement's acceptance text:

1. `withdrawn` or `follow-up` gives `none`. An R-FAKE requirement gives
   `fake-self`.
2. Split the acceptance into clauses. A clause **needs** `clock` when it
   advances paused time, reads "with paused time not advanced", or injects a
   deadline, retry delay, settle or liveness value. It needs `retry-hook`,
   `idle-barrier`, `clock-hook` or `read-barrier` when it reads one of them
   for a negative or an exact count. It needs `added-member` when it reads a
   member from "Contract additions". It needs `outside-module` when its
   observable is not reachable through QML at all: the transport's own
   outcomes and tokens, the parsed status where the contract hides it, a
   shell script, packaging or a repository check.
3. Clauses with no needs run on C++. If there is at least one, the class is
   `harness-on-cpp`. Every other clause goes under `deferred`, with class
   `cpp-suite` (it is `parity`, and a Table B function asserts it; `tests`
   names them), `phase3-only` (with `reason`), or `harness-on-cpp` with a
   `pr` field (it runs on C++ but a later PR's scenario covers it).
4. With no clause that runs: `parity` with Table B functions gives
   `cpp-suite`, and `tests` lists **every** Table B function that maps the
   ID. Otherwise the class is `phase3-only` with a reason that starts
   `cannot run on C++:` and names the needs.

The checks in `tests/evidence.rs` (Task 10) are mechanical. Judgement stays
with the reviewers, who check each entry against this procedure. A later PR
(#307 to #309) may move an entry between classes only by editing this file,
with the reason in its commit message.

Worked entries this PR depends on:

- **R-HTTP-01** `harness-on-cpp`. It runs the request line, the lone Host
  header and "would be accepted", all rendered through the backend's opening
  pass. The "exactly one request" count is deferred (above).
- **R-HTTP-09** `harness-on-cpp`. It runs the first acceptance paragraph:
  PATCH 403 with a body, the same chunked, 500 `{"error":"boom"}` on
  `/status`, `{"message":"boom"}`, 403 with `Content-Length: 0` and invalid
  UTF-8, all read at `writeError` or `readError` after a positive wait on
  their change signal. Deferred as `phase3-only` (needs `clock`,
  `retry-hook`): "Bounds and incomplete bodies" (512-byte cut, 403 cut
  short, stalled 403, chunked 403 cut), every watch case and the backend
  half. This PR's scenario covers only the PATCH 403 case. The rest of the
  untimed clauses are #307's (`pr: 307`).
- **R-FAKE-03** `fake-self`. The fake's half is in this PR. The backend
  half's `writeError`, `writable` and `state` clauses are deferred as
  `harness-on-cpp` (`pr: 308`). Its "retry hook reads 0" clause is
  `phase3-only` (needs `retry-hook`).
- **R-CONN-07**, **R-CONN-10** and **R-HTTP-13** are `cpp-suite` (timing
  parity, evidence in #286's QtTest suites). **R-CONN-13**, **R-HTTP-15** and
  **R-WATCH-07** are `phase3-only` (timing fixes). **R-UI-02** and **R-UI-13**
  are `phase3-only` (needs `added-member`: the decided set has members #286
  lacks).

## Scenario format

One JSON object per file in `tests/fixtures/tailscale/scenarios/`. The
file's stem equals its `id`. Unknown fields are rejected.

```json
{
  "format": 1,
  "id": "http-09-error-body-in-write-error",
  "requirements": ["R-HTTP-09"],
  "tag": "fix",
  "evidence": "harness-on-cpp",
  "clauses": ["prose: each acceptance clause this scenario runs, quoted or rendered"],
  "deferred": ["prose: the clauses of these requirements it does not run, and where they are tested"],
  "needs": [],
  "fake": { "rules": [ ] },
  "steps": [ ],
  "on": {
    "cpp-286": { "result": "fail", "failing": [ { "id": "...", "actual": "..." } ], "reason": "..." },
    "rust": { "result": "pass" }
  }
}
```

- `tag` is `parity` or `fix` (a `new` requirement's scenario is tagged
  `fix`: it cannot pass on C++). `evidence` is the class of the clauses the
  scenario runs.
- `needs` lists capabilities (P9). The validator derives the needs from the
  steps and rejects a mismatch, so a scenario cannot hide a clock advance.
  `evidence: harness-on-cpp` requires empty needs.
- `fake.rules`, each `{ "match": { "method", "target" | "path" }, "times": N | "always", then one of "reply": ReplySpec, "hold": true, "stream": ReplySpec }`.
  `ReplySpec` has `status`, `reason` (canonical text by default),
  `status_line` (a raw override, for `garbage` or `HTTP/1.1 abc OK`),
  `headers` (`[[name, value], ...]`, verbatim, in order), `body` (`Bytes`
  or `{"json": value}`), `framing` (`"content-length"`,
  `{"content-length": N}` for a wrong length, `"chunked"`,
  `{"chunked": {"sizes": [...], "extension": ";ext=1", "trailers": [...], "final": true}}`
  or `"none"`), `split` (`[{"at": byte offset, "await": "label"}]`, in
  increasing order), and `then` (`"close"` by default, `"keep-open"`, or
  `"close-without-reply"`). A `stream` rule writes its head and keeps the
  client as a watch stream.
- `steps`, in order:
  - `{"start": {}}`: load `driver.qml`, which touches `Tailscale` and so
    constructs the backend.
  - `{"call": {"name": "setAcceptRoutes", "args": [true]}}`.
  - `{"wait": {"contract": {"state": {"enum": "Running"}}}}`,
    `{"wait": {"signal": {"name": "writeErrorChanged", "at_least": 1}}}`,
    `{"wait": {"fake": {"connected": 1}}}` (the client barrier),
    `{"wait": {"fake": {"recorded": {"method": "PATCH", "target": "/localapi/v0/prefs"}, "count": 1}}}`,
    `{"wait": {"fake": {"held": 1}}}`. A wait the implementation never
    reaches is an error, never an expected failure.
  - `{"fake": {...}}`: `push_line`, `push_chunk`, `push_watch_line`,
    `hold_next`, `complete_held` (a `ReplySpec`), `resume` (a label), and
    `close_client` (`{"holding": fragment}`, `{"stream": true}` or
    `{"index": n}`).
  - `{"barrier": "read" | "idle" | "retry"}` needs that capability, and
    `{"advance_ms": N}` needs `clock`. No `cpp-286` scenario uses them. They
    are defined now so Phase 3 adds capabilities, not format.
  - `{"expect": {"id": "...", "precondition": false, ...}}`, with exactly
    one of `"contract": {member: value}`, `"signal": {"name", "count"}`,
    `"request": {"match": {...}, "raw": Bytes}` (every recorded request
    that matches equals `raw`, and at least one matches), or
    `"requests": {"match": {...}, "count": N}`. Values are JSON scalars,
    `{"enum": "Running"}`, `{"date": null}` for an invalid date, or
    `{"date": "2027-04-11T09:06:08.000Z"}`. A failed precondition is an
    error.
- `on` must name every implementation the runner knows (`cpp-286`, `rust`).
  `result` is `pass`, `fail` (with `failing`, the exact ids and actual
  values, and `reason`) or `cannot-run` (with `reason`, allowed only when
  `needs` is not a subset of that implementation's capabilities). A `fix`
  scenario declares `fail` or `cannot-run` on `cpp-286` and `pass` on
  `rust`.
- The runner also fails a scenario when the fake answered any request with
  its unmatched-request `404`.

An outcome **matches its declaration** when it is `Pass` for `pass`;
`Fail` whose failing ids and actual values equal `failing` exactly, for
`fail`; and `CannotRun` for `cannot-run`. An `Error` (a wait never reached,
an unknown member, a failed precondition, an unmatched request, a crash or a
missing result line) never matches. So a `fix` scenario cannot "fail as
expected" by timing out.

## Tasks

Each task lists the test written first, the code that makes it pass and the
command that proves it. "Commit" means two commits, the test first and then
the code, with the paths listed. The fake's tests run from `plugin/`:
`cd plugin && cargo test --locked -p fake-tailscaled`.

### Task 1: the workspace and its guards

**Files:** create `tests/test-fake-tailscaled.sh`, `plugin/Cargo.toml`,
`plugin/Cargo.lock`, `plugin/.cargo/config.toml`, `plugin/rust-toolchain.toml`,
`plugin/lib/testing/fake-tailscaled/{Cargo.toml,src/lib.rs}`; modify
`.gitignore`.

- [x] **Test.** `tests/test-fake-tailscaled.sh` sources
  `tests/fixtures/harness.sh`. It prints `SKIP: cargo is not on PATH` and
  exits 0 when `command -v cargo` fails. Otherwise it fails unless:
  1. `plugin/Cargo.toml` declares `[workspace]`.
  2. `(cd plugin && cargo metadata --locked --format-version 1 --no-deps)`
     reports `"target_directory":"<repo>/target"` (matched with `grep -F`,
     no `jq`).
  3. `plugin/.cargo/config.toml` holds `link-arg=-fuse-ld=lld`.
  4. With host git config shut out (`GIT_CONFIG_GLOBAL=/dev/null
     GIT_CONFIG_NOSYSTEM=1`, as `tests/test-c7-plugin.sh` does), git ignores
     `target/x` and ignores no file `find plugin -type f` lists.
  5. After `(cd plugin && cargo build --locked)`, `plugin/target` does not
     exist.
  6. `(cd plugin && cargo test --locked -p fake-tailscaled)` passes.

  Later tasks append the 50-run loop (Task 6). Run it to see it fail:
  `tests/test-fake-tailscaled.sh` gives `plugin/Cargo.toml declares no
  [workspace]`. Commit it alone:
  `test(fake-tailscaled): guard the Cargo workspace layout`.
- [x] **Code.** Create the files in the file map. The fake crate starts
  with an empty `lib.rs` (crate docs only). Add `/target/` to `.gitignore`
  under a `# cargo build (plugin/.cargo/config.toml sets target-dir)`
  comment. Run `(cd plugin && cargo generate-lockfile)` once.
- [x] **Prove.** `tests/test-fake-tailscaled.sh && tests/test-c7-plugin.sh &&
  tests/test-native-boundary.sh && tests/test-native-boundary-selftest.sh`.
  All pass. `git status --short` shows no file under `target/` and none under
  `plugin/target/`.
- [x] **Commit.** `build(plugin): start the Cargo workspace beside the CMake build`.

### Task 2: the fake binds its socket (R-FAKE-05, R-FAKE-06)

**Files:** create `src/server.rs`, `tests/support/mod.rs`,
`tests/socket_server.rs` (all under `plugin/lib/testing/fake-tailscaled/`).

**Interface:**

```rust
pub struct Fake { /* Arc<Shared>, acceptor JoinHandle */ }
impl Fake {
    pub fn start(path: impl Into<PathBuf>) -> Fake; // never panics on a bind failure
    pub fn is_listening(&self) -> bool;
    pub fn error(&self) -> Option<String>;          // the reason when not listening
    pub fn path(&self) -> &Path;
}
impl Drop for Fake { /* stop accepting, disconnect every client, remove the socket file it bound */ }
```

- [x] **Tests** (each `r_fake_05_...` or `r_fake_06_...`, ported from the
  `tst_fakesocketserver.cpp` function named, with the same assertions):
  - `r_fake_06_listens_at_the_given_path_for_this_user_only`: listening;
    the socket's mode has no group or other bits; a missing parent directory
    is created.
  - `r_fake_05_refuses_a_path_already_taken`, one case each for a live
    fake (which still accepts a connection afterwards), a regular file and a
    dangling symlink: not listening, `error()` contains `already exists`,
    and what is there is unchanged.
  - `r_fake_05_a_destroyed_fake_frees_its_path`: drop it, then a new fake
    on the same path listens.
  - `r_fake_06_reports_a_directory_it_cannot_create` (parent under a
    regular file) and `r_fake_06_reports_a_path_too_long_to_listen_on` (a
    200-byte path): not listening, a reason given, no panic.

  They fail to compile without `Fake`. Commit:
  `test(fake-tailscaled): the fake binds, refuses and frees its socket`.
- [x] **Code.** `std::os::unix::net::UnixListener`. Refuse when
  `symlink_metadata(path)` succeeds. Create parents with mode 0700. Bind,
  then set the socket's mode to 0600, and record its inode. Drop: set a
  closing flag, wake `accept` by connecting to the path, join the acceptor,
  `shutdown(Both)` every client, join the readers, and remove the path only
  if it still has the recorded inode.
- [x] **Prove.** `cd plugin && cargo test --locked -p fake-tailscaled --test socket_server`.
- [x] **Commit.** `feat(fake-tailscaled): bind a private socket and refuse a taken path`.

### Task 3: framing, handler and records (R-FAKE-01, R-FAKE-06)

**Interface:**

```rust
pub type Handler = Box<dyn Fn(&Request) -> Option<Vec<u8>> + Send + Sync>;
pub enum AfterReply { CloseAfterReply, KeepOpen }
impl Fake {
    pub fn on_request(&self, handler: Handler, after: AfterReply, delimiter: Option<&[u8]>);
    pub fn requests(&self) -> Vec<Request>;
    pub fn wait_until<T>(&self, what: &str, f: impl FnMut(&State) -> Option<T>) -> T; // condvar; panics naming `what` after FAILURE_BOUND
}
```

- [x] **Tests:**
  - `r_fake_01_frames_a_request_with_its_declared_body`: R-FAKE-01's
    acceptance, word for word. The partial PATCH records nothing once the
    fake has received all 50 bytes (read through the received report,
    Task 5's, stubbed here as `wait_until` on the received count). After
    `true}` one request equals the whole message and the client reads `ok`.
    The following `GET /q HTTP/1.1\r\n\r\n` records as `GET /q HTTP/1.1`.
  - `r_fake_06_replies_and_closes_like_a_request_socket`,
    `r_fake_06_can_keep_the_client_open`,
    `r_fake_06_splits_framed_requests_whatever_the_reads_look_like` (writes
    split at every byte offset, and two requests in one write),
    `r_fake_06_answers_nothing_after_closing` (two requests in one write,
    close-after-reply: one answered, one recorded) and
    `r_fake_06_records_requests_without_a_handler` (recorded, client still
    connected, nothing written).
  - `request_parses_method_target_headers_and_body`, a unit test of
    `Request`: `raw` holds the head, the delimiter and the body, `recorded`
    is #286's shape, and headers keep their case and order.

  Commit: `test(fake-tailscaled): frame requests and record every byte`.
- [x] **Code.** One reader thread per client. Each read appends to that
  client's buffer and to its received count, then frames on the delimiter;
  with `Content-Length` in the head, the body is taken too. A hold check
  comes before the handler (Task 4). Every state change does a
  `notify_all` on one `Condvar`.
- [x] **Prove.** `cd plugin && cargo test --locked -p fake-tailscaled`.
- [x] **Commit.** `feat(fake-tailscaled): frame, answer and record requests`.

### Task 4: push, hold and complete (R-FAKE-02, R-FAKE-06)

**Interface:** `push_line(&[u8]) -> usize`, `push_chunk(&[u8]) -> usize`,
`push_to(ClientId, &[u8]) -> bool`, `hold_next(&[u8])`,
`complete_held(&[u8]) -> usize`, `held_count() -> usize`.

- [x] **Tests:** `r_fake_02_pushes_exact_bytes_and_holds_a_request`, the
  whole R-FAKE-02 acceptance in its order. That covers the split `{"half":`
  push, a push to a held client returning 0 while its written report stays
  0, `complete_held` returning 1, the one-shot hold, holds accumulating to
  2, and a completion never reaching a request held after it.
  `r_fake_06_pushes_lines_to_every_client_like_an_event_socket` and
  `r_fake_06_says_when_a_line_reached_nobody`. Commit:
  `test(fake-tailscaled): push bytes and hold requests`.
- [x] **Code.** Writes go through a per-client writer lock. A push skips
  held clients and parked ones (Task 7). It returns how many clients took
  the bytes.
- [x] **Prove.** As Task 3.
- [x] **Commit.** `feat(fake-tailscaled): push to clients and hold a request in flight`.

### Task 5: the reports the barriers read (R-FAKE-07)

**Interface:** `clients() -> Vec<ClientReport>` (id in accept order,
connected, received, written, held, parked, stream), `connected_count()`,
`accepted_total()`, `disconnects()`.

- [x] **Test:** `r_fake_07_reports_what_the_barriers_read`, R-FAKE-07's
  acceptance step by step: 19 received, 2 written, 1 connected, 1 accepted;
  6 written after the `abc` push; 24 received and no new request after
  `GET /`; a second client; a disconnect handled (`disconnects()` moves)
  leaves 1 connected and 2 accepted. Commit:
  `test(fake-tailscaled): report bytes and clients for the barriers`.
- [x] **Code.** Counters in the shared state, updated before `notify_all`.
  Replace Task 3's stub.
- [x] **Prove.** As Task 3.
- [x] **Commit.** `feat(fake-tailscaled): report received and written bytes per client`.

### Task 6: close one chosen client (R-FAKE-03) and destroy (R-FAKE-06)

**Interface:** `close_client(ClientId) -> bool`;
`client_holding(&[u8]) -> Option<ClientId>`.

- [x] **Tests:**
  - `r_fake_03_drops_one_chosen_client`. The fake's half of R-FAKE-03, with
    a raw test client standing in for the transport: a held GET of
    `/status` plus a keep-open client that has already been answered.
    Closing only the held client gives that client end of file. The other
    still receives a pushed line, and a new connection is still answered.
    `connected_count` drops by exactly 1.
  - `r_fake_06_disconnects_its_clients_and_removes_the_socket_when_destroyed`.
  - Append to `tests/test-fake-tailscaled.sh` the 50-run loop: build once
    with `cargo test --locked --no-run -p fake-tailscaled`, then run
    `cargo test --locked -q -p fake-tailscaled` 50 times and fail with the
    run number at the first failure. This mirrors check 3b of
    `tests/test-c7-plugin.sh`.

  Commit: `test(fake-tailscaled): close one client and keep serving the rest`.
- [x] **Code.** `shutdown(Both)` on that client's stream, and mark it
  disconnected when its reader sees end of file.
- [x] **Prove.** `tests/test-fake-tailscaled.sh`. It prints 50 passing runs.
- [x] **Commit.** `feat(fake-tailscaled): drop one chosen client on demand`.

### Task 7: scripted HTTP replies

**Files:** create `src/reply.rs`, `src/script.rs`, `src/bytes.rs`,
`tests/http_replies.rs`.

**Interface:** `Fake::set_script(Script)` (implies the `\r\n\r\n`
delimiter and per-rule keep-open), `push_watch_line(&[u8]) -> usize` (writes
`<hex len>\r\n<line>\n\r\n` to every stream client), `resume(&str) ->
usize`, and `Request::unmatched`.

- [x] **Tests.** A raw client sends a request and asserts the exact bytes
  received, then end of file or still open, for:
  - `Content-Length` (the header added, body exact);
  - a declared wrong length (`Content-Length: 99` and 9 bytes, then close);
  - `chunked` as one chunk; given sizes (`6`, `7`, `0`); `;ext=1`; a
    trailer; no final chunk;
  - `none` framing, then close or keep open;
  - 403 with a body; 500 with `{"error":"boom"}`; the raw status lines
    `garbage` and `HTTP/1.1 abc OK`;
  - `close-without-reply`;
  - a split at byte 40 with await `rest`: exactly 40 bytes arrive and the
    client is parked (a push skips it). `resume("rest")` delivers the rest.
  - a `stream` rule then `push_watch_line(b"{\"a\":1}")` giving
    `7\r\n{"a":1}\n\r\n`;
  - `times: 1` falling through to the next rule;
  - an unmatched request answered `HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n`
    and flagged;
  - a `hold` rule released by `complete_held`.

  Also a `Bytes` round trip: a string, hex, and `{"json": ...}` serialised
  compactly. Commit: `test(fake-tailscaled): script every reply shape the scenarios need`.
- [x] **Code.** `ReplySpec::encode() -> (Vec<u8>, Vec<Split>)`, pure. The
  rule engine runs inside the handler path. A parked client holds the
  remaining bytes and its label.
- [x] **Prove.** As Task 3, plus
  `cd plugin && cargo clippy --locked -p fake-tailscaled -- -D warnings`.
- [x] **Commit.** `feat(fake-tailscaled): replay scripted LocalAPI replies`.

### Task 8: the standalone binary (P2)

**Files:** create `src/control.rs`, `src/bin/fake-tailscaled.rs`,
`tests/binary.rs`.

**Protocol.** On start, one line: `{"event":"listening","path":"..."}`, or
`{"event":"not-listening","reason":"..."}` and exit 2. Then each stdin line
is `{"id":N,"cmd":"...",...}` and gets one stdout line
`{"id":N,"ok":true,"result":...}` or `{"id":N,"ok":false,"error":"..."}`.
The commands are `requests`, `clients`, `connected`, `accepted`,
`set-script`, `push-line`, `push-chunk`, `push-to`, `push-watch-line`,
`hold-next`, `complete-held`, `held-count`, `resume`, `close-client`,
`faults` (the fake's own failures) and `set-write-timeout` (`ms`, at least 1). Out
of process, a client waits by polling `requests` or `clients`, a bounded
poll. The binary has no wait command. End of stdin: drop the fake, exit 0.

- [x] **Tests** (they spawn `env!("CARGO_BIN_EXE_fake-tailscaled")` in a
  `TestDir`):
  - the listening event, and the refusal (exit 2, `already exists`);
  - every command once;
  - malformed JSON and an unknown command answered `ok:false` without
    exiting;
  - closing stdin removes the socket and exits 0;
  - `binary_and_library_record_the_same_bytes`: one script and the same
    client traffic, run in-process and through the binary, give equal
    `requests()` (compared as `Bytes` JSON).

  Commit: `test(fake-tailscaled): run the fake as a standalone binary`.
- [x] **Code.** `control::serve` reads lines in a loop on the main thread.
  The binary's `main` parses arguments by hand (no `clap`).
- [x] **Prove.** As Task 3.
- [x] **Commit.** `feat(fake-tailscaled): a standalone binary controlled over stdin`.

### Task 9: the scenario format

**Files:** create `src/scenario.rs`, `tests/scenario_format.rs`.

- [x] **Tests:** `Scenario::load(path)` accepts a full inline example of
  each step and expect kind. It rejects each of these, with an error naming
  the field:
  - an unknown field;
  - `format` other than 1;
  - an `id` that differs from the file stem;
  - empty `requirements`;
  - an `advance_ms` step with `needs: []`;
  - `evidence: harness-on-cpp` with needs;
  - a `fix` declaring `pass` on `cpp-286`;
  - `cannot-run` with needs the implementation has;
  - `failing` naming an unknown or precondition expect id;
  - a missing `on.rust`;
  - duplicate expect ids;
  - split offsets out of order.

  Plus `every_committed_scenario_validates`, which loads every
  `tests/fixtures/tailscale/scenarios/*.json` and passes with none there
  yet. Commit: `test(fake-tailscaled): define and validate the scenario format`.
- [x] **Code.** `serde` types (`#[serde(deny_unknown_fields)]`), `Script`
  built from `fake.rules`, `Scenario::derived_needs()`, `validate()`.
- [x] **Prove.** As Task 3.
- [x] **Commit.** `feat(fake-tailscaled): load and validate scenario files`.

### Task 10: the evidence classification

**Files:** create `src/evidence.rs`, `tests/evidence.rs`,
`tests/fixtures/tailscale/evidence.json`.

- [x] **Tests** (they read the spec and the traceability file from the
  repository, through `CARGO_MANIFEST_DIR`):
  - The IDs equal the spec's `### R-...` headings above "Contract
    additions": exactly 154, each once. Each `tag` equals the heading's.
  - `class` is one of the five. `none` holds exactly the `withdrawn` and
    `follow-up` IDs. `fake-self` holds exactly R-FAKE-01, -02, -03, -05,
    -06 and -07.
  - `cpp-suite` entries are `parity`, and their `tests` equal **exactly**
    the Table B rows whose requirement cell names that ID (`file::function`
    under each `###` file heading, or `file:line` for a shell check row).
    The tests of a deferred `cpp-suite` clause are a non-empty subset of
    those rows.
  - `phase3-only` entries have a `reason` starting `cannot run on C++:`
    (or, for parity with no Table B row, `no #286 test and cannot run on
    C++:`) and non-empty `needs`.
  - `harness-on-cpp` entries are `parity` or `fix`. Each deferred clause
    has a class and needs.
  - Every `needs` value is a known capability or `added-member` or
    `outside-module`.
  - `every_fake_requirement_has_its_tests`: for each `fake-self` ID, the
    fake crate's `tests/*.rs` define at least one `fn r_fake_0N_`. For
    R-FAKE-06, they define one per Table B function mapped to it in "tests
    from before #286", snake-cased.
  - `scenarios_agree_with_the_evidence`: each scenario's requirements exist,
    its `evidence` equals the entry's class or a deferred clause's class,
    and a `harness-on-cpp` scenario declares `pass` or `fail` on `cpp-286`.

  Commit: `test(fake-tailscaled): check the evidence classification against the spec`.
- [x] **Code.** Write `evidence.json` by applying "the procedure" to every
  requirement, reading each acceptance criterion in full. Take each
  `cpp-suite` `tests` list from Table B. Write `src/evidence.rs` (types and
  the two markdown readers: headings, and Table B rows).
- [x] **Prove.** As Task 3. Then hand-check five random entries per area
  against the procedure, and record which ones in the PR description.
- [x] **Commit.** `feat(fake-tailscaled): classify all 154 requirements by evidence`.

### Task 11: the reference build and harness bring-up

**Files:** create the `plugin/tests/tailscale-parity/` crate (`Cargo.toml`,
`build.rs`, `src/{lib,probe,contract,implementation}.rs`, `qml/driver.qml`,
`tests/harness_selftest.rs`, `build-reference.sh`, `README.md`); add it to
the workspace `members` (not `default-members`).

- [x] **Test.** `tests/harness_selftest.rs` (`harness = false`) runs these
  bring-up checks:
  1. `import C7Harness` resolves in the test binary, and a `Probe` round
     trip returns what the driver sent. This proves P7, or stops the task
     (see Stop below).
  2. With `C7_QML_DIR` unset, `Implementation::from_env()` fails with a
     message containing `build-reference.sh`. A directory without
     `C7/qmldir` fails the same way.
  3. With `C7_IMPL=cpp-286`, `C7_QML_DIR` set, and `TS_SOCKET` set by
     `Command::env` in a respawned child to an absent path in a private
     root, the driver loads and `Contract::read("state")` equals
     `Contract::enum_value("NoState")`. `members()` lists `writeError`, and
     `signal_count("writeErrorChanged")` is 0. This is check 6 again, with
     Rust reading the contract.

  Run `cd plugin && cargo test --locked -p tailscale-parity --test harness_selftest`.
  It fails: nothing builds yet. Commit:
  `test(tailscale-parity): load a C7 module and read Tailscale from Rust`.
- [x] **Code:**
  - `probe.rs`: a `#[qml_element] #[qml_singleton]` `Probe` with
    `#[qsignal] fn command(json: QString)`, `#[qinvokable] fn reply(json:
    &QString)` and `#[qinvokable] fn ready()`. `cxx_qt::Initialize` stores
    the instance in a thread-local, which `Drop` clears. Register the
    module with the call cxx-qt 0.10 documents for a statically linked QML
    module in a test binary.
  - `driver.qml`: `import QtQml`, `import C7`, `import C7Harness`. In
    `Component.onCompleted` it connects a counter to every `Tailscale`
    member named `*Changed` that has `connect`, then calls `Probe.ready()`.
    A `Connections` on `Probe` handles `onCommand` with the ops `read`,
    `enum`, `call`, `count` and `members`. Values are encoded as JSON
    (enums as ints, an invalid `Date` as `{"date": null}`, a valid one as
    its ISO string, a model as `{"rows": rowCount()}`). Any exception
    becomes `{"error": ...}`.
  - `lib.rs`: `headless_app()`, `wait_until` and `pump`, as in the spike.
    `MAX_ITERATIONS` is overridable by `C7_HARNESS_MAX_ITERATIONS`, for the
    self-tests only.
  - `build-reference.sh`, with `set -euo pipefail`:
    - Pin `sha=a38dbcae841a1134514f68cba8f5b98d4efddb68`. Set
      `cache=${C7_REFERENCE_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/c7shell/tailscale-reference}/$sha`.
    - If `git cat-file -e "$sha^{commit}"` fails, run
      `git fetch origin feat/tailscale-backend`. Fail, exit 2, if the commit
      is still missing.
    - `git worktree prune`. If `$cache/src` is missing, run
      `git worktree add --detach "$cache/src" "$sha"`.
    - Check that `HEAD` there is `$sha` and that `git status --porcelain` is
      empty.
    - `cmake -S "$cache/src/plugin" -B "$cache/build" -G Ninja -DCMAKE_BUILD_TYPE=Debug`,
      then `cmake --build "$cache/build" --target c7`.
    - Check `$cache/build/qml/C7/qmldir`, and print `$cache/build/qml` as
      the last line.
    - Never touch `/home/joren/git/c7shell-286`.
- [x] **Prove.**
  `qml=$(plugin/tests/tailscale-parity/build-reference.sh | tail -1) && cd plugin && C7_IMPL=cpp-286 C7_QML_DIR=$qml cargo test --locked -p tailscale-parity --test harness_selftest`.
  It passes. A second `build-reference.sh` rebuilds nothing (Ninja: "no
  work to do"). `shellcheck plugin/tests/tailscale-parity/*.sh` prints
  nothing.
- [x] **Stop condition.** If cxx-qt 0.10 cannot register a static QML module
  in a test binary, or a Rust-emitted signal does not run the QML handler
  before `emit` returns, stop and report. That is a spike-class failure
  ("Spike failure: stop and re-decide"). The fallback to propose is a
  dynamic `C7Harness` plugin staged like the spike's `C7Spike`.
- [x] **Commit.** `feat(tailscale-parity): build #286's C7 and drive it from Rust`.

### Task 12: the scenario runner

**Files:** create `src/runner.rs`, `src/child.rs`,
`selftest/qml/C7/{qmldir,Tailscale.qml}`, `selftest/scenarios/*.json`,
`tests/scenarios.rs`; extend `tests/harness_selftest.rs`.

- [x] **Tests.** `harness_selftest` runs each `selftest/scenarios/*.json`
  against the stub (`C7_QML_DIR=<crate>/selftest/qml`, implementation name
  `stub`, no capabilities, `C7_HARNESS_MAX_ITERATIONS` small). It asserts
  the runner's verdict:

  | Self-test scenario | Verdict the test asserts |
  |---|---|
  | declared pass, all expectations hold | matches |
  | declared fail with the exact id and actual | matches |
  | declared fail, but it passes | mismatch: "unexpected pass" |
  | declared fail, actual differs | mismatch naming both values |
  | a wait never reached | error, even when declared fail |
  | a failed precondition | error |
  | `needs: ["clock"]` declared `cannot-run` | matches without starting the child's app |
  | `needs: ["clock"]` declared `pass` | rejected at load |
  | a request the script does not match | error naming it |
  | the child crashes (stub `call` of `Qt.exit(3)` before a result) | error "no result line" |

  It also asserts the child's environment: only the keep-list plus the
  private `HOME`, `XDG_*`, `TMPDIR` and `TS_SOCKET` (the stub reports it
  through `Qt.application.arguments`, which the child sets). It asserts the
  private root is removed afterwards. Commit:
  `test(tailscale-parity): pin the runner's verdicts on a stub C7`.
- [x] **Code.** Child: load the scenario, start the `Fake` at `TS_SOCKET`
  with its script, start the app and engine (import path `C7_QML_DIR`
  only, `QML_IMPORT_PATH` and `QML2_IMPORT_PATH` removed), run the steps,
  and print one `C7-SCENARIO-RESULT <json>` line. Parent: list the
  scenarios (`C7_SCENARIOS` filters by id), give each a private root, and
  respawn with `env_clear()` and the allowlist. Keep `LLVM_PROFILE_FILE`
  and `CARGO_LLVM_COV*` so coverage still works. Parse the line, compare it
  with `on.<impl>`, print `ok`/`FAIL` per scenario, and repeat
  `C7_REPEAT` times, stopping at the first mismatch with the run number.
  `tests/scenarios.rs` is the parent's `main`. `run.sh`:
  `qml=$(build-reference.sh | tail -1)`, then `cd plugin && C7_IMPL=cpp-286
  C7_QML_DIR=$qml C7_REPEAT=${repeat:-1} cargo test --locked -p
  tailscale-parity --test scenarios`.
- [x] **Prove.** `cd plugin && cargo test --locked -p tailscale-parity --test harness_selftest`.
  With no scenario files yet,
  `plugin/tests/tailscale-parity/run.sh` fails with `no scenarios found`. An
  empty run is a failure, not a pass.
- [x] **Commit.** `feat(tailscale-parity): run scenarios in a private child per scenario`.

### Task 13: the parity scenario, R-HTTP-01

**Files:** create `tests/fixtures/tailscale/scenarios/http-01-request-line-and-host.json`.

The criterion is rendered through the backend's opening pass. The transport
is not reachable through QML, but every request #286 sends goes through the
one request builder (`plugin/lib/tailscale/LocalApiClient.cpp:152-160`), and
the opening pass sends four of them (watch, `/status`, `/prefs`,
`/suggest-exit-node`; `LocalApiTailscaleBackend.cpp:244-282`).

```json
{
  "format": 1,
  "id": "http-01-request-line-and-host",
  "requirements": ["R-HTTP-01"],
  "tag": "parity",
  "evidence": "harness-on-cpp",
  "clauses": [
    "Every request starts with `<METHOD> <path> HTTP/1.1`, carries `Host: local-tailscaled.sock` and, without a body, no other header: the four requests of the backend's opening pass, each recorded as exactly its request line, the Host line and CRLFCRLF",
    "tailscaled would accept that request: 200 replies to those requests bring the contract to Running"
  ],
  "deferred": [
    "exactly one request after the read and fake barriers: needs the read barrier (cpp-suite: tst_localapiclient.cpp::sendsAHostHeaderTailscaledAccepts; Phase 3: the transport test)"
  ],
  "needs": [],
  "fake": { "rules": [
    { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" },
      "stream": { "status": 200, "framing": "chunked" } },
    { "match": { "method": "GET", "target": "/localapi/v0/status" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {
        "BackendState": "Running",
        "CurrentTailnet": { "Name": "example.com" },
        "Self": { "ID": "nSELF1CNTRL", "HostName": "self", "DNSName": "self.example.ts.net.",
                  "TailscaleIPs": ["100.64.0.1"], "Online": true },
        "Peer": {} } } } },
    { "match": { "method": "GET", "target": "/localapi/v0/prefs" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {
        "WantRunning": true, "RouteAll": false, "CorpDNS": true,
        "ExitNodeID": "", "ExitNodeAllowLANAccess": false } } } },
    { "match": { "method": "GET", "target": "/localapi/v0/suggest-exit-node" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {} } } }
  ] },
  "steps": [
    { "start": {} },
    { "wait": { "contract": { "state": { "enum": "Running" } } } },
    { "wait": { "fake": { "connected": 1 } } },
    { "expect": { "id": "status-request", "request": { "match": { "method": "GET", "target": "/localapi/v0/status" },
      "raw": "GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n" } } },
    { "expect": { "id": "prefs-request", "request": { "match": { "method": "GET", "target": "/localapi/v0/prefs" },
      "raw": "GET /localapi/v0/prefs HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n" } } },
    { "expect": { "id": "suggest-request", "request": { "match": { "method": "GET", "target": "/localapi/v0/suggest-exit-node" },
      "raw": "GET /localapi/v0/suggest-exit-node HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n" } } },
    { "expect": { "id": "watch-request", "request": { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" },
      "raw": "GET /localapi/v0/watch-ipn-bus?mask=18 HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n" } } }
  ],
  "on": { "cpp-286": { "result": "pass" }, "rust": { "result": "pass" } }
}
```

- [x] **Test.** Commit the file:
  `test(tailscale-parity): R-HTTP-01 request line and Host header, parity`.
- [x] **Prove it runs.** `plugin/tests/tailscale-parity/run.sh`: `ok
  http-01-request-line-and-host (cpp-286: pass, as declared)`. `cargo test
  -p fake-tailscaled --test scenario_format --test evidence` still passes.
- [x] **Prove it bites.** This step is not committed. Edit the Host value to
  `local-tailscaled.sock.` and the runner reports a mismatch on
  `status-request` showing both byte strings. Swap the `/prefs` rule to
  answer `[]` and the run is an error ("wait never reached: state Running"),
  not a pass. Revert both.
- No code commit: the scenario characterises #286 as it is. For Phase 3 it
  is the failing test the Rust module must pass.

### Task 14: the fix scenario, R-HTTP-09

**Files:** create `tests/fixtures/tailscale/scenarios/http-09-error-body-in-write-error.json`.

**Expected failure on `a38dbca`, exactly.** `writeError` reads
`/localapi/v0/prefs answered HTTP/1.1 403 Forbidden`. #286 fails a non-2xx
exchange as soon as its headers end (`plugin/lib/tailscale/LocalApiClient.cpp:221-230`,
reason `"%1 answered %2"` at `:227` from the status line), so it never reads
the body. The write client passes that reason unchanged to `writeError`
(`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:136-143` and
`:201-216`). The corrected value is
`/localapi/v0/prefs answered HTTP/1.1 403 Forbidden: prefs write access denied`.
The wait before the expectation (a `writeErrorChanged`) is reached on both
implementations, so the failure is that one value and never a timeout.

```json
{
  "format": 1,
  "id": "http-09-error-body-in-write-error",
  "requirements": ["R-HTTP-09"],
  "tag": "fix",
  "evidence": "harness-on-cpp",
  "clauses": [
    "Given a fake that answers a PATCH of /localapi/v0/prefs with HTTP/1.1 403 Forbidden and the body `prefs write access denied\\n`, writeError equals `/localapi/v0/prefs answered HTTP/1.1 403 Forbidden: prefs write access denied` (read after writeErrorChanged and the client barrier, in place of the read barrier)"
  ],
  "deferred": [
    "the chunked 403, the 500 bodies on /status, the empty and invalid UTF-8 bodies: harness-on-cpp, #307",
    "bounds and incomplete bodies, the watch cases and the backend half: phase3-only, they need the clock and the retry hook"
  ],
  "needs": [],
  "fake": { "rules": [
    { "match": { "method": "GET", "target": "/localapi/v0/watch-ipn-bus?mask=18" },
      "stream": { "status": 200, "framing": "chunked" } },
    { "match": { "method": "GET", "target": "/localapi/v0/status" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {
        "BackendState": "Running", "CurrentTailnet": { "Name": "example.com" },
        "Self": { "ID": "nSELF1CNTRL", "HostName": "self", "DNSName": "self.example.ts.net.",
                  "TailscaleIPs": ["100.64.0.1"], "Online": true }, "Peer": {} } } } },
    { "match": { "method": "GET", "target": "/localapi/v0/prefs" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {
        "WantRunning": true, "RouteAll": false, "CorpDNS": true,
        "ExitNodeID": "", "ExitNodeAllowLANAccess": false } } } },
    { "match": { "method": "GET", "target": "/localapi/v0/suggest-exit-node" },
      "reply": { "status": 200, "framing": "content-length", "body": { "json": {} } } },
    { "match": { "method": "PATCH", "target": "/localapi/v0/prefs" },
      "reply": { "status": 403, "reason": "Forbidden", "framing": "content-length",
                 "body": "prefs write access denied\n" } }
  ] },
  "steps": [
    { "start": {} },
    { "wait": { "contract": { "state": { "enum": "Running" } } } },
    { "wait": { "fake": { "connected": 1 } } },
    { "call": { "name": "setAcceptRoutes", "args": [true] } },
    { "wait": { "signal": { "name": "writeErrorChanged", "at_least": 1 } } },
    { "wait": { "fake": { "connected": 1 } } },
    { "expect": { "id": "patch-sent", "precondition": true,
      "requests": { "match": { "method": "PATCH", "target": "/localapi/v0/prefs" }, "count": 1 } } },
    { "expect": { "id": "write-error-keeps-the-daemons-words",
      "contract": { "writeError": "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden: prefs write access denied" } } }
  ],
  "on": {
    "cpp-286": { "result": "fail",
      "failing": [ { "id": "write-error-keeps-the-daemons-words",
                     "actual": "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden" } ],
      "reason": "#286 fails a non-2xx exchange at its headers (plugin/lib/tailscale/LocalApiClient.cpp:221-230) and never reads the body, so writeError is the status line alone; the defect pr286-body:119-120 names" },
    "rust": { "result": "pass" }
  }
}
```

- [x] **Test.** Commit the file:
  `test(tailscale-parity): R-HTTP-09 error body kept in writeError, fix`.
- [x] **Prove.** `plugin/tests/tailscale-parity/run.sh` prints `ok
  http-09-error-body-in-write-error (cpp-286: fail as declared:
  write-error-keeps-the-daemons-words)`. Edit `failing[0].actual` (not
  committed) and the runner reports a mismatch. Revert it.
- No code commit. The `patch-sent` precondition is setup, not acceptance
  ("Setup is not acceptance"), so it can never be the declared failure.

### Task 15: gates and wrap-up

- [x] `tests/test-fake-tailscaled.sh` passes: layout guards, the fake's
  tests, and 50 consecutive runs.
- [x] `plugin/tests/tailscale-parity/run.sh --repeat 50` passes: 50 runs of
  each scenario, matching its declaration in each.
- [x] `cd plugin && C7_IMPL=cpp-286 C7_QML_DIR=$qml cargo test --locked -p tailscale-parity --test harness_selftest`
  passes, 50 consecutive times in a loop.
- [x] Coverage, on stable:
  `cd plugin && cargo llvm-cov --locked -p fake-tailscaled --fail-under-lines 90`
  (the binary is covered through `CARGO_BIN_EXE_*`). Paste the summary into
  the PR description. Branch coverage needs the dated nightly and is not
  this PR's gate.
- [x] `cd plugin && cargo fmt --check && cargo clippy --locked --workspace --all-targets -- -D warnings`.
- [x] `tests/test-c7-plugin.sh`, `tests/test-native-boundary.sh` and
  `tests/test-native-boundary-selftest.sh` pass. Then the whole suite:
  `for t in tests/*.sh; do "$t"; done` (this checkout includes `5d04913`,
  so `tests/test-upgrade.sh` is safe to run).
- [ ] `graphify update .`
- [ ] The PR description lists every requirement each new test covers, the
  evidence class counts, the five hand-checked entries per area (Task 10),
  the coverage summary, the 50-run results, and "No Quickshell code copied
  or adapted." It asks the owner to confirm the per-clause reading.

## Gates for #306

| Gate | Command | Pass |
|---|---|---|
| Every R-FAKE requirement is tested | `cargo test -p fake-tailscaled --test evidence` (`every_fake_requirement_has_its_tests`) | green |
| The fake's tests are stable | `tests/test-fake-tailscaled.sh` | 50/50 |
| Line coverage of the fake crate | `cargo llvm-cov -p fake-tailscaled --fail-under-lines 90` | at least 90% |
| Parity scenario on `a38dbca` | `run.sh --repeat 50` | 50/50 pass |
| Fix scenario on `a38dbca` | `run.sh --repeat 50` | 50/50 fail as declared |
| Evidence file | `cargo test -p fake-tailscaled --test evidence` | 154 IDs, all checks green |
| C++ build on `main` unchanged | `tests/test-c7-plugin.sh` | green |
| Boundary | `tests/test-native-boundary.sh`, `tests/test-native-boundary-selftest.sh` | green |
| Review | three review agents | approve |

## Open points for the owner

1. **The per-clause reading** of split by evidence (above). If it is
   rejected, most `harness-on-cpp` entries become `cpp-suite` or
   `phase3-only`. The two scenarios stay as they are.
2. **#306's issue text** says the harness drives the explicit-advance clock,
   and #308's says its tests run "on the explicit-advance clock". The
   2026-10-21 decision moves the clock to Phase 3. This PR defines the
   `advance_ms` step and the `clock` capability only. Both issue texts need
   the owner's edit.
3. **Requirements outside the module** (R-BOOT, R-PKG, R-SEC-04, R-SEC-05)
   are not observable through QML. The procedure makes their parity ones
   `cpp-suite` (their #286 shell checks) and their `fix`/`new` ones (R-BOOT-03,
   R-BOOT-07, R-BOOT-08) `phase3-only`, although #286's bootstrap could be
   tested by a shell check today. Decide whether #308 adds such shell checks
   against the `a38dbca` tree.
4. **`PKGBUILD`.** `tests/test-fake-tailscaled.sh` runs in `check()` only
   where `cargo` exists, and fetches crates then. Adding `rust` to
   `makedepends` and a `cargo fetch` in `prepare()` is Phase 2b's switch of
   `PKGBUILD` to Cargo.

## What the later PRs inherit

- #307 to #309 add scenario files and, where needed, new step or expect
  kinds (a model-row read, a view-half driver for #286's views and the QML
  stand-in). Each new kind lands with its runner self-test first.
- #310 runs `run.sh` (and #286's suites) per mutant. The standalone binary
  is there if its script needs the fake without the Rust harness.
- Phase 2b ports the rest of `plugin/lib/testing/` beside this crate. Its
  `FakeSocketServer` port starts from `Fake`, which already passes the
  R-FAKE-06 ports.
- Phase 3 adds the `rust` implementation's capabilities to
  `implementation.rs`, and the clock, barrier and retry hooks behind them.
  It then runs every scenario with `C7_IMPL=rust`.

## Implementation notes (2026-10-21)

Where the implementation departed from the plan above, and why. Each is
also in the commit that made it.

1. **Cargo reports the target directory unnormalised.** `cargo metadata`
   prints `"target_directory":"<repo>/plugin/../target"`, so the guard in
   `tests/test-fake-tailscaled.sh` resolves the path (`realpath -m`)
   before it compares it with `<repo>/target`. Check 5 (no `plugin/target`
   after a build) still catches a target directory inside `plugin/`.
2. **A watch line's chunk length counts its newline.** `push_watch_line`
   writes `<hex(len + 1)>\r\n<line>\n\r\n`, so `{"a":1}` goes out as
   `8\r\n{"a":1}\n\r\n`. The plan's example gave `7`, the length without the
   newline, which is malformed chunked framing.
3. **No ninja on this host.** `build-reference.sh` passes `-G Ninja` only
   when `ninja` is on `PATH`, as `tests/test-c7-plugin.sh` does, and builds
   with `cmake --build ... --parallel $(nproc)` (make here). The first build
   took a few minutes; a second run is a no-op (`Built target c7`, 0.2 s).
4. **No worktree at all.** The plan's `git worktree prune` and `git
   worktree add` both write the shared repository's `.git/worktrees/`, and
   its `git fetch` writes refs, outside the cache the task allows. After
   review, `build-reference.sh` extracts the commit's `plugin/` tree with
   `git archive a38dbca plugin | tar -x` into `<cache>/<sha>/tree` (a stamp
   file, written last, names the commit), builds into `<cache>/<sha>/out`,
   and fails with the `git fetch` to run when the commit is missing. The
   worktree the first version registered at `<cache>/<sha>/src` is left
   for the owner to drop (`git worktree remove --force <path>`).
5. **`.qmlls.ini` is committed.** cxx-qt-build 0.10 writes
   `plugin/tests/tailscale-parity/.qmlls.ini` whenever the file is missing.
   Ignoring it would fail `tests/test-c7-plugin.sh` check 1, and leaving it
   untracked dirties the tree, so a portable one (a relative `buildDir`) is
   committed and the builder leaves it alone.
6. **`plugin/rustfmt.toml`** sets `max_width = 120`, the width the code is
   written to; `cargo fmt --check` passes with it.
7. **The child's environment is reported in its result line**, as a map in
   `C7-SCENARIO-RESULT`, not through `Qt.application.arguments`. The self-test
   asserts every name is on the keep-list, a private variable, a dead bus
   address, `QT_QPA_PLATFORM` or `TS_SOCKET`, and that `TS_SOCKET`, `HOME`,
   `XDG_RUNTIME_DIR`, `TMPDIR` and `PATH` lie under the private root. The
   child gets the scenario path and module directory as arguments and no
   `C7_IMPL`; it parses the scenario with the new `Scenario::read` (no
   validation; the parent has already validated it with `load_for`).
8. **`Qt.exit(code)` during a scenario ends the child** with that code and no
   result line. That is how the "child crashes" self-test stages a crash
   (the stub's `quit(3)`), and the parent reports `no result line`.
9. **The unmatched-request self-test runs against #286**
   (`selftest/scenarios-cpp/unmatched.json`), because the QML stub does no
   I/O: a script without a `/prefs` rule makes #286's opening pass request
   it, and the runner reports `GET /localapi/v0/prefs` as an error. The
   stub self-tests add one case, an unknown member, which is an error too.
10. **Task 13's second bite proof.** A `/prefs` answered `[]` still brings
    #286 to `Running`: #286 reads a non-object `/prefs` as defaults, the
    defect R-CONN-14 fixes. A `/prefs` answered 500 is used instead, and the
    run is an error (`wait never reached: state {"enum":"Running"}`), not a
    pass. The Host edit is a mismatch on `status-request`; the child's log
    shows the wanted and the actual bytes (a log line added test-first).
11. **Scenario validation, beyond the list in Task 9.** `start` must be the
    first step and appear once; a `parity` scenario cannot declare `fail` on
    `cpp-286`; `rust` declares `pass` or, while it lacks a capability the
    scenario needs, `cannot-run` (the rewrite has no capabilities until Phase
    3, so "a `fix` declares `pass` on `rust`" holds only for scenarios with
    no needs); a declared `fail` or `cannot-run` must give a `reason`.
12. **The evidence file.** 81 `harness-on-cpp` (2 in #306, the rest in #307
    to #309), 37 `cpp-suite`, 25 `phase3-only`, 6 `fake-self`, 5 `none`.
    Entries carry `pr` and `runs` (harness-on-cpp), and the file carries
    `notes` stating how the procedure was applied: the transport's own
    outcomes are `outside-module`, the request bytes it sends are not (the
    fake records them when a backend pass or action sends them), and values
    of one published snapshot are read once a positive wait has seen that
    snapshot. R-UI-02 and R-UI-13 are `harness-on-cpp`, not `phase3-only` as
    "Worked entries" said: their parity sub-checks (the 24 names, the five
    signatures) run on `a38dbca`, and only the exact-set clauses, deferred as
    `phase3-only` (`added-member`), need the additions. One check was added:
    every `harness-on-cpp` entry assigned to #306 has a scenario.
13. **`shellcheck` is not installed on this host**, so Task 11's
    `shellcheck plugin/tests/tailscale-parity/*.sh` was not run.
14. **Results.** `tests/test-fake-tailscaled.sh`: the layout guards, the
    fake's tests and 50 consecutive runs pass. `run.sh --repeat 50`: 50/50,
    R-HTTP-01 passing and R-HTTP-09 failing as declared in every run.
    `harness_selftest`: 50/50. `cargo llvm-cov -p fake-tailscaled`: 94.61%
    lines (1225 lines, 66 missed), 94.15% regions. `cargo fmt --check` and
    `cargo clippy --workspace --all-targets -- -D warnings` are clean.
15. **Review round 1 (code-reviewer, test-analyzer, silent-failure-hunter).**
    - R-HTTP-01 waited only on `connected: 1` before reading the request
      log, which a watch request the fake had not yet read could satisfy:
      3 of 12 parallel jobs of 40 runs failed (`watch-request` actual
      null). The scenario now waits on `recorded` for each of the four
      requests first. 12 parallel jobs of 40 runs pass.
    - The runner's failing paths are pinned: a request expectation on other
      bytes (actual: the bytes sent), on a request never sent (actual
      null), a requests and a signal expectation on a wrong count, a client
      barrier never reached. Each mutant the review named is killed.
      `client_holding` is pinned with two held requests.
    - A push, resume or completion that reaches no client ends the step in
      an error, and so does a hold armed and never used
      (`Fake::armed_hold`).
    - `C7_REPEAT` / `--repeat` below 1 or not a number exits 2; a
      `C7_SCENARIOS` id naming no scenario is an error naming it.
    - The driver reports an exception while it starts through
      `Probe.failed`, so a C7 without `Tailscale` fails at once with
      `ReferenceError: Tailscale is not defined`.
    - A write that times out and an `accept()` that fails are the fake's
      faults (`Fake::faults`); the runner reports them ahead of anything
      else. A broken pipe or reset is not a fault.
    - Not moved out of the lock: the fake's writes still block. Instead
      `MAX_WRITE` (128 KiB) bounds every scripted reply, stream head, push
      and completion at load time, below an unread Unix socket's one-write
      capacity (about 228 KiB with the default 208 KiB `wmem_default`).
      Many small pushes fill it sooner (about 27 KiB in 100-byte writes);
      a scenario must pump between long runs of pushes. A per-client
      writer queue is the fix if a later scenario needs more.
    - `MAX_ITERATIONS` is 1 000 000 (about 10 s), down from 50 000 000
      (about 9 min); measured waits take under 300.
    - `server.rs` is split into `client.rs`, `scripted.rs` and
      `listener.rs` (496 lines left); `run_one` and `Run::step` are under
      50 lines.
    - `/plugin/target/` is ignored and skipped by both layout guards;
      check 5 builds the workspace with `--all-targets`.
    - `tests/test-tailscale-parity.sh` runs `harness_selftest` and 50
      scenario runs when the reference build is cached, and skips
      otherwise. `run.sh` itself stays a manual gate.
    - Results: `tests/test-fake-tailscaled.sh` (50 runs) passes;
      `harness_selftest` 50/50; `tests/test-tailscale-parity.sh` 50/50;
      12 parallel jobs x 40 runs of both scenarios pass; fake coverage
      94.48% lines; `cargo clippy -- -D warnings` and `cargo fmt --check`
      clean; `tests/test-c7-plugin.sh` and `tests/test-native-boundary.sh`
      pass.
