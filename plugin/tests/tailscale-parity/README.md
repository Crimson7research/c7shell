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
something the suite makes. `tests/test-tailscale-parity.sh` always runs
`stub_selftest`, the harness self-tests that need only the QML-only stub C7.
It runs `harness_selftest` and 50 runs of the scenarios when the reference
build is already in the cache, and skips them with the reason when it is
not. A `C7_QML_DIR` that holds no `C7/qmldir` is a failure, never a skip.
The parallel stress is run by hand until a later PR wires the reference
build into the suite.

## Run

```sh
plugin/tests/tailscale-parity/run.sh               # every scenario once against cpp-286
plugin/tests/tailscale-parity/run.sh --repeat 50   # 50 consecutive runs of each

qml=$(plugin/tests/tailscale-parity/build-reference.sh | tail -1)
cd plugin
cargo test --locked -p tailscale-parity --test stub_selftest
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
empty `PATH`, dead bus addresses, `QT_QPA_PLATFORM=offscreen`, `TZ=UTC`
(a date-time without a zone then reads the same on every host), and
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

## Kinds added after the plan

The plan's "Scenario format" lists the step and expect kinds #306 shipped.
These came later, each with its runner self-test under `selftest/`.

### Array values (#307)

A `contract` value in a `wait` or an `expect` may be an array of values the
format compares, for a string-list member such as `issues`:

```json
{ "expect": { "id": "issues", "contract": { "issues": ["a", "", ""] } } }
```

The driver reads a list as a JSON array, so the comparison is element by
element and in order. A failed one reports the array read as its actual
value. `{"enum": key}` inside an array is resolved like any other.

### Model reads (#307)

A `model` expect, and a `model` wait that holds once the same read does,
query a list model member of `Tailscale` (`peers`, `exitNodes`). Give
`name` and exactly one of `count`, `values` and `has_children`:

```json
{ "wait":   { "model": { "name": "peers", "count": 3 } } },
{ "expect": { "id": "gamma", "model": { "name": "peers", "row": 0,
              "values": { "hostName": "gamma", "group": 1 } } } },
{ "expect": { "id": "off-end", "model": { "name": "peers", "row": 99,
              "values": { "#0": { "undefined": true } } } } },
{ "expect": { "id": "flat", "model": { "name": "peers", "row": 0, "has_children": false } } }
```

- `count` is `rowCount()`; with `row` it is that row's child count. Its
  actual value is the count read.
- `values` reads roles of row `row` (required, never negative). A key is a
  role name or `#<n>`, role number `n` (`#0` is `Qt::DisplayRole`). A role
  named by name is read the way a view reads it, through a
  `DelegateModel` item for the row, since `roleNames()` is not invokable
  from QML: the row must exist and the name must be a role, or the step is
  an error naming it. A role by number goes straight to `data()`, so it
  can read any row, one off the end included. `{"undefined": true}` is no
  value. The actual value is the one role's value, or an object by role
  for several.
- `has_children` is `hasChildren()`, of the root or with `row` of that row.

A `name` that is no model member is an error. A model `wait` never reached
says what it last read.

### Model signals (#307)

Beside every `*Changed` signal, the driver counts each model member's
`rowsInserted`, `rowsRemoved`, `rowsMoved`, `modelReset`, `dataChanged` and
`layoutChanged` from the moment it loads, named `<member>.<signal>`. A
`signal` wait or expect takes those names as it takes any other:

```json
{ "expect": { "id": "no-reset", "signal": { "name": "peers.modelReset", "count": 0 } } }
```

Each model member is read once, at load, and its signals are connected
on that object: #286's `peers` and `exitNodes` are `CONSTANT`.

### Request parts (#307)

A `request_parts` expect checks every recorded request that matches by
its parts, so it pins neither header order nor JSON key order, which a
`request` expect's exact bytes would:

```json
{ "expect": { "id": "patch-bytes", "request_parts": {
  "match": { "method": "PATCH", "target": "/localapi/v0/prefs" },
  "starts_with": "PATCH /localapi/v0/prefs HTTP/1.1\r\n",
  "headers": [["Host", "local-tailscaled.sock"], ["Content-Length", "36"]],
  "body_json": { "RouteAll": true, "RouteAllSet": true } } } }
```

Each request starts with `starts_with`, ends its head with CRLFCRLF and
carries each header once (the name compared without case, the value
exactly). With `body_json` its body parses as JSON equal to it and its
`Content-Length` is the body's own byte length. At least one request
must match. A failure's actual value is the first differing request's
bytes, and the log says which part differed; no request reads null.

### Counts since a mark (#307)

A `{"mark": label}` step records the count of every signal the driver
counts, and a `signal` expect with `"since": label` compares the count
since that step instead of since load:

