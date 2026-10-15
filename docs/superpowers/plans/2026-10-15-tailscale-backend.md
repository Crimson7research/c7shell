# Tailscale C7 Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A read-only `Tailscale` C7 singleton backed by tailscaled's local API, and a bar slot and popover that bind to it — the first backend in the C7 plugin.

**Architecture:** Three layers. `plugin/lib/tailscale/` is plain Qt (Core + Network, no QML): value types, a JSON parser, a `QAbstractListModel` with stable rows, and an HTTP-over-`QLocalSocket` client. `plugin/src/contracts/TailscaleBackend.h` is the abstract `QObject` carrying `Q_PROPERTY`s and the QML-visible enum. `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp` subscribes to `watch-ipn-bus` and republishes into the contract. QML binds `Tailscale.*` and starts no process.

**Tech Stack:** C++20, Qt 6.5 (Core, Network, Qml, Test), CMake 3.21, QtTest, `c7::testing::FakeSocketServer`, Quickshell QML.

**Spec:** `docs/superpowers/specs/2026-10-15-tailscale-module-design.md`

**Visual reference:** the visual mock attached to the pull request

## Global Constraints

### Build host, and how to run anything

**This machine has no C++ toolchain** — no `cmake`, no Qt6, no `qml6`, no
`ninja`. Nothing in this plan compiles or runs locally. Every build and every
test goes through one helper, which mirrors the worktree to the `arch-dev01`
VM (Arch, Qt 6.12.0) over tar+ssh and runs the command there:

```
$RR <command…>        # $RR = <workspace>/remote-run, absolute path in your dispatch
```

The VM has no GPU and that does not matter: the C++ tests are headless QtTest,
and the QML view tests run offscreen under `qml6` with no compositor — verified
before Task 1 with `DISPLAY` and `WAYLAND_DISPLAY` both empty.

**One invocation per phase, never one per assertion.** Each `remote-run` call
costs a full worktree sync and a human approval, so a task makes *one* call to
see red and *one* to see green, each running every command for that phase
chained with `&&`. A task that shells out once per test case is a defect.
Configure only when `CMakeLists.txt` changed; the VM keeps its object cache
between runs, so a rebuild is incremental.

### Rules

- `plugin/lib/` may not include a QML, Quick or Quickshell header, link a QML or Quick target, or declare a QML module. `tests/test-c7-plugin.sh` check 2 enforces it.
- Every plugin test's main is `C7_TEST_MAIN`, which isolates it from the host. Check 2b enforces it. No test may open the real `/var/run/tailscale/tailscaled.sock`.
- Socket path is `qEnvironmentVariable("TS_SOCKET", "/var/run/tailscale/tailscaled.sock")`.
- **The repository is public.** Every committed fixture is redacted per the table in Task 1. No real login name, node public key, RFC1918 range or AWS hostname lands in git.
- Headers under `plugin/lib/` are included as `"tailscale/<name>.h"` — `plugin/lib` is the include root, as `c7_core` sets it.
- `tests/test-native-boundary.sh`: no new entry in `spawn_debt` or `import_debt`. New QML imports only `qs.*` and `QtQuick`.
- Contract enum `State` has the six values tailscaled's `BackendState` actually reports: `NoState`, `NeedsMachineAuth`, `NeedsLogin`, `Stopped`, `Starting`, `Running`. The macOS menu's two extra states come from tailnet-lock data and are out of scope.
- v1 is read-only. No `Q_INVOKABLE` mutator, no `PATCH`, no polkit.
- Qt JSON only (`QJsonDocument`), never a hand-rolled parser.

## Review Focus

- **Exit node selected whose peer is gone from the `Peer` map** (removed or stale): the name join yields nothing and the alert must name the ID rather than render an empty string. Task 2 tests it.
- **`ExitNodeStatus.TailscaleIPs` carry `/32` and `/128`; peer `TailscaleIPs` are bare.** A direct comparison never matches. Task 2 tests the stripping.
- **tailscaled not running — socket absent or refusing.** The backend must settle on `NoState` and keep retrying, never block the QML engine or crash. Task 4 tests connect-failure and Task 6 tests the resulting state.
- **A `watch-ipn-bus` line split across two reads.** A stream keeps no write boundaries, so a half-line must not reach the parser. Task 4 tests a line delivered in two chunks.
- **Two peers with the same hostname** (`C7-LAP-G1157C6M` appears twice on this tailnet). Model rows key on `NodeID`; keying on hostname collapses them. Task 3 tests it.
- **Health containing only the suppressed `--accept-routes` warning.** `issueCount` must be 0, or the module warns forever on the only machine it runs on. Task 6 tests it.

