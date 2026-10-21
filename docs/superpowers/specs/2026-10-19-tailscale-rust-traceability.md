# Tailscale backend: traceability for the Rust rewrite

**Status:** draft for #289 (Phase 1 of epic #287).

**Source pin:** branch `feat/tailscale-backend` (PR #286) at commit `a38dbca`.

**Requirements:** `docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md`.

Phase 1 exits when every public symbol of the contract header and every
assertion of the existing suites maps to at least one requirement, or, for an
assertion that only checks the test's own setup, to the "Harness
preconditions" table. Table A maps the symbols. Table B maps the tests. The
harness table lists every setup-only assertion by `file:line`. Table C
lists the Phase 2 harness tests of the R-HTTP, R-PARSE and R-GROUP
requirements. The requirements reflect the owner's decisions of 2026-10-21
(the requirements' "Decisions (2026-10-21)" section); where a decision
changed #286's behaviour, the #286 assertion that pinned the old behaviour
maps to the `fix` requirement, as noted below Table B.

## How the counts were taken

- **C++ suites.** The count is the number of `QCOMPARE`, `QVERIFY`, `QVERIFY2`,
  `QTRY_COMPARE`, `QTRY_VERIFY`, `QTRY_VERIFY2` (each with or without
  `_WITH_TIMEOUT`) and `QFAIL` calls inside the test function's own body. The
  three `QTRY_VERIFY2` calls are all in the backend suite
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:798`,
  `:1291` and `:1349`) and are in its 218. String literals and comments are
  ignored. Assertions inside shared helpers are not counted. A `_data`
  function has 0, because it only supplies rows.
- **Scope.** A test function is in scope when it tests Tailscale behaviour, or
  when #286 added it to a shared suite for Tailscale's sake. A test that #286
  touched only in passing and that tests something else is listed with `—` and
  maps to no requirement. The one such test is
  `plugin/tests/tst_module.cpp::buildSingletonReportsTheLibraryVersion`: #286 moved it onto
  the new `singleton()` helper and reworded its `QVERIFY2` message, but it
  tests the `Build` singleton.
- **QML suite.** `tests/tailscale-qml-test.qml` has no `test_*` functions. Its
  `run()` holds the bar-slot checks and calls six check functions. The count is
  the number of `check(...)` calls in each function's body. Six more
  `check(...)` calls sit in helpers; they are counted in their own table, so
  the file's 262 calls are 256 in functions plus 6 in helpers.
- **Shell suites.** Each check is one `fail` site, so each counts as 1. The
  stand-ins `tests/test-tailscale.sh` writes are listed with 0, because they define
  behaviour and assert nothing.
- **Harness column.** Each count includes the function's harness
  preconditions. The "Harness" column says how many of them there are; the
  "Harness preconditions" table names each one. The requirements in a row map
  the function's other assertions. A row whose every assertion is a harness
  precondition maps to no requirement and reads "— (harness)".

## Table A: contract symbols

Every public symbol of `plugin/src/contracts/TailscaleBackend.h` maps to the
requirements that pin it.

### Registration and factory

| Symbol | Requirements |
|---|---|
| `QML_NAMED_ELEMENT(Tailscale)` | R-UI-01 |
| `QML_SINGLETON` | R-UI-01 |
| `create(QQmlEngine*, QJSEngine*)` | R-UI-01, R-CONN-01, R-SEC-02 |

### Enum

| Symbol | Requirements |
|---|---|
| `State` (enum, `Q_ENUM`) | R-UI-04, R-WATCH-13 |
| `State::NoState` | R-UI-04, R-UI-05, R-CONN-02, R-CONN-06, R-QML-01, R-QML-05 |
| `State::NeedsMachineAuth` | R-UI-04, R-WATCH-13, R-QML-05 |
| `State::NeedsLogin` | R-UI-04, R-WATCH-13, R-WRITE-01, R-QML-05, R-QML-22, R-UI-17 |
| `State::Stopped` | R-UI-04, R-WATCH-13, R-QML-05, R-UI-15, R-WRITE-09 |
| `State::Starting` | R-UI-04, R-WATCH-13, R-QML-05, R-QML-22 |
| `State::Running` | R-UI-04, R-WATCH-13, R-QML-05, R-UI-15 |

### Properties

| Property | Type | Requirements |
|---|---|---|
| `state` | `State` | R-UI-02, R-UI-03, R-UI-04, R-WATCH-13, R-CONN-06, R-QML-05 |
| `selfName` | string | R-UI-02, R-UI-03, R-PARSE-05, R-WATCH-13, R-QML-23 |
| `selfIp4` | string | R-UI-02, R-UI-03, R-PARSE-03, R-WATCH-13, R-QML-23 |
| `selfIp6` | string | R-UI-02, R-UI-03, R-PARSE-03, R-WATCH-13, R-QML-23 |
| `selfDnsName` | string | R-UI-02, R-UI-03, R-UI-07, R-WATCH-13, R-QML-23 |
| `tailnet` | string | R-UI-02, R-UI-03, R-PARSE-02, R-WATCH-13, R-QML-23 |
| `keyExpiry` | date-time | R-UI-02, R-UI-03, R-PARSE-04, R-QML-06 |
| `exitNodeActive` | bool | R-UI-02, R-UI-03, R-UI-08, R-WATCH-14, R-UI-15 |
| `exitNodeId` | string | R-UI-02, R-UI-03, R-UI-10, R-WATCH-14, R-QML-11 |
| `exitNodeName` | string | R-UI-02, R-UI-03, R-PARSE-09, R-WATCH-14, R-QML-04, R-QML-08 |
| `exitNodeOnline` | bool | R-UI-02, R-UI-03, R-UI-08, R-PARSE-08, R-WATCH-14 |
| `exitNodeBlocked` | bool | R-UI-02, R-UI-03, R-UI-06, R-UI-08, R-UI-09, R-QML-03, R-QML-25, R-CONN-14 |
| `issues` | string list | R-UI-02, R-UI-03, R-UI-11, R-PARSE-12, R-QML-07 |
| `issueCount` | int | R-UI-02, R-UI-03, R-UI-11, R-UI-15 |
| `peers` | list model, constant | R-UI-02, R-UI-12, R-GROUP-01 to R-GROUP-08, R-GROUP-10, R-GROUP-11, R-GROUP-12, R-QML-09 |
| `exitNodes` | list model, constant | R-UI-02, R-UI-12, R-GROUP-09, R-GROUP-10, R-GROUP-12, R-QML-11 |
| `recommendedExitNodeId` | string | R-UI-02, R-UI-03, R-PARSE-11, R-CONN-11, R-WATCH-12, R-UI-14, R-QML-11 (R-PARSE-11's newest-pass rule is decision 17) |
| `writable` | bool | R-UI-02, R-UI-03, R-WRITE-06, R-WRITE-08, R-WRITE-11, R-HTTP-09, R-QML-20, R-QML-22, R-UI-17 |
| `writeError` | string | R-UI-02, R-UI-03, R-WRITE-06, R-WRITE-08, R-WRITE-11, R-HTTP-09, R-UI-16, R-QML-20, R-QML-22, R-UI-17 |
| `readError` | string | R-UI-02, R-UI-03, R-CONN-02, R-CONN-03, R-CONN-04, R-CONN-05, R-CONN-06, R-CONN-13, R-CONN-14, R-CONN-15, R-CONN-16, R-HTTP-09, R-HTTP-15, R-WATCH-13, R-WATCH-15, R-QML-02, R-UI-16 |
| `wantRunning` | bool | R-UI-02, R-UI-03, R-WRITE-01, R-WRITE-09, R-QML-22, R-CONN-14 |
| `exitNodeAllowLANAccess` | bool | R-UI-02, R-UI-03, R-WRITE-01, R-QML-18, R-CONN-14 |
| `acceptRoutes` | bool | R-UI-02, R-UI-03, R-WRITE-01, R-WRITE-08, R-QML-21, R-CONN-14 |
| `acceptDns` | bool | R-UI-02, R-UI-03, R-WRITE-01, R-QML-21, R-CONN-14 |

Each property row also maps the public READ accessor that backs it: the 21
pure virtuals (`state()`, `selfName()`, ... `readError()`, including
`peers()` and `exitNodes()`;
`plugin/src/contracts/TailscaleBackend.h:118-339`). Three READ accessors are non-virtual
and carry a rule the contract itself owns, so each is named with the
requirement it implements: `selfDnsName()` is R-UI-07 (the trailing root dot
is stripped), `exitNodeBlocked()` is R-UI-08 (`exitNodeActive` and not
`exitNodeOnline`), and `issueCount()` is R-UI-11 (the length of `issues`,
sharing its signal).

The members the 2026-10-21 decisions add are listed in the requirements'
"Contract additions" table, not here, because #286 has none of them:
`loginUrl` and `login()` (R-UI-17), `advertisingExitNode`,
`exitNodeAwaitingApproval`, `ipForwardingWarning` and
`setAdvertiseExitNode(bool)` (R-WRITE-10), and `peersKnown` (R-GROUP-11).
Their fresh values, the test-only fake's setters for them and the QML
stand-in's copies of them are R-UI-18, R-UI-19 and R-QML-30 (`fix`), split
from the parity requirements R-UI-05, R-UI-14 and R-QML-25, which keep
#286's members only. Likewise the clauses that apply #286's contract rules
to the added members (read-only from R-UI-03, store-then-announce from
R-UI-06 and R-WATCH-11, no collapsing from R-WRITE-05, no process and no
blocking from R-SEC-01) are R-UI-18's, and the stand-in comparison's
coverage of the added members and `PeerFilter` (from R-QML-24) is
R-QML-30's; those parity requirements now cover #286's members only.
Decisions 3 and 5 add no member, and decision 18 defers one to follow-up issue #299.
R-UI-02 and R-UI-13 check the surface against the #286 set plus that list:
29 properties and 7 invokables. Both are `fix`, because decisions 1, 2 and 6
change #286's exact sets: #286's exact-set assertions
(`plugin/tests/tst_module.cpp:152`, 24 properties, and `:171`, 5
invokables) hold on `a38dbca` only because the decided members are missing,
and map to R-UI-02 and R-UI-13, whose criteria name 29 and 7 at the same
comparison.

### Signals

Every signal below is also covered by R-UI-06, which says each fires once,
only on change, after the whole snapshot is stored.

| Signal | Requirements |
|---|---|
| `stateChanged` | R-UI-06, R-CONN-06 |
| `selfNameChanged` | R-UI-06, R-WATCH-13 |
| `selfIp4Changed` | R-UI-06, R-WATCH-13 |
| `selfIp6Changed` | R-UI-06, R-WATCH-13 |
| `selfDnsNameChanged` | R-UI-06, R-UI-07 |
| `tailnetChanged` | R-UI-06, R-WATCH-13 |
| `keyExpiryChanged` | R-UI-06, R-WATCH-13 |
| `exitNodeActiveChanged` | R-UI-06, R-UI-09 |
| `exitNodeIdChanged` | R-UI-06, R-WATCH-14 |
| `exitNodeNameChanged` | R-UI-06, R-WATCH-14 |
| `exitNodeOnlineChanged` | R-UI-06, R-UI-09 |
| `exitNodeBlockedChanged` | R-UI-06, R-UI-09 |
| `issuesChanged` | R-UI-06, R-UI-11 |
| `recommendedExitNodeIdChanged` | R-UI-06, R-PARSE-11 |
| `writableChanged` | R-UI-06, R-WRITE-06 |
| `writeErrorChanged` | R-UI-06, R-WRITE-06, R-WRITE-08 |
| `readErrorChanged` | R-UI-06, R-CONN-03, R-CONN-05 |
| `wantRunningChanged` | R-UI-06, R-WRITE-01 |
| `exitNodeAllowLANAccessChanged` | R-UI-06, R-WRITE-01 |
| `acceptRoutesChanged` | R-UI-06, R-WRITE-01 |
| `acceptDnsChanged` | R-UI-06, R-WRITE-01 |

### Constructor

| Symbol | Requirements |
|---|---|
| `explicit TailscaleBackend(QObject *parent = nullptr)` (public) | R-UI-09 (it connects `exitNodeActiveChanged` and `exitNodeOnlineChanged` to `exitNodeBlockedChanged`), R-UI-08 (so no backend can skip the derivation), R-UI-14 (the fake backend is built through it) |

### Invokables

| Invokable | Requirements |
|---|---|
| `setWantRunning(bool)` | R-UI-13, R-WRITE-02, R-WRITE-04, R-WRITE-09, R-QML-22 |
| `setExitNode(QString)` | R-UI-13, R-WRITE-02, R-WRITE-03, R-WRITE-04, R-QML-17 |
| `setExitNodeAllowLANAccess(bool)` | R-UI-13, R-WRITE-02, R-WRITE-04, R-QML-18 |
| `setAcceptRoutes(bool)` | R-UI-13, R-WRITE-02, R-WRITE-04, R-QML-21 |
| `setAcceptDns(bool)` | R-UI-13, R-WRITE-02, R-WRITE-04, R-WRITE-05, R-QML-21 |

### Non-public members

These are not on the QML surface. They are listed so the header is covered in
full.

| Member | Requirements |
|---|---|
| `rawSelfDnsName()` (protected) | R-UI-07 |
| `withoutRootDot()` (private) | R-UI-07 |

The constructor is public and is listed under "Constructor" above.

## Table B: tests

### `plugin/lib/tailscale/tests/tst_localapiclient.cpp` (90 assertions, 9 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `init` | 1 | 1 | — (harness) |
| `getReturnsTheBodyWithoutHeaders` | 2 | 0 | R-HTTP-03 |
| `failsWhenTheConnectionClosesBeforeTheResponseHeaders` | 4 | 0 | R-HTTP-07 |
| `sendsAHostHeaderTailscaledAccepts` | 3 | 0 | R-HTTP-01 |
| `patchSendsTheBodyUnderItsOwnLength` | 6 | 0 | R-HTTP-02 |
| `patchCarriesItsTokenBackOnEitherEnding` | 2 | 0 | R-HTTP-02, R-HTTP-12 |
| `patchFailsWhenTailscaledRefusesTheWrite` | 3 | 0 | R-HTTP-08 |
| `getReassemblesAChunkedBody` | 3 | 0 | R-HTTP-04 |
| `readsABodyThatEndsAtTheClose` | 3 | 0 | R-HTTP-06 |
| `failsRatherThanHangingWhenTheSocketIsAbsent` | 1 | 0 | R-HTTP-10 |
| `failsOnANonSuccessStatus` | 4 | 0 | R-HTTP-08 |
| `emitsOneEventPerCompleteLine` | 3 | 1 | R-WATCH-03, R-WATCH-01 |
| `saysWhenTheWatchIsEstablished` | 4 | 0 | R-WATCH-02 |
| `neverSaysAWatchStartedWhenItWasRefused` | 2 | 0 | R-WATCH-02 |
| `neverSaysAWatchStartedForAGet` | 2 | 0 | R-WATCH-02 |
| `watchesWithoutTheEngineUpdateBitAndWithoutPrivateKeys` | 2 | 0 | R-WATCH-01 |
| `neverEmitsAPartialLine` | 4 | 1 | R-WATCH-03, R-WATCH-01 |
| `joinsAWatchLineSplitAcrossChunks` | 4 | 1 | R-HTTP-04, R-WATCH-01 |
| `waitsForAChunkSizeLineSplitAcrossReads` | 5 | 1 | R-HTTP-04, R-WATCH-01 |
| `endsTheWatchOnTheLastChunk` | 3 | 1 | R-WATCH-04, R-WATCH-01 |
| `endsTheWatchWhenTailscaledGoes` | 3 | 1 | R-WATCH-04 |
| `aFailingWatchSaysWhyAndThenThatItEnded` | 1 | 0 | R-WATCH-04 |
| `aGetWithNoAnswerAtAllEndsInFailedAtItsDeadline` | 5 | 1 | R-HTTP-13 |
| `aGetWhoseBodyNeverArrivesEndsInFailedAtItsDeadline` | 2 | 0 | R-HTTP-13 |
| `aWatchThatNeverStartsEndsInFailedAndThenWatchEnded` | 2 | 0 | R-WATCH-05 |
| `anEstablishedWatchIsNotTimedOutByAQuietBus` | 4 | 0 | R-WATCH-05 |
| `handsTheTokenBackOnTheReply` | 2 | 0 | R-HTTP-12 |
| `handsTheTokenBackOnTheFailure` | 2 | 0 | R-HTTP-12 |
| `reportsZeroForAnUntaggedGetAndForTheWatch` | 4 | 0 | R-HTTP-12 |
| `saysNothingWhenTheWatchIsStopped` | 4 | 1 | R-WATCH-06 |

`sendsAHostHeaderTailscaledAccepts` asserts a reply arrives (line 95) and the
recorded bytes; R-HTTP-01's acceptance names both. In
`joinsAWatchLineSplitAcrossChunks`, line 358 (no event after the first chunk
only) is R-HTTP-04's "after only the first chunk and the read barrier"
clause, not a harness precondition.

### `plugin/lib/tailscale/tests/tst_statusparser.cpp` (48 assertions, 1 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `parsesBackendStateAndHealth` | 6 | 0 | R-PARSE-02, R-PARSE-03 |
| `parsesSelfIp6AndKeyExpiry` | 4 | 0 | R-PARSE-03, R-PARSE-04 |
| `leavesKeyExpiryInvalidWhenTheNodeKeyNeverExpires` | 2 | 0 | R-PARSE-04 |
| `saysWhetherTheReplyCarriedAPeerSectionAtAll` | 7 | 0 | R-PARSE-07 (150, `"Peer":null` under `Running` has no Peer section: pins the defect; the corrected R-PARSE-07 asserts it has one, with no peers) |
| `rejectsMalformedJson` | 2 | 0 | R-PARSE-01 |
| `groupsPeersByUserId` | 3 | 0 | R-GROUP-01 |
| `namesTheOwnerOnlyForOtherUsers` | 2 | 0 | R-GROUP-02 |
| `prefersTheDnsLabelOverTheHostName` | 3 | 0 | R-PARSE-05 |
| `fallsBackToTheHostNameWithoutMagicDns` | 2 | 0 | R-PARSE-05 |
| `namesThisDeviceByItsDnsLabelToo` | 2 | 0 | R-PARSE-05 |
| `fallsBackToThisDevicesHostNameWithoutMagicDns` | 2 | 0 | R-PARSE-05 |
| `joinsExitNodeNameFromItsPeer` | 3 | 0 | R-PARSE-08, R-PARSE-09 |
| `namesTheExitNodeByItsDnsLabelNotItsHostName` | 4 | 1 | R-PARSE-09 |
| `fallsBackToTheIdWhenTheExitPeerIsMissing` | 3 | 0 | R-PARSE-09 |
| `stripsTheMaskFromExitNodeAddresses` | 3 | 0 | R-PARSE-13 (replaces the withdrawn R-PARSE-10) |

### `plugin/lib/tailscale/tests/tst_peermodel.cpp` (56 assertions, 3 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `keepsRowIdentityAcrossAnUpdate` | 3 | 0 | R-GROUP-06, R-GROUP-07 |
| `ordersGroupsThenOfflineLast` | 2 | 0 | R-GROUP-03 |
| `insertsAndRemovesRatherThanResetting` | 2 | 0 | R-GROUP-06 |
| `movesARowRatherThanRebuildingIt` | 6 | 0 | R-GROUP-06, R-GROUP-03 |
| `insertsANewPeerInPlace` | 5 | 0 | R-GROUP-06 |
| `leavesUntouchedRowsAlone` | 1 | 0 | R-GROUP-07 |
| `pinsAKnownPeersFields` | 10 | 2 | R-PARSE-06, R-GROUP-04, R-GROUP-01 |
| `pinsTheOwnerAndExitNodeRoles` | 4 | 0 | R-GROUP-02, R-GROUP-04 |
| `namesEveryRoleForViews` | 11 | 0 | R-GROUP-04 |
| `answersNothingOffTheEndOrBeneathARow` | 4 | 0 | R-GROUP-05 |
| `dropsRowsLeftOverWhenPeersShareANodeId` | 5 | 1 | R-GROUP-08 |
| `emptiesWithoutResetting` | 3 | 0 | R-GROUP-07 |

### `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp` (218 assertions, 21 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `init` | 1 | 1 | — (harness) |
| `publishesStateAndPeersFromTheStatusReply` | 6 | 0 | R-WATCH-13 |
| `reportsTheBlockedStateWhenTheExitNodeIsOffline` | 4 | 0 | R-WATCH-14 |
| `doesNotReportBlockedWhileTheExitNodeAnswers` | 4 | 0 | R-WATCH-14 |
| `failsClosedWhenPrefsSelectsAnExitNodeTheStatusHasNotResolved` | 7 | 1 | R-WATCH-14 |
| `clearsTheBlockWhenPrefsStopsSelectingAnExitNode` | 6 | 0 | R-WATCH-14, R-HTTP-11 |
| `publishesTheSwitchPrefsFromTheSamePrefsReadItAlreadyMakes` | 5 | 0 | R-WRITE-01 |
| `followsTheBusWhenASwitchPrefChanges` | 11 | 0 | R-WRITE-01, R-HTTP-11 |
| `dropsAHalfFinishedPassWhenTheConnectionIsLost` | 10 | 2 | R-WATCH-12 (540, 541: criterion clauses), R-CONN-06 (551: decision 24), R-HTTP-11 |
| `connectsThroughASuggestionThatFails_data` | 0 | 0 | R-CONN-11 |
| `connectsThroughASuggestionThatFails` | 5 | 0 | R-CONN-11 (line 620, `state` still the served state after the wait: the criterion's re-check after the 10 ms advance) |
| `forgetsTheSuggestionWhenTheEndpointStopsOfferingOne` | 5 | 0 | R-PARSE-11, R-HTTP-11 |
| `keepsTheDeviceListWhenAStatusDoesNotDescribeTheTailnet` | 6 | 0 | R-GROUP-10 (all hold under the fix: a status with no `Peer` key keeps the rows and `"Peer":{}` clears them), R-HTTP-11 |
| `retriesWhenTailscaledAcceptsARequestAndNeverAnswersIt` | 5 | 0 | R-CONN-12, R-HTTP-11 |
| `doesNotCountTheSuppressedRouteWarning` | 5 | 2 | R-PARSE-12 |
| `countsEveryOtherHealthWarning` | 3 | 1 | R-PARSE-12 (its third assertion reads the internal suppression list; R-PARSE-12 pins the observable form) |
| `settlesInNoStateWhenTailscaledIsAbsent` | 3 | 0 | R-CONN-02 |
| `saysWhyWhenTheDaemonIsThereAndUnreadable` | 4 | 0 | R-CONN-03 |
| `saysNothingWhenThereIsNoTailscaledAtAll` | 3 | 0 | R-CONN-02 |
| `clearsTheReadErrorWhenTheDaemonAnswersAgain` | 3 | 0 | R-CONN-05 |
| `republishesOnAWatchEvent` | 5 | 0 | R-WATCH-08, R-HTTP-11 |
| `publishesOnlyExitNodeCapablePeersAsExitNodes` | 5 | 1 | R-GROUP-09, R-PARSE-11 |
| `everyExitNodeFieldIsStoredBeforeBlockedIsAnnounced` | 5 | 0 | R-UI-06, R-HTTP-11 |
| `returnsToNoStateAndReconnectsWhenTailscaledRestarts` | 6 | 2 | R-CONN-06 |
| `refusesAStatusThatCarriesNoBackendState` | 2 | 0 | R-CONN-04 (940: the four-request count that decision 24 replaces) |
| `readsEachEndpointOnceAndThenWatches` | 4 | 0 | R-WATCH-07, R-CONN-13 |
| `theRetryCurveDoublesAndCapsAtThirtySeconds` | 6 | 0 | R-CONN-07 |
| `oneLostConnectionArmsOneRetry` | 4 | 0 | R-CONN-08 (991: the four-request count that decision 24 replaces) |
| `theBackoffAdvancesWhenOnlyPartOfTheLocalApiAnswers` | 2 | 0 | R-CONN-09 |
| `theBackoffAdvancesWhenTheWatchKeepsEndingAfterItStarts` | 4 | 0 | R-CONN-10, R-WATCH-07, R-HTTP-11 |
| `aConnectionThatHoldsClearsTheBackoff` | 5 | 0 | R-CONN-10, R-HTTP-11 |
| `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem` | 11 | 2 | R-WATCH-10, R-HTTP-11 |
| `aNotificationCarryingNothingThisModuleReadsDoesNotRefresh` | 5 | 0 | R-WATCH-09, R-HTTP-11 |
| `refreshesOnANotificationItDoesNotRecognise` | 3 | 0 | R-WATCH-09, R-HTTP-11 |
| `rereadsTheSuggestionOnANotification` | 4 | 0 | R-WATCH-08, R-HTTP-11 |
| `writesThePrefAndItsSetSibling_data` | 0 | 0 | R-WRITE-02 |
| `writesThePrefAndItsSetSibling` | 5 | 0 | R-WRITE-02, R-UI-13 |
| `reportsThatItCannotWriteOnA403` | 12 | 0 | R-WRITE-06, R-WRITE-07, R-WRITE-08 (1313: the pinned defect) |
| `keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` | 7 | 2 | R-WRITE-06 |
| `aTransientFailureAfterARefusalDoesNotReviveTheControls` | 6 | 2 | R-WRITE-06 |
| `letsTheBusOverruleAnOptimisticWrite` | 12 | 3 | R-WRITE-04, R-WRITE-06, R-WRITE-08 (1420 and 1421: the pinned defect) |
| `selectsAnExitNodeByIdNotByIp` | 9 | 2 | R-WRITE-03 |

Single lines worth naming: `republishesOnAWatchEvent` line 854
(`exitNodeActive` false before the notification) is R-WATCH-08's first
clause. `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem`
line 1143 (`state` still `Running` after the replay pass) is R-WATCH-10's last
clause. `reportsThatItCannotWriteOnA403` line 1286 and
`keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` line 1339
(`writable` true on a running backend before any write) are R-WRITE-06's
first clause. `letsTheBusOverruleAnOptimisticWrite` lines 1420 (`writeError`
empty after a 200 for an exit node the daemon did not select) and 1421
(`exitNodeId` still empty at that point) pin the R-WRITE-08 defect, "an
accepted write that tailscaled does not apply produces no feedback at all".
Under the requirements' rule for `fix` tags both map to R-WRITE-08, whose
"exit node imposed" run repeats #286's staging and names the corrected
values at the same observables: with decision 5's confirmation pass, after
the idle barrier `writeError` is `exit node was not applied` and
`exitNodeId` is already the imposed id, and both assertions fail on the
rewrite for that reason. R-WRITE-04 states the same corrected values, so the
two agree. Lines 1409-1410 (`exitNodeId`
still empty and `exitNodeActive` still false right after `setExitNode`,
before the event loop ran) are R-WRITE-04's "setter returning is the
barrier" clause, which states both values. Line 1414 (the fake records
exactly one PATCH) is R-WRITE-04's PATCH count, read after the "Request
counts" barriers. Lines 1424-1425 (the imposed id, never the chosen one)
stay R-WRITE-04's.
`reportsThatItCannotWriteOnA403` line 1313 (`writeError` empty after the
200 that follows the 403, with `/prefs` still holding `RouteAll` false)
likewise pins the R-WRITE-08 defect and maps to R-WRITE-08's "403 then 200,
not applied" run, which names `accept routes was not applied` there; lines
1311-1312 stay R-WRITE-06's recovery clause, staged as #286 stages it.
`dropsAHalfFinishedPassWhenTheConnectionIsLost` line 551 (`Running` again
after a notification pushed on the watch the 503 left open) pins #286's
open orphan watch, which decision 24 removes: it maps to R-CONN-06, whose
third run asserts the corrected value (the push reaches no client, `state`
stays `NoState` until the reconnect). Lines 552-553 (the newer pass's exit
node, never the straggler's) stay R-WATCH-12's; its rewritten criterion
reaches that pass through the reconnect.
`readsEachEndpointOnceAndThenWatches` lines 951, 952 and 956 (`Running`, then
four requests, one GET each of `status`, `prefs` and `suggest-exit-node` and
one watch) are R-WATCH-07's count after the opening pass: its criterion
asserts exactly four requests after the idle barrier that follows that pass,
before paused time advances, the same value as line 952. Line 959 (still 4
requests after a wait with no notification, "nothing polls") pins #286's
absence of a liveness probe, which decision 4 changes, so it maps to
R-WATCH-07, tagged `fix` for that reason. The rewrite's test asserts the
corrected value at the same observable, the fake's request list after a wait
with no notification: after one hour of paused time it holds exactly 124
requests, the four plus exactly 120 probes (`GET /localapi/v0/prefs`), and
still exactly one watch and one GET each of `status` and
`suggest-exit-node`. That test fails on `a38dbca`, which records no probe.

### `plugin/tests/tst_tailscalebackend.cpp` (44 assertions, 0 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `aFreshBackendReadsAsNothingKnownYet` | 12 | 0 | R-UI-05 (lines 23-31, 37, 38 and 42: its fresh-fake paragraph, which states these values for the test-only fake) |
| `everyActionIsCallableByName_data` | 0 | 0 | R-UI-13 |
| `everyActionIsCallableByName` | 2 | 0 | R-UI-13 |
| `anActionChangesNothingOnTheContract` | 3 | 0 | R-WRITE-04, R-UI-14 |
| `aRefusedWriteReachesQmlAsState` | 9 | 0 | R-UI-14 (lines 122-131: the fake's `setWritable` and `setWriteError` each fire one change signal and read back through the metaobject), R-UI-05 (line 117: a fresh backend reads `writable` true) |
| `selfDnsNameLosesTheRootDotWhateverTheBackendStored` | 3 | 0 | R-UI-07 |
| `exitNodeBlockedIsFailClosed_data` | 0 | 0 | R-UI-08 |
| `exitNodeBlockedIsFailClosed` | 2 | 0 | R-UI-08 |
| `exitNodeBlockedAnnouncesItselfOnEitherInput` | 4 | 0 | R-UI-09 |
| `issueCountRidesTheIssuesSignal` | 5 | 0 | R-UI-11 |
| `bothCollectionsAreStableRowModels` | 4 | 0 | R-UI-12, R-UI-14 |

The suite runs against the fake backend, which R-UI-14 pins.

### `plugin/tests/tst_module.cpp`, Tailscale tests (13 assertions, 5 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `initTestCase` | 1 | 1 | — (harness) |
| `tailscaleSingletonLoadsAndStaysInNoState` | 8 | 2 | R-UI-04, R-UI-05, R-UI-12 |
| `tailscaleSingletonExposesExactlyTheContract` | 2 | 1 | R-UI-02 (fix: `:152` pins the 24-name set, which decisions 1, 2 and 6 grow to 29) |
| `tailscaleSingletonExposesExactlyItsActions` | 2 | 1 | R-UI-13 (fix: `:171` pins the 5 signatures, which decisions 1 and 2 grow to 7) |
| `buildSingletonReportsTheLibraryVersion` (changed by #286, not counted) | 2 | — | — (out of scope) |

The helpers `declaredProperties` and `invokableMethods` serve R-UI-02 and
R-UI-13. The `singleton()` helper #286 adds loads a named singleton from module
C7; the suite's checks that it resolved (lines 108, 127 and 164) are harness
preconditions. `buildSingletonReportsTheLibraryVersion` tests the
`Build` singleton, not Tailscale. #286 changed it only to use `singleton()`
and to reword its `QVERIFY2` message, so it is excluded under the scope rule in
"How the counts were taken". Its 2 assertions are not in the 13.

### `plugin/lib/testing/tests/tst_fakesocketserver.cpp`, #286 additions (14 assertions, 3 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `readsTheBodyARequestDeclaresBeforeFramingIt` | 7 | 1 | R-FAKE-01 |
| `pushesExactlyTheBytesOfAChunk` | 7 | 2 | R-FAKE-02 |

### `plugin/lib/testing/tests/tst_fakesocketserver.cpp`, tests from before #286

These are not #286's, so they are not in the counts above. The Tailscale
acceptances rely on them, and plan Phase 2b ports them, so they are mapped
here.

| Test function | Requirements |
|---|---|
| `init` | — (harness: line 48 checks the per-test temporary directory) |
| `listensAtTheGivenPathForThisUserOnly` | R-FAKE-06 |
| `repliesAndClosesLikeARequestSocket` | R-FAKE-06 |
| `canKeepTheClientOpen` | R-FAKE-06 |
| `splitsFramedRequestsWhateverTheReadsLookLike` | R-FAKE-06, R-FAKE-01 |
| `answersNothingAfterClosing` | R-FAKE-06 |
| `pushesLinesToEveryClientLikeAnEventSocket` | R-FAKE-06, R-FAKE-02 |
| `saysWhenALineReachedNobody` | R-FAKE-06, R-FAKE-02 |
| `recordsRequestsWithoutAHandler` | R-FAKE-06 |
| `disconnectsItsClientsAndRemovesTheSocketWhenDestroyed` | R-FAKE-06, R-CONN-06 |
| `refusesAPathAlreadyTaken_data` | R-FAKE-05 |
| `refusesAPathAlreadyTaken` | R-FAKE-05 |
| `reportsADirectoryItCannotCreate` | R-FAKE-06 |
| `reportsAPathTooLongToListenOn` | R-FAKE-06 |

Their `QVERIFY(client)` checks (a client connected to the fake) are harness
preconditions of the same kind as line 129; they are outside the #286 counts,
so they are not listed one by one.

### `plugin/lib/testing/tests/tst_isolation.cpp`, #286 addition (2 assertions, 0 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `theTailscaleSocketPointsNowhere` | 2 | 0 | R-SEC-02 |

### `tests/tailscale-qml-test.qml` (262 checks: 256 in functions, 6 in helpers; 20 harness)

| Function | Checks | Harness | Requirements |
|---|---:|---:|---|
| `run` (bar slot, sections 1 to 6b) | 37 | 1 | R-QML-01, R-QML-02, R-QML-03, R-QML-04, R-UI-15, R-QML-25, R-SEC-03 |
| `panelChecks` | 55 | 2 | R-QML-05, R-QML-06, R-QML-07, R-QML-08, R-QML-09, R-QML-10, R-QML-11, R-QML-12, R-QML-17, R-QML-20, R-SEC-03 |
| `foldOutChecks` | 40 | 1 | R-QML-09, R-QML-12, R-QML-13, R-QML-14, R-GROUP-11 |
| `exitNodeControlChecks` | 44 | 1 | R-QML-17, R-QML-18, R-QML-19, R-QML-20, R-WRITE-10, R-SEC-03 |
| `settingsChecks` | 40 | 1 | R-QML-12, R-QML-20, R-QML-21, R-SEC-03 |
| `connectToggleChecks` | 19 | 0 | R-QML-22, R-WRITE-09, R-SEC-03 |
| `delegateIdentityChecks` | 21 | 9 | R-GROUP-06, R-QML-10, R-QML-25 |

Functions with more than ten checks, by line range. Each range's checks map
to the requirements given. A single line inside a range that maps somewhere
else, or that is a harness precondition, is listed on its own.

| Function | Lines | Requirements |
|---|---|---|
| `run` | 180 | — (harness) |
| `run` | 206-208 | R-QML-01 |
| `run` | 223-241 | R-QML-02 |
| `run` | 246-298 | R-UI-15 (287: R-QML-25) |
| `run` | 309-316 | R-QML-03 |
| `run` | 330-343 | R-QML-04 |
| `run` | 364 | R-SEC-03 |
| `panelChecks` | 521-539 | R-QML-05 (521: R-QML-12; 535 checked with devices folded, see below) |
| `panelChecks` | 546-561 | R-QML-06 |
| `panelChecks` | 569-576 | R-QML-07 (574: R-SEC-03) |
| `panelChecks` | 586-596 | R-QML-08 (590: R-SEC-03) |
| `panelChecks` | 605-648 | R-QML-09 (610: R-QML-12) |
| `panelChecks` | 660-724 | R-QML-10 (670, 672: harness) |
| `panelChecks` | 748-791 | R-QML-11 |
| `panelChecks` | 800-808 | R-QML-17, R-QML-20 |
| `panelChecks` | 816-822 | R-QML-11 |
| `foldOutChecks` | 854-909 | R-QML-12 (864: R-QML-09, R-QML-12; 896: harness) |
| `foldOutChecks` | 918-968 | R-QML-13 (961: R-GROUP-11, fix) |
| `foldOutChecks` | 979-984 | R-QML-14 |
| `foldOutChecks` | 995-998 | R-QML-13 |
| `foldOutChecks` | 1008-1013 | R-QML-12 |
| `foldOutChecks` | 1026-1040 | R-QML-14 |
| `exitNodeControlChecks` | 1090-1096 | R-QML-17, R-QML-20 |
| `exitNodeControlChecks` | 1105-1128 | R-QML-17 (1105: harness) |
| `exitNodeControlChecks` | 1146-1174 | R-QML-18 (1171: the false-to-true request; 1174: the unapplied write) |
| `exitNodeControlChecks` | 1183-1188 | R-WRITE-10 (all four: 1183 unchanged; 1184, 1186 and 1188 pin the dead row that decision 2 replaces, and R-WRITE-10's view half states each replacement) |
| `exitNodeControlChecks` | 1196-1236 | R-QML-19 |
| `exitNodeControlChecks` | 1248-1280 | R-QML-20 (1251: R-SEC-03) |
| `settingsChecks` | 1319-1340 | R-QML-12, R-QML-21 |
| `settingsChecks` | 1346 | R-QML-20 |
| `settingsChecks` | 1349-1413 | R-QML-21 (1375: harness; 1383: R-SEC-03) |
| `settingsChecks` | 1421-1453 | R-QML-20 (1424: R-SEC-03; 1443: R-QML-21) |
| `settingsChecks` | 1471-1481 | R-QML-20 |
| `settingsChecks` | 1493-1496 | R-QML-12 |
| `connectToggleChecks` | 1540-1559 | R-QML-22 |
| `connectToggleChecks` | 1567-1577 | R-QML-22, R-WRITE-09 |
| `connectToggleChecks` | 1588-1597 | R-QML-22 (the `NoState` clause; 1597: the toggle returns with the daemon) |
| `connectToggleChecks` | 1605-1640 | R-QML-22 (1618: R-SEC-03; 1640: a request once `writable` returns) |
| `delegateIdentityChecks` | 1683-1764 | R-GROUP-06 at 1715, 1716, 1719, 1723 (alpha's delegate reads `online` false), 1727, 1742, 1744, 1749, 1751 and 1761; R-GROUP-06 and R-QML-25 at 1764 (the rebuilt delegate lost the local state); R-QML-10 at 1696; every other line (1683, 1684, 1688, 1695, 1713, 1725, 1741, 1748, 1760) is a harness precondition |

Single lines whose clause the audit of the mapped acceptance had to find:

- `tests/tailscale-qml-test.qml:1008` (`foldOutChecks`) checks that
  `ts-self-name` stays visible when the exit sub-card folds out, with devices
  open. R-QML-12's acceptance names it ("keeps the root row `ts-self-name`
  visible" in the exit case).
- `tests/tailscale-qml-test.qml:1331` (`settingsChecks`) checks the same for the
  settings sub-card. The test sets `pop.expanded = ""` at :1316, so devices
  are shut before that click. R-QML-12's acceptance names the settings case
  with every sub-card shut, and `:1333` (no `ts-peer` row) maps to its
  "shows no `ts-peer` row" clause, not to "folds devices away".
- `tests/tailscale-qml-test.qml:1210` (`exitNodeControlChecks`) checks that a
  query matching nothing draws no `ts-exit-row`. R-QML-19's acceptance names
  it ("shows no `ts-exit-row`").

Line 521 checks that toggling the popover manager with the name `tailscale`
opened the panel. Its message calls it a precondition of what follows, but it
is also R-QML-12's only check that the slot opens the panel by that name, so
it maps to R-QML-12, not to the harness table.

The C++ test functions keep one row each. None has more than 12 assertions,
and each asserts one staged scenario for the requirements listed beside it.
Two single assertions are named here because their clause is easy to miss:
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:341`
(`neverEmitsAPartialLine`, the joined event's bytes are exactly
`{"half":1}`) is R-WATCH-03's "whose bytes are exactly `{"half":1}`", and
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1454`
(`selectsAnExitNodeByIdNotByIp`, no `ExitNodeIPSet` key) is R-WRITE-03's "no
`ExitNodeIPSet` key".

Six checks sit in helpers. Every function that calls a helper runs its check,
so each one is asserted many times, but each line counts once here.

| Helper | Line | Checks | What it asserts | Requirements |
|---|---|---:|---|---|
| `label` | 146 | 1 | Exactly one exit-node label in the slot | — (harness) |
| `iconTint` | 154 | 1 | Exactly one `Icon` in the slot | — (harness) |
| `panelOne` | 398 | 1 | Exactly one panel element per `objectName` asked for | — (harness) |
| `everyTextIsPlain` | 467 | 1 | The element holds at least one `Text` | — (harness: the check's own reach) |
| `everyTextIsPlain` | 469 | 1 | Every `Text` in it has plain-text format | R-SEC-03 |
| `peerRow` | 480 | 1 | A peer row exists for the display name | — (harness) |

Other helpers, such as `slot`, `panelShown`, `seedPeers` and `layout`, are
plumbing with no checks of their own. `everyTextIsPlain` returns its `Text`
count, and `panelChecks` asserts it is at least 3 for a peer row
(`tests/tailscale-qml-test.qml:670`), a harness check of the R-SEC-03 test's
reach. R-SEC-03 states both reach checks (`:467` and `:670`) as "Setup, not
acceptance", so its criterion clauses and this table agree.

`exitNodeControlChecks` asserts that the "use this device as an exit node"
row is dead (`tests/tailscale-qml-test.qml:1183-1188`), all with `writable`
true: visible (1183), title in `Theme.textDisabled` (1184), a non-empty
reason subtitle (1186), and no action on click (1188). Decision 2 gives the
row an action, so on the rewrite it is live, and all four map to R-WRITE-10
(`new`). Its view half is staged as #286 stages these checks (`writable`
true, `exitNodeAwaitingApproval` false, `advertisingExitNode` false) and
states the replacement at each observable:

- 1183: `ts-exit-advertise` is visible, unchanged.
- 1184: the title colour is `Theme.alpha(Theme.text, 0.85)`, the live rows'
  colour, not `Theme.textDisabled`.
- 1186: the subtitle is exactly the empty string; it reads
  `awaiting approval` only while `exitNodeAwaitingApproval` is true.
- 1188: a click records exactly one call, `setAdvertiseExitNode(true)`.

1184, 1186 and 1188 hold on `a38dbca` only because the action is missing, so
R-WRITE-10's view half fails there for that reason. R-QML-29, which
described the dead row, is withdrawn (decision 2).

### `tests/test-tailscale.sh` (6 checks)

| Check | Line | Assertions | Requirements |
|---|---|---:|---|
| The contract scan finds at least 15 properties | 286 | 1 | R-QML-24 |
| The stand-in's properties equal the contract's | 288 | 1 | R-QML-24 |
| The QML runner exits 0 | 367 | 1 | R-QML-26 |
| No `TAILSCALE-TEST-FAIL` line | 372 | 1 | R-QML-26 |
| The run reached `TAILSCALE-TEST-PASS` | 374 | 1 | R-QML-26 |
| No QML diagnostics | 377 | 1 | R-QML-26 |
| Stand-in: Quickshell clipboard, no process | 132-143 | 0 | R-QML-10, R-SEC-04 |
| Stand-in: `C7.Tailscale` | 159-265 | 0 | R-QML-25 |
| Stand-in: Theme, from `tests/fixtures/theme-stub.sh` | 145-147 | 0 | R-QML-27 |
| Stand-in: `qs.Modules.Bar` `BatteryIndicator` (the pill reads only `warn`) | 38-46 | 0 | R-QML-26 |
| Stand-in: `qs.Common` `ProgressRing` (QtQuick.Shapes, not under test) | 53-54 | 0 | R-QML-26 |
| Stand-in: `qs.Common` `GlassPopover` | 70-102 | 0 | R-QML-26 |
| Stand-in: `qs.Common` `Tooltip` | 106-119 | 0 | R-QML-26 |
| Stand-ins: `Quickshell.Networking`, `Quickshell.Bluetooth` and `Quickshell.Services.Pipewire`, all radios absent | 291-330 | 0 | R-QML-26 |
| Stand-ins: the `qs.Services` singletons (`ScreenshareService`, `UpdatesService`, `CaptureService`, `AirplaneService`, `NetworkService`, `BatteryService`, and `PopoverManager`, which records the anchor) | 332-359 | 0 | R-QML-26 |

### `tests/test-bootstrap.sh`, Tailscale checks (12 checks)

| Check | Line | Assertions | Requirements |
|---|---|---:|---|
| No client: the operator is untouched | 394 | 1 | R-BOOT-02 |
| No client: the operator step does not run | 395 | 1 | R-BOOT-02 |
| Daemon down: the operator is untouched | 424 | 1 | R-BOOT-02 |
| `USER=root` never makes root the operator | 434 | 1 | R-BOOT-01 |
| The desktop user is named | 435-436 | 1 | R-BOOT-01 |
| Both the services step and the operator step appear | 444-445 | 1 | R-BOOT-03 |
| The operator step follows the services step | 446-447 | 1 | R-BOOT-03 |
| A real run names the operator | 453-454 | 1 | R-BOOT-01 |
| A second run does not set it again | 456-457 | 1 | R-BOOT-04 |
| A second run reports the operator already in place | 458 | 1 | R-BOOT-04 |
| Another user's operator is not overwritten | 463-464 | 1 | R-BOOT-05 |
| Another user's operator is reported | 465 | 1 | R-BOOT-05 |

### `tests/test-c7-plugin.sh`, #286 changes (3 checks)

| Check | Line | Assertions | Requirements |
|---|---|---:|---|
| ctest runs every Tailscale suite | 160-164 | 1 | R-PKG-01 |
| Every registered test carries the `testing` label | 186-187 | 1 | R-PKG-01 |
| The labelled tests pass 50 consecutive runs | 188-189 | 1 | R-PKG-01 |

## Table C: Phase 2 harness tests (R-HTTP, R-PARSE, R-GROUP)

Each R-HTTP, R-PARSE and R-GROUP requirement, with its evidence class from
`tests/fixtures/tailscale/evidence.json` and the Phase 2 tests that run it
against `a38dbca` through QML: the scenarios in
`tests/fixtures/tailscale/scenarios/` and the parser corpus cases in
`tests/fixtures/tailscale/corpus/`, each named by its `id`. Both run with
`plugin/tests/tailscale-parity/run.sh`. A `cpp-suite` requirement's
evidence is its #286 tests in Table B; a `phase3-only` one has no test on
C++ and gets its Rust tests in Phase 3. The Notes column names the PR whose
tests run the requirement, the tests declared to fail on `cpp-286` (each a
`fix` scenario or case, failing at the value its declaration gives), and
the classes of the clauses evidence.json defers. A `parity` scenario or
case may name a `fix` requirement whose clause #286 already meets.

`cargo test -p fake-tailscaled --test evidence`
(`table_c_lists_the_harness_tests_of_each_http_parse_and_group_requirement`)
checks every row against evidence.json and the test files.

| Requirement | Class | Scenarios | Corpus cases | Notes |
|---|---|---|---|---|
| R-HTTP-01 | `harness-on-cpp` | `http-01-request-line-and-host` | — | PR #306; deferred clauses: cpp-suite |
| R-HTTP-02 | `harness-on-cpp` | `http-02-patch-bytes` | — | PR #307; deferred clauses: cpp-suite |
| R-HTTP-03 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-04 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-05 | `phase3-only` | — | — | Rust tests in Phase 3 |
| R-HTTP-06 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-07 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-08 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-09 | `harness-on-cpp` | `http-09-403-empty-body`, `http-09-chunked-403-in-write-error`, `http-09-error-body-in-write-error`, `http-09-status-500-error-member`, `http-09-status-500-invalid-utf8`, `http-09-status-500-whole-body` | — | PR #306; fail on cpp-286: `http-09-chunked-403-in-write-error`, `http-09-error-body-in-write-error`, `http-09-status-500-error-member`, `http-09-status-500-invalid-utf8`, `http-09-status-500-whole-body`; deferred clauses: harness-on-cpp (#307), phase3-only |
| R-HTTP-10 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-11 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-12 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-13 | `cpp-suite` | — | — | #286 tests in Table B |
| R-HTTP-14 | `phase3-only` | — | — | Rust tests in Phase 3 |
| R-HTTP-15 | `phase3-only` | — | — | Rust tests in Phase 3 |
| R-PARSE-01 | `phase3-only` | — | — | Rust tests in Phase 3 |
| R-PARSE-02 | `harness-on-cpp` | — | `parse-02-health-non-strings`, `parse-02-health-null`, `status-idle` | PR #307; deferred clauses: cpp-suite |
| R-PARSE-03 | `harness-on-cpp` | — | `parse-03-ipv6-listed-first`, `parse-03-peer-addresses`, `parse-03-self-ipv4-only`, `status-idle` | PR #307 |
| R-PARSE-04 | `harness-on-cpp` | — | `parse-04-absent`, `parse-04-date-only`, `parse-04-fraction-dropped-not-rounded`, `parse-04-nanoseconds`, `parse-04-no-zone`, `parse-04-not-a-date`, `parse-04-offset`, `parse-04-one-fraction-digit`, `status-idle` | PR #307; fail on cpp-286: `parse-04-date-only`, `parse-04-fraction-dropped-not-rounded`, `parse-04-no-zone` |
| R-PARSE-05 | `harness-on-cpp` | — | `parse-05-self-hostname-only`, `status-idle` | PR #307; deferred clauses: cpp-suite |
| R-PARSE-06 | `harness-on-cpp` | — | `parse-06-peer-without-id`, `status-idle` | PR #307 |
| R-PARSE-07 | `harness-on-cpp` | — | `parse-07-entry-not-an-object`, `parse-07-entry-not-an-object-beside-a-peer`, `parse-07-needslogin-peer-null`, `parse-07-no-peer-key`, `parse-07-nostate-peer-null`, `parse-07-peer-array`, `parse-07-peer-number`, `parse-07-peer-string`, `parse-07-running-peer-empty`, `parse-07-running-peer-null`, `parse-07-stopped-peer-empty`, `parse-07-stopped-peer-null`, `status-idle` | PR #307; fail on cpp-286: `parse-07-entry-not-an-object`, `parse-07-entry-not-an-object-beside-a-peer`; deferred clauses: phase3-only |
| R-PARSE-08 | `harness-on-cpp` | — | `parse-08-exit-node-status-null`, `status-exitnode`, `status-exitnode-offline`, `status-idle` | PR #307 |
| R-PARSE-09 | `harness-on-cpp` | — | `parse-09-empty-id-never-joined`, `parse-09-empty-string-id-never-joined`, `parse-09-exit-peer-gone`, `parse-09-named-through-another-peer`, `parse-09-status-without-id`, `status-exitnode`, `status-exitnode-offline` | PR #307; fail on cpp-286: `parse-09-empty-id-never-joined`, `parse-09-empty-string-id-never-joined` |
| R-PARSE-10 | `none` | — | — | withdrawn |
| R-PARSE-11 | `harness-on-cpp` | `parse-11-suggestion-500-clears`, `parse-11-suggestion-array-clears`, `parse-11-suggestion-id-not-a-string-clears`, `parse-11-suggestion-not-json-clears` | `parse-11-suggestion-id` | PR #307; deferred clauses: phase3-only |
| R-PARSE-12 | `harness-on-cpp` | — | `parse-12-other-health-kept`, `status-idle` | PR #307 |
| R-PARSE-13 | `cpp-suite` | — | — | #286 tests in Table B |
| R-PARSE-14 | `harness-on-cpp` | — | `parse-14-array-wrong-type`, `parse-14-bool-from-number-and-string`, `parse-14-exit-node-status-fields`, `parse-14-integer-null-self`, `parse-14-integer-wrong-type`, `parse-14-null-string-and-object`, `parse-14-object-wrong-type`, `parse-14-user-entry-not-an-object`, `parse-14-wrong-string-and-bool` | PR #307; deferred clauses: phase3-only |
| R-GROUP-01 | `harness-on-cpp` | — | `group-01-tagged-test-comes-first`, `group-03-hand-built-order`, `status-idle` | PR #307 |
| R-GROUP-02 | `harness-on-cpp` | — | `group-01-tagged-test-comes-first`, `status-idle` | PR #307 |
| R-GROUP-03 | `harness-on-cpp` | — | `group-03-accented-names`, `group-03-full-lowercase`, `group-03-full-not-simple-lowercase`, `group-03-hand-built-order`, `group-03-outside-the-bmp`, `group-03-same-name-by-node-id`, `status-idle` | PR #307; fail on cpp-286: `group-03-full-lowercase`, `group-03-outside-the-bmp` |
| R-GROUP-04 | `harness-on-cpp` | — | `status-idle` | PR #307; deferred clauses: cpp-suite |
| R-GROUP-05 | `harness-on-cpp` | `group-05-flat-list` | — | PR #307 |
| R-GROUP-06 | `harness-on-cpp` | `group-06-join-and-leave`, `group-06-offline-row-moves`, `group-06-unmoved-row-updates` | — | PR #307; deferred clauses: harness-on-cpp (#309) |
| R-GROUP-07 | `harness-on-cpp` | `group-06-offline-row-moves`, `group-07-only-changed-rows-announce` | — | PR #307 |
| R-GROUP-08 | `harness-on-cpp` | `group-08-duplicate-empty-ids` | — | PR #307; deferred clauses: cpp-suite |
| R-GROUP-09 | `harness-on-cpp` | `group-09-a-separate-model` | `status-exitnode`, `status-idle` | PR #307 |
| R-GROUP-10 | `harness-on-cpp` | `group-10-empty-peer-object-clears` | — | PR #307; deferred clauses: phase3-only |
| R-GROUP-11 | `phase3-only` | — | — | Rust tests in Phase 3 |
| R-GROUP-12 | `harness-on-cpp` | `group-12-needs-login-keeps-rows` | — | PR #307; deferred clauses: phase3-only |

## Harness preconditions

Each assertion below checks only the test's own staging: a temporary
directory, a fake that bound its socket or holds a request, a client that
connected, a fixture that holds what the test reads from it, a lookup that
found its element, or a negative control proving the real check can fail. It
is not product behaviour and maps to no requirement. "Setup for" names the
requirement whose test it stages; the Rust port keeps an equivalent setup
step, written as a precondition, not as an acceptance clause. These 62
assertions are inside the counts of Table B: 9 + 1 + 3 + 21 + 5 + 3 from the
C++ suites and 20 from the QML suite. Line 48 of the pre-#286 fake suite is
listed too, outside the counts.

### C++ suites

| File:line | Function | What it checks | Setup for |
|---|---|---|---|
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:24` | `init` | The per-test temporary directory is valid | Every R-HTTP and R-WATCH client test (R-SEC-02 isolation) |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:239` | `emitsOneEventPerCompleteLine` | The fake recorded the watch before the first push | R-WATCH-03 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:335` | `neverEmitsAPartialLine` | The fake recorded the watch before the first push | R-WATCH-03 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:355` | `joinsAWatchLineSplitAcrossChunks` | The fake recorded the watch before the first push | R-HTTP-04 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:376` | `waitsForAChunkSizeLineSplitAcrossReads` | The fake recorded the watch before the first push | R-HTTP-04 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:395` | `endsTheWatchOnTheLastChunk` | The fake recorded the watch before the zero chunk | R-WATCH-04 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:412` | `endsTheWatchWhenTailscaledGoes` | A client is connected to the fake (count 1) | R-WATCH-04 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:461` | `aGetWithNoAnswerAtAllEndsInFailedAtItsDeadline` | The fake recorded the GET, so the socket is connected and silent | R-HTTP-13 |
| `plugin/lib/tailscale/tests/tst_localapiclient.cpp:600` | `saysNothingWhenTheWatchIsStopped` | A client is connected to the fake (count 1) | R-WATCH-06 |
| `plugin/lib/tailscale/tests/tst_statusparser.cpp:258` | `namesTheExitNodeByItsDnsLabelNotItsHostName` | The hand-edited fixture really points `ExitNodeStatus` at `ip-172-31-0-10` | R-PARSE-09 |
| `plugin/lib/tailscale/tests/tst_peermodel.cpp:170` | `pinsAKnownPeersFields` | The fixture parsed | R-PARSE-06, R-GROUP-04 |
| `plugin/lib/tailscale/tests/tst_peermodel.cpp:173` | `pinsAKnownPeersFields` | The `gamma` row was found | R-PARSE-06, R-GROUP-04 |
| `plugin/lib/tailscale/tests/tst_peermodel.cpp:239` | `dropsRowsLeftOverWhenPeersShareANodeId` | The setup leaves 2 rows before the update under test | R-GROUP-08 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:290` | `init` | The per-test temporary directory is valid | Every backend test (R-SEC-02 isolation) |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:344` | `failsClosedWhenPrefsSelectsAnExitNodeTheStatusHasNotResolved` | The fixture node id is non-empty | R-WATCH-14 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:505` | `dropsAHalfFinishedPassWhenTheConnectionIsLost` | The three fixture ids are non-empty | R-WATCH-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:506` | `dropsAHalfFinishedPassWhenTheConnectionIsLost` | The three fixture ids are distinct | R-WATCH-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:746` | `doesNotCountTheSuppressedRouteWarning` | The fixture parsed | R-PARSE-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:747` | `doesNotCountTheSuppressedRouteWarning` | The fixture has exactly one health entry | R-PARSE-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:757` | `countsEveryOtherHealthWarning` | The fixture parsed | R-PARSE-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:874` | `publishesOnlyExitNodeCapablePeersAsExitNodes` | The fixture node id is non-empty | R-GROUP-09, R-PARSE-11 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:908` | `returnsToNoStateAndReconnectsWhenTailscaledRestarts` | The fake bound its socket | R-CONN-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:919` | `returnsToNoStateAndReconnectsWhenTailscaledRestarts` | The second fake bound the same path | R-CONN-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1120` | `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem` | The fake holds one request | R-WATCH-10 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1140` | `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem` | Completing the hold reached one client | R-WATCH-10 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1332` | `keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` | The fake bound its socket | R-WRITE-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1346` | `keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` | The fake holds the PATCH | R-WRITE-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1364` | `aTransientFailureAfterARefusalDoesNotReviveTheControls` | The fake bound its socket | R-WRITE-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1375` | `aTransientFailureAfterARefusalDoesNotReviveTheControls` | The fake holds the PATCH | R-WRITE-06 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1392` | `letsTheBusOverruleAnOptimisticWrite` | The chosen fixture id is non-empty | R-WRITE-04 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1393` | `letsTheBusOverruleAnOptimisticWrite` | The imposed fixture id is non-empty | R-WRITE-04 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1394` | `letsTheBusOverruleAnOptimisticWrite` | The two fixture ids differ | R-WRITE-04 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1438` | `selectsAnExitNodeByIdNotByIp` | The fixture node id is non-empty | R-WRITE-03 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1439` | `selectsAnExitNodeByIdNotByIp` | The fixture IPv4 is non-empty | R-WRITE-03 |
| `plugin/tests/tst_module.cpp:77` | `initTestCase` | The module directory holds `C7/qmldir` | R-UI-01, R-UI-02, R-UI-05, R-UI-13 |
| `plugin/tests/tst_module.cpp:102` | `tailscaleSingletonLoadsAndStaysInNoState` | `TS_SOCKET` lies under the isolation root before the singleton is built | R-UI-05 (R-SEC-02 isolation) |
| `plugin/tests/tst_module.cpp:108` | `tailscaleSingletonLoadsAndStaysInNoState` | The singleton resolved | R-UI-05 |
| `plugin/tests/tst_module.cpp:127` | `tailscaleSingletonExposesExactlyTheContract` | The singleton resolved | R-UI-02 |
| `plugin/tests/tst_module.cpp:164` | `tailscaleSingletonExposesExactlyItsActions` | The singleton resolved | R-UI-13 |
| `plugin/lib/testing/tests/tst_fakesocketserver.cpp:129` | `readsTheBodyARequestDeclaresBeforeFramingIt` | A client connected to the fake | R-FAKE-01 |
| `plugin/lib/testing/tests/tst_fakesocketserver.cpp:192` | `pushesExactlyTheBytesOfAChunk` | A client connected to the fake | R-FAKE-02 |
| `plugin/lib/testing/tests/tst_fakesocketserver.cpp:193` | `pushesExactlyTheBytesOfAChunk` | The fake counts that one client | R-FAKE-02 |
| `plugin/lib/testing/tests/tst_fakesocketserver.cpp:48` (pre-#286, not counted) | `init` | The per-test temporary directory is valid | Every fake test (R-FAKE-06) |

### QML suite (`tests/tailscale-qml-test.qml`)

| Line | Function | What it checks | Setup for |
|---|---|---|---|
| 146 | `label` | Exactly one exit-node label in the slot, so the lookup is unambiguous | R-QML-01, R-QML-03, R-QML-04, R-UI-15 |
| 154 | `iconTint` | Exactly one `Icon` in the slot | R-QML-02, R-QML-03, R-UI-15 |
| 180 | `run` | The bar has a slot named `tailscale` | Every bar-slot check |
| 398 | `panelOne` | Exactly one panel element per addressed `objectName` | Every panel check |
| 467 | `everyTextIsPlain` | The element holds at least one `Text`, so the plain-text check cannot pass empty | R-SEC-03 |
| 480 | `peerRow` | A peer row exists for the display name | R-QML-09, R-QML-10, R-QML-12 |
| 670 | `panelChecks` | A peer row holds three or more `Text`s, so the plain-text check reaches `ListRow`'s own | R-SEC-03 |
| 672 | `panelChecks` | The owner line is where the plain-text check looks for it | R-SEC-03 |
| 896 | `foldOutChecks` | `tango` took the local "copied" state the reopen check is about | R-QML-12 |
| 1105 | `exitNodeControlChecks` | The twin row sharing a hostname exists | R-QML-17 |
| 1375 | `settingsChecks` | The issue list the test set to `[]` is empty | R-QML-21 |
| 1683 | `delegateIdentityChecks` | The view has the 3 seeded rows | R-GROUP-06 |
| 1684 | `delegateIdentityChecks` | The ListView built delegates | R-GROUP-06 |
| 1688 | `delegateIdentityChecks` | A delegate for `bravo` exists | R-GROUP-06 |
| 1695 | `delegateIdentityChecks` | The delegate took the local state | R-GROUP-06 |
| 1713 | `delegateIdentityChecks` | The test's update left 3 rows | R-GROUP-06 |
| 1725 | `delegateIdentityChecks` | The test's `move` landed (negative control) | R-GROUP-06 |
| 1741 | `delegateIdentityChecks` | The test's `insert` landed | R-GROUP-06 |
| 1748 | `delegateIdentityChecks` | The test's `remove` landed | R-GROUP-06 |
| 1760 | `delegateIdentityChecks` | The reset control still has a `bravo` row | R-GROUP-06 |

Lines 540 and 541 of `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp`
(`dropsAHalfFinishedPassWhenTheConnectionIsLost`: the held count reads 1
after the loss, and completing the hold reaches one client) are not in this
table either. R-WATCH-12's acceptance states both as criterion clauses (the
held count reads exactly 1 because the loss leaves the abandoned `/prefs`
connected; the completion reaches exactly 1 client), so they map to
R-WATCH-12 in Table B, not to this table.

Lines 1723 and 1764 of `delegateIdentityChecks` are not in this table. Each
is a clause of R-GROUP-06's acceptance (a role update reaches the delegate of
the row it changed; a rebuilt model yields a new delegate without the local
state), and 1764 is also R-QML-25's rebuild clause. Their messages call them
controls, but what they check is behaviour the requirements state, so they map
to those requirements.

The backend suite's `QTRY_COMPARE(b.state(), Running)` waits at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:359`,
`:743`, `:870`, `:890`, `:1161`, `:1188`, `:1255`, `:1401` and `:1446` are not
in this table either. Reaching `Running` is product behaviour, and each mapped
acceptance (R-WATCH-14, R-PARSE-12, R-GROUP-09, R-UI-06, R-WATCH-09,
R-WRITE-02, R-WRITE-03 and, for `:1401` in
`letsTheBusOverruleAnOptimisticWrite`, R-WRITE-04) now names it. Line 994 of the same suite (the
client count reaches 0) is R-CONN-08's client barrier at 0.

`tests/tailscale-qml-test.qml:535` (no visible `ts-peer` in `NoState`) stays
mapped to R-QML-05, but #286 checks it with the device list folded:
`pop.expanded` is `""` after `PopoverManager.toggle`, so no `ts-peer` row is
shown in any state and the check cannot fail. R-QML-05's acceptance now opens
`ts-devices-row`, the exit sub-card and the settings sub-card, and seeds a
health entry, before entering `NoState`. The rewrite's test therefore fails if
`root.live &&` is dropped from any of the bindings at
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:429`, `:597`,
`:774` or `:813`. The "visible in `Running` first" checks of those cases are
the test's own setup.

### Withdrawn requirements

R-FAKE-04 and R-QML-28 were made of harness preconditions and are withdrawn
(see the requirements file). R-PARSE-10 is withdrawn and replaced by
R-PARSE-13: no owner decision removes the mask stripping, so R-PARSE-13
states it against the parsed status and the parsing library's public
interface. The three #286 assertions
(`plugin/lib/tailscale/tests/tst_statusparser.cpp:273`, `:274` and `:276`,
in `stripsTheMaskFromExitNodeAddresses`) map to R-PARSE-13 and are
ported. R-QML-29 is withdrawn by decision 2: the row it
described has an action on the rewrite, and its #286 checks map to
R-WRITE-10 (see the note under the QML table). R-FAKE-05 keeps only the fake's own behaviour,
tested before #286 by `refusesAPathAlreadyTaken`; the backend tests'
`isListening()` checks are above. R-UI-01 and R-SEC-02 keep their behaviour
clauses; the "`C7/qmldir` exists" and "temporary directory is valid" checks
are above.

## Requirements with no #286 test

These requirements trace to code or to the PR text only. Phase 2 writes their
first test. R-FAKE-04, R-PARSE-10, R-QML-28 and R-QML-29 are withdrawn and need none. R-QML-16 is
`follow-up` (decision 9): it is moved out of epic #287 to issue #298, Phase 2 writes no
test for it, and no gate of the rewrite (coverage, mutation, the 50-run
loop) checks it. #286 has no assertion that maps to it.

- **Implemented but untested (parity):** R-HTTP-05, R-UI-03, R-UI-01 (#286
  checks only that the singleton resolves, as a harness precondition; the
  contract-type, same-object and two-engine checks have no #286 test),
  R-UI-10, R-WATCH-11, R-WRITE-05, R-BOOT-06,
  R-SEC-01, R-SEC-05, R-PKG-02, R-PARSE-14. R-UI-08 lacks its checks that the
  singleton's metaobject has exactly one `exitNodeBlocked` and that the
  shipped backend derives it for every reachable input combination (three of
  the four; false/true cannot come from a fake tailscaled). R-QML-26 lacks its
  failing-stand-in case, its no-`qml6` skip case and its stub-runner case, and
  a check that `PKGBUILD` declares `qt6-declarative`. R-SEC-02 lacks a check that two tests' directories
  differ. R-CONN-01 lacks its check of the resolved default socket path. R-HTTP-07 lacks its short-body-at-close case. R-HTTP-08 and
  R-HTTP-10 lack direct checks of the numeric status and the socket-absent flag.
  R-HTTP-04 lacks chunk extensions, trailers and mixed-case headers. R-WATCH-06
  lacks re-entrant stop and stop before connect. R-BOOT-03 lacks the bounded
  wait. R-HTTP-11 lacks its client-level checks (one outcome per exchange,
  delivered after the call returns); #286 pins only the backend-level
  consequence that the watch is the one client left connected. R-QML-23 lacks
  its check that clicking `ts-self-ip4` copies the IPv4, and its scan for
  readers of `tailnet`, `hostName` and `exitNodeOption`. R-QML-06 lacks its
  "1 month", days, "1 day", "under a day" and "session expired" cases, and
  the half-day offsets that make its criterion independent of the wall
  clock's value (#286 offsets a whole number of days from `Date.now()`; the
  view is unchanged and gets no clock seam). R-QML-25 lacks its
  row-signal checks on the stand-in's models. R-CONN-06 lacks its second run
  (a socket-absent connect clears a non-empty `readError`). R-GROUP-08 lacks
  its seeded property test. R-UI-14 lacks its check that the installed module
  carries no fake type. R-SEC-01 lacks its held-request scenario. R-QML-01 lacks the second and third armed
  reconnects (at paused time 500 ms and 1500 ms); #286 checks the first.
  R-CONN-06 lacks its check that a reconnect attempt finding nothing at the
  path clears `recommendedExitNodeId` and moves nothing else. R-CONN-03's
  stagings other than the 403 do not fail the watch in #286, and #286 keeps
  the watch open after a read loss; under decision 24 the backend stops the
  watch itself, so the rewrite's test reaches the client barrier at 0
  without failing the watch, and asserts `readErrorChanged` exactly once.
  R-WATCH-06's stop-before-connect check uses a second client's
  reply as its ordering point. R-FAKE-05's refusal of a taken path is
  tested by `plugin/lib/testing/tests/tst_fakesocketserver.cpp::refusesAPathAlreadyTaken` (lines
  236-269), which predates #286; #286's own `isListening()` checks are harness
  preconditions. R-FAKE-02's hold and complete have no
  self-test in `plugin/lib/testing/tests/tst_fakesocketserver.cpp`; only the backend tests that map to
  it exercise them. R-FAKE-01 lacks the fake barrier (bytes consumed per
  client); #286 proves its negative with `qWait(50)`. The read barrier
  (bytes the client consumed of what the fake pushed) is new: R-HTTP-04,
  R-WATCH-03, R-WATCH-06 and R-WATCH-10 use it, and #286 has no equivalent.
  R-WATCH-07 lacks its client-side check that the watch is issued first in
  every attempt; #286 counts the four requests but never their order.
  R-HTTP-08 lacks the PATCH's numeric status 403 (#286 checks the no-reply
  and the reason text). R-SEC-05's scan, including its `192.168.1.129`
  exception, has no #286 test. R-WATCH-13 lacks `Weird` mapping to `NoState`, and its checks that an
  unknown `BackendState` sets the named `readError` (decision 23), arms no
  reconnect, keeps the watch open and shows the slot dimmed. R-CONN-06's
  third run (a read loss stops the watch, so a notification pushed before
  the reconnect reaches no client) is decision 24's corrected value of
  `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:551`. R-CONN-05
  lacks its held-`/status` check that a `/prefs` reply alone fires no
  `readErrorChanged`. R-WRITE-06's #286 deadline clause (a deadline
  `writeError` persisting after a snapshot shows the value applied) is gone:
  decision 5 reconciles it, and R-WRITE-08's "reconciled after a deadline"
  run asserts the corrected value (a 403's message is not reconciled while
  `writable` is false); #286 has no test of either.
  R-PARSE-01 lacks the `[]` and `{}` cases. R-PARSE-02 lacks a null `Health`
  and its non-string entries. R-PARSE-09 lacks an `ExitNodeStatus` with no
  `ID`. R-HTTP-04 lacks headers split across reads. R-HTTP-06 lacks a
  negative or non-numeric `Content-Length`. R-HTTP-08 lacks a head that is
  not a valid status line, and R-CONN-03 lacks that staging at backend
  level. R-HTTP-13 lacks the PATCH deadline. R-WRITE-06 lacks its
  socket-absent and deadline write clauses (#286's writer ignores the
  socket-absent flag at
  `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:138-143`, but
  no test proves a write to an absent socket is reported).
  R-PARSE-03 lacks its order and IPv4-only cases. R-PARSE-06 lacks a peer
  without an `ID`. R-PARSE-08 lacks a null or absent `ExitNodeStatus`.
  R-GROUP-07 lacks its `ownerName` change. R-BOOT-05 lacks its closing-note
  clause: `tests/test-bootstrap.sh:460-465` checks that no `tailscale set` is
  logged and that the warning names `other-user`, but never that the notes
  contain `sudo tailscale set --operator=tester`
  (`bin/c7shell-bootstrap:600`). R-UI-06 lacks
  its replay clause and its count of the other signals.
- **Added after review, untested in #286:** R-CONN-14 (a non-object
  `/prefs`, now a named read error, decision 16), R-CONN-15 (a clean watch
  end before a snapshot, now diagnosed, decision 19), R-PARSE-11's
  arrival-order case (now the newest pass wins, decision 17), R-WRITE-06's two-write case, R-BOOT-03's exhausted wait,
  R-SEC-01's `PATH` stubs and source scan, R-QML-27's scan of the real theme,
  R-UI-08's metaobject check on the shipped backend, R-WATCH-09's
  `{"State":null}` and `ErrMessage` lines, and R-HTTP-09's incomplete-body
  cases. R-WATCH-07's one-hour count, R-CONN-03's count and R-WRITE-04's
  never-the-requested-id spy are restated against barriers, so their #286
  tests no longer match them one for one.
- **Added in the third review round, parity, untested in #286:** R-CONN-16
  (a watch that fails after it started sets `readError`), R-GROUP-12 (rows
  from an earlier session survive a non-Running status without a Peer
  section), R-WATCH-04's framing and close-before-headers failures on a
  watch, R-HTTP-05's path in both reasons, R-PARSE-07's non-object `Peer`
  and non-object Peer entry, R-CONN-11's timeout and empty-body stagings,
  R-UI-15's slot-border checks in all six states and R-QML-22's three
  no-note tooltip strings. R-WRITE-06 and R-WRITE-07 now name the applied
  value in every run that expects an empty `writeError` after a 2xx, so they
  hold under R-WRITE-08's decided design (decision 5): each 2xx starts a
  whole confirmation pass, a read-back that differs sets `writeError` to
  `<setting> was not applied`, and a snapshot that shows the value applied
  clears a stale `writeError`. In those runs the confirmation finds the
  value applied and sets nothing. #286's staging of the 403-then-200 run
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1306-1313`) leaves `/prefs` at
  `plugin/lib/tailscale/tests/fixtures/prefs.json` (`RouteAll` false), and
  R-WRITE-06's recovery clause now keeps that staging: lines 1311-1312
  (`writable` true, `writableChanged` twice) map to R-WRITE-06 in the state
  #286 asserts them. Line 1313 (`writeError` empty after the recovering 200)
  holds on `a38dbca` only because #286 never confirms an accepted write, so
  it maps to R-WRITE-08's "403 then 200, not applied" run, which repeats
  #286's staging and names the corrected value, `accept routes was not
  applied`, at that observable.
- **Added in the fourth review round, untested in #286:** the idle barrier
  now includes the read barrier on every connection and stays unsettled
  until a pass's suggestion and forwarding-check outcomes are applied or
  dropped ("How to read"). R-WATCH-12 ignores only the snapshot halves of
  an abandoned pass; its suggestion and check outcomes follow R-PARSE-11
  and R-WRITE-10. R-WATCH-07 and R-CONN-13 advance paused time in explicit
  30 000 ms steps, and R-CONN-13(a) reads `Running` at P + 69 999 ms after
  named barriers. R-CONN-11's clearing runs from a published
  `nEwJFIats021CNTRL` (404, 500, timeout, empty body). R-WRITE-08's
  "confirmation fails" run continues to the reconnect's judgement, and its
  new "2xx between a loss and its reconnect" run pins that such a 2xx
  starts no pass and is judged on the reconnect's opening snapshot
  (decisions 5 and 24). R-WRITE-08 no longer reconciles a 403's message, or
  any message while `writable` is false, so `writable` false with
  `writeError` empty is never published; its "reconciled after a deadline"
  403 variant now asserts the message kept. R-WRITE-10's failed or
  malformed forwarding check sets a named `could not check ip forwarding:
  ...` value (a socket-absent failure still sets it empty). R-UI-17 adds
  `loginUrl`'s clearing on every non-`NeedsLogin` snapshot, on a loss and on
  `login()`'s POST, the opener that opens only a URL arriving after the
  click, `ts-login` dead while `writable` is false, and `ts-login-error`.
  R-QML-15 pins `PeerFilter`'s trim to ECMAScript's set and records the
  case-folding difference beyond ASCII (decision 10). R-HTTP-09 pins the
  reason of a 403 whose body stalls past the deadline. R-BOOT-07 adds the
  failed conf-file write. None of these maps a #286 assertion; the
  mappings in Table B are unchanged.
- **Added in the fifth review round, untested in #286:** R-PARSE-07 reads
  `"Peer":null` under `Running` as an empty Peer section (tailscaled's
  `ipnstate.Status.Peer` is a lazily made map with no `omitempty`) and
  `null` in any other state as none; R-GROUP-10 (now `fix`) and R-GROUP-12
  clear the rows on that `null`, and R-GROUP-11's backend half stages it as
  the known-empty case. Only R-PARSE-07's change maps a #286 assertion
  (`plugin/lib/tailscale/tests/tst_statusparser.cpp:150`, Table B). R-WRITE-08's "pass already in
  flight" run and R-WRITE-10's "advertising stops" runs now stage two
  passes that disagree, with a held request fixing the arrival order.
  R-WATCH-13 pins tailscaled's own `"NoState"` as a known value (empty
  `readError`, no retry). R-PARSE-11 adds malformed 2xx suggestion bodies
  (`x`, `[]`, `{"ID":5}`), each clearing the id. R-UI-17 adds the release of
  `login()`'s single-flight guard after every outcome, the
  `ts-login-url-error` line when the browser cannot be opened (its opener
  stand-in, R-QML-25, returns a configurable bool), and records the
  `ErrMessage` gap left to follow-up #299 (decision 18). None of these but
  R-PARSE-07's maps a #286 assertion.
- **Added in the sixth review round, untested in #286:** R-WRITE-10 sends
  a follow-up `check-ip-forwarding` when a snapshot publishes
  `advertisingExitNode` true from a pass that sent no check (the first
  attempt on a machine already advertising, or advertising turned on
  outside the panel), drops a check outcome once a newer snapshot has
  published `advertisingExitNode` false, refuses to rebuild
  `AdvertiseRoutes` while `state` is `NoState` or the published value is
  malformed, and reads `exitNodeAwaitingApproval` false when `Self.AllowedIPs`
  is absent; the idle barrier now also waits for an unsent follow-up check.
  No staging elsewhere advertises an exit node, so no other request count
  changes. R-WRITE-08 drops a pending judgement when a later write of the
  same setting gets a 2xx, with a new "later write of the same setting"
  run, and its "pass already in flight" run is restaged so the fake holds
  only one request at a time. R-FAKE-02 states that holds accumulate and a
  completion reaches every request held at that moment. R-FAKE-07 (`kit`)
  specifies the fake's byte, client-count and accepted-total reports that
  the barriers read. R-QML-24's loader reads the registered metaobject
  without creating the singleton and runs with a private `TS_SOCKET`.
  R-WATCH-15 caps a chunk-size line at 1 024 bytes. R-CONN-13 closes an
  in-flight probe silently at a loss. R-WATCH-14 takes its fallback on
  whether `ExitNodeStatus` is an object. R-GROUP-11 and R-GROUP-12 place
  `ts-devices-count` on the root row and hide it outside `Running`.
  R-QML-15 states that `PeerFilter` counts synchronously. R-BOOT-07 checks
  the live forwarding values when its file is already in place, and
  R-BOOT-08 skips empty `debug prefs` output silently. R-HTTP-10, R-HTTP-11,
  R-HTTP-13 and R-WATCH-01 name their barriers. R-UI-17 states what the
  opener actually guarantees. None of these maps a #286 assertion; the
  mappings in Table B are unchanged.
- **Added in the seventh review round, untested in #286:** "How to read"
  defines paused time as a clock that moves only when the test advances it
  (tokio's auto-advance does not qualify), and every barrier a criterion
  places at a named instant also asserts the clock reads that instant.
  R-PARSE-14 (new ID, parity) pins #286's lenient reading of a known
  `/status` field that is `null` or of another type (`CurrentTailnet`,
  `User`, `TailscaleIPs`, `KeyExpiry`, a peer's `Online` and
  `ExitNodeOption`, `ExitNodeStatus.ID`), with a backend half reaching
  `NeedsLogin`; #286 behaves this way (`plugin/lib/tailscale/StatusParser.cpp:106-175`) but no
  #286 test stages a null field. R-WATCH-05 turns the watch deadline off
  only at an accepted (2xx) head, and R-HTTP-09 adds the watch answered 403 whose
  error body stalls (with and without framing) and its backend half;
  R-WATCH-04 and R-CONN-15 define a clean end after an accepted head. On
  `a38dbca` a non-2xx watch fails at its head, so those R-HTTP-09
  clauses fail there at the 49 ms check. R-HTTP-13 adds a disabled
  deadline (0 and -1) and the shipped 10 000 ms deadline. R-CONN-10 adds
  two shipped-settle runs (a loss at P + 29 999 ms arms 1 000 ms, at
  P + 30 000 ms arms 500 ms), and R-CONN-01 names the criterion that pins
  each shipped timing. R-GROUP-11 draws `ts-peer` rows from the model
  whatever `peersKnown` reads and shows `ts-peer-unknown` only for an
  empty model, so the parity view criteria that seed peers on a fresh
  stand-in (R-QML-09, -10, -12, -14, R-GROUP-06, R-SEC-03) hold unchanged.
  R-WRITE-08 states that a judgement made while `writable` is false sets
  nothing and is spent, with a new "judgement after a 403" run. R-WRITE-04
  and R-UI-06 list the refused `setAdvertiseExitNode` as the one path that
  sets `writeError` with no request. R-UI-13 and (since the eighth round,
  split from R-UI-05 and R-UI-14) R-UI-18 and R-UI-19 extend the test-only
  fake to the five added properties and the two added invokables. R-UI-17 accepts only an `https://` `BrowseToURL`. R-WRITE-10
  records the staleness of `ipForwardingWarning` between passes as an
  accepted gap. R-BOOT-07 writes under the `C7SHELL_ROOT` prefix, names the
  logged `sysctl -p` argument under a test root, and runs between the
  operator step and `== enabling user services`. The 1 024-byte
  chunk-size-line cap (R-WATCH-15) and the names `exitNodeAwaitingApproval`
  and `ipForwardingWarning` are labelled as the spec's choices made to
  implement decisions 21 and 2, not values the owner set. None of these
  maps a #286 assertion; the mappings in Table B are unchanged.