```json
{ "mark": "before-change" },
{ "fake": { "push_watch_line": "{\"State\":6}" } },
{ "wait": { "model": { "name": "peers", "row": 1, "values": { "online": false } } } },
{ "expect": { "id": "one-move", "signal": { "name": "peers.rowsMoved", "count": 1, "since": "before-change" } } }
```

This is how R-GROUP-06 to 08 count "from just before" a change: how
many signals the first fill emits is the implementation's choice. A
label is named once, and `since` names an earlier mark, or the scenario
is a format error.

### Bodies from capture files (#307)

A reply body, a stream head's body or a `complete_held` body may be
`{"file": path}`: the file's bytes, unchanged, read when the scenario is
loaded. The path is relative to the fixture root, the parent of the
scenario's directory, so a committed scenario names
`tests/fixtures/tailscale/captures/status-idle.json` as:

```json
{ "match": { "method": "GET", "target": "/localapi/v0/status" },
  "reply": { "status": 200, "body": { "file": "captures/status-idle.json" } } }
```

An absolute path, one with `..`, and a missing file are format errors
naming the rule or step. The self-tests' root is `selftest/`, so
`selftest/scenarios-cpp/served-change.json` reads
`selftest/captures/two-peers.json`.

### A served change

A change is a second `/status` reply. Give the first a `"times": 1` rule
and the second an `always` rule after it, then push a watch line that
starts a new pass. On #286, any notification with a non-null field other
than `Version`, `SessionID` and `Engine` does
(`LocalApiTailscaleBackend.cpp:57-70`, `worthRefreshing` at 298-309, called
from `onEvent` at 311-325), so
`{"State":6}` is enough. Wait for the first snapshot's value (a row count,
say) before the push, and for the second's after it: the opening pass asks
for `/status` once, and nothing else asks again until the push.
`selftest/scenarios-cpp/served-change.json` is the worked example.

## The parser corpus (#307)

`tests/fixtures/tailscale/corpus/` holds one case per `/status` input: a
capture from `tests/fixtures/tailscale/captures/` or a status written for
the case, and what the contract must publish from it. A case names
implementation-neutral output only, contract members and the `peers` and
`exitNodes` rows, so Phase 3's own tests read the same files. The format
is documented in `plugin/lib/testing/fake-tailscaled/src/corpus.rs`:

```json
{
  "format": 1, "id": "parse-03-ipv6-listed-first", "requirements": ["R-PARSE-03"],
  "tag": "parity", "clauses": ["Listing the IPv6 address first changes neither"],
  "status": { "file": "captures/status-idle.json" },
  "edits": [ { "op": "replace", "path": "/Self/TailscaleIPs",
               "value": ["fd7a:115c:a1e0::fd27:82d8", "100.115.228.122"] } ],
  "expect": { "contract": { "selfIp4": "100.115.228.122", "selfIp6": "fd7a:115c:a1e0::fd27:82d8" } },
  "on": { "cpp-286": { "result": "pass" }, "rust": { "result": "pass" } }
}
```

- `status` is `{"file": path}` (served byte for byte unless `edits`
  apply) or `{"json": value}`. `edits` are JSON Patch `add`, `replace` and
  `remove` operations. `prefs` (default `captures/prefs.json`) and
  `suggest` (default `{}`) answer the pass's other two reads.
- `expect.peers` and `expect.exitNodes` list every row, in order, each
  with the roles it checks by name.
- `tag` is the case's own: `fix` when it expects what #286 does not do,
  so it declares `fail` there; `parity` when #286 meets it, which a
  clause of a `fix` requirement can (R-GROUP-03's ASCII orders, say).

`cargo test --test corpus` makes each case a scenario in a private
directory and runs it as any scenario: the fake answers the opening pass
from the case, the run waits until `wantRunning` reads true (the prefs
half is published with the status half, R-WATCH-11) and, when the case
gives a suggestion, until `recommendedExitNodeIdChanged` has fired, then
expects `contract.<member>`, `<model>.count` and `<model>[<i>]`, the ids a
declared failure names. A row is read by role name, so a case can only
expect rows an implementation has; a shorter model fails at
`<model>.count` and then is an error at the first missing row.
`C7_SCENARIOS` and `C7_REPEAT` work as for the scenarios.

Each child runs with `TZ=UTC`: #286 reads a date-time without a zone as
local time, and the instant it then reads must not depend on the host.

The captures are #286's (`plugin/lib/tailscale/tests/fixtures/` at
`a38dbca`), whose names, users and addresses were already made up; the
node keys, numeric node ids and the tailnet's stable id were replaced with
made-up values too.

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
and every model member's own signals, so the same driver serves #286's
contract and the rewrite's.

No Quickshell code is copied or adapted here.
