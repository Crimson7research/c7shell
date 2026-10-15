# Tailscale v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Tailscale panel names devices the way Tailscale does, and changes tailnet state instead of only reporting it.

**Architecture:** v1's layering is unchanged — `plugin/lib/tailscale/` plain Qt, `plugin/src/contracts/` + `backends/` for the QML-facing contract, `quickshell/c7shell/` for views. v2 adds a write direction: `Q_INVOKABLE` actions on the contract, `PATCH /localapi/v0/prefs` in the backend, and the operator set once at install so those writes are permitted. The bus stays the authority: a write is optimistic only until the next notification.

**Tech Stack:** C++20, Qt 6.5 (Core, Network, Qml, Test), CMake, QtTest, `c7::testing::FakeSocketServer`, Quickshell QML.

**Spec:** `docs/superpowers/specs/2026-10-15-tailscale-v2-design.md`

**Predecessor:** `docs/superpowers/plans/2026-10-15-tailscale-backend.md` (v1, merged on this branch). Read a task's v1 report under `.superpowers/sdd/2026-10-15-tailscale-backend/` before touching the area it covers.

## Global Constraints

### Build and test

This machine has no C++ toolchain. Everything runs on the arch-dev01 VM:

```
$RR --verify 'REGEX'     # configure, build, matching ctest, full C++ gate
$RR tests/test-tailscale.sh
```

`$RR` is `<workspace>/remote-run`. **Never wrap a command in `bash -c`** — the helper contains an `rm` and a `-c` script is opaque to the command safety check. One call for red, one for green.

A second loop puts a build in front of a human: `<workspace>/vm-install` builds this worktree inside a VNC-attached test VM and restarts the shell. It installs the package **and** runs `c7shell-setup --force`, because `qs -c c7shell` reads `~/.config/quickshell/c7shell`, not `/usr/share`. Three v1 installs reported success while the running bar never changed.

### Rules

- `plugin/lib/` is Qt Core and Network only. No QML header, target or module.
- Every plugin test uses `C7_TEST_MAIN` and must never touch the host's real `/var/run/tailscale/tailscaled.sock`. `TS_SOCKET` is set by `isolateFromHost()` — **not** added to `isolationKeeps()`, which is the survives-from-host allowlist.
- Every new test gets `LABELS testing`; gate check 3b asserts the labelled set equals the registered set and names any test that is missing.
- No new `spawn_debt` or `import_debt` entry. Debt stays 33 / 40 / 21.
- No colour literal in a view. Compare colours as strings in tests — `Qt.colorEqual` is unreliable against `Theme.accentSoft`.
- Call `forceLayout()` before every geometry read in a QML test; a synchronous read returns the previous frame and **fails open**.
- Daemon-supplied strings render through `Text.PlainText`, including via `Common/ListRow.qml`.
- The repository is **public**. Fixtures stay redacted.

## Review Focus

- **A refused write must not look like a successful one.** A 403 (operator not set) is the ordinary failure on an un-bootstrapped machine. Task 3 tests it; the panel must say so.
- **A write that succeeds but is then contradicted by the bus.** The daemon is the authority; an optimistic toggle must settle to what the next notification says, not to what was clicked. Task 3 tests a write followed by a notification carrying the opposite value.
- **`ExitNodeID` written as a `StableNodeID` vs an IP.** `/prefs` carries both `ExitNodeID` and `ExitNodeIP`; writing the wrong field silently selects nothing. Task 3 pins the field.
- **A DNS label that is empty, or equal to the hostname.** Task 1 covers both — MagicDNS off must not produce a blank row.
- **Search with a query matching nothing, and a query matching a row in a collapsed section.** Task 5 and Task 6 test both; an empty list must read as "no matches", not as an empty tailnet.

---

### Task 1: Devices show their DNS label

**Files:**
- Modify: `plugin/lib/tailscale/Types.h`, `plugin/lib/tailscale/StatusParser.cpp`
- Modify: `plugin/lib/tailscale/tests/tst_statusparser.cpp`
- Modify: `quickshell/c7shell/Modules/Popovers/PeerRow.qml`, `ExitNodeList.qml`, `TailscalePopover.qml`
- Modify: `tests/tailscale-qml-test.qml`

**Interfaces:**
- Produces: `Peer::displayName` — the first label of `dnsName`, falling back to `hostName` when `dnsName` is empty. `hostName` stays, unchanged, for anything that wants the OS name.
- Rows keep keying on `nodeId`. Display name is not identity.