- **Added in the eighth review round, untested in #286:** "How to read"
  defines the test clock as one that advances only by an explicit test
  advance, never on its own while the runtime is idle, records that tokio's
  paused clock auto-advances and that Phase 3 must provide a clock that does
  not (a Phase 3 constraint, not a design choice of this spec), and states
  that every "advance exactly N ms, then nothing yet" clause reads only the
  outcomes due by t + N. "Accepted head" (a complete 2xx head) and "refused
  head" (any other status) are defined terms; R-HTTP-09, R-HTTP-13,
  R-WATCH-02, R-WATCH-04, R-WATCH-05 and R-CONN-15 use them, and R-WATCH-05
  states that a non-2xx watch keeps its deadline while its error body is
  read, so one whose body never finishes fails by the deadline (R-HTTP-09
  tests it; on `a38dbca` it fails at its head). R-PARSE-14 adds one parser
  case per field type (string, bool, integer, object, array), a second
  backend-half run, and states it is parity with no field failing closed
  under decisions 16 or 23. R-CONN-05, R-UI-09 and R-WATCH-08 give exact
  counts at named barriers. R-QML-06 asserts its 12-hour clock margin with a
  second `Date.now()` read. R-UI-05, R-UI-14 and R-QML-25 keep #286's
  members, and the decided members move to R-UI-18, R-UI-19 and R-QML-30;
  R-CONN-02 hands `loginUrl` and `ipForwardingWarning` to R-UI-17 and
  R-WRITE-10. Every decision's requirement list and the requirements' own
  decision citations now match both ways. Every citation gives its path
  from the repository root; a capture named by file name alone is test
  data in `plugin/lib/tailscale/tests/fixtures/`, not a citation. None of these maps a #286 assertion; the mappings in
  Table B are unchanged.
