# Plan: rewrite PR #286 (Tailscale backend) in Rust

Status: draft. No Rust code is written until Phase 3, and Phase 3 does not
start until the Phase 0 decision and the Phase 1–2 exit gates are met.

Source of truth for behaviour: branch `feat/tailscale-backend` (PR #286, open,
+14,770 lines). The QML under `quickshell/c7shell/Modules/` and the
`TailscaleBackend` contract surface stay; only the system side is rewritten.

## Decisions (2026-10-19)

| Decision | Choice | Consequence |
|---|---|---|
| Language | Rust, no hand-written C++ | `docs/architecture.md:178` and `CLAUDE.md` change in the first PR |
| Bridge | cxx-qt | Qt Bridges (`qt/qtbridge-rust`) rejected for now: it owns the engine and builds no QML plugin |
| PR #286 | Kept as an unmerged reference branch | Characterisation tests run against `feat/tailscale-backend`; `main` never holds its C++ |
| Async | tokio runtime, results marshalled with `CxxQtThread::queue` | The spike must prove clean runtime shutdown on Quickshell reload and object destruction |
| Reconnect machinery | Extracted now, as a Rust `plugin/lib/core/` crate with Tailscale as its first caller | Replaces the follow-up extraction #286 proposed |
| Known defects | Fixed during the rewrite | Phase 2 splits into parity tests and defect tests (see below) |
| Build | Cargo only, no CMake | A Cargo-only QML plugin build is unverified; the spike must prove it before Phase 1 |
| Existing C++ | Ported in this rewrite: `plugin/lib/core/`, `plugin/lib/testing/`, `plugin/tests/tst_module.cpp`, `plugin/src/build.h` | The repository ends with zero hand-written C++ and no `plugin/CMakeLists.txt` |
| Enforcement | `tests/test-native-boundary.sh` learns Rust contracts and backends, and fails on any hand-written `.cpp`/`.h` | The selftest proves the new check catches a planted `.cpp` |
| QML tests | Driven from Rust test binaries through cxx-qt | `tests/tailscale-qml-test.qml` (1,768 lines) is rewritten; the spike must prove a Rust test binary can load QML headless (`QT_QPA_PLATFORM=offscreen`) |
| Spike failure | Stop and re-decide; no automatic fallback | Any failed spike check ends Phase 0 with a report, not a workaround |
| Time in tests | `tokio::time::pause()` / `advance()` | No sleeps; the core crate uses tokio time throughout |
| PR slicing | One PR per phase, each with the three-agent review | Rule change + spike, requirements, characterisation tests, harness port, core crate, Tailscale crates, cut-over |
| #286 non-goals | `AdvertiseRoutes` and in-panel login are in scope | Both designs are undecided: login needs a browser flow, and an exit node may need IP forwarding |
| Tracking | A GitHub epic with one sub-issue per phase PR | The plan links to the epic once it is filed |
| Linker (2026-10-20) | rust-lld, pinned in `.cargo/config.toml` | GNU ld cannot export the plugin entry points (spike check 8); `PKGBUILD` appends `-C link-arg=-fuse-ld=lld` to makepkg's `RUSTFLAGS` |
| Branch coverage (2026-10-20) | Only the coverage gate runs on a pinned, dated nightly | Stable rejects `--branch`; the plugin builds and ships on stable |
| Split by evidence (2026-10-21) | Requirements that need no time are characterised by the Rust harness against the `a38dbca` C++ build loaded through QML. A requirement whose acceptance needs the explicit-advance test clock, an injected timing, a test hook or a decided member #286 lacks cannot run against the C++ through QML | Timing `parity` requirements take #286's own QtTest suites as their C++ evidence, as mapped in the traceability's Table B, and their Rust tests are written in Phase 3. Timing `fix` and `new` requirements are written in Phase 3 and recorded as "cannot run on C++". `tests/fixtures/tailscale/evidence.json` records each requirement's class (plan `2026-10-21-phase2-harness.md`) |

## Phase 0 — adopt Rust (decided)

The rewrite is in Rust; that decision is made. `docs/architecture.md:178` and
`CLAUDE.md` still say "C++ with Qt 6, and nothing else", so update them in the
first PR of this work:

1. Amend the rule to allow Rust, and state where it is allowed (proposal:
   `plugin/lib/<name>/` pure libraries), the bridge, the toolchain in
   `PKGBUILD`, and how the coverage, mutation and 50-run gates apply to Rust
   (`cargo llvm-cov`, `cargo mutants`, `cargo nextest` ×50).