- [ ] **Step 1: Write the failing tests**

```cpp
void prefersTheDnsLabelOverTheHostName()
{
    const auto s = StatusParser::parse(readFixture("status-idle.json"));
    const Peer p = byNodeId(s->peers, nodeIdOfHostName(s->peers, "ip-172-31-0-10"));
    QCOMPARE(p.displayName, QStringLiteral("keystone-equivalent"));  // the fixture's label
    QCOMPARE(p.hostName,    QStringLiteral("ip-172-31-0-10"));       // unchanged
}

void fallsBackToTheHostNameWithoutMagicDns()
{
    // A peer whose DNSName is "" keeps its hostName as displayName.
}
```

The fixtures must grow at least one peer whose DNS label differs from its hostname and one with an empty `DNSName`. Follow the existing redaction: greek-letter names, `example-tailnet.ts.net`.

- [ ] **Step 2: Run to verify they fail** — `$RR --verify tst_statusparser`
- [ ] **Step 3: Implement `displayName` and bind the views to it**
- [ ] **Step 4: Run to verify they pass** — `$RR --verify tst_statusparser` and `$RR tests/test-tailscale.sh`
- [ ] **Step 5: Commit**

---

### Task 2: A reply belongs to its own pass

**Files:**
- Modify: `plugin/lib/tailscale/LocalApiClient.h`, `.cpp`
- Modify: `plugin/lib/tailscale/tests/tst_localapiclient.cpp`
- Modify: `plugin/src/backends/tailscale/LocalApiTailscaleBackend.{h,cpp}` and its tests

This is v1's deferred residual, landing here because v2's write path touches the same code. The diagnosis is already proven and saved at `.superpowers/sdd/2026-10-15-tailscale-backend/residual-skewed-pairing.patch`, with a failing test; **read that patch and its report section first.**

`m_refreshInFlight` is a boolean, and the question is not "is a pass open?" but "is this reply from the pass that is open?". A dead pass's `/prefs` routinely arrives while the next pass is open, and is accepted as that pass's half.

**Interfaces:**
- Produces: `LocalApiClient::get(const QString &path, quint64 token = 0)` and `replied(const QString &path, const QByteArray &body, quint64 token)` / `failed(const QString &path, const QString &reason, quint64 token)`. The watch is unaffected: `event` and `watchEnded` carry no token.
- The backend increments a pass counter in `refresh()` and ignores any reply whose token is not the open pass.

- [ ] **Step 1: Write the failing test** — use `dropsAHalfFinishedPassWhenTheConnectionIsLost` from the saved patch verbatim; it already fails for the right reason.
- [ ] **Step 2: Run to verify it fails** — `$RR --verify 'tailscalebackend|localapiclient'`
- [ ] **Step 3: Implement the token**
- [ ] **Step 4: Run to verify it passes, with no diagnostic `qWait`** — a test that passes because of a sleep is the failure mode this task exists to remove.
- [ ] **Step 5: Commit**

---

### Task 3: The contract can write

**Files:**
- Modify: `plugin/src/contracts/TailscaleBackend.h`
- Modify: `plugin/src/backends/tailscale/LocalApiTailscaleBackend.{h,cpp}`, `FakeTailscaleBackend.h`
- Modify: `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp`, `plugin/tests/tst_tailscalebackend.cpp`
- Create: `plugin/lib/tailscale/tests/fixtures/prefs-patched.json`

**Interfaces:**
- Produces, on the contract:
  - `Q_INVOKABLE virtual void setWantRunning(bool on) = 0`
  - `Q_INVOKABLE virtual void setExitNode(const QString &nodeId) = 0` — `""` means none
  - `Q_INVOKABLE virtual void setExitNodeAllowLANAccess(bool on) = 0`
  - `Q_INVOKABLE virtual void setAcceptRoutes(bool on) = 0`
  - `Q_INVOKABLE virtual void setAcceptDns(bool on) = 0`
  - `Q_PROPERTY(bool writable …)` — false until a write has been seen to succeed, or after a 403
  - `Q_PROPERTY(QString writeError …)`
- `FakeTailscaleBackend` records calls so QML tests can assert them.