---

### Task 1: `c7_tailscale` library, fixtures, and parsing state and health

**Files:**
- Create: `plugin/lib/tailscale/CMakeLists.txt`
- Create: `plugin/lib/tailscale/Types.h`
- Create: `plugin/lib/tailscale/StatusParser.h`, `plugin/lib/tailscale/StatusParser.cpp`
- Create: `plugin/lib/tailscale/tests/tst_statusparser.cpp`
- Create: `plugin/lib/tailscale/tests/fixtures/status-idle.json`
- Create: `plugin/lib/tailscale/tests/fixtures/status-exitnode.json`
- Modify: `plugin/CMakeLists.txt` — `add_subdirectory(lib/tailscale)` after `lib/core`
- Modify: `tests/test-c7-plugin.sh:155` — add `tst_statusparser` to the test-name loop

**Interfaces:**
- Produces: `c7::tailscale::Status` (`struct`: `QString backendState; QString selfName; QString selfIp4; QString selfIp6; QString selfDnsName; QDateTime keyExpiry; QStringList health; QString tailnet; std::optional<ExitNode> exitNode; QList<Peer> peers;`)
- Produces: `c7::tailscale::StatusParser::parse(const QByteArray &json) -> std::optional<Status>` — `nullopt` on malformed input, never a partially filled `Status`.

**Fixture redaction.** Capture is in the session scratchpad (`ts-laptop.json`, `ts-ACTIVE.json`). Apply exactly this mapping, preserving every key, type, array length and string shape:

| Real | Fixture |
|---|---|
| `adriaan@crimson7.io` | `owner@example.com` |
| `bryan@crimson7.io`, `atilla.balin@crimson7.io` | `second@example.com`, `third@example.com` |
| `cama-major.ts.net` | `example-tailnet.ts.net` |
| `crimson7.io` (tailnet name) | `example.com` |
| `nodekey:…`, node IDs | same length, hex re-randomised |
| `10.0.0.0/18` and the other three | `172.31.0.0/18` etc. |
| `ip-10-20-9-170` | `ip-172-31-0-10` |
| Hostnames | keep `pentest-exit-node`; others → `alpha`, `beta`, … **keeping the duplicate pair duplicated** |

`status-idle.json` is the no-exit-node capture; `status-exitnode.json` is the captured-live one, so it keeps `ExitNodeStatus` populated and one peer with `"ExitNode": true`.

- [ ] **Step 1: Write the failing test**

```cpp
void parsesBackendStateAndHealth()
{
    const auto s = StatusParser::parse(readFixture("status-idle.json"));
    QVERIFY(s.has_value());
    QCOMPARE(s->backendState, QStringLiteral("Running"));
    QCOMPARE(s->health.size(), 1);
    QVERIFY(s->health.first().contains(QStringLiteral("--accept-routes")));
    QCOMPARE(s->selfIp4, QStringLiteral("100.73.10.20"));
    QCOMPARE(s->tailnet, QStringLiteral("example.com"));
}

void rejectsMalformedJson()
{
    QVERIFY(!StatusParser::parse(QByteArrayLiteral("{\"Self\":")).has_value());
    QVERIFY(!StatusParser::parse(QByteArray()).has_value());
}
```

- [ ] **Step 2: Run to verify it fails**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_statusparser --output-on-failure'``
Expected: build failure — no `StatusParser`.

- [ ] **Step 3: Implement `Types.h` and `StatusParser::parse`**

`parse` returns `nullopt` when `QJsonDocument::fromJson` reports an error or the root is not an object. `health` is `Health` as a `QStringList`, empty when the key is absent. `tailnet` is `CurrentTailnet.Name`.

- [ ] **Step 4: Run to verify it passes**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_statusparser --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Run the repo's plugin gate**

Run: ``$RR tests/test-c7-plugin.sh``
Expected: PASS, including check 2 (no QML header under `plugin/lib/`) and check 2b.