- **Fix, named by #286:** R-HTTP-09, R-GROUP-11, R-CONN-13, R-WRITE-08,
  R-WRITE-09, R-UI-16, R-QML-15, R-FAKE-03. R-QML-16 is no longer among
  them: it is `follow-up` (decision 9).
- **Fix, by owner decision (2026-10-21):** R-HTTP-15 and R-WATCH-15
  (decision 21), R-PARSE-04 (11), R-PARSE-07 (27, and 6 and 25:
  `"Peer":null` under `Running` is an empty Peer section, the shape
  tailscaled sends for a tailnet with no other devices), R-GROUP-10 (25,
  retagged from parity: that `null` clears the rows), R-PARSE-09 (22),
  R-PARSE-11 (17), R-GROUP-03 (10), R-GROUP-12 (25), R-WATCH-13 (23),
  R-CONN-03, R-CONN-06 and R-CONN-08 (24), R-CONN-04 (14 and 24),
  R-PARSE-01 (14), R-CONN-14
  (16), R-CONN-15
  (19), R-WRITE-11 (20), R-WRITE-07 (20), R-WRITE-04 (5), R-WATCH-07 (4
  and 5), R-BOOT-03 (15), R-BOOT-08 (26), R-UI-02
  (decisions 1, 2 and 6), R-UI-13 (decisions 1 and 2), and R-UI-18, R-UI-19
  and R-QML-30 (decisions 1, 2 and 6; R-QML-30 also 8). R-HTTP-15,
  R-WATCH-15, R-WRITE-11, R-BOOT-08, R-UI-18, R-UI-19 and R-QML-30 are new
  IDs with no #286 test.
  R-WRITE-07's reconnect run (a held PATCH answered after a reconnect
  attempt has run, with `writable` re-armed in between) has no #286 test.
  Of these, five have a #286 assertion pinning the old behaviour:
  R-PARSE-07 (`plugin/lib/tailscale/tests/tst_statusparser.cpp:150`, a
  `null` `Peer` under `Running` read as no Peer section),
  R-WATCH-07 (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:959`, no request after a
  wait, above), R-CONN-06 (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:551`, above), R-UI-02
  (`plugin/tests/tst_module.cpp:152`, the exact 24-property set) and R-UI-13
  (`plugin/tests/tst_module.cpp:171`, the exact 5-invokable set). Two more
  have a #286 assertion that decision 24 no longer guarantees: R-CONN-04
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:940`)
  and R-CONN-08
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:991`)
  each wait for the fake to record four requests, but the decided watch stop
  can cancel the watch's deferred connect, so the fake may record fewer. Each
  requirement maps that line and replaces it with the transport's
  issue-order count (four issued, the watch first, R-WATCH-07's test hook),
  read after the retry barrier. The
  others' #286 assertions, where they have any, hold under the decided
  behaviour too. R-QML-29 is withdrawn by decision 2.
- **Fix rule.** As the requirements file's `fix` rule
  says, an assertion that pins the corrected value of a defect fails on
  `a38dbca` for the stated reason; the other clauses of a fix requirement
  may pass there. R-WRITE-09 is the named exception as a whole: its defect is
  a missing test, not wrong behaviour. At `a38dbca` `setWantRunning(false)`
  already sends `{"WantRunning":false,"WantRunningSet":true}` (the
  `writesThePrefAndItsSetSibling` "disconnect" row), `Stopped` maps to
  itself, and the view half passes (`tests/tailscale-qml-test.qml:1567-1577`).
  Its fix is that the backend-half test exists, and that test is expected to
  pass on `a38dbca`. R-FAKE-03's test fails on `a38dbca` because the fake has
  no way to close a single client. R-GROUP-11's backend half reads
  `peersKnown` (decision 6) and its view half sets it on the stand-in and
  reads `ts-peer-unknown` (`Devices not known yet`). #286's
  `tests/tailscale-qml-test.qml:961` (zero peers show `ts-peer-empty`) pins
  the defect: at `a38dbca` the stand-in has no `peersKnown`, so zero peers
  alone show `ts-peer-empty`. It maps to R-GROUP-11, whose criterion states
  the replacement at the same staging: with `peersKnown` at its fresh value
  false the list shows `ts-peer-unknown` and no `ts-peer-empty`, and only
  with `peersKnown` true does it show `ts-peer-empty`, exactly once. That
  check fails on `a38dbca`, which has no `ts-peer-unknown`. R-QML-13
  (parity) keeps the rest of the 918-968 range, including 963 (an empty
  list shows no `ts-peer-no-match`), with `peersKnown` set true as setup;
  it no longer states which empty-list message shows.
  R-WRITE-08's whole-snapshot run holds the confirmation's `/status` without
  advancing paused time, so it never meets R-HTTP-13's deadline. R-QML-15's
  plugin half tests `PeerFilter` (decision 8); its view half binds to the
  stand-in's count.
- **New:** R-WRITE-10 and R-BOOT-07 (decision 2), and R-UI-17 and R-HTTP-14
  (decision 1). **Kit** (test-kit infrastructure, the requirements' `kit`
  tag): R-FAKE-07 (the fake's reports for the barriers, decision 12; #286's
  fake reports only its client count, which no #286 test checks as a
  requirement). Each now pins the decided bytes and member names:
  `setAdvertiseExitNode(bool)`'s exact `AdvertiseRoutes` bodies,
  `advertisingExitNode`, `exitNodeAwaitingApproval`, `ipForwardingWarning`,
  the bootstrap's `--tailscale-exit-node` step, `login()`'s
  `POST /localapi/v0/login-interactive` and `loginUrl`. R-WRITE-10 also
  carries #286's dead-row checks (`tests/tailscale-qml-test.qml:1184`,
  `:1186` and `:1188`) with their replacements. R-UI-16 counts the
  tooltip `Text` by its text, because the harness's `Tooltip` stand-in is
  never visible.