2. Use cxx-qt end to end (decided: no hand-written C++). Rust owns the
   LocalAPI client, parser, peer model, backend and the `QML_SINGLETON`
   contract (`#[qml_element]` + `#[qml_singleton]`), and the list models
   (`#[base = QAbstractListModel]`). cxx-qt generates C++ glue at build time.
   That glue is build output, never committed or edited. Before Phase 1, run
   a spike that proves these on this Qt and Quickshell version: a Rust
   singleton loads in Quickshell, a Rust `QAbstractListModel` keeps stable rows
   across a reset-free update, and `cargo llvm-cov` measures coverage through
   the bridge. It must also prove four more: a Cargo-only build produces a
   QML plugin Quickshell loads; tokio shuts down cleanly on Quickshell reload
   and object destruction; a Rust test binary loads QML headless
   (`QT_QPA_PLATFORM=offscreen`); and that binary loads the C++ #286 plugin,
   so the Rust-driven QML tests have a parity baseline. If any check fails,
   stop and report it before going on.

Exit: the architecture and `CLAUDE.md` change is merged and the cxx-qt spike passes.

## Phase 1 — requirements and acceptance criteria

Write `docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md`.
Derive every requirement from the branch, not memory: the two specs and two
plans under `docs/superpowers/`, `plugin/src/contracts/TailscaleBackend.h`,
the PR description's "measured, not assumed" list, and the existing tests.
Give each one an ID, a source `file:line`, and an acceptance criterion phrased
as an observable test.

Requirement areas (minimum set):

| ID | Area | Examples of acceptance criteria |
|---|---|---|
| R-HTTP | LocalAPI transport | De-chunks `/status` and `/watch-ipn-bus`; honours `Content-Length` on `/prefs`, `/suggest-exit-node`; sends `Host: local-tailscaled.sock`; error body preserved |
| R-PARSE | Status parsing | Exit node name joined via `Peer[].ID`; IP masks stripped for exit node only; malformed input → named diagnosis, never a crash |
| R-GROUP | Peer model | Own → tagged → shared grouping; named by DNS label, not OS hostname; stable rows across updates |
| R-WATCH | IPN bus | Updates from `watch-ipn-bus`, no polling; client-side skip of unmasked notifications; straggler reply from attempt N never applied in N+1 |
| R-CONN | Lifecycle | Reconnect backoff curve, settle timer, `OpeningRead` wholeness, the seven read-failure diagnoses each distinct |
| R-WRITE | Prefs writes | `PATCH /prefs` always sends the `…Set` sibling; switches read back from daemon; only 403 sets `writable = false`; other failures are transient |
| R-UI | Contract surface | Every `Q_PROPERTY`, signal and `Q_INVOKABLE` in `TailscaleBackend.h` with identical names, types and notify behaviour; six bar-slot states reachable |
| R-SEC | Untrusted input | Hostnames from the network never reach a rich-text sink; no shell-out |
| R-BOOT | Bootstrap | `c7shell-bootstrap` names the desktop user as operator |

The PR's "deliberately does not do" list (`AdvertiseRoutes`, in-panel login)
is in scope for this rewrite. Each becomes a requirement tagged `new`, with
its design left open for refinement. Turn
each "known work" defect into a requirement with the corrected behaviour, tagged
`fix`. Parity requirements are tagged `parity`.

Exit: every public symbol in the contract header and every assertion in the
existing suites maps to at least one requirement ID. Reviewers approve.

## Phase 2 — language-neutral characterisation tests

Pin today's behaviour with tests that do not care which language implements
it. They run green against the C++ branch first.

1. **Contract-level suite.** `tests/tailscale-qml-test.qml` and
   `plugin/tests/tst_tailscalebackend.cpp` drive the contract, not internals.
   Audit them against the requirement table, and add tests for each
   requirement with no coverage.
2. **Wire-level golden traces.** Extend `FakeSocketServer` (or add a
   use a fake daemon) to record every request byte the backend sends and
   to replay scripted replies. Write the fake daemon in Rust, as a standalone
   binary that serves a Unix socket. It works against the C++ branch today
   and the Rust backend later, and it adds no new C++. It must replay: chunked, split mid-chunk, wrong `Content-Length`,
   403, 500 with body, connection drop with one request in flight (the PR notes
   `FakeSocketServer` cannot do this yet — add per-client close). Store the
   scenarios as data files under `tests/fixtures/tailscale/scenarios/`, so the
   Rust suite reuses them verbatim.
3. **Parser corpus.** Turn the three `status-*.json` fixtures plus generated
   edge cases into input → expected-output pairs (JSON), consumable by both
   the Qt test and a future `cargo test`.
4. **Close the hollow tests.** The PR's test analyzer found six hollow tests
   and closed three. Close the other three now.