- [ ] **Step 6: Commit**

```bash
git add plugin/lib/tailscale plugin/CMakeLists.txt tests/test-c7-plugin.sh
git commit -m "feat(plugin): parse tailscaled status into typed values"
```

---

### Task 2: peers, grouping, and the exit-node join

**Files:**
- Modify: `plugin/lib/tailscale/Types.h`, `plugin/lib/tailscale/StatusParser.cpp`
- Modify: `plugin/lib/tailscale/tests/tst_statusparser.cpp`

**Interfaces:**
- Consumes: `Status`, `StatusParser::parse` from Task 1.
- Produces: `struct Peer { QString nodeId; QString hostName; QString ip4; QString ip6; QString dnsName; bool online; Group group; QString ownerName; bool exitNodeOption; };`
- Produces: `enum class Group { Mine, Tagged, Others };`
- Produces: `struct ExitNode { QString id; QString name; bool online; QString ip4; };` — `name` is joined from the peer list, falling back to `id` when no peer matches.
- Produces: `c7::tailscale::stripMask(const QString &cidr) -> QString`

- [ ] **Step 1: Write the failing tests**

```cpp
void groupsPeersByUserId()
{
    const auto s = StatusParser::parse(readFixture("status-idle.json"));
    QCOMPARE(count(s->peers, Group::Mine), 10);
    QCOMPARE(count(s->peers, Group::Tagged), 8);
    QCOMPARE(count(s->peers, Group::Others), 2);
}

void namesTheOwnerOnlyForOtherUsers()
{
    const auto s = StatusParser::parse(readFixture("status-idle.json"));
    const Peer other = find(s->peers, Group::Others);
    QVERIFY(!other.ownerName.isEmpty());
    QCOMPARE(find(s->peers, Group::Mine).ownerName, QString());
}

void joinsExitNodeNameFromItsPeer()
{
    const auto s = StatusParser::parse(readFixture("status-exitnode.json"));
    QVERIFY(s->exitNode.has_value());
    QCOMPARE(s->exitNode->name, QStringLiteral("pentest-exit-node"));
    QCOMPARE(s->exitNode->online, true);
}

void fallsBackToTheIdWhenTheExitPeerIsMissing()
{
    QByteArray j = readFixture("status-exitnode.json");
    j = withoutPeer(j, QStringLiteral("pentest-exit-node"));   // helper in the test
    const auto s = StatusParser::parse(j);
    QVERIFY(s->exitNode.has_value());
    QCOMPARE(s->exitNode->name, s->exitNode->id);
    QVERIFY(!s->exitNode->name.isEmpty());
}

void stripsTheMaskFromExitNodeAddresses()
{
    QCOMPARE(stripMask(QStringLiteral("100.111.18.72/32")), QStringLiteral("100.111.18.72"));
    QCOMPARE(stripMask(QStringLiteral("fd7a:115c:a1e0::5101:1248/128")),
             QStringLiteral("fd7a:115c:a1e0::5101:1248"));
    QCOMPARE(stripMask(QStringLiteral("100.111.18.72")), QStringLiteral("100.111.18.72"));
}
```

- [ ] **Step 2: Run to verify they fail**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_statusparser --output-on-failure'``
Expected: FAIL — no `Peer`, `Group`, `stripMask`.

- [ ] **Step 3: Implement grouping, the join and `stripMask`**

Group by the rule in the spec: a peer is `Tagged` when `User[peer.UserID].LoginName == "tagged-devices"`, `Mine` when `peer.UserID == Self.UserID`, else `Others` with `ownerName` from `User[uid].DisplayName`. `ip4` is the first `TailscaleIPs` entry without a `:`, `ip6` the first with one. `dnsName` has its trailing `.` removed.