Each write is `PATCH /localapi/v0/prefs` with the value and its `…Set` sibling. Measured: `{"ExitNodeAllowLANAccessSet":true,"ExitNodeAllowLANAccess":true}` returns 200 for the operator user and `403 "prefs write access denied"` otherwise.

- [ ] **Step 1: Write the failing tests**

```cpp
void writesThePrefAndItsSetSibling()      // the PATCH body is exactly right
void reportsThatItCannotWriteOnA403()     // writable goes false, writeError is set
void lettsTheBusOverruleAnOptimisticWrite()  // notification carrying the opposite value wins
void selectsAnExitNodeByIdNotByIp()       // ExitNodeID is written, ExitNodeIP is not
```

- [ ] **Step 2: Run to verify they fail** — `$RR --verify tailscalebackend`
- [ ] **Step 3: Implement the five actions and the two properties**
- [ ] **Step 4: Run to verify they pass**
- [ ] **Step 5: Commit**

---

### Task 4: A fresh install can write

**Files:**
- Modify: `bin/c7shell-bootstrap`
- Modify: `tests/test-bootstrap.sh`

`tailscaled` authorises by peer credentials, not polkit, so the desktop user must be named as its operator once, with root. Set it when tailscale is installed, idempotently, and never override an operator that is already set to someone else without saying so.

- [ ] **Step 1: Write the failing test** — bootstrap sets the operator when tailscale is present; is a no-op when it is not installed; does not clobber a different existing operator.
- [ ] **Step 2: Run to verify it fails** — `$RR tests/test-bootstrap.sh`
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify it passes**
- [ ] **Step 5: Commit**

---

### Task 5: The exit-node view gains its controls and a search

**Files:**
- Modify: `quickshell/c7shell/Modules/Popovers/ExitNodeList.qml`
- Modify: `tests/tailscale-qml-test.qml`

Restores what the mock drew and v1 dropped: rows become selectable, plus `allow local network access` as a switch and `use this device as an exit node…`, and a search field filtering the list.

- [ ] **Step 1: Write the failing tests** — clicking a row calls `setExitNode(nodeId)`; `none` calls it with `""`; the LAN switch calls `setExitNodeAllowLANAccess`; search filters and a no-match query reads as "no matches"; every control is disabled with an explanation when `!Tailscale.writable`.
- [ ] **Step 2: Run to verify they fail** — `$RR tests/test-tailscale.sh`
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify they pass**, and `$RR tests/test-qml-hygiene.sh`
- [ ] **Step 5: Commit**

---

### Task 6: Sub-cards fold out, and devices gain a search

**Files:**
- Modify: `quickshell/c7shell/Common/GlassPopover.qml`
- Modify: `quickshell/c7shell/Modules/Popovers/TailscalePopover.qml`
- Modify: `tests/tailscale-qml-test.qml`

v1 replaces the panel contents and offers `‹`. v2 folds a sub-card out of the main card, as the macOS app does, and the device list gains a search field. `GlassPopover` is shared — **check every other popover still lays out** (`tests/test-bluetooth.sh`, `test-wifi.sh`, `test-power.sh`).

- [ ] **Step 1: Write the failing tests** — opening a sub-view grows the card rather than replacing it; the root stays visible; closing returns without a reload; search filters the device list across its three sections and hides a section that ends up empty.
- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify they pass**, plus the three neighbouring popover suites
- [ ] **Step 5: Commit**

---

### Task 7: Settings — accept routes and accept dns

**Files:**
- Modify: `quickshell/c7shell/Modules/Popovers/TailscalePopover.qml`
- Create: `quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml`
- Modify: `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp`
- Modify: `tests/tailscale-qml-test.qml`

A settings sub-card with `accept routes` (`RouteAll`) and `accept dns` (`CorpDNS`).

`accept routes` closes a loop from v1: `RouteAll: false` is the pref behind the standing health warning the module suppresses. With the switch present, the suppressed warning becomes explicable — say why it is suppressed, beside the control that changes it.

- [ ] **Step 1: Write the failing tests** — both switches reflect the backend and call their actions; the suppressed route warning is shown as an explanation beside `accept routes` rather than silently dropped; both are disabled with a reason when `!Tailscale.writable`.
- [ ] **Step 2: Run to verify they fail**
- [ ] **Step 3: Implement**
- [ ] **Step 4: Run to verify they pass**
- [ ] **Step 5: Commit, then `vm-install` and look at it**
