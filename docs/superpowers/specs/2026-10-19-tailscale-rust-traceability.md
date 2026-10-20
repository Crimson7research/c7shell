# Tailscale backend: traceability for the Rust rewrite

**Status:** draft for #289 (Phase 1 of epic #287).

**Source pin:** branch `feat/tailscale-backend` (PR #286) at commit `a38dbca`.

**Requirements:** `docs/superpowers/specs/2026-10-19-tailscale-rust-requirements.md`.

Phase 1 exits when every public symbol of the contract header and every
assertion of the existing suites maps to at least one requirement, or, for an
assertion that only checks the test's own setup, to the "Harness
preconditions" table. Table A maps the symbols. Table B maps the tests. The
harness table lists every setup-only assertion by `file:line`.

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
  `tst_module.cpp::buildSingletonReportsTheLibraryVersion`: #286 moved it onto
  the new `singleton()` helper and reworded its `QVERIFY2` message, but it
  tests the `Build` singleton.
- **QML suite.** `tests/tailscale-qml-test.qml` has no `test_*` functions. Its
  `run()` holds the bar-slot checks and calls six check functions. The count is
  the number of `check(...)` calls in each function's body. Six more
  `check(...)` calls sit in helpers; they are counted in their own table, so
  the file's 262 calls are 256 in functions plus 6 in helpers.
- **Shell suites.** Each check is one `fail` site, so each counts as 1. The
  stand-ins `test-tailscale.sh` writes are listed with 0, because they define
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
| `recommendedExitNodeId` | string | R-UI-02, R-UI-03, R-PARSE-11, R-CONN-11, R-UI-14, R-QML-11 |
| `writable` | bool | R-UI-02, R-UI-03, R-WRITE-06, R-HTTP-09, R-QML-20, R-QML-22 |
| `writeError` | string | R-UI-02, R-UI-03, R-WRITE-06, R-WRITE-08, R-HTTP-09, R-UI-16, R-QML-22 |
| `readError` | string | R-UI-02, R-UI-03, R-CONN-02, R-CONN-03, R-CONN-05, R-CONN-06, R-CONN-13, R-CONN-14, R-CONN-15, R-CONN-16, R-HTTP-09, R-QML-02, R-UI-16 |
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

The members R-WRITE-10, R-UI-17, R-GROUP-11 and open questions 3, 5 and 18 add or may add are
listed in the requirements' "Contract additions" table, not here: #286 has
none of them. R-UI-02 and R-UI-13 check the surface against the #286 set plus
that list.

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
| `saysWhetherTheReplyCarriedAPeerSectionAtAll` | 7 | 0 | R-PARSE-07 |
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
| `stripsTheMaskFromExitNodeAddresses` | 3 | 0 | R-PARSE-10 |

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

### `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp` (218 assertions, 23 harness)

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
| `dropsAHalfFinishedPassWhenTheConnectionIsLost` | 10 | 4 | R-WATCH-12, R-CONN-06, R-HTTP-11 |
| `connectsThroughASuggestionThatFails_data` | 0 | 0 | R-CONN-11 |
| `connectsThroughASuggestionThatFails` | 5 | 0 | R-CONN-11 |
| `forgetsTheSuggestionWhenTheEndpointStopsOfferingOne` | 5 | 0 | R-PARSE-11, R-HTTP-11 |
| `keepsTheDeviceListWhenAStatusDoesNotDescribeTheTailnet` | 6 | 0 | R-GROUP-10, R-HTTP-11 |
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
| `refusesAStatusThatCarriesNoBackendState` | 2 | 0 | R-CONN-04 |
| `readsEachEndpointOnceAndThenWatches` | 4 | 0 | R-WATCH-07, R-CONN-13 |
| `theRetryCurveDoublesAndCapsAtThirtySeconds` | 6 | 0 | R-CONN-07 |
| `oneLostConnectionArmsOneRetry` | 4 | 0 | R-CONN-08 |
| `theBackoffAdvancesWhenOnlyPartOfTheLocalApiAnswers` | 2 | 0 | R-CONN-09 |
| `theBackoffAdvancesWhenTheWatchKeepsEndingAfterItStarts` | 4 | 0 | R-CONN-10, R-WATCH-07, R-HTTP-11 |
| `aConnectionThatHoldsClearsTheBackoff` | 5 | 0 | R-CONN-10, R-HTTP-11 |
| `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem` | 11 | 2 | R-WATCH-10, R-HTTP-11 |
| `aNotificationCarryingNothingThisModuleReadsDoesNotRefresh` | 5 | 0 | R-WATCH-09, R-HTTP-11 |
| `refreshesOnANotificationItDoesNotRecognise` | 3 | 0 | R-WATCH-09, R-HTTP-11 |
| `rereadsTheSuggestionOnANotification` | 4 | 0 | R-WATCH-08, R-HTTP-11 |
| `writesThePrefAndItsSetSibling_data` | 0 | 0 | R-WRITE-02 |
| `writesThePrefAndItsSetSibling` | 5 | 0 | R-WRITE-02, R-UI-13 |
| `reportsThatItCannotWriteOnA403` | 12 | 0 | R-WRITE-06, R-WRITE-07 |
| `keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` | 7 | 2 | R-WRITE-06 |
| `aTransientFailureAfterARefusalDoesNotReviveTheControls` | 6 | 2 | R-WRITE-06 |
| `letsTheBusOverruleAnOptimisticWrite` | 12 | 3 | R-WRITE-04, R-WRITE-06, R-WRITE-08 (1420: the pinned defect) |
| `selectsAnExitNodeByIdNotByIp` | 9 | 2 | R-WRITE-03 |

Single lines worth naming: `republishesOnAWatchEvent` line 854
(`exitNodeActive` false before the notification) is R-WATCH-08's first
clause. `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem`
line 1143 (`state` still `Running` after the replay pass) is R-WATCH-10's last
clause. `reportsThatItCannotWriteOnA403` line 1286 and
`keepsTheControlsLiveWhenAWriteFailsWithoutBeingRefused` line 1339
(`writable` true on a running backend before any write) are R-WRITE-06's
first clause. `letsTheBusOverruleAnOptimisticWrite` line 1420 (`writeError`
empty after a 200 for an exit node the daemon did not select) pins the
R-WRITE-08 defect, "an accepted write that tailscaled does not apply produces
no feedback at all". Under the requirements' rule for `fix` tags it maps to
R-WRITE-08, whose "not applied" clause asserts the corrected value at the same
observable and fails on `a38dbca` for that reason. R-WRITE-04's criterion
sets nothing about `writeError` in that scenario, so the two do not conflict.
`readsEachEndpointOnceAndThenWatches` lines 951, 952 and 956 (`Running`, then
four requests, one GET each of `status`, `prefs` and `suggest-exit-node` and
one watch) are R-WATCH-07's count after the opening pass. Line 959 (still 4 requests with no notification) is R-WATCH-07's
"no watch and no `/status` re-read" clause; the requests R-CONN-13's liveness
check adds beyond #286's four are that fix's change, so the rewrite's test
does not assert a total of 4.

### `plugin/tests/tst_tailscalebackend.cpp` (44 assertions, 0 harness)

| Test function | Assertions | Harness | Requirements |
|---|---:|---:|---|
| `aFreshBackendReadsAsNothingKnownYet` | 12 | 0 | R-UI-05 |
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
| `tailscaleSingletonExposesExactlyTheContract` | 2 | 1 | R-UI-02 |
| `tailscaleSingletonExposesExactlyItsActions` | 2 | 1 | R-UI-13 |
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
| `foldOutChecks` | 40 | 1 | R-QML-09, R-QML-12, R-QML-13, R-QML-14 |
| `exitNodeControlChecks` | 44 | 1 | R-QML-17, R-QML-18, R-QML-19, R-QML-20, R-QML-29, R-WRITE-10, R-SEC-03 |
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
| `foldOutChecks` | 918-968 | R-QML-13 |
| `foldOutChecks` | 979-984 | R-QML-14 |
| `foldOutChecks` | 995-998 | R-QML-13 |
| `foldOutChecks` | 1008-1013 | R-QML-12 |
| `foldOutChecks` | 1026-1040 | R-QML-14 |
| `exitNodeControlChecks` | 1090-1096 | R-QML-17, R-QML-20 |
| `exitNodeControlChecks` | 1105-1128 | R-QML-17 (1105: harness) |
| `exitNodeControlChecks` | 1146-1174 | R-QML-18 (1171: the false-to-true request; 1174: the unapplied write) |
| `exitNodeControlChecks` | 1183-1188 | R-QML-29 (all four, with `writable` true); R-WRITE-10 (1183, once the advertise action exists) |
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

`exitNodeControlChecks` asserts that the "use this device as an exit node" row
is dead (`tests/tailscale-qml-test.qml:1183-1188`): visible (1183), title in
`Theme.textDisabled` (1184), a non-empty reason subtitle (1186), and no action
on click (1188), all while `writable` is true. R-QML-29 (parity) covers all
four in exactly that state: a contract with no advertise action, `writable`
true. R-WRITE-10 (new) governs the row only once the advertise action is on the
contract, so the two never apply to the same surface. Phase 2 runs R-QML-29
against the C++ branch; Phase 4 records the row's change as `new`.

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

## Harness preconditions

Each assertion below checks only the test's own staging: a temporary
directory, a fake that bound its socket or holds a request, a client that
connected, a fixture that holds what the test reads from it, a lookup that
found its element, or a negative control proving the real check can fail. It
is not product behaviour and maps to no requirement. "Setup for" names the
requirement whose test it stages; the Rust port keeps an equivalent setup
step, written as a precondition, not as an acceptance clause. These 64
assertions are inside the counts of Table B: 9 + 1 + 3 + 23 + 5 + 3 from the
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
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:540` | `dropsAHalfFinishedPassWhenTheConnectionIsLost` | The fake holds one request (its hold took effect) | R-WATCH-12 |
| `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:541` | `dropsAHalfFinishedPassWhenTheConnectionIsLost` | Completing the hold reached one client | R-WATCH-12 |
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
(see the requirements file). R-FAKE-05 keeps only the fake's own behaviour,
tested before #286 by `refusesAPathAlreadyTaken`; the backend tests'
`isListening()` checks are above. R-UI-01 and R-SEC-02 keep their behaviour
clauses; the "`C7/qmldir` exists" and "temporary directory is valid" checks
are above.

## Requirements with no #286 test

These requirements trace to code or to the PR text only. Phase 2 writes their
first test. R-FAKE-04 and R-QML-28 are withdrawn and need none.

- **Implemented but untested (parity):** R-HTTP-05, R-UI-03, R-UI-01 (#286
  checks only that the singleton resolves, as a harness precondition; the
  contract-type, same-object and two-engine checks have no #286 test),
  R-UI-10, R-WATCH-11, R-WRITE-05, R-WRITE-07 (the reconnect half: its second run, a held PATCH answered 200
  after a reconnect attempt has run, clearing an earlier 403), R-BOOT-06,
  R-SEC-01, R-SEC-05, R-PKG-02. R-UI-08 lacks its checks that the
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
  readers of `tailnet`, `hostName` and `exitNodeOption`. R-QML-06 lacks the
  clock seam (#286 measures against the host's wall clock) and its "1 month",
  days, "1 day", "under a day" and "session expired" cases. R-QML-25 lacks its
  row-signal checks on the stand-in's models. R-CONN-06 lacks its second run
  (a socket-absent connect clears a non-empty `readError`). R-GROUP-08 lacks
  its seeded property test. R-UI-14 lacks its check that the installed module
  carries no fake type. R-SEC-01 lacks its held-request scenario. R-QML-01 lacks the second and third armed
  reconnects (at paused time 500 ms and 1500 ms); #286 checks the first.
  R-CONN-06 lacks its check that a reconnect attempt finding nothing at the
  path clears `recommendedExitNodeId` and moves nothing else. R-CONN-03's
  stagings other than the 403 do not fail the watch in #286; the rewrite's
  test stages every failure but the close mid-body on the watch too, so its
  client barrier at 0 is reachable. A watch closed mid-body ends cleanly, so
  that staging holds the watch until the read barrier shows `readError`
  consumed and then drops it with R-FAKE-03. R-WATCH-06's stop-before-connect check uses a second client's
  reply as its ordering point. R-FAKE-05's refusal of a taken path is
  tested by `tst_fakesocketserver.cpp::refusesAPathAlreadyTaken` (lines
  236-269), which predates #286; #286's own `isListening()` checks are harness
  preconditions. R-FAKE-02's hold and complete have no
  self-test in `tst_fakesocketserver.cpp`; only the backend tests that map to
  it exercise them. R-FAKE-01 lacks the fake barrier (bytes consumed per
  client); #286 proves its negative with `qWait(50)`. The read barrier
  (bytes the client consumed of what the fake pushed) is new: R-HTTP-04,
  R-WATCH-03, R-WATCH-06 and R-WATCH-10 use it, and #286 has no equivalent.
  R-WATCH-07 lacks its client-side check that the watch is issued first in
  every attempt; #286 counts the four requests but never their order.
  R-HTTP-08 lacks the PATCH's numeric status 403 (#286 checks the no-reply
  and the reason text). R-SEC-05's scan, including its `192.168.1.129`
  exception, has no #286 test. R-WATCH-13 lacks `Weird` mapping to `NoState`, and its checks that an
  unknown `BackendState` leaves `readError` empty, arms no reconnect, keeps
  the watch open and, with no earlier state, leaves the slot hidden.
  R-CONN-06 lacks its third run (a notification on the watch left open after
  a read failure publishes a whole snapshot before the reconnect). R-CONN-05
  lacks its held-`/status` check that a `/prefs` reply alone fires no
  `readErrorChanged`. R-WRITE-06 lacks its check that a deadline
  `writeError` persists after a snapshot shows the value applied.
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
  its replay clause and its count of the other signals. R-QML-29 is tested
  by #286 at `tests/tailscale-qml-test.qml:1183-1188` with `writable` true
  only; its `writable`-false case has no #286 test.
- **Added after review, parity, untested in #286:** R-CONN-14 (a non-object
  `/prefs`), R-CONN-15 (a clean watch end before a snapshot), R-PARSE-11's
  arrival-order case, R-WRITE-06's two-write case, R-BOOT-03's exhausted wait,
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
  hold under every R-WRITE-08 design; #286's staging of the 403-then-200 run
  (`tst_localapitailscalebackend.cpp:1306-1312`) leaves `/prefs` at
  `prefs.json` and still maps to R-WRITE-06's recovery clause, whose
  rewritten test serves `RouteAll` true from the 200 on.
- **Fix:** R-HTTP-09, R-GROUP-11, R-CONN-13, R-WRITE-08, R-WRITE-09, R-UI-16,
  R-QML-15, R-QML-16, R-FAKE-03. As the requirements file's `fix` rule
  says, an assertion that pins the corrected value of a defect fails on
  `a38dbca` for the stated reason; the other clauses of a fix requirement
  may pass there. R-WRITE-09 is the named exception as a whole: its defect is
  a missing test, not wrong behaviour. At `a38dbca` `setWantRunning(false)`
  already sends `{"WantRunning":false,"WantRunningSet":true}` (the
  `writesThePrefAndItsSetSibling` "disconnect" row), `Stopped` maps to
  itself, and the view half passes (`tests/tailscale-qml-test.qml:1567-1577`).
  Its fix is that the backend-half test exists, and that test is expected to
  pass on `a38dbca`. R-FAKE-03's test fails on `a38dbca` because the fake has
  no way to close a single client. R-GROUP-11's two halves are executable now: the backend half
  reads one boolean peers-known member and the view half sets it on the
  stand-in; open question 6 pins only the member's name and place and the
  panel's wording. #286's `tests/tailscale-qml-test.qml:961` (zero peers show
  `ts-peer-empty`) is R-QML-13's known-empty clause; R-GROUP-11 adds the
  unknown case. At `a38dbca` the stand-in has no peers-known member, so that
  check shows `ts-peer-empty` for zero peers alone; R-QML-13 states only the
  corrected clause, and the rewrite's test sets peers-known true before it. R-WRITE-08's whole-snapshot run holds the confirmation's
  `/status` without advancing paused time, so it never meets R-HTTP-13's
  deadline.
- **New:** R-WRITE-10, R-UI-17. R-WRITE-10's acceptance is executable now:
  it names the request and the row state any answer to open question 2
  produces, and the answer pins only field and member names. R-UI-17's acceptance is executable now: it
  names the observables any answer to open question 1 produces. The answer
  pins the exact request bytes and the contract member's name. R-UI-16 counts the tooltip `Text` by its text, because the
  harness's `Tooltip` stand-in is never visible.

## Tests that use real waits

These #286 tests call `QTest::qWait`, mostly to prove a negative. Their
acceptance criteria use paused time and a named barrier instead (client,
retry, idle, fake or read barrier, defined in the requirements' "How to
read"). A negative about bytes the fake pushed uses the read barrier; the fake
barrier only covers bytes a client wrote.

- `tst_module.cpp::tailscaleSingletonLoadsAndStaysInNoState` (R-UI-05).
- `tst_fakesocketserver.cpp::readsTheBodyARequestDeclaresBeforeFramingIt`
  (R-FAKE-01).
- `tst_localapiclient.cpp`: `neverEmitsAPartialLine` (R-WATCH-03),
  `joinsAWatchLineSplitAcrossChunks` and
  `waitsForAChunkSizeLineSplitAcrossReads` (R-HTTP-04),
  `anEstablishedWatchIsNotTimedOutByAQuietBus` (R-WATCH-05) and
  `saysNothingWhenTheWatchIsStopped` (R-WATCH-06).
- `tst_localapitailscalebackend.cpp`: `connectsThroughASuggestionThatFails`
  (R-CONN-11), `keepsTheDeviceListWhenAStatusDoesNotDescribeTheTailnet`
  (R-GROUP-10), `readsEachEndpointOnceAndThenWatches` (R-WATCH-07),
  `aConnectionThatHoldsClearsTheBackoff` (R-CONN-10),
  `coalescesNotificationsArrivingWhileARefreshIsOutAndThenReplaysThem`
  (R-WATCH-10), `aNotificationCarryingNothingThisModuleReadsDoesNotRefresh`
  (R-WATCH-09) and `letsTheBusOverruleAnOptimisticWrite` (R-WRITE-04).