- [ ] **Step 4: Run to verify they pass**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_statusparser --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/lib/tailscale
git commit -m "feat(plugin): group tailnet peers and resolve the exit node's name"
```

---

### Task 3: `PeerModel` — stable rows

**Files:**
- Create: `plugin/lib/tailscale/PeerModel.h`, `plugin/lib/tailscale/PeerModel.cpp`
- Create: `plugin/lib/tailscale/tests/tst_peermodel.cpp`
- Modify: `plugin/lib/tailscale/CMakeLists.txt`
- Modify: `tests/test-c7-plugin.sh:155` — add `tst_peermodel`

**Interfaces:**
- Consumes: `Peer`, `Group` from Task 2.
- Produces: `class PeerModel : public QAbstractListModel` with `void setPeers(const QList<Peer> &)` and roles `HostNameRole`, `Ip4Role`, `Ip6Role`, `DnsNameRole`, `OnlineRole`, `GroupRole`, `OwnerNameRole`, `NodeIdRole`, `ExitNodeOptionRole`.
- Rows are ordered `Mine`, `Tagged`, `Others`, and within a group offline last then hostname case-insensitively.

- [ ] **Step 1: Write the failing tests**

```cpp
void keepsRowIdentityAcrossAnUpdate()
{
    PeerModel m;
    m.setPeers(twoPeersSameHostNameDifferentIds());
    QSignalSpy reset(&m, &QAbstractItemModel::modelAboutToBeReset);
    QSignalSpy changed(&m, &QAbstractItemModel::dataChanged);
    m.setPeers(sameTwoPeersOneNowOffline());
    QCOMPARE(m.rowCount(), 2);                 // not collapsed to one
    QCOMPARE(reset.count(), 0);                // updated in place
    QVERIFY(changed.count() > 0);
}

void ordersGroupsThenOfflineLast()
{
    PeerModel m;
    m.setPeers(StatusParser::parse(readFixture("status-idle.json"))->peers);
    QCOMPARE(m.index(0, 0).data(PeerModel::GroupRole).toInt(), int(Group::Mine));
    QVERIFY(lastRowOfGroup(m, Group::Mine).data(PeerModel::OnlineRole).toBool() == false);
}