## Tests that use real waits

These #286 tests call `QTest::qWait`, mostly to prove a negative. Their
acceptance criteria use paused time and a named barrier instead (client,
retry, idle, fake or read barrier, defined in the requirements' "How to
read"). A negative about bytes the fake pushed uses the read barrier; the fake
barrier only covers bytes a client wrote.

- `plugin/tests/tst_module.cpp::tailscaleSingletonLoadsAndStaysInNoState` (R-UI-05).
- `plugin/lib/testing/tests/tst_fakesocketserver.cpp::readsTheBodyARequestDeclaresBeforeFramingIt`
  (R-FAKE-01).
- `plugin/lib/tailscale/tests/tst_localapiclient.cpp`: `neverEmitsAPartialLine` (R-WATCH-03),
  `joinsAWatchLineSplitAcrossChunks` and
  `waitsForAChunkSizeLineSplitAcrossReads` (R-HTTP-04),
  `anEstablishedWatchIsNotTimedOutByAQuietBus` (R-WATCH-05) and
  `saysNothingWhenTheWatchIsStopped` (R-WATCH-06).
- `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp`: `connectsThroughASuggestionThatFails`
  (R-CONN-11), `keepsTheDeviceListWhenAStatusDoesNotDescribeTheTailnet`
  (R-GROUP-10), `readsEachEndpointOnceAndThenWatches` (R-WATCH-07),
  `aConnectionThatHoldsClearsTheBackoff` (R-CONN-10),
  `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem`
  (R-WATCH-10), `aNotificationCarryingNothingThisModuleReadsDoesNotRefresh`
  (R-WATCH-09) and `letsTheBusOverruleAnOptimisticWrite` (R-WRITE-04).