5. **Prove the suite bites.** Run mutation testing against the C++
   implementation. Every surviving mutant gets a killing test or a written
   justification. Target ≥ the repo's 70% gate, aim higher: this suite is the
   only proof the rewrite is equivalent.

6. **Split parity from fixes.** Parity tests must pass on the C++ branch.
   Each `fix` test must fail on the C++ branch, for the reason the defect
   describes, and pass on Rust. Record the expected failures in the scenario
   files, so the cut-over check can name every behaviour change. This holds
   for the requirements the harness can run on the C++; the others follow
   the "Split by evidence" decision (2026-10-21).

Exit: every `parity` scenario the harness runs on C++ passes on `a38dbca`
for 50 consecutive runs, and every `fix` scenario it runs there fails for
its stated reason in each of 50 runs. Every timing `parity` requirement
names the #286 QtTest functions that are its C++ evidence. Every requirement
that cannot run on C++ is recorded as such, with its reason, and its test is
written in Phase 3. The evidence file classifies all 154 requirements, the
mutation score is recorded as the baseline, and the scenario and corpus
files are committed.

## Phase 2b — port the existing C++ harness

Before the Tailscale crates, port what `main` already has, test first:

1. `plugin/lib/testing/` (`FakeSocketServer`, `FakeService`, `PrivateBus`,
   `FakeProgram`, `wait`, isolation) to a Rust `testing` crate. Port each
   `tst_*.cpp` in `plugin/lib/testing/tests/` as its acceptance test, and
   add the per-client close #286 lacked.
2. `plugin/lib/core/` (`version`) and `plugin/src/build.h` to the Rust core
   crate, beside the reconnect machinery.
3. `plugin/tests/tst_module.cpp` to a Rust test that loads the module.
4. Remove `plugin/CMakeLists.txt` and switch `PKGBUILD` and
   `tests/test-c7-plugin.sh` to Cargo.

Exit: the ported tests pass 50 consecutive runs, no `.cpp`/`.h` remains on
`main`, and the extended boundary check is green.

## Phase 3 — Rust implementation (test first)

Only now does production Rust code appear. The Phase 2 fake daemon is test code.

1. Create the crates: `plugin/lib/tailscale/` (pure Rust, no Qt: transport,
   parser, grouping, the reconnect state machine on a fake clock) and
   `plugin/src/backends/tailscale/` (cxx-qt: contract singleton, models,
   backend). Port the Phase 2 scenario and corpus files into `cargo test`
   harnesses first and watch them fail.
2. Implement in requirement order: R-HTTP, then R-PARSE, R-GROUP, R-WATCH,
   R-CONN, R-WRITE. Each step lands with its tests green.
3. Implement the cxx-qt contract with the same property, signal and
   invokable names as `TailscaleBackend.h`, so the QML does not change. Add a
   Rust fake backend that replaces `FakeTailscaleBackend.h`.
4. Build with Cargo, and load the module through Quickshell's QML import path.
5. Rewrite `tests/tailscale-qml-test.qml` as Rust-driven QML tests against
   the Rust fake backend. Keep every assertion's intent, mapped to its
   requirement ID.

## Phase 4 — parity and cut-over

1. Run Phase 2's suites against both implementations in CI. Diff the
   recorded wire traces byte for byte. Require zero diffs, except in
   scenarios tagged `fix`.
2. Run the Rust crate's gates: 90% line / 80% branch coverage, mutation
   score ≥ the C++ baseline, 50 consecutive runs.
3. Do a manual check on the test VM against a live `tailscaled`, covering
   the PR's "measured" list. `tailscale down` stays excluded, as in #286.
4. Delete every C++ file #286 added: `plugin/lib/tailscale/*.cpp|h`,
   `plugin/src/backends/tailscale/`, `plugin/src/contracts/TailscaleBackend.h`,
   and their `tst_*.cpp` files. Then run `tests/*.sh` and
   `graphify update .`, and have the three reviewers approve.

## Risks

- **Policy:** until the Phase 0 doc change lands, `docs/architecture.md:178`
  still forbids Rust, and reviewers following it will block.
- **Hidden behaviour in timing:** backoff, settle and straggler logic are the
  parts "got wrong twice". Tests must drive time with a fake clock, never sleeps.
- **Remaining C++ outside this feature:** `main` already holds C++ in
  `plugin/lib/core/` (version), `plugin/lib/testing/` (fakes, private bus) and
  `plugin/tests/tst_module.cpp`. This plan removes only #286's C++. Porting
  the rest is a separate plan. Otherwise the repository carries both languages.
- **cxx-qt maturity:** singleton and list-model support is the riskiest
  dependency. The Phase 0 spike exists to surface it before any other work.