void insertsAndRemovesRatherThanResetting()
{
    PeerModel m;
    m.setPeers(threePeers());
    QSignalSpy removed(&m, &QAbstractItemModel::rowsRemoved);
    m.setPeers(threePeersMinusTheMiddleOne());
    QCOMPARE(m.rowCount(), 2);
    QCOMPARE(removed.count(), 1);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_peermodel --output-on-failure'``
Expected: FAIL — no `PeerModel`.

- [ ] **Step 3: Implement `PeerModel`**

`setPeers` diffs against the current rows keyed by `nodeId`: emit `rowsInserted`/`rowsRemoved` for membership changes and `dataChanged` for a row whose fields moved. Never `beginResetModel` — that is the whole point of the class.

- [ ] **Step 4: Run to verify they pass**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_peermodel --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/lib/tailscale tests/test-c7-plugin.sh
git commit -m "feat(plugin): a peer list model with stable rows"
```

---

### Task 4: `LocalApiClient` — HTTP over a Unix socket

**Files:**
- Create: `plugin/lib/tailscale/LocalApiClient.h`, `plugin/lib/tailscale/LocalApiClient.cpp`
- Create: `plugin/lib/tailscale/tests/tst_localapiclient.cpp`
- Modify: `plugin/lib/tailscale/CMakeLists.txt` — link `Qt6::Network`
- Modify: `plugin/lib/testing/fakesocketserver.h`, `…/fakesocketserver.cpp` — add `int pushChunk(const QByteArray &bytes)`, which `pushLine` then calls with a trailing newline
- Modify: `plugin/lib/testing/tests/tst_fakesocketserver.cpp` — a test that `pushChunk` sends exactly its bytes
- Modify: `tests/test-c7-plugin.sh:155` — add `tst_localapiclient`

**Interfaces:**
- Produces: `class LocalApiClient : public QObject`
  - `explicit LocalApiClient(QString socketPath, QObject *parent = nullptr)`
  - `void get(const QString &path)` → `void replied(const QString &path, const QByteArray &body)` or `void failed(const QString &path, const QString &reason)`
  - `void watch()` → `void event(const QByteArray &line)` per complete line, `void watchEnded()`
  - `void stop()`
- Requests are `GET <path> HTTP/1.1\r\nHost: local-tailscaled.sock\r\n\r\n`. `replied` carries the body only.

- [ ] **Step 1: Write the failing tests**

```cpp
void getReturnsTheBodyWithoutHeaders()
{
    FakeSocketServer server(socketPath());
    server.onRequest([](const QByteArray &) {
        return QByteArrayLiteral("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n");
    }, FakeSocketServer::CloseAfterReply, "\r\n\r\n");
    LocalApiClient c(socketPath());
    QSignalSpy replied(&c, &LocalApiClient::replied);
    c.get(QStringLiteral("/localapi/v0/status"));
    QVERIFY(replied.wait());
    QCOMPARE(replied.first().at(1).toByteArray().trimmed(), QByteArrayLiteral("{\"ok\":true}"));
}

void failsRatherThanHangingWhenTheSocketIsAbsent()
{
    LocalApiClient c(socketPath() + QStringLiteral("-nope"));
    QSignalSpy failed(&c, &LocalApiClient::failed);
    c.get(QStringLiteral("/localapi/v0/status"));
    QVERIFY(failed.wait());
}

void emitsOneEventPerCompleteLine()
{
    FakeSocketServer server(socketPath());
    server.onRequest([](const QByteArray &) {
        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
    }, FakeSocketServer::KeepOpen, "\r\n\r\n");
    LocalApiClient c(socketPath());
    QSignalSpy ev(&c, &LocalApiClient::event);
    c.watch();
    QTRY_COMPARE(server.clientCount(), 1);
    server.pushLine(QByteArrayLiteral("{\"a\":1}"));
    server.pushLine(QByteArrayLiteral("{\"b\":2}"));
    QTRY_COMPARE(ev.count(), 2);
    QCOMPARE(ev.at(0).first().toByteArray(), QByteArrayLiteral("{\"a\":1}"));
}

void neverEmitsAPartialLine()
{
    FakeSocketServer server(socketPath());
    server.onRequest([](const QByteArray &) {
        return QByteArrayLiteral("HTTP/1.1 200 OK\r\n\r\n");
    }, FakeSocketServer::KeepOpen, "\r\n\r\n");
    LocalApiClient c(socketPath());
    QSignalSpy ev(&c, &LocalApiClient::event);
    c.watch();
    QTRY_COMPARE(server.clientCount(), 1);
    server.pushChunk(QByteArrayLiteral("{\"half\":"));   // no newline yet
    QTest::qWait(50);
    QCOMPARE(ev.count(), 0);
    server.pushChunk(QByteArrayLiteral("1}\n"));
    QTRY_COMPARE(ev.count(), 1);
    QCOMPARE(ev.first().first().toByteArray(), QByteArrayLiteral("{\"half\":1}"));
}
```

- [ ] **Step 2: Run to verify they fail**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_localapiclient --output-on-failure'``
Expected: FAIL — no `LocalApiClient`.

- [ ] **Step 3: Implement `LocalApiClient`**

One `QLocalSocket` per in-flight request; `watch()` holds its own. Buffer incoming bytes and split on `\n`, emitting only complete lines — the half-line case is what the fourth test pins. `failed` fires on `QLocalSocket::errorOccurred` and on a non-2xx status line.

- [ ] **Step 4: Run to verify they pass**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_localapiclient --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add plugin/lib/tailscale tests/test-c7-plugin.sh
git commit -m "feat(plugin): a local API client over tailscaled's unix socket"
```

---

### Task 5: the `TailscaleBackend` contract and the `Tailscale` singleton

**Files:**
- Create: `plugin/src/contracts/TailscaleBackend.h`
- Create: `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h`, `…/LocalApiTailscaleBackend.cpp`
- Modify: `plugin/CMakeLists.txt` — add the two headers and the `.cpp` to `qt_add_qml_module(c7 … SOURCES …)`, link `c7_tailscale`
- Modify: `plugin/tests/tst_module.cpp` — a second test slot
- Modify: `docs/architecture.md:135` — add the contracts-table row

**Interfaces:**
- Produces: `class TailscaleBackend : public QObject` with `QML_NAMED_ELEMENT(Tailscale)`, `QML_SINGLETON`, and:
  - `enum class State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running }; Q_ENUM(State)`
  - `Q_PROPERTY(State state READ state NOTIFY stateChanged)`
  - `Q_PROPERTY(QString selfName / selfIp4 / selfIp6 / selfDnsName / tailnet …)`
  - `Q_PROPERTY(QDateTime keyExpiry …)`
  - `Q_PROPERTY(bool exitNodeActive …)`, `Q_PROPERTY(QString exitNodeName …)`, `Q_PROPERTY(bool exitNodeBlocked …)`
  - `Q_PROPERTY(QStringList issues …)`, `Q_PROPERTY(int issueCount …)`
  - `Q_PROPERTY(QAbstractItemModel *peers READ peers CONSTANT)`
  - `Q_PROPERTY(QAbstractItemModel *exitNodes READ exitNodes CONSTANT)` — a second `PeerModel` holding only peers whose `exitNodeOption` is true
  - `Q_PROPERTY(QString recommendedExitNodeId …)` — the `ID` from `/localapi/v0/suggest-exit-node`, empty when it returns nothing
  - `static TailscaleBackend *create(QQmlEngine *, QJSEngine *)`
- `exitNodeBlocked` is `exitNodeActive && !ExitNodeStatus.Online` — the fail-closed flag.

- [ ] **Step 1: Write the failing test**

```cpp
void tailscaleSingletonLoadsAndStartsInNoState()
{
    QQmlEngine engine;
    engine.setImportPathList({importPath()});
    auto *ts = engine.singletonInstance<QObject *>("C7", "Tailscale");
    QVERIFY2(ts, "module C7 loaded but its Tailscale singleton did not");
    QCOMPARE(ts->property("state").toInt(), 0);          // State::NoState
    QCOMPARE(ts->property("exitNodeBlocked").toBool(), false);
    QVERIFY(ts->property("peers").value<QAbstractItemModel *>() != nullptr);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_module --output-on-failure'``
Expected: FAIL — no `Tailscale` singleton in module `C7`.

- [ ] **Step 3: Implement the contract and a backend that does not connect yet**

`create()` returns a `LocalApiTailscaleBackend` whose constructor does **not** open the socket — Task 6 adds that. Every property returns its default so the singleton is loadable and the test pins the starting state.

- [ ] **Step 4: Run to verify it passes**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_module --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Verify the whole plugin gate, including the install layout**

Run: ``$RR tests/test-c7-plugin.sh``
Expected: PASS — check 4 confirms `cmake --install` ships the module and nothing else.

- [ ] **Step 6: Commit**

```bash
git add plugin/src plugin/CMakeLists.txt plugin/tests/tst_module.cpp docs/architecture.md
git commit -m "feat(plugin): the Tailscale contract and its C7 singleton"
```

---

### Task 6: wire the backend to the stream, and suppress the standing warning

**Files:**
- Modify: `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp`
- Create: `plugin/src/backends/tailscale/tests/tst_tailscalebackend.cpp`
- Modify: `plugin/CMakeLists.txt`, `tests/test-c7-plugin.sh:155` — add `tst_tailscalebackend`

**Interfaces:**
- Consumes: `LocalApiClient` (Task 4), `StatusParser` (Tasks 1–2), `PeerModel` (Task 3), the contract (Task 5).
- Produces: `static const QStringList &suppressedHealth()` — messages never counted as issues. Seeded with the `--accept-routes` warning, matched by `QString::contains` on `"advertising routes but --accept-routes is false"`.

- [ ] **Step 1: Write the failing tests**

```cpp
void publishesStateAndPeersFromTheStatusReply()
{
    FakeSocketServer server(socketPath());
    serveFixture(server, "status-idle.json");
    LocalApiTailscaleBackend b;
    QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
    QTRY_COMPARE(b.peers()->rowCount(), 20);
}

void reportsTheBlockedStateWhenTheExitNodeIsOffline()
{
    FakeSocketServer server(socketPath());
    serveFixture(server, "status-exitnode-offline.json");   // ExitNodeStatus.Online = false
    LocalApiTailscaleBackend b;
    QTRY_VERIFY(b.exitNodeBlocked());
    QCOMPARE(b.exitNodeName(), QStringLiteral("pentest-exit-node"));
}

void doesNotCountTheSuppressedRouteWarning()
{
    FakeSocketServer server(socketPath());
    serveFixture(server, "status-idle.json");    // its only health entry is the suppressed one
    LocalApiTailscaleBackend b;
    QTRY_COMPARE(b.state(), TailscaleBackend::State::Running);
    QCOMPARE(b.issueCount(), 0);
    QVERIFY(b.issues().isEmpty());
}

void settlesInNoStateWhenTailscaledIsAbsent()
{
    LocalApiTailscaleBackend b;        // TS_SOCKET points at nothing
    QTRY_COMPARE(b.state(), TailscaleBackend::State::NoState);
}

void republishesOnAWatchEvent()
{
    FakeSocketServer server(socketPath());
    serveFixture(server, "status-idle.json");
    LocalApiTailscaleBackend b;
    QTRY_COMPARE(b.exitNodeActive(), false);
    serveFixture(server, "status-exitnode.json");       // next GET answers differently
    server.pushLine(QByteArrayLiteral("{\"Prefs\":{}}"));
    QTRY_COMPARE(b.exitNodeActive(), true);
}

void publishesOnlyExitNodeCapablePeersAsExitNodes()
{
    FakeSocketServer server(socketPath());
    serveFixture(server, "status-idle.json");
    LocalApiTailscaleBackend b;
    QTRY_COMPARE(b.exitNodes()->rowCount(), 2);         // the fixture has two
    QCOMPARE(b.recommendedExitNodeId(), QStringLiteral("nWqTQFdqb121CNTRL"));
}
```

- [ ] **Step 2: Run to verify they fail**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_tailscalebackend --output-on-failure'``
Expected: FAIL

- [ ] **Step 3: Implement the wiring**

On construction: `get("/localapi/v0/status")`, `get("/localapi/v0/prefs")`, `get("/localapi/v0/suggest-exit-node")`, then `watch()`. Each `event()` re-issues the status `get` — the notification says *something* changed and the status reply is the authority. On `failed` or `watchEnded`, publish `NoState` and retry with a backoff capped at 30 s, in the shape of `AuthService.qml:202`. Create a third fixture `status-exitnode-offline.json` from `status-exitnode.json` with `ExitNodeStatus.Online` set to `false`.

- [ ] **Step 4: Run to verify they pass**

Run: ``$RR bash -c 'cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build -R tst_tailscalebackend --output-on-failure'``
Expected: PASS

- [ ] **Step 5: Confirm the boundary tables did not grow**

Run: ``$RR tests/test-native-boundary.sh``
Expected: PASS, and the reported debt counts are unchanged from `main`.

- [ ] **Step 6: Commit**

```bash
git add plugin tests/test-c7-plugin.sh
git commit -m "feat(plugin): drive the Tailscale backend off the ipn bus"
```

---

### Task 7: the bar slot

**Files:**
- Create: `quickshell/c7shell/Assets/icons/globe.svg`
- Modify: `quickshell/c7shell/Modules/Bar/StatusPill.qml`
- Create: `tests/tailscale-qml-test.qml`, `tests/test-tailscale.sh`

**Interfaces:**
- Consumes: `Tailscale.state`, `.exitNodeActive`, `.exitNodeBlocked`, `.exitNodeName`, `.issueCount` from Task 5.

The slot goes **before** `netSlot` in the `Row`, is visible whenever `Tailscale.state !== Tailscale.NoState`, and renders the six states from the spec: dimmed when not `Running`; an amber dot when `issueCount > 0`; `slotColor: Theme.accentFill` plus `exitNodeName` as a label when `exitNodeActive`; the crimson `✕`-style badge when `exitNodeBlocked`.

- [ ] **Step 1: Write the failing test**

`tests/test-tailscale.sh` follows `tests/test-wifi.sh`: stub `Quickshell.Singleton`, write the Theme stub with `write_theme_stub`, and stand in a fake `Tailscale` singleton whose properties the test drives.

```qml
// tests/tailscale-qml-test.qml — assertions, run under qml6
// 1. state=NoState            -> slot.visible === false
// 2. state=Running            -> visible, no label, not tinted
// 3. issueCount=1             -> warn badge visible
// 4. exitNodeActive           -> tinted and label === exitNodeName
// 5. exitNodeBlocked          -> error badge, and still tinted
```

- [ ] **Step 2: Run to verify it fails**

Run: ``$RR tests/test-tailscale.sh``
Expected: FAIL — `StatusPill` has no Tailscale slot.

- [ ] **Step 3: Add `globe.svg` and the slot**

`globe.svg` is a Lucide `globe` at 24×24, `stroke="#fff"`, `stroke-width="2"`, `fill="none"` — matching the other 47 icons, which `Icon.qml` recolours at runtime.

- [ ] **Step 4: Run to verify it passes**

Run: ``$RR tests/test-tailscale.sh``
Expected: PASS

- [ ] **Step 5: Run the QML gates**

Run: ``$RR bash -c 'tests/test-qml-hygiene.sh && tests/test-native-boundary.sh'``
Expected: PASS — no colour literal in a view, no new import debt.

- [ ] **Step 6: Commit**

```bash
git add quickshell/c7shell/Assets/icons/globe.svg quickshell/c7shell/Modules/Bar/StatusPill.qml tests/
git commit -m "feat(bar): a tailscale slot carrying six states"
```

---

### Task 8: the popover

**Files:**
- Create: `quickshell/c7shell/Modules/Popovers/TailscalePopover.qml`
- Create: `quickshell/c7shell/Modules/Popovers/PeerRow.qml`
- Create: `quickshell/c7shell/Modules/Popovers/ExitNodeList.qml`
- Create: `quickshell/c7shell/Modules/Popovers/CopyMenu.qml`
- Modify: `quickshell/c7shell/shell.qml` — `TailscalePopover {}` beside `WifiPopover {}`
- Modify: `quickshell/c7shell/Modules/Bar/StatusPill.qml` — `PopoverManager.toggle("tailscale", tsSlot)`
- Modify: `tests/tailscale-qml-test.qml`

**Interfaces:**
- Consumes: everything from Task 5, plus `Tailscale.peers` as a `ListView` model.

`ExitNodeList.qml` is §5 of the mock: a checked `none` row, the `recommendedExitNodeId`
peer promoted under a `RECOMMENDED` heading, then every `exitNodes` row under
`TAILNET EXIT NODES`. In v1 the rows are not selectable — selection is a write — so
they render at `Theme.textDisabled` and the heading carries `(read-only)`.

`CopyMenu.qml` is the right-click menu of §4: `Copy IPv4`, `Copy IPv6`,
`Copy MagicDNS hostname`, with an entry disabled when the peer has no such value.

Root panel per the visual mock attached to the pull request §3: `GlassPopover { name: "tailscale"; panelWidth: 320 }`, header row (title, state subtitle, a disabled `TogglePill` with a v1 tooltip), this-device rows, `network devices ›`, `exit nodes ›`. The blocked alert from §6 appears above everything when `Tailscale.exitNodeBlocked`. Device list sections per `GroupRole`, with the labels `my devices`, `tagged devices`, `other users`.

- [ ] **Step 1: Write the failing tests**

```qml
// 6.  a peer row click sets the clipboard to its ip4
// 7.  right-click opens CopyMenu; its three entries copy ip4, ip6 and dnsName
// 8.  a peer with an empty ip6 renders that entry disabled, and clicking it copies nothing
// 9.  exitNodeBlocked -> the alert is visible above the rows and names exitNodeName
// 10. section headers appear once per non-empty group, in Mine/Tagged/Others order
// 11. a group with no peers renders no header
// 12. keyExpiry 18 months out -> the expiry line reads "expires in 18 months", dimmed
// 13. keyExpiry unset (null QDateTime) -> no expiry line at all
// 14. ExitNodeList shows a checked "none" row and one RECOMMENDED row matching
//     recommendedExitNodeId
```

- [ ] **Step 2: Run to verify they fail**

Run: ``$RR tests/test-tailscale.sh``
Expected: FAIL — no `TailscalePopover`.

- [ ] **Step 3: Implement `TailscalePopover.qml` and `PeerRow.qml`**

Copy goes through `qsTr`. The clipboard write is Quickshell's clipboard API — **not** a `Process` running `wl-copy`, which would add a `spawn_debt` entry.

- [ ] **Step 4: Run to verify they pass**

Run: ``$RR tests/test-tailscale.sh``
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: ``$RR bash -c 'for t in tests/test-*.sh; do "$t" || exit 1; done'``
Expected: every test passes.

- [ ] **Step 6: Commit**

```bash
git add quickshell/c7shell tests/
git commit -m "feat(bar): the tailscale popover"
```
