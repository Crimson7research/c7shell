# Tailscale backend: requirements for the Rust rewrite

**Status:** draft for #289 (Phase 1 of epic #287).

**Source pin:** branch `feat/tailscale-backend` (PR #286) at commit `a38dbca`.
Every requirement comes from that branch, its PR description and its PR
comments. None comes from memory.

**Plan:** `docs/superpowers/plans/2026-10-19-tailscale-rust-rewrite.md` on
branch `docs/tailscale-rust-plan` of the main repository, Phase 1. It is not
in the #286 checkout or on `main`.
The traceability tables live in
`docs/superpowers/specs/2026-10-19-tailscale-rust-traceability.md`.

## How to read this document

Each requirement has an ID, a tag, a title, a statement, an acceptance
criterion and its sources.

- **ID.** The area plus a two-digit number, for example `R-HTTP-01`. IDs are
  stable. A removed requirement leaves a gap; it is never renumbered. Its
  heading stays, tagged `withdrawn`, with the reason, so the ID is never
  reused.
- **Tag.**
  - `parity`: #286 behaves this way today, and the rewrite keeps it.
  - `fix`: #286 names this as a defect, or the owner decided on 2026-10-21
    to change #286's behaviour (see "Decisions (2026-10-21)"). The statement
    gives the corrected behaviour. The source names the defect, or cites both
    the #286 code it changes and the decision. A #286 assertion that pins the
    old behaviour itself (it holds on `a38dbca` only because of the defect or
    the decided change) maps to the fix requirement. That requirement's
    acceptance names the corrected value at the same observable, and its test
    fails on `a38dbca` for that reason. Every other #286 assertion maps to a
    requirement whose acceptance covers it in the state #286 asserts it.
  - `new`: #286 deliberately left this out. The statement gives the
    user-visible goal, and the design the owner decided on 2026-10-21.
  - `kit`: test-kit infrastructure that the rewrite's own acceptance tests
    read, not behaviour of the shipped product, so neither `parity`, `fix`
    nor `new` fits it. The statement says what #286's kit already has and
    what the rewrite's kit adds, and why the barriers need it (decision 12).
    It has its own acceptance test and is gated like any other requirement,
    but no #286 product assertion maps to it and it has no user-visible
    goal.
  - `follow-up`: moved out of epic #287 by an owner decision. The ID and the
    text stay, so the ID is never reused, but the rewrite does not implement
    it and no gate of the rewrite checks it.
  - `withdrawn`: removed, with the reason. See "ID" above.
- **Statement.** Observable behaviour only: bytes on the wire, QML-visible
  properties, signals and invokables, model rows and model signals, process
  exit codes and file contents. It names no internal class or method, except
  the public contract surface (`Tailscale` and its members).
- **Acceptance.** A test that needs no sleep and no host state. It uses a fake
  tailscaled on a Unix socket under the test's private directory, and paused
  time as defined below. The one exception is R-QML-06, whose unchanged view
  reads the wall clock: that criterion states the bounds under which its
  outcome does not depend on the clock, and that a clock outside them fails
  the check.
- **Sources.** `file:line` in the #286 checkout, relative to the repository
  root. `pr286-body:N` is line N of the PR #286 description. `pr286-comments:N`
  is line N of its review comments. Both are line-numbered as captured for
  Phase 1. A path that names a file outside the #286 checkout says whose it
  is: an upstream tailscale source is cited as the repository
  (`github.com/tailscale/tailscale`), a tag and its commit, and
  `file:line` in that tree; the plan is cited as its path on branch
  `docs/tailscale-rust-plan` of the main repository. A capture named by its
  file name alone (`status-idle.json`, `prefs.json`, `prefs-patched.json`,
  `suggest-exit-node.json` and the other `status-*.json`) is test data,
  not a citation: it is the file of that name in
  `plugin/lib/tailscale/tests/fixtures/`. Every citation gives the path
  from the repository root.

Terms used throughout:

- **Fake tailscaled.** A test server on a Unix socket. It records request
  bytes, replies from scripted data, pushes watch lines and can hold a request
  unanswered.
- **Pass.** One refresh: `GET /localapi/v0/status`, `GET /localapi/v0/prefs` and
  `GET /localapi/v0/suggest-exit-node`.
- **Snapshot.** What one pass publishes: the status and prefs replies, applied
  together.
- **Live.** The contract's `state` is not `NoState`.
- **Accepted head.** A complete response head (status line and headers,
  within R-HTTP-15's cap) whose status is in 200-299. Only a 2xx head is
  ever accepted. A complete head with any other status is a **refused
  head**: it is never accepted, a watch never emits "started" for it, and it
  never turns the watch deadline off. The failure it leads to always carries
  its status code (R-HTTP-08, R-HTTP-09). Every criterion uses these two
  terms; none calls a non-2xx head "accepted".
- **Barrier.** A positive event that proves the exchange under test has been
  consumed. It replaces #286's `qWait` and any "drain the events" that has no
  end condition. One of:
  - **client barrier:** the fake's connected-client count returns to its
    expected value, usually 1, the watch alone. Every read and write closes
    its own connection (R-HTTP-11), so this proves its outcome was consumed;
  - **retry barrier:** a reconnect has been armed (R-CONN-07's test hook).
    It follows the stored diagnosis, so it proves a loss was fully handled;
  - **idle barrier:** the backend reports to its test that no pass is in
    flight, that no pass has a `/suggest-exit-node` or
    `/check-ip-forwarding` outcome still to apply or drop, and no
    follow-up check still to send (R-PARSE-11, R-WRITE-10; a follow-up
    check belongs to the pass whose snapshot started it; a pass "ends" for
    R-WRITE-10 when it publishes, but it
    stays unsettled here until both of those outcomes have been applied or
    dropped, or a reconnect has closed their connections), and that no
    notification is waiting to start one; the client barrier holds; and
    the read barrier holds on every connection, not only on the watch. So
    it cannot hold while any exchange the backend issued (a snapshot read,
    a suggestion, a forwarding check, a probe) has a scheduled connect,
    unsent request bytes or an undelivered outcome. A request the fake
    holds, with nothing pushed on it, does not prevent it: nothing is
    waiting on that connection. The rewrite exposes this to tests like the
    retry hook, as a test hook on the core crate (decision 12);
  - **fake barrier:** the fake has consumed every byte a client wrote. The
    fake reports bytes received per client (R-FAKE-07, which also specifies
    and tests the bytes-written report, the connected-client count and the
    accepted total that the other barriers read). It runs from client to fake only:
    it proves nothing about bytes the fake pushed;
  - **read barrier:** the client side has consumed every byte the fake pushed
    to it, and holds no outcome or event it has not yet delivered. The fake
    reports bytes pushed per client. The transport reports to its test, per
    connection, the bytes it has consumed, and whether an outcome or event is
    waiting to be delivered. The barrier holds when every connection's
    consumed count equals the fake's pushed count for that client and nothing
    is waiting. An exchange whose connect has been scheduled but has not yet
    run, or whose request bytes have not all been written to its socket,
    counts as waiting, so the barrier cannot hold before a deferred
    connect has run or been cancelled, or before a request has been sent
    in full. With no connection left, as after a
    stop, it holds once nothing is waiting. The rewrite exposes this to tests like the idle
    barrier, as a test hook on the core crate (decision 12). The idle barrier
    includes the read barrier on every connection;
  - **layout barrier** (view halves and the QML suite only; criteria also
    call it "the layout pass"): after the last property set, click or key
    press, the harness calls `forceLayout()` on every descendant of the
    popover and of the bar slot that has one, five passes over the tree, as
    #286's `layout()` helper does (`tests/tailscale-qml-test.qml:414-418`,
    and `slotWidth()` at `:135-139` for the slot), and returns. The QML
    stand-in (R-QML-25) changes its properties synchronously and the views
    have no asynchronous step besides positioner polish, so once it returns
    every binding and every layout has settled. It is a positive end
    condition, not a wait for time.

  Every negative ("nothing changed", "no request", "fired exactly N times")
  is measured after a named barrier. A count is stated as an exact value at
  that point.

  Two barriers are often taken together:
  - **Request counts.** The read barrier and then the fake barrier prove
    that every request the client has issued so far has reached the fake
    and been recorded. The read barrier rules out a connect still scheduled
    and request bytes not yet written. The fake barrier rules out written
    bytes the fake has not consumed. An exact request count, or "no
    request", is read once both hold.
  - **Transport outcomes.** A transport criterion that reads "no reply",
    "no failure", "no started" or an exact count of outcomes reads it after
    the read barrier. That is never just after the exchange's own outcome:
    an outcome delivered one event-loop turn later would fail the read
    barrier's "nothing is waiting".
- **Setup is not acceptance.** A step that only makes the test's own staging
  true (the fake bound its socket, a client connected, the fake recorded the
  watch before a push, the fixture holds the expected entry) is a
  precondition of the test, not a clause of the criterion. The traceability
  file lists every such #286 assertion in its "Harness preconditions" table.
- **An accepted write is applied unless stated.** Unless a criterion says
  otherwise, a fake that answers a PATCH 2xx has applied it: its later
  `/prefs` reads hold the requested value, and the 2xx body is the resulting
  prefs. Such a write is applied, so R-WRITE-08's confirmation pass leaves
  `writeError` empty. Criteria that stage a 2xx the daemon did not apply
  (R-WRITE-04, R-WRITE-08) say so.
- **Paused time.** The backend's and the transport's timers run on a test
  clock. The test clock advances only by an explicit test advance, and by
  nothing else. It never advances on its own, in particular not while the
  runtime is idle waiting for a barrier, a held request or the fake, so it
  always reads exactly the sum of the test's advances. tokio's paused clock
  (`time::pause()`, or `start_paused`) does not qualify as it stands: it
  auto-advances to the next pending timer whenever the runtime has no work,
  and a held request always leaves a deadline timer pending, so the clock
  would jump while the test awaits a barrier.
  **Phase 3 constraint, not a design choice made here.** Phase 3 must
  provide a test clock that never auto-advances. Either of these would
  satisfy it, named as examples only: tokio paused time driven so that it
  never auto-advances (the runtime is kept from idling while a test awaits
  a barrier), or a clock abstraction in the core crate whose test
  implementation moves only on an explicit advance. Which one is Phase 3's
  decision. An advance
  of exactly N ms moves the clock from t to t + N; every timer due in
  (t, t + N], including one armed during the advance, fires at its own due
  instant, in order of due time, and the clock never passes a timer it has
  not fired. The order in which timers due at the same instant fire is
  unspecified, and no criterion depends on it. The core crate reports the clock's current instant to tests
  through a test hook, like the retry hook (decision 12). At every barrier
  that a criterion places at a named instant ("with paused time not
  advanced", "after an advance of exactly N ms", "at P + 69 999 ms", "short
  of the 20 000 ms retry"), the test also asserts that the clock reads
  exactly that instant, counted from the test's own start or from the
  instant the criterion names. A clock that moved by itself then fails the
  test instead of firing a timer the criterion says has not fired. A
  criterion that names no advance assumes none: the clock reads the instant
  of the test's last advance. Because nothing but an advance moves the clock,
  the instants a criterion counts from ("from the call", "from the instant
  the fake recorded the request", "past the instant the fake recorded the
  PATCH") are one and the same clock reading when no advance lies between
  them, and every "advance exactly N ms, then nothing yet" clause reads the
  outcomes due by t + N only: a timer due at t + N + 1 or later has not
  fired, because the clock has not reached it.
- **Shipped timings.** Unless a criterion injects others (R-CONN-01): a
  10 000 ms request deadline, a 500 ms first retry delay, a 30 000 ms settle
  period and a 30 000 ms liveness interval (R-CONN-13).
- **Two halves.** An acceptance that names both a fake tailscaled and `ts-`
  elements or `Theme` colours runs as two tests. The backend half drives the
  contract from the fake and asserts contract values. The view half sets those
  same values on the QML stand-in (R-QML-25) and asserts the `ts-` elements and
  the recorded actions. In a view half, and in every QML-suite check, unless
  the criterion names another barrier, each visibility, text, colour,
  checked, enabled, hoverable, width or truncation clause, positive or
  negative ("not visible", "no `ts-peer` row", "none reads ..."), is read
  after the layout barrier that follows the last property set, click or key
  press; each recorded-call clause ("records exactly one call", "records
  nothing", "no PATCH") is read when that click or set returns, because the
  stand-in records calls synchronously, and counts from just before it. Both halves together are the criterion. No harness
  loads the real module in `qml6` against a fake socket.

## R-HTTP: LocalAPI transport

### R-HTTP-01 · parity · Request line and Host header

**Statement.** Every request is HTTP/1.1 over the Unix socket. It starts with
`<METHOD> <path> HTTP/1.1` and carries `Host: local-tailscaled.sock`. tailscaled
rejects any other Host. A request without a body carries no other header.

**Acceptance.** Given a fake tailscaled that frames requests on CRLFCRLF, when
the client GETs `/localapi/v0/status`, then after the read barrier and the
fake barrier ("Request counts") the fake has recorded exactly one request,
and it is exactly
`GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock` and nothing
else before CRLFCRLF. A fake that answers `200` with `{}` gets, after the read
barrier ("Transport outcomes"), exactly one reply back and no failure, so
tailscaled would accept that request.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:152-160`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:84-99`, `pr286-body:35-36`.

### R-HTTP-02 · parity · A PATCH carries a JSON body under its own length

**Statement.** A write is `PATCH <path>` with the Host header,
`Content-Type: application/json` and `Content-Length` equal to the body's byte
length. The body bytes follow verbatim. A PATCH ends in the same reply or
failure outcomes as a read. The rewrite's transport also sends a POST without
a body (R-HTTP-14, decision 1).

**Acceptance.** Given a fake that answers `200` with `Content-Length: 2` and `{}`,
when the client PATCHes `/localapi/v0/prefs` with
`{"RouteAllSet":true,"RouteAll":true}`, then after the read barrier and the
fake barrier ("Request counts") the fake has recorded exactly one request.
That request starts with
`PATCH /localapi/v0/prefs HTTP/1.1\r\n`. It contains the Host header and
`Content-Length: 36`, and ends with CRLFCRLF plus the exact body. After the
read barrier ("Transport outcomes") exactly one reply has arrived, with body
`{}`, and no failure.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:87-100`,
`plugin/lib/tailscale/LocalApiClient.cpp:106-109`,
`plugin/lib/tailscale/LocalApiClient.cpp:152-160`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:101-139`.

### R-HTTP-03 · parity · A Content-Length body is cut to the declared length

**Statement.** tailscaled answers `/prefs` and `/suggest-exit-node` with a
`Content-Length`. The delivered body is exactly that many bytes, without
headers. Extra bytes are not delivered. The reply is delivered as soon as the
declared bytes have arrived.

**Acceptance.** Given a fake that answers
`HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{"ok":true}\r\n`, when the client
GETs a path, then after the read barrier exactly one reply has arrived. Its
body equals the 11 bytes `{"ok":true}`, compared exactly. At that barrier no
failure has been reported.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:79-87`,
`plugin/lib/tailscale/LocalApiClient.cpp:202-204`,
`plugin/lib/tailscale/LocalApiClient.cpp:402-405`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:27-50`, `pr286-body:32-34`.

### R-HTTP-04 · parity · A chunked body is de-chunked, however it is split

**Statement.** tailscaled answers `/status` and `/watch-ipn-bus` with
`Transfer-Encoding: chunked`. The client removes the framing before it
delivers a body or splits watch lines. A size line is hex, and any `;extension`
is ignored. A zero-size chunk ends the body, and trailers are ignored. Size
lines, data and the closing CRLF may each arrive split across reads. A partial
size line is not an error. Header names match case-insensitively. The
response headers may also arrive split across reads, anywhere, including
inside the blank line that ends them. Nothing is decided about status or
framing until that blank line has arrived.

**Acceptance.** Given a fake that answers `/status` with chunks
`6\r\n{"a":1\r\n`, `7\r\n,"b":2}\r\n` and `0\r\n\r\n`, after the read barrier
exactly one reply has arrived, its body is exactly `{"a":1,"b":2}`, and no
failure has been reported for that exchange. On a chunked
watch, pushing `1` alone and then the read barrier yields no event and no
failure. Pushing `1\r\n{"chunk":"size"}\n\r\n` then yields exactly one event, whose
bytes are exactly `{"chunk":"size"}`. Pushing
`4\r\n{"ha\r\n` and then the read barrier yields no event. Pushing
`7\r\nlf":1}\n\r\n` then yields exactly one event `{"half":1}`. A size line
`a;ext=1` reads as 10 bytes. Trailers: a fake that answers `/status` with
the chunks `2\r\n{}\r\n` and then `0\r\nX-Trailer: 1\r\n\r\n` yields exactly
one reply, whose body is exactly `{}`, and no failure; the trailer line is
neither part of the body nor a framing error.

Split headers, on a watch the fake has recorded and not answered: pushing
`HTTP/1.1 200 OK\r\nTransfer-Enc` and then the read barrier yields no started
and no failure. Pushing `oding: chunked\r\n\r` and the read barrier still
yields no started. Pushing `\n` yields exactly one started. Then
`8\r\n{"a":1}\n\r\n` yields exactly one event `{"a":1}`. A GET whose
`Content-Length: 11` header line arrives split over two pushes, followed by
`{"ok":true}`, yields exactly one reply with that 11-byte body. A GET framed by
`content-length: 11`, and a watch framed by `TRANSFER-ENCODING: Chunked`,
behave exactly as their canonical spellings do. Every "exactly one" and every
"no" in this criterion is read after the read barrier (see "Transport
outcomes" under "Barrier"). Setup, not acceptance: each watch case waits
until the fake has recorded the watch (R-WATCH-01) before the first push.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:51-55`,
`plugin/lib/tailscale/LocalApiClient.cpp:66-77`,
`plugin/lib/tailscale/LocalApiClient.cpp:66-89`,
`plugin/lib/tailscale/LocalApiClient.cpp:215-218`,
`plugin/lib/tailscale/LocalApiClient.cpp:231-234`,
`plugin/lib/tailscale/LocalApiClient.cpp:248-308`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:162-182`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:344-384`, `pr286-body:32-34`.

### R-HTTP-05 · parity · Malformed chunk framing is a named failure

**Statement.** A size line that is not a non-negative hex number fails the
exchange. The reason names the path and the offending text. A chunk whose data
is not followed by CRLF fails with a reason that names the path. Neither
delivers a reply.

**Acceptance.** Given a chunked answer with size line `zz\r\n`, the client
reports exactly one failure whose reason contains `zz`, and no reply. Given
`2\r\nabXY`, it reports exactly one failure saying the chunk did not end where
it said, and no reply. Both are a GET of `/localapi/v0/status`, and both
failure reasons contain `/localapi/v0/status`. Each count, and each "no
reply", is read after the read barrier.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:273-279`,
`plugin/lib/tailscale/LocalApiClient.cpp:297-303`,
`plugin/src/contracts/TailscaleBackend.h:310-320`.

### R-HTTP-06 · parity · A body with neither framing ends at the close

**Statement.** A 2xx response with neither `Content-Length` nor chunked
encoding has a body of everything that arrived before the peer closed. It is a
successful reply. A `Content-Length` that is negative or not a number counts
as no `Content-Length`.

**Acceptance.** Given a fake that writes `HTTP/1.1 200 OK\r\n\r\n{"ok":true}` and
closes, a GET yields exactly one reply with body `{"ok":true}` and no failure.
With `Content-Length: -5`, and separately with `Content-Length: x`, followed
by `{}` and a close, a GET yields exactly one reply `{}` and no failure. Each
count, and each "no failure", is read after the read barrier.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:202`,
`plugin/lib/tailscale/LocalApiClient.cpp:82-87`,
`plugin/lib/tailscale/LocalApiClient.cpp:338-342`,
`plugin/lib/tailscale/LocalApiClient.cpp:356-362`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:184-200`.

### R-HTTP-07 · parity · A response cut short is a failure, never a partial success

**Statement.** If the peer closes before the headers are complete, the
exchange fails. The reason says the connection closed before the response
headers. If the peer closes after the headers but before the body ended, the
reason says it closed before the response ended. A close is judged by what
arrived.

**Acceptance.** Given a fake that reads the request and closes without writing,
a GET of `/localapi/v0/prefs` yields no reply. It yields one failure for that
path whose reason contains `before the response headers`. Given
`Content-Length: 99`, 9 body bytes and a close, a GET yields no reply and one
failure containing `before the response ended`. A chunked body closed before
its zero chunk behaves the same. Each count, and each "no reply", is read
after the read barrier.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:333-363`,
`plugin/lib/tailscale/LocalApiClient.cpp:365-385`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:52-82`.

### R-HTTP-08 · parity · A non-2xx status fails with its status code

**Statement.** Any status outside 200-299 ends the exchange in failure, never
in a reply. So does a status line that is not `HTTP/x NNN`. A `1xx` or a
`304` is such a failure too; R-HTTP-14 adds only that, having no body, it
fails as soon as its headers end. The failure carries
the path, a reason that includes the status line, and the numeric status. The
status is 0 when no valid status line arrived. A caller tells 403 apart without
parsing prose.

**Acceptance.** Given `HTTP/1.1 403 Forbidden\r\nContent-Length: 0`, a GET of
`/localapi/v0/prefs` yields no reply. It yields one failure with that path, a
reason containing `403` and status 403. Given a 500, the status is 500. A PATCH
answered 403 likewise yields no reply and one failure whose reason contains
`403` and whose status is 403. With no listener, the status
is 0. A head that is not a valid status line also fails: given a fake
answering `garbage\r\nContent-Length: 2\r\n\r\n{}`, a GET yields no reply
and exactly one failure with status 0 and socket-absent false. The status
lines `HTTP/1.1 abc OK` and a bare `HTTP/1.1`, each followed by
`Content-Length: 2` and `{}`, give the same result. Each count, and each "no
reply", is read after the read barrier.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:112-134`,
`plugin/lib/tailscale/LocalApiClient.cpp:46-64`,
`plugin/lib/tailscale/LocalApiClient.cpp:221-230`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:136-143` (the
backend tells a 403 apart by the numeric status, `status == kForbidden`),
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:141-160`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:210-225`.

### R-HTTP-09 · fix · An error reply keeps the daemon's own words

**Statement.** tailscaled may answer a non-2xx status with a body. The failure
reason then carries that body's text appended to the status line; there is no
separate field (decision 3). The reason is exactly
`<path> answered <status line>: <text>`, where `<path> answered <status line>`
is #286's reason unchanged. `<text>` is:

- the value of the `error` member when the body is a JSON object whose
  `error` member is a string (tailscaled's own error shape);
- otherwise the whole body as text;
- in both cases with leading and trailing whitespace removed, invalid UTF-8
  replaced by U+FFFD, and then cut to its longest prefix of at most 512
  bytes that ends on a character boundary. Nothing marks the cut.

When `<text>` is empty (no body, or only whitespace), the reason is
`<path> answered <status line>` with no `: `. `writeError` and `readError`
therefore publish the words of whatever refused the request. The failure
still yields no reply. The status
code from a refused head always survives an error body that is cut short,
stalls past the deadline or ends mid-chunk. The failure then carries that
status, with whatever body arrived, and never becomes a status-0 failure. A
403 therefore always revokes `writable` (R-WRITE-06).

The watch reads its error body the same way. A watch answered with a status
outside 200-299 never emits "started", and its establishment deadline stays
on while the error body arrives (R-WATCH-05): it ends at the body's end, or
at the deadline when the body stalls or has neither framing and the peer
keeps the connection open (R-HTTP-06). Either way it emits exactly one
failure in this requirement's form, with its status, then "ended". The
backend treats that as a lost connection with that `readError` (R-CONN-03,
R-CONN-16). So a daemon that refuses the watch and then stalls can never
leave the backend waiting with no bus, no `readError` and no retry. In #286
a non-2xx watch fails as soon as its headers arrive
(`plugin/lib/tailscale/LocalApiClient.cpp:221-230`), before the deadline is
turned off at `:235-239`, and reads no body.

**Defect.** "The HTTP error body is discarded where the contract promises 'the
words of whatever refused it'; only the status line survives."

**Acceptance.** Given a fake that answers a PATCH of `/localapi/v0/prefs` with
`HTTP/1.1 403 Forbidden` and the body `prefs write access denied\n`, then
`writeError` equals
`/localapi/v0/prefs answered HTTP/1.1 403 Forbidden: prefs write access denied`.
The same holds for a chunked error body. Given a GET of `/localapi/v0/status`
answered `HTTP/1.1 500 Internal Server Error` with `{"error":"boom"}`,
`readError` equals
`/localapi/v0/status answered HTTP/1.1 500 Internal Server Error: boom`. A 500
whose body is `{"message":"boom"}` (an object without a string `error`) gives
`...: {"message":"boom"}`, the whole body. A 403 with `Content-Length: 0`
gives exactly `/localapi/v0/prefs answered HTTP/1.1 403 Forbidden`. Invalid
UTF-8: a GET of `/localapi/v0/status` answered
`HTTP/1.1 500 Internal Server Error` with `Content-Length: 9` and the body
bytes `62 61 64 20 FF 20 65 6E 64` (`bad `, the lone invalid byte `0xFF`,
` end`) gives `readError` exactly
`/localapi/v0/status answered HTTP/1.1 500 Internal Server Error: bad � end`,
where `�` is one U+FFFD (the bytes `EF BF BD`) in place of `0xFF` and
nothing else changed. No reply
is delivered in any case. Each value is read after the read barrier, and
"no reply" and every failure count, here and below, are read there too.

Bounds and incomplete bodies, each with paused time and a 50 ms deadline:

- An error body of 65 536 ASCII bytes `a` yields exactly one failure whose
  `<text>` is exactly the first 512 of them. A body of 511 ASCII bytes
  followed by `é` (2 bytes) yields a `<text>` of the 511 ASCII bytes only, so
  the cut never splits a character.
- A PATCH answered `403` with `Content-Length: 100`, 20 body bytes and a
  close yields exactly one failure with status 403. `writable` becomes false.
- The same 403 with its 20 body bytes sent and the rest withheld: once the
  fake has recorded the PATCH, paused time advances exactly 50 ms. After the
  read barrier there is exactly one failure, with status 403, that carries
  the 20 bytes, and no reply. Its reason is this requirement's form, with
  `<text>` taken from the partial body by the same rules, and carries no
  deadline wording (R-HTTP-13's `50 ms` is only for a failure that has
  received no refused head). In this run and the close run above the 20 bytes are
  `prefs write access d`, so the reason, and `writeError` at the backend,
  is exactly
  `/localapi/v0/prefs answered HTTP/1.1 403 Forbidden: prefs write access d`.
- A chunked 403 cut before its zero chunk yields exactly one failure with
  status 403.

The watch, each with paused time and a 50 ms deadline; each count is read
after the read barrier, and the 20 body bytes are `watch access denied.`:

- A watch answered `HTTP/1.1 403 Forbidden`, `Content-Length: 100` and the
  20 body bytes, then held. Paused time advances exactly 49 ms from the
  instant the fake recorded the watch: no "started" and no failure. It
  advances exactly 1 ms more: exactly one failure with status 403 whose
  reason is exactly
  `/localapi/v0/watch-ipn-bus answered HTTP/1.1 403 Forbidden: watch access denied.`,
  with no deadline wording, then exactly one "ended", and no "started".
- The same with a 403 that has neither `Content-Length` nor chunked framing,
  sends the 20 body bytes and keeps the connection open: the same results at
  the same instants.
- Backend half: a fresh backend whose opening `/status`, `/prefs` and
  `/suggest-exit-node` are answered and whose watch gets the first case's
  answer. Paused time advances exactly 50 ms from the instant the fake
  recorded the watch. After the retry barrier `state` is `NoState`,
  `readError` is exactly that reason, and exactly one retry is armed.

**Sources.** `pr286-body:119-120`,
`plugin/src/contracts/TailscaleBackend.h:303-304` (the promise to publish "the
words of whatever refused it"),
`plugin/src/contracts/TailscaleBackend.h:305-311`,
`plugin/src/contracts/TailscaleBackend.h:250-252` (only the measured 403 body
`prefs write access denied` that the acceptance replays),
`plugin/lib/tailscale/LocalApiClient.cpp:221-230` (#286's reason
`<path> answered <status line>` at `:227`; a non-2xx watch fails there, at
its headers), `plugin/lib/tailscale/LocalApiClient.cpp:235-239` (the watch
deadline turned off after that check), decision 3.

### R-HTTP-10 · parity · An absent socket is told apart from an unreadable daemon

**Statement.** A connect that fails because nothing exists at the socket path
is a failure flagged socket-absent. Every other transport error is a failure
with that flag false. Refused, permission denied and reset are examples.
Neither case hangs.

**Acceptance.** Given a socket path with nothing at it, a GET yields, after
the read barrier ("Transport outcomes"), exactly one failure, delivered
asynchronously, with status 0 and socket-absent true, and no reply. Given a
path that exists but refuses connections, after the read barrier exactly one
failure has been delivered and its flag is false.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:127-134`,
`plugin/lib/tailscale/LocalApiClient.cpp:386-390`,
`plugin/src/contracts/TailscaleBackend.h:322-330`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:202-208`.

### R-HTTP-11 · parity · Each exchange ends in exactly one outcome unless stopped, never synchronously

**Statement.** Each read or write opens its own connection. It runs
independently of other exchanges and of the watch. Unless the client is
stopped or destroyed before its outcome is delivered, it ends in exactly one
reply or one failure. A stopped or destroyed client delivers nothing for its
open exchanges (R-WATCH-06): that is the one way an exchange ends with no
outcome. That outcome is delivered after the call has returned,
even when the connect fails at once. Request bytes are written only after the
connection is established.

**Acceptance.** With a fake that answers one path and holds another, two GETs
and a watch yield, after the read barrier ("Transport outcomes"), exactly one
reply and no failure. At that same point the held exchange and the watch are
still open: the fake's connected-client count is exactly 2 and its held count
is 1. Right
after any call returns, before the event loop runs, no outcome has been
delivered. This holds for a socket path with nothing at it too. Against the
backend, once a pass has been answered, after the idle barrier the fake's
connected-client count is exactly 1: every read has closed its own
connection and only the watch stays.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:25-27`,
`plugin/lib/tailscale/LocalApiClient.cpp:125-176`,
`plugin/lib/tailscale/LocalApiClient.cpp:431-446`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1064-1067`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1088`.
#286 pins only the backend-level consequence (the client count of 1, asserted
in 14 backend tests); the client-level clauses have no #286 test.

### R-HTTP-12 · parity · A caller's token comes back unchanged

**Statement.** A read or write may carry a caller-supplied 64-bit token. Its
reply or failure returns the token unchanged. The default is 0. A failed watch
always reports 0.

**Acceptance.** A GET with token 7 answered 200 yields a reply with token 7. A
GET with token 9 answered 403 yields a failure with token 9. An untagged GET
yields 0. A watch answered 500 yields a failure with 0. A PATCH with token 7
returns 7 on either outcome.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:72-85`,
`plugin/lib/tailscale/LocalApiClient.cpp:111-116`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:128-139`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:535-586`.

### R-HTTP-13 · parity · A read or write is bounded by a deadline

**Statement.** A read or write that has not completed within the deadline
fails. The default deadline is 10 000 ms. Tests can configure it, and zero or
less disables it. The reason names the deadline in ms, except when a
refused head was already received: that failure's reason is
R-HTTP-09's, with the partial body as its text and no deadline wording. The deadline starts
before the connect and covers connect, headers and body.

**Acceptance.** With paused time and a 50 ms deadline, a fake records
`GET /localapi/v0/status` and never answers. Paused time advances exactly
49 ms from the call; after the read barrier ("Transport outcomes") nothing
has been yielded, no reply and no failure. Paused time advances exactly 1 ms
more; after the read barrier exactly one failure for that path has been
yielded, containing `50 ms`, and no reply. A fake that sends
`Content-Length: 99` and 9 bytes, then stalls: after paused time has advanced
exactly 50 ms from the call and the read barrier, exactly one failure and no
reply. A PATCH of `/localapi/v0/prefs` that the fake records and never
answers likewise: after an advance of exactly 49 ms and the read barrier,
nothing has been yielded; after 1 ms more and the read barrier, exactly one
failure for that path containing `50 ms`, with status 0, and no reply.
With the deadline configured to 0, and in a separate run to -1, a GET of
`/localapi/v0/status` that the fake records and never answers has, after
paused time advances exactly 3 600 000 ms from the call and the read
barrier, no reply and no failure, and the fake's held count is still 1.
With the shipped deadline and no injection, the same held GET has nothing
after an advance of exactly 9 999 ms and the read barrier, and exactly one
failure containing `10000 ms` after 1 ms more and the read barrier.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:34-49`,
`plugin/lib/tailscale/LocalApiClient.h:60-69`,
`plugin/lib/tailscale/LocalApiClient.cpp:135-150`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:440-483`.

### R-HTTP-14 · new · A POST without a body, and a reply with no body

**Statement.** The transport sends `POST <path>` with no body. Like every
request without a body, it carries the Host header and no other (R-HTTP-01).
It ends in the same reply or failure outcomes as a read, under the same
deadline (R-HTTP-13), and carries its caller's token (R-HTTP-12). R-UI-17's
login start is this request. A `204` reply has no body whatever its
headers say: the reply is delivered, with an empty body, as soon as the
blank line that ends its headers has arrived, without waiting for the peer
to close. tailscaled answers a login start `204` and keeps the connection
open, so waiting for the close would end every login start at its deadline.
A `1xx` or `304` answer has no body either, but it is not a reply: it is the
failure R-HTTP-08 gives every status outside 200-299, delivered as soon as
the blank line that ends its headers has arrived, with its numeric status
and the reason `<path> answered <status line>` with no `: <text>` (R-HTTP-09
reads no error body from it, whatever its headers say).

**Acceptance.** When the client POSTs `/localapi/v0/login-interactive`, the
fake records exactly
`POST /localapi/v0/login-interactive HTTP/1.1\r\nHost: local-tailscaled.sock`
before CRLFCRLF, and no byte after it. With paused time and a 50 ms deadline,
a fake that answers `HTTP/1.1 204 No Content\r\n\r\n` and keeps the connection
open yields exactly one reply with an empty body, after the read barrier and
before paused time has advanced at all. Paused time then advances exactly
50 ms, and after the read barrier there is still exactly one reply and no
failure. A POST answered
`HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\n\r\n`, with no body bytes
sent and the connection kept open, yields, after the read barrier and before
paused time has advanced at all, no reply and exactly one failure with
status 304 and the reason exactly
`/localapi/v0/login-interactive answered HTTP/1.1 304 Not Modified`. A POST
answered `HTTP/1.1 100 Continue\r\n\r\n`, kept open, likewise yields no
reply and exactly one failure with status 100 before paused time has
advanced. A POST answered `403` yields, after the read barrier, no reply and
exactly one failure with status 403. A POST with token 7 returns 7 on either
outcome. The recorded-request clause is read after the read barrier and the
fake barrier ("Request counts").

**Sources.** decision 1; `plugin/lib/tailscale/LocalApiClient.h:87-100`
(#286 sends only GET and PATCH), `plugin/lib/tailscale/LocalApiClient.cpp:202`
(#286 waits for the close when a 2xx has neither framing).

### R-HTTP-15 · fix · Response headers are capped at 64 KiB

**Statement.** The response headers of any exchange, the watch included, may
take at most 65 536 bytes, counted from the first byte of the status line up
to and including the CRLFCRLF that ends them. Once 65 537 bytes have arrived
without that CRLFCRLF, the exchange fails at once, without waiting for more
bytes, the close or the deadline. The reason is
`<path> sent response headers longer than 65536 bytes`, the status is 0 and
no reply is delivered. On the watch this is a failure then "ended"
(R-WATCH-04), so the backend treats it as a lost connection with that
`readError` (R-CONN-16).

**Defect.** #286 caps neither buffer, so a peer that never ends its headers
grows the client's memory without bound and is noticed only at the deadline
(on the watch only at establishment). The owner decided to cap it
(decision 21).

**Acceptance.** A GET answered by a header block of exactly 65 536 bytes,
padded with one long `X-Pad:` header, then `Content-Length: 2` and `{}`,
yields, after the read barrier ("Transport outcomes"), exactly one reply `{}`
and no failure. A block that has reached 65 537 bytes with no
CRLFCRLF yields, after the read barrier and with paused time not advanced,
exactly one failure whose reason is
`/localapi/v0/status sent response headers longer than 65536 bytes`, and no
reply. On the backend, with paused time and the shipped timings: the
backend is `Running`, and the fake closes the watch with `0\r\n\r\n`. After
the retry barrier for that loss, whose armed delay is 500 ms (R-CONN-07),
with paused time not advanced, the fake is set to answer the next watch with
such a block and to hold every read of the next attempt, so only the watch
decides it. Paused time then advances exactly 500 ms, the reconnect attempt
runs, and its watch receives the block. After the retry barrier of that
attempt, with paused time not advanced further, `state` is `NoState`,
`readError` contains `longer than 65536 bytes`, and exactly one retry has
been armed since the 500 ms advance, the second, with a delay of
1 000 ms.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:215-218` (headers are
buffered until CRLFCRLF, without a bound), decision 21.

## R-PARSE: status parsing

### R-PARSE-01 · fix · Only a JSON object is a status, and a refusal says why

**Statement.** A `/status` body that is not valid JSON, is empty, or is not a
JSON object yields no status. It never crashes and never yields a partial
status. Any JSON object parses, and each missing key leaves its field empty;
a known field that is `null` or of another type reads as its default too
(R-PARSE-14).
`{}` yields an empty backend state. A body that yields no status says which of
two causes applies: it is not JSON (the empty string included), or it is JSON
that is not an object. R-CONN-04 names each cause in `readError` (decision
14). The tag is `fix` because of that cause: #286's parser reports only
absent or present, so nothing tells the two apart.

**Acceptance.** The bodies `{"Self":` and the empty string each yield no
status, with the cause "not JSON". `[]` and `"x"` each yield no status, with
the cause "not an object". `{}` yields a status with an empty backend state,
no peers and no exit node. No input ends the process. The "no status" and
`{}` clauses hold on `a38dbca`; the cause clauses fail there, because #286
reports no cause.

**Sources.** `plugin/lib/tailscale/StatusParser.h:13-16`,
`plugin/lib/tailscale/StatusParser.cpp:99-104`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:158-162`, decision 14 (the
cause; #286's parser reports only absent or present).

### R-PARSE-02 · parity · Backend state, tailnet name and health list

**Statement.** The status carries `BackendState` verbatim and the tailnet name
from `CurrentTailnet.Name`. It carries every `Health` entry in order. A `Health`
of null or an absent `Health` yields an empty list. Healthy nodes report null.
An entry that is not a string (null, a number, an object) is kept, in its
place, as an empty string, so `issueCount` counts it (R-UI-11).

**Acceptance.** `status-idle.json` yields backend state `Running`, tailnet
`example.com` and exactly one health entry containing `--accept-routes`.
`{"BackendState":"Running","Health":null}` yields an empty list.
`{"BackendState":"Running","Health":["a",null,3]}` yields exactly
`["a","",""]`.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:111`,
`plugin/lib/tailscale/StatusParser.cpp:119-122` (`toString()` of a
non-string is empty),
`plugin/lib/tailscale/Types.h:57-69`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:4`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:118-123`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:96-105`.

### R-PARSE-03 · parity · Addresses split by family

**Statement.** `selfIp4` is the first entry of `Self.TailscaleIPs` without a
colon. `selfIp6` is the first entry with one. Array order does not matter. A
missing family yields an empty string. Peer `ip4` and `ip6` follow the same rule
and are kept as reported.

**Acceptance.** `status-idle.json` yields `selfIp4` `100.115.228.122` and
`selfIp6` `fd7a:115c:a1e0::fd27:82d8`. Listing the IPv6 address first changes
neither. A Self with only IPv4 yields an empty `selfIp6`.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:12-25`,
`plugin/lib/tailscale/StatusParser.cpp:114-115`,
`plugin/lib/tailscale/StatusParser.cpp:141-142`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:114-122`.

### R-PARSE-04 · fix · Key expiry is an RFC 3339 instant; absent means never

**Statement.** `keyExpiry` is `Self.KeyExpiry` read as an RFC 3339 date-time,
the form Go's `time.Time` marshals to:
`YYYY-MM-DDTHH:MM:SS`, an optional fraction of one to nine digits after a
`.`, then `Z` or a `+HH:MM`/`-HH:MM` offset. The instant is kept to the
millisecond; further fraction digits are dropped, not rounded. Any other form
is unparsable, including one without a zone, which Qt's ISO parser in #286
reads as local time. An absent or unparsable value means the key never
expires. The contract then reads an invalid date-time. A tagged node and a
node with expiry disabled both look like this.

**Acceptance.** `status-idle.json`, a real tailscaled capture, yields
`2027-04-11T09:06:08Z`. `2027-04-11T09:06:08.123456789Z` yields
`2027-04-11T09:06:08.123Z`. `2027-04-11T11:06:08+02:00` yields
`2027-04-11T09:06:08Z`. `2027-04-11T09:06:08` (no zone), `2027-04-11` and
`soon` each yield an invalid `keyExpiry`. A Self without `KeyExpiry` yields an
invalid `keyExpiry`, and QML sees an invalid Date.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:117-118`,
`plugin/lib/tailscale/Types.h:67`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:116`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:107-133`,
`plugin/src/contracts/TailscaleBackend.h:125-127`, decision 11 (RFC 3339
instead of Qt's ISO-8601 set; the forms Go writes parse alike in both).

### R-PARSE-05 · parity · Devices are named by DNS label

**Statement.** A device's display name is the first label of its MagicDNS name.
When the MagicDNS name is empty, it is the OS hostname. The same rule gives
`selfName`. A peer's `dnsName` loses its trailing root dot. `hostName` stays the
OS hostname. The parsed Self DNS name is kept whole, root dot included; only the
contract's `selfDnsName` strips the dot (R-UI-07).

**Acceptance.** In `status-idle.json`, the peer with hostName `ip-172-31-0-10`
has displayName `host-5` and dnsName `host-5.example-tailnet.ts.net`. The peer
`xi` has an empty dnsName and displayName `xi`. `selfName` is `host-6`, and the
parsed Self DNS name is exactly `host-6.example-tailnet.ts.net.`, trailing dot
included. A Self with only `HostName: "omega"` yields `selfName` `omega`.

**Sources.** `plugin/lib/tailscale/Types.h:21-27`,
`plugin/lib/tailscale/Types.h:60-66`,
`plugin/lib/tailscale/StatusParser.cpp:27-47`,
`plugin/lib/tailscale/StatusParser.cpp:112-116`,
`plugin/lib/tailscale/StatusParser.cpp:143-145`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:180-227`, `pr286-body:13-15`.

### R-PARSE-06 · parity · A peer's identity is its string ID

**Statement.** A peer's `nodeId` is its string `ID` field. It is never the
public key or the numeric node ID. A peer without `ID` is still listed, with an
empty `nodeId`. `online` and `exitNodeOption` come from `Online` and
`ExitNodeOption`, and read false when absent.

**Acceptance.** In `status-idle.json`, the `gamma` row has nodeId
`nPFCxlUqVJ11CNTRL`, ip4 `100.67.243.58`, ip6 `fd7a:115c:a1e0::8d19:e3a4` and
online true. A peer object without `ID` is listed with an empty nodeId.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:133-149`,
`plugin/lib/tailscale/Types.h:18-35`,
`plugin/lib/tailscale/PeerModel.h:16-18`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:166-187`.

### R-PARSE-07 · fix · A present Peer section differs from an absent one

**Statement.** The status records whether the reply described the peer set
(has a Peer section), judged from both the `Peer` key and `BackendState`. A
`Peer` object always describes it; an empty object is a tailnet with no other
devices. `"Peer": null` in a status whose `BackendState` is `Running` also
describes it, as an empty set: tailscaled's `ipnstate.Status.Peer` is a Go map
with no `omitempty`, and `StatusBuilder.AddPeer` creates it only when the
first peer is added, so a `Running` tailnet with no other devices is
marshalled as `"Peer": null`, never `{}`. An absent `Peer` key, `null` in any
other `BackendState`, or a `Peer` of another JSON type does not describe the
peer set. Every case without a Peer section yields an empty peer list. #286
treats `null` as no Peer section in every state
(`plugin/lib/tailscale/StatusParser.cpp:126-130`), so a single-device tailnet
is never described; the rule above is the fix, and it is what lets
R-GROUP-10, R-GROUP-11 and R-GROUP-12 reach the "known, empty" state
(decisions 6 and 25).

**Acceptance.** `status-idle.json` has a Peer section.
`{"BackendState":"Running"}` has none and yields an empty peer list.
`{"BackendState":"Running","Peer":null}` has one, with no peers.
`{"BackendState":"NeedsLogin","Peer":null}`,
`{"BackendState":"Stopped","Peer":null}` and
`{"BackendState":"NoState","Peer":null}` each have none and yield an empty
peer list. `{"BackendState":"Running","Peer":{}}` has one, with no peers, and
so does `{"BackendState":"Stopped","Peer":{}}`. A `Peer` of another JSON type
is no Peer section in any state:
`{"BackendState":"Running","Peer":[]}`, `"Peer":"x"` and `"Peer":5` each have
none and yield an empty peer list. A Peer entry that is not an object is
dropped (decision 27): `{"BackendState":"Running","Peer":{"k":5}}` has a Peer
section and no peers, and
`{"BackendState":"Running","Peer":{"k":5,"n":{"ID":"nX1CNTRL","HostName":"x"}}}`
has a Peer section and exactly one peer, `nX1CNTRL`. #286 lists such an entry
as a row with every field empty, which cannot be acted on.

**Sources.** `plugin/lib/tailscale/Types.h:72-77`,
`plugin/lib/tailscale/StatusParser.cpp:126-131` (#286 reads only
`isObject()`, so `null` under `Running` is no Peer section),
`plugin/lib/tailscale/StatusParser.cpp:132-150` (#286 turns a non-object
entry into an empty row),
`plugin/lib/tailscale/tests/tst_statusparser.cpp:135-156` (its assertion at
`:150`, `null` under `Running` has no Peer section, pins the defect this
requirement corrects), tailscale `github.com/tailscale/tailscale` at tag `v1.102.5` (commit
`5fb2a81b065b0a0bbbfc67ab20a0d9c6a1108115`),
`ipn/ipnstate/ipnstate.go:79-80` (`Status.Peer`
has no json tag and no `omitempty`) and `ipn/ipnstate/ipnstate.go:461-463`
(`StatusBuilder.AddPeer` creates the map
lazily), decisions 6, 25 and 27.

### R-PARSE-08 · parity · The exit node comes from ExitNodeStatus

**Statement.** An exit node is reported only when `ExitNodeStatus` is an
object. Its id is `ExitNodeStatus.ID`. Its online flag is
`ExitNodeStatus.Online`, never the peer's own `Online`. Through the contract
these are `exitNodeId` and `exitNodeOnline` (R-WATCH-14). #286 also computes
the exit node's IPv4 from `ExitNodeStatus.TailscaleIPs`
(`plugin/lib/tailscale/StatusParser.cpp:165`); R-PARSE-13 keeps that value
in the parsed status.

**Acceptance.** `status-exitnode.json` yields id `nEwJFIats021CNTRL` and
online true. `status-exitnode-offline.json` yields online false,
although the peer reads `Online`. `status-idle.json` and `"ExitNodeStatus":null`
yield no exit node.

**Sources.** `plugin/lib/tailscale/Types.h:37-47`,
`plugin/lib/tailscale/StatusParser.cpp:155-166`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode.json:118`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode-offline.json:118-124`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:229-235`, `pr286-body:39-40`.

### R-PARSE-09 · fix · The exit node is named through its peer, else by its id

**Statement.** `ExitNodeStatus` carries no name. The exit node's name is the
display name of the peer whose `nodeId` equals the exit node's id. When no such
peer is listed, the name is the id itself, never empty while the id is
non-empty. An `ExitNodeStatus` object with no `ID` (or an empty one) yields
an empty id and an empty name. An empty id is never joined to a peer, not
even one listed with an empty `nodeId` (R-PARSE-06), so the bar label and the
blocked alert never name an unrelated device (decision 22). The same holds
for the contract's fallback join in R-WATCH-14.

**Acceptance.** `status-exitnode.json` names the exit node `pentest-exit-node`.
Pointing `ExitNodeStatus` at peer `ip-172-31-0-10` names it `host-5`. Removing
the exit peer names it by its id. `{"BackendState":"Running","ExitNodeStatus":
{"Online":true}}` yields an exit node with an empty id and an empty name. So
does the same status with one peer `{"HostName":"stranger","Online":true}`,
which has no `ID`: the name stays empty, never `stranger`. Through the
contract, `exitNodeName` reads the same strings.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:159-175` (#286 joins on
the id even when it is empty), decision 22,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:54-88`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:229-269`, `pr286-body:39-40`.

### R-PARSE-10 · withdrawn · Mask stripping

Withdrawn and replaced by R-PARSE-13. R-PARSE-10 was withdrawn because the
exit node's IPv4 (`plugin/lib/tailscale/StatusParser.cpp:165`) reaches no
contract member. No owner decision removes the behaviour, though, and the
parsed status and the parsing library's public interface are tested
directly elsewhere (R-PARSE-01 to R-PARSE-09), so R-PARSE-13 states it
against those. #286's three `stripMask` assertions map to R-PARSE-13 (see
the traceability file). The ID R-PARSE-10 is not reused.

**Sources.** `plugin/lib/tailscale/Types.h:44-47`,
`plugin/lib/tailscale/StatusParser.cpp:93-97`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:271-277`.

### R-PARSE-11 · fix · The recommended exit node is the suggestion's ID

**Statement.** `recommendedExitNodeId` is the `ID` field of the latest
`/suggest-exit-node` reply, not its `Name`. It matches a `nodeId` in
`exitNodes`. A failed, empty or malformed reply clears it: a 2xx body that
is not JSON, is JSON but not an object, or is an object whose `ID` is
missing or not a string, as #286 does (its `fromJson().object().value("ID")
.toString()` yields an empty string for each). Such a reply is not a lost
connection (R-CONN-11). `recommendedExitNodeIdChanged`
fires only when the value changes. "Latest" means the outcome of the newest
pass, not the last outcome to arrive (decision 17). Every pass, across
attempts, is numbered in the order it starts. A suggestion outcome, reply or
failure, is applied only when its pass is newer than the pass whose
suggestion outcome was last applied; an outcome from an older pass is
dropped and moves nothing. This holds for a pass a loss abandoned too: its
suggestion outcome is not a snapshot half, so R-WATCH-12's "ignored" does
not apply to it, and it is applied by this rule unless a reconnect has
already closed its connection, in which case it has no outcome
(R-WATCH-12). In #286 a late outcome from an earlier pass, a failure
included, overwrites a newer one.

**Acceptance.** Given `suggest-exit-node.json`, after the idle barrier that
follows the backend reaching `Running`, `recommendedExitNodeId` is
`nEwJFIats021CNTRL` and `recommendedExitNodeIdChanged` has fired exactly once
since the backend was made. When the fake then answers 500
and a notification arrives, after the idle barrier it is empty, `state` is
`Running` and no retry has been scheduled. Arrival order: the fake holds pass N's
`/suggest-exit-node`. A notification starts pass N+1, whose suggestion is
answered with id X. Once the read barrier holds with the client count at
exactly 2 (the watch and the held suggestion; the idle barrier cannot hold
while that outcome is outstanding), `recommendedExitNodeId` reads X. The
held request is then completed with a 500. After the client barrier, `recommendedExitNodeId`
still reads X and `recommendedExitNodeIdChanged` has fired 0 times since it
became X. In a second run the held request is completed with id Y instead;
it still reads X.

Malformed replies, each in a separate run from a published
`nEwJFIats021CNTRL`: the fake answers `/suggest-exit-node` 200 with the body
`x`, `[]` or `{"ID":5}` and pushes `{"Prefs":{}}`. After the idle barrier
`recommendedExitNodeId` is empty, `recommendedExitNodeIdChanged` has fired
exactly once since the push, `state` is `Running`, `readError` is empty and
the retry hook reads 0 retries armed since the push.

**Sources.** `plugin/lib/tailscale/tests/fixtures/suggest-exit-node.json:1`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:340-352`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:677-694` (#286
applies every outcome in arrival order),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:686-689` (a
malformed body yields an empty id),
`plugin/src/contracts/TailscaleBackend.h:75-76`,
`plugin/src/contracts/TailscaleBackend.h:175-180`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:625-652`,
decision 17.

### R-PARSE-12 · parity · One health warning is suppressed

**Statement.** `issues` is the status's health list minus any message
containing `advertising routes but --accept-routes is false`. Every other
message is published verbatim.

**Acceptance.** Both cases run on the backend against the fake. A fake
serving `status-idle.json`, whose only health entry is that warning, brings
the backend to `Running`; after the idle barrier that follows, `issues` is
exactly empty and `issueCount` is exactly 0. In a separate run the fake
serves `status-idle.json` with `DNS is not working` appended to its `Health`
list, after that warning; after the idle barrier that follows the backend
reaching `Running`, `issues` equals exactly `["DNS is not working"]` and
`issueCount` is exactly 1. #286 runs this second case on its public policy
function (`reportableHealth`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:752-763`);
the rewrite need not expose that function, so the case runs on the backend,
which is the observable form of the same policy. The suppression policy is not
empty: the first case proves it through `issues`, which is the observable form
of #286's direct check on its internal list
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:762`). The rewrite need not expose the list
itself.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:67-79`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:219-242`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:631`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:738-763`.

### R-PARSE-13 · parity · Addresses lose their prefix length

**Statement.** The parsing library's public interface (in #286 its public
header `plugin/lib/tailscale/Types.h`, used by the parser and the backend,
not by QML) includes the rule that turns a CIDR-written address into a
bare address: the text before the first `/`, or the whole text when there
is no `/`. It applies to IPv4 and IPv6 alike. The parsed status's exit node
carries an IPv4 address, the first IPv4 entry of
`ExitNodeStatus.TailscaleIPs` passed through that rule. No contract member
publishes that address; it is part of the parsed status, which R-PARSE-01
to R-PARSE-09 also test directly. This replaces the withdrawn R-PARSE-10.

**Acceptance.** The rule maps `100.101.102.103/32` to `100.101.102.103`,
`fd7a:115c:a1e0::aaaa:bbbb/128` to `fd7a:115c:a1e0::aaaa:bbbb`, and
`100.101.102.103` to itself. A status
`{"BackendState":"Running","ExitNodeStatus":{"ID":"nX1CNTRL","Online":true,"TailscaleIPs":["100.101.102.103/32","fd7a:115c:a1e0::aaaa:bbbb/128"]}}`
yields an exit node whose IPv4 is exactly `100.101.102.103`.

**Sources.** `plugin/lib/tailscale/Types.h:44-47`,
`plugin/lib/tailscale/StatusParser.cpp:93-97`,
`plugin/lib/tailscale/StatusParser.cpp:165`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:271-277`.

### R-PARSE-14 · parity · A known field that is null or of another type reads as its default

**Statement.** Inside a `/status` object, a known field that is `null`, or
holds another JSON type than the one it is read as, takes its empty default,
and the rest of the status still parses and publishes. The default follows
the type the field is read as:

- a string field (`DNSName`, `HostName`, `ID`, `LoginName`, `DisplayName`,
  `CurrentTailnet.Name`, `KeyExpiry`) reads as the empty string, so
  `KeyExpiry` reads as an invalid date-time (never expires);
- a bool field (a peer's `Online` and `ExitNodeOption`,
  `ExitNodeStatus.Online`) reads as false; a string `"true"` or a number 1 is
  not true;
- an integer field (`Self.UserID`, a peer's `UserID`) reads as 0; a string
  `"7"` is not 7;
- an object field (`Self`, `User`, `CurrentTailnet`, one `User` entry) reads
  as an empty object, so every field read through it takes its default;
- an array field (`Health`, `Self.TailscaleIPs`, a peer's `TailscaleIPs`,
  `ExitNodeStatus.TailscaleIPs`) reads as an empty array, so no health entry
  and no address.

Real tailscaled sends such nulls: `ipnstate.Status.CurrentTailnet` is a
pointer with no `omitempty`, so it is `null` while logged out, and `User`,
`Self.TailscaleIPs` and a peer's `TailscaleIPs` are nil maps or slices, so
they are `null`. A parser that rejected the whole body for one such field
would turn a logged-out daemon into a permanent R-CONN-04 loss and make the
login flow (R-UI-17) unreachable.

This is parity: #286's lenient reading, field by field, kept unchanged. No
decision makes any of these fields fail closed. The rules that do judge a
`/status` more strictly are each their own requirement, and none of them is
this one:

- the body as a whole (R-PARSE-01, R-CONN-04): a `BackendState`
  that is `null` or not a string reads as empty here, and R-CONN-04 then
  rejects the status as `answered without a BackendState`, as #286 does;
- a `BackendState` string that is not a known state (R-WATCH-13, decision
  23): a named `readError`. Decision 23 covers an unrecognised value, not a
  wrong type, so it does not reach the fields above;
- the `Peer` section and its entries (R-PARSE-07), and `ExitNodeStatus` as
  a section (R-PARSE-08) and its empty id (R-PARSE-09).

Decision 16 is the `/prefs` counterpart and is narrower than it looks: it
fails closed only on a `/prefs` body that is not a JSON object (R-CONN-14).
Inside a prefs object a known field of another type still reads as its
default, as here.

**Acceptance.** Parser, one case per field type, each with every other
field of the status parsed as normal:

- String and object, `null`:
  `{"BackendState":"NeedsLogin","CurrentTailnet":null,"User":null,"Self":{"TailscaleIPs":null,"KeyExpiry":5,"UserID":"7","DNSName":null,"HostName":"h"}}`
  yields a status with backend state `NeedsLogin`, an empty tailnet,
  `selfName` `h`, an empty `selfDnsName`, empty `selfIp4` and `selfIp6`, and
  an invalid key expiry.
- String and bool, wrong type:
  `{"BackendState":"Running","Peer":{"n":{"ID":"nX1CNTRL","HostName":"x","TailscaleIPs":null,"Online":"yes","ExitNodeOption":null,"DNSName":5}}}`
  yields exactly one peer, `nX1CNTRL`, with empty `ip4`, `ip6` and
  `dnsName`, `displayName` `x`, and `online` and `exitNodeOption` false.
  The same peer with `"Online":1,"ExitNodeOption":"true"` gives `online`
  and `exitNodeOption` false too.
- Integer, wrong type and `null`:
  `{"BackendState":"Running","Self":{"UserID":7},"User":{"7":{"LoginName":"me@example.com"}},"Peer":{"a":{"ID":"nA","HostName":"a","UserID":"7"},"b":{"ID":"nB","HostName":"b","UserID":null}}}`
  yields exactly two peers, `nA` and `nB`. Each reads user id 0, so neither
  is in Mine: both are in Others, each with an empty `ownerName` (no `User`
  entry `"0"`). The same status with `"Self":{"UserID":null}` and the peers'
  `UserID` 0 puts both in Mine.
- Object, wrong type:
  `{"BackendState":"Running","Self":"me","CurrentTailnet":["t"],"User":5,"Peer":{"n":{"ID":"nX1CNTRL","HostName":"x","UserID":3}}}`
  yields a status with backend state `Running`, an empty `selfName`,
  `selfDnsName`, `selfIp4` and `selfIp6`, an empty tailnet and an invalid
  key expiry, and exactly one peer, `nX1CNTRL`, in Others with an empty
  `ownerName`. A `User` entry that is not an object,
  `"User":{"3":"Alice"}` with the same peer, gives the same `ownerName`,
  empty.
- Array, wrong type:
  `{"BackendState":"Running","Health":"bad","Self":{"HostName":"h","TailscaleIPs":"100.64.0.1"},"Peer":{"n":{"ID":"nX1CNTRL","HostName":"x","TailscaleIPs":{"v4":"100.64.0.2"}}},"ExitNodeStatus":{"ID":"nX1CNTRL","Online":true,"TailscaleIPs":"100.64.0.2/32"}}`
  yields an empty health list, `selfName` `h` with empty `selfIp4` and
  `selfIp6`, one peer `nX1CNTRL` with empty `ip4` and `ip6`, and an exit
  node with id `nX1CNTRL`, name `x`, online true and an empty IPv4.
- `ExitNodeStatus` fields:
  `{"BackendState":"Running","ExitNodeStatus":{"ID":5,"Online":"true"}}`
  yields an exit node with an empty id, an empty name and online false,
  which fails closed (R-WATCH-14).

Backend half: a fresh backend whose fake serves the first case's status and
`prefs.json`. After the idle barrier `state` is `NeedsLogin`, `readError` is
empty, `selfName` is `h`, `selfIp4` and `tailnet` are empty, and the
retry hook reads 0 retries armed. A second run serves the object case's
status: after the idle barrier `state` is `Running`, `readError` is empty,
`selfName` and `tailnet` are empty, the retry hook reads 0 retries armed,
and the `peers` model has exactly one row, `nX1CNTRL`.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:106-175` (every field is
read with `toObject()`, `toArray()`, `toString()`, `toBool()` or
`toInteger()`, each of which returns its default for `null` or another
type; the integer reads at `:58` and `:125`),
`plugin/lib/tailscale/StatusParser.cpp:17-25` (a non-array `TailscaleIPs`
yields no address), `plugin/lib/tailscale/StatusParser.cpp:55-66` (grouping
by the integer `UserID` and the `User` entry), tailscale `github.com/tailscale/tailscale` at tag `v1.102.5` (commit
`5fb2a81b065b0a0bbbfc67ab20a0d9c6a1108115`),
`ipn/ipnstate/ipnstate.go:65-67` (`Status.CurrentTailnet` is a pointer without
`omitempty`) and `ipn/ipnstate/ipnstate.go:84` (`Status.User` is a map
without `omitempty`), decisions 16 and 23 (each named to say it does not reach
these fields).

## R-GROUP: peer model

### R-GROUP-01 · parity · Three groups: Mine, Tagged, Others

**Statement.** A peer is Tagged when its owner's `LoginName` is
`tagged-devices`; that test comes first. It is Mine when its `UserID` equals
`Self.UserID`. Otherwise it is Others. Tags are not read. Views see the group as
an integer: 0 Mine, 1 Tagged, 2 Others.

**Acceptance.** `status-idle.json` yields 10 peers in group 0, 8 in group 1 and
2 in group 2. The `gamma` row's group role reads 1.

**Sources.** `plugin/lib/tailscale/Types.h:12-14`,
`plugin/lib/tailscale/StatusParser.cpp:49-66`,
`plugin/lib/tailscale/StatusParser.cpp:124-125`,
`plugin/lib/tailscale/PeerModel.cpp:52-55`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:1025-1046`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:164-170`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:184`, `pr286-body:13-14`.

### R-GROUP-02 · parity · The owner is named only for other users' devices

**Statement.** `ownerName` is the owner's `DisplayName` for group Others. It is
empty for Mine and Tagged, whose headings already say who owns them.

**Acceptance.** In `status-idle.json`, `beta` has group 2 and ownerName
`Second Example`. Every Mine row has an empty ownerName.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:53-65`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:1026-1030`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:172-178`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:188-200`.

### R-GROUP-03 · fix · One total order for the device list

**Statement.** Peers sort by group, then online before offline, then display
name case-insensitively, then host name case-insensitively, then `nodeId`. The
JSON member order carries no meaning. "Case-insensitively" is defined
without Qt (decision 10): map each Unicode scalar value of both strings
through its full Unicode lowercase mapping, then compare the resulting
sequences of scalar values lexicographically, a shorter prefix first.
`nodeId` compares by its scalar values exactly. For ASCII text this is the
order #286 produces. Beyond ASCII it is a deliberate difference: #286 folds
case per UTF-16 unit with Qt's tables, and the rewrite does not reproduce
that.

**Acceptance.** `status-idle.json` puts a group-0 row first, and the last
group-0 row is offline. Two online peers with the same name, `nAAA1CNTRL` and
`nBBB1CNTRL`, sort `nAAA1CNTRL` first. Hand-built peers in any input order come
out in the defined order. The set includes names equal except for case, empty
names, and peers equal except for `nodeId`. Four online group-0 peers named
`Émile`, `zoe`, `éclair` and `Zürich`, in that input order, sort `zoe`,
`Zürich`, `éclair`, `Émile`; #286 sorts these the same way, so this case
pins only that common ground. Two non-ASCII fixtures pin the decided
difference, each with two online group-0 peers given in the input order
shown and equal in every other sort key:

- Display names `\u{1F642}a` (U+1F642, outside the Basic Multilingual Plane,
  so two UTF-16 units starting `0xD83D`) and `\u{FF5A}a` (U+FF5A, fullwidth
  small z, one unit `0xFF5A`): the rewrite sorts `\u{FF5A}a` first, because
  scalar U+FF5A is less than U+1F642. #286 sorts `\u{1F642}a` first, because
  unit `0xD83D` is less than `0xFF5A` (Qt 6's
  `QString::compare(..., Qt::CaseInsensitive)` returns a negative value for
  `\u{1F642}a` against `\u{FF5A}a`).
- Display names `\u{0130}x` (U+0130, capital I with dot above) and
  `i\u{0307}y` (`i` then U+0307, combining dot above): the full Unicode
  lowercase of U+0130 is `i` U+0307, so the rewrite compares `i`, U+0307,
  `x` against `i`, U+0307, `y` and sorts `\u{0130}x` first. #286 folds
  U+0130 to itself, compares U+0130 against `i`, and sorts `i\u{0307}y`
  first.

Both fixtures fail on `a38dbca`, for the reason decision 10 records.

**Sources.** `plugin/lib/tailscale/Types.h:49-55`,
`plugin/lib/tailscale/StatusParser.cpp:70-91`,
`plugin/lib/tailscale/StatusParser.cpp:151-153`,
`plugin/lib/tailscale/PeerModel.h:46-48`,
`plugin/lib/tailscale/PeerModel.cpp:94-97`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:99-105`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:120-125`, decision 10 (#286's
`QString::compare` with `Qt::CaseInsensitive` at
`plugin/lib/tailscale/StatusParser.cpp:70-91` is replaced beyond ASCII).

### R-GROUP-04 · parity · Ten named roles

**Statement.** Each row of `peers` and `exitNodes` exposes exactly ten roles:
`hostName`, `displayName`, `ip4`, `ip6`, `dnsName`, `online`, `group` (int),
`ownerName`, `nodeId` and `exitNodeOption`. No default Qt role is exposed.

**Acceptance.** The role-name table has exactly these 10 entries. In
`status-idle.json`, `pentest-exit-node` has exitNodeOption true and `beta`
false. The `gamma` row returns hostName `gamma`, dnsName
`host-1.example-tailnet.ts.net`, displayName `host-1` and group 1, plus the
nodeId, ip4, ip6 and online values pinned in R-PARSE-06.

**Sources.** `plugin/lib/tailscale/PeerModel.h:23-38`,
`plugin/lib/tailscale/PeerModel.cpp:34-81`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:166-220`.

### R-GROUP-05 · parity · A flat list with nothing off the end

**Statement.** The model is a flat list. A new model has zero rows. Reading off
the end, reading an unknown role, or asking for children of a row yields
nothing.

**Acceptance.** A new model has 0 rows. With three peers, row 99 returns no
value, row 0's display role returns no value, and row 0 has 0 children.

**Sources.** `plugin/lib/tailscale/PeerModel.cpp:26-37`,
`plugin/lib/tailscale/PeerModel.cpp:62-64`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:221-230`.

### R-GROUP-06 · parity · Rows are diffed by nodeId and never reset

**Statement.** Replacing the peer list never resets the model. Rows are keyed by
`nodeId`. A peer still present keeps its row and therefore its QML delegate and
that delegate's local state. Gone peers are removed. New peers are inserted at
their sorted place. A peer whose place changed is moved. Two peers with one
hostName and two nodeIds are two rows. A role update reaches the delegate of the
row it changed, and no other delegate.

**Acceptance.** The model's list replacement is synchronous: the replacement call
returning is the barrier, since every model signal it emits is emitted
before it returns, and every count and every "no ..." below is read
right after that call returns, counting from just before it was made. With rows nAAA and nBBB both online, nAAA going offline keeps 2
rows. It emits one `rowsMoved`, no reset, no insert and no remove. Setting
alpha, bravo, charlie over alpha, charlie emits one `rowsInserted` at row 1. The
reverse emits one `rowsRemoved`. In QML, the bravo delegate survives a re-sort,
a join and a leave as the identical object with its local state. Rebuilding
the model, by clearing it and filling it again as the harness's `seedPeers`
does, yields a new delegate without that state. In the same update that moves bravo, alpha's delegate
reads `online` false and gamma's delegate, which did not move, reads its new
`ip4` `100.64.0.9` while bravo's still reads `100.64.0.2`.

**Sources.** `plugin/lib/tailscale/PeerModel.h:10-18`,
`plugin/lib/tailscale/PeerModel.cpp:92-149`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:87-153`,
`tests/tailscale-qml-test.qml:1644-1767`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml:14-18`.

### R-GROUP-07 · parity · Only changed rows announce; neighbours leave together

**Statement.** A row whose visible fields are unchanged emits no
`dataChanged`. Setting an identical list emits nothing. A changed row emits
`dataChanged` for itself only; a flip of its `online` flag is such a change.
Neighbouring rows that leave together go in one removal. Emptying the list
removes everything without a reset.

**Acceptance.** The model's list replacement is synchronous: the replacement call
returning is the barrier, since every model signal it emits is emitted
before it returns, and every count and every "no ..." below is read
right after that call returns, counting from just before it was made. Setting the same three peers again emits 0 `dataChanged`.
Setting an empty list leaves 0 rows, one `rowsRemoved` and no reset. Changing
one row's ownerName emits one `dataChanged` for that row only. With rows
`nAAA1CNTRL` and `nBBB1CNTRL` online, `nAAA1CNTRL` going offline emits
exactly one `dataChanged`, for `nAAA1CNTRL`'s row at its new place (row 1,
after the one `rowsMoved` of R-GROUP-06 put `nBBB1CNTRL` at row 0) and for
no other row, keeps 2 rows and emits no reset.

**Sources.** `plugin/lib/tailscale/PeerModel.cpp:12-22`,
`plugin/lib/tailscale/PeerModel.cpp:104-116`,
`plugin/lib/tailscale/PeerModel.cpp:145-148`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:87-97`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:154-161`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:251-262`.

### R-GROUP-08 · parity · Rows equal the new list, even with duplicate ids

**Statement.** After any replacement, the rows equal the new sorted list field
for field. This holds when several peers share a `nodeId`, such as several
with no `ID`.

**Acceptance.** The model's list replacement is synchronous: the replacement call
returning is the barrier, since every model signal it emits is emitted
before it returns, and every count and every "no ..." below is read
right after that call returns, counting from just before it was made. Over two peers with empty ids, alpha and bravo, setting alpha
alone leaves 1 row titled alpha. It emits one `rowsRemoved`. A property test
over random list sequences always leaves the rows equal to the latest sorted
list, with no reset. Its generator runs from a fixed seed written in the test,
over a fixed number of sequences, so all 50 runs of the gate see the same
inputs. A failure prints the seed and the shrunk sequence.

**Sources.** `plugin/lib/tailscale/PeerModel.cpp:151-160`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:231-250`.

### R-GROUP-09 · parity · exitNodes is the exit-capable subset

**Statement.** `exitNodes` is a separate model from `peers`, with the same
roles and the same stable-row behaviour. It holds exactly the peers whose
`exitNodeOption` is true, in the same order. It updates from the same snapshot
as `peers`.

**Acceptance.** Given a fake serving `status-idle.json`, after the idle
barrier that follows the backend reaching `Running`, `state` is `Running`
and `exitNodes` has exactly 2 rows,
each with exitNodeOption true. It is a different object from `peers`. Its rows
equal the `peers` rows filtered on exitNodeOption, in the same order.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:166-173`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:665-671`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:865-876`.

### R-GROUP-10 · fix · Rows change only from a status that describes the tailnet

**Statement.** `peers` and `exitNodes` change only from a `/status` that has a
Peer section (R-PARSE-07). A status without one leaves both models as they
were. A Peer section with no peers clears them: an empty Peer object, and
`"Peer": null` under `Running`, which is how tailscaled reports that the last
other device has left. In #286 a `null` never counts, so once the last other
device leaves, the stale rows, and the exit nodes that can still be clicked,
stay for good (decision 25: rows are replaced by the next `Running` status).

**Acceptance.** With 20 peers shown, a notification that brings a status
without a `Peer` key makes the fake record a second GET of `/status`. After the
idle barrier, 20 rows remain, with no `rowsRemoved`, and `state`
`Running`. A later status with `"Peer":{}` leaves 0 rows in both models. In a
second run, from `Running` with 20 peers and 2 exit nodes, the fake serves
the same status with `"Peer":null` (`BackendState` still `Running`) and
pushes `{"Prefs":{}}`. After the idle barrier `peers` and `exitNodes` each
have 0 rows, `peersKnown` reads true and `state` is `Running`. The second run
fails on `a38dbca`, which keeps the 20 rows.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:655-671`
(#286 replaces rows only from a Peer object), decision 25, R-PARSE-07's
tailscaled source,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:654-699`,
the second read at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:677`.

### R-GROUP-11 · fix · "No other devices" needs a reply that described the peers

**Statement.** The panel claims "no other devices on this tailnet" only after a
`/status` reply carried a Peer section that was empty (R-PARSE-07; on a real
single-device tailnet that is `"Peer": null` under `Running`). Until any reply has
described the peer set, the peer set is unknown. The panel then makes no claim
about the device count, and an empty device list shows one row,
`ts-peer-unknown`, reading `Devices not known yet` (decision 6). The contract carries "the peer
set is known" to QML as the read-only bool property `peersKnown` of
`Tailscale`, with its own change signal `peersKnownChanged`, listed under
"Contract additions". It is false on a fresh backend, becomes true in the
snapshot whose `/status` first carries a Peer section (R-PARSE-07: a `Peer`
object, or `"Peer": null` under `Running`), and stays true from
then on: a later status without a Peer section, a non-`Running` status
without a Peer section (R-GROUP-12) and a lost connection (R-CONN-06) all
leave it as it was, like the rows (R-GROUP-10). It never goes from true to
false. It is a snapshot property, stored with the rest of the
snapshot before any change signal fires (R-UI-06).

One rule covers both the shipped backend and the stand-in:
`ts-peer-unknown` shows only while the model is empty, and the `ts-peer`
rows are drawn from the model whatever `peersKnown` reads. So rows seeded on
a stand-in whose `peersKnown` is still false are drawn as rows, and
`ts-peer-unknown` is never drawn beside them.

These view rules hold while `state` is `Running`; in every other state
R-GROUP-12 governs, and the device list draws none of `ts-peer-unknown`,
`ts-peer-empty` or `ts-peer-no-match`, whatever `peersKnown` reads. While
`state` is `Running`, the `ts-peer` rows are drawn from the model whatever
`peersKnown` reads: `peersKnown` gates only the messages and the count,
never a row. While `state` is `Running` and `peersKnown` is false, the
device list shows `ts-peer-unknown` exactly while the model is empty, never
shows `ts-peer-empty` or `ts-peer-no-match`, and `ts-devices-count` is
hidden too. The shipped backend never publishes rows with `peersKnown`
false (rows come only from a status with a Peer section, R-GROUP-10), so
rows with `peersKnown` false occur only on the QML stand-in, whose fresh
`peersKnown` is false (R-QML-30); the parity view criteria that seed peers
on it (R-QML-09, R-QML-10, R-QML-12, R-QML-14, R-GROUP-06, R-SEC-03) hold
as written. That count is not part of the device
list: it is the Text on the root card's `ts-devices-row`
(`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:580`), so it is hidden whether or not the list is
open. While `state` is `Running` and `peersKnown` is true,
`ts-peer-unknown` is hidden, an empty model shows exactly one
`ts-peer-empty` ("no other devices on this tailnet") and no
`ts-peer-no-match`, and R-QML-13 governs the rest.

**Defect.** "A `/status` carrying `BackendState` and no `Peer` key makes the
panel state 'no other devices on this tailnet' — a positive claim about a
tailnet from a reply that never described it." At `a38dbca` the backend keeps
earlier rows (R-GROUP-10). The claim still appears when no reply has ever
carried a Peer section, because the empty-row test is `peerList.count === 0`.

**Acceptance.**

- **Backend half.** A fresh backend reads `peersKnown` false. Given a fake
  whose first `/status` is `{"BackendState":"Running","Self":{...}}` with no
  `Peer` key, after the idle barrier `state` is `Running`, `peers` has 0 rows
  and `peersKnown` reads false. The fake then serves the same status with
  `"Peer":null`, the shape tailscaled sends for a `Running` tailnet with no
  other devices, and pushes `{"Prefs":{}}`. After the idle barrier
  `peersKnown` reads true, `peersKnownChanged` fired exactly once, and
  `peers` still has 0 rows. In a separate run the same sequence with
  `"Peer":{}` in place of `"Peer":null` gives the same values. A third status without a `Peer` key, after a notification and the
  idle barrier, leaves it true with `peersKnownChanged` fired 0 more times.
  The fake then serves `{"BackendState":"NeedsLogin","Self":{...}}` with no
  `Peer` key and pushes `{"Prefs":{}}`; after the idle barrier `state` is
  `NeedsLogin`, `peersKnown` is still true and `peersKnownChanged` has fired
  0 times since the push. The same holds for a following
  `{"BackendState":"Stopped","Self":{...}}` with no `Peer` key.
  Destroying the fake then leaves it true after the retry barrier. In a
  separate run, a fresh backend whose first `/status` is
  `{"BackendState":"NeedsLogin","Self":{...}}` with no `Peer` key (and in a
  third run with `"Peer":null`, which outside `Running` describes nothing)
  reads,
  after the idle barrier, `state` `NeedsLogin`, `peersKnown` false and
  `peersKnownChanged` fired 0 times; after a `{"Prefs":{}}` push that brings
  `{"BackendState":"Stopped","Self":{...}}`, again with no `Peer` key, and
  the idle barrier, `peersKnown` is still false and `peersKnownChanged` has
  still fired 0 times.
- **View half.** On the QML stand-in (R-QML-25) with `state` `Running`, 0
  peers and the device list open: with `peersKnown` false, `ts-peer-unknown`
  is visible and reads `Devices not known yet` as plain text, and
  `ts-peer-empty`, `ts-peer-no-match` and `ts-devices-count` are not visible,
  also with a device query typed. Setting `peersKnown` true hides
  `ts-peer-unknown` and shows exactly one `ts-peer-empty`, with no
  `ts-peer-no-match`. Rows are not gated: with `peersKnown` false again and
  two peers seeded, exactly two `ts-peer` rows are visible, and
  `ts-peer-unknown`, `ts-peer-empty` and `ts-devices-count` are not
  visible; seeding zero peers then shows `ts-peer-unknown` again.
- **The #286 check this replaces.** #286 stages zero peers by clearing the
  query and seeding an empty list on a stand-in that has no `peersKnown`,
  and asserts exactly one `ts-peer-empty`
  (`tests/tailscale-qml-test.qml:961`). That holds on `a38dbca` only because
  of this defect: nothing there tells "known empty" from "unknown". On the
  rewrite's stand-in the same staging, with `peersKnown` left at its fresh
  value false, shows `ts-peer-unknown` and no `ts-peer-empty`; only with
  `peersKnown` true is `ts-peer-empty` shown, exactly once. The first half
  fails on `a38dbca`, which has no `ts-peer-unknown`.

**Sources.** `pr286-body:116-118`, decision 6,
`tests/tailscale-qml-test.qml:958-961` (the zero-peer staging and the
`ts-peer-empty` check that pins the defect),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:659-671`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:729-741`,
`plugin/lib/tailscale/StatusParser.cpp:126-131` (#286 never counts
`"Peer": null`, which is what a single-device tailnet sends; R-PARSE-07).

### R-GROUP-12 · fix · Rows from an earlier session are kept but not shown outside Running

**Statement.** R-GROUP-10 holds in every state. A `/status` that reports
`NeedsLogin`, `NeedsMachineAuth` or `Stopped` with no Peer section, as
tailscaled sends once it has no netmap, leaves `peers` and `exitNodes` as an
earlier status described them, so they are back at once on a quick resume,
until the next `Running` status replaces them. Every `Running` status that
has a Peer section replaces them, `"Peer": null` included (R-PARSE-07): on a
resume into a tailnet that is now empty, that `null` clears both models. A
`Running` status with no `Peer` key keeps them (R-GROUP-10). The views
do not show them outside `Running` (decision 25): while `state` is
`NeedsLogin`, `NeedsMachineAuth`, `Stopped` or `Starting`, the device list
draws no `ts-peer` row and none of `ts-peer-empty`, `ts-peer-no-match` or
`ts-peer-unknown`, the root card's `ts-devices-row` shows no
`ts-devices-count` (a count of an earlier session's rows would be the same
stale claim; #286 shows it in those states,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:579-585`), and the exit-node list draws no `ts-exit-row`, no
`ts-exit-recommended` and no `ts-exit-recommended-label`. `ts-exit-none`
stays in those four states, so an exit node can still be turned off. No
error is shown. In `NoState` this requirement adds nothing: R-QML-05 hides
the device list and the whole exit sub-card, `ts-exit-none` included. In #286 the panel gates both lists on live
alone, so it keeps showing the previous session's rows with their last online
dots, and keeps offering those exit nodes, as if current.

**Acceptance.** Two halves. Backend half: from `Running` with 20 peers and 2
exit nodes, a notification brings `{"BackendState":"NeedsLogin","Peer":null}`
as the next `/status`. After the idle barrier, `state` is `NeedsLogin`,
`peers` has 20 rows, `exitNodes` has 2, and no `rowsRemoved` fired on either
model. The fake then serves `{"BackendState":"Running","Self":{...},"Peer":null}`
and pushes `{"Prefs":{}}`; after the idle barrier `state` is `Running`,
`peers` and `exitNodes` each have 0 rows and `peersKnown` is true. View
half: on the stand-in with `state` `NeedsLogin`, `peersKnown`
true, 20 seeded peers and the two exit peers, clicking `ts-devices-row` shows
no `ts-peer` row and no `ts-peer-empty`; clicking `ts-exit-row-entry` shows no
`ts-exit-row` and no `ts-exit-recommended`, and shows `ts-exit-none`;
`ts-devices-count` is not visible, with the device list open and with it
closed. The same holds for `Stopped`, `NeedsMachineAuth` and `Starting`: in
particular, with `state` `Stopped`, `peersKnown` true and 20 peers,
`ts-devices-count` is not visible. Setting `state` to
`Running` then shows 20 `ts-peer` rows with the device list open. In a
further view run, a daemon that first reports `NeedsLogin` without a Peer
section is staged as `state` `NeedsLogin`, `peersKnown` false and 0 peers:
with the device list open, `ts-peer-unknown`, `ts-peer-empty` and
`ts-peer-no-match` are all not visible. Setting `state` to `Running` then
shows `ts-peer-unknown` (R-GROUP-11). Each "no" and "not visible" in the view
half is read after the layout pass that follows the last property set or
click, as R-QML-13 reads its negatives.

**Sources.** decision 25, `plugin/lib/tailscale/StatusParser.cpp:126-131`
(#286 never counts `"Peer": null`, so a resume into an empty tailnet keeps
the earlier rows),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:655-671`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:47`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:579-585` (the
count on the root row),
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:597`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:774`.

## R-WATCH: IPN bus

### R-WATCH-01 · parity · The watch asks for mask 18, so private keys are stripped

**Statement.** The watch is `GET /localapi/v0/watch-ipn-bus?mask=18`. That is
NotifyInitialState (2) plus NotifyNoPrivateKeys (16). The engine-updates bit (1)
is never requested. tailscaled therefore strips private key material from
every notification.

**Acceptance.** When the client starts a watch, then after the read barrier
and the fake barrier ("Request counts") the fake has recorded exactly one
request, `GET /localapi/v0/watch-ipn-bus?mask=18 HTTP/1.1`, with the Host
header. Read as
an integer, the mask has bit 16 set and bit 1 clear.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:11-41`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:302-324`.

### R-WATCH-02 · parity · The watch says when it is established

**Statement.** A watch emits "started" exactly once, when its accepted head
(a 2xx head) arrives, before any event. A read never emits it. A refused watch, or one that
fails before its head, never emits it.

**Acceptance.** A watch answered `200` that then gets two lines emits started,
event, event, with one started. A watch answered 403 ends with no started. A GET
answered 200 emits no started. Every count and every "no started" is read
after the read barrier, never just after the exchange's own failure, ended
or reply.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:135-143`,
`plugin/lib/tailscale/LocalApiClient.cpp:235-245`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:246-300`.

### R-WATCH-03 · parity · One event per complete notification line

**Statement.** After de-framing, the watch body splits on LF. Each complete,
non-empty line becomes one event, in order, without a trailing CR. A partial
line waits for its newline. Empty lines emit nothing. Bytes after the last
newline at stream end are discarded.

**Acceptance.** Every event count below is read after the read barrier
("Transport outcomes") that follows its push, and counts the events
delivered since that push. Pushing `{"a":1}\n{"b":2}\n` yields exactly two
events, `{"a":1}` then `{"b":2}`. Pushing
`{"half":` yields no event. Pushing `1}\n` then
yields exactly one event, whose bytes are exactly `{"half":1}`. Pushing
`\n\r\n` yields no event. Pushing
`{"c":3}\r\n` yields exactly one event, whose bytes are exactly `{"c":3}`.
Bytes after the last newline at stream end:
on a chunked watch, pushing `a\r\n{"tail":1}\r\n` and then `0\r\n\r\n`
yields, after the read barrier, exactly one ended, no failure and no event
carrying `{"tail":1}`. On a watch answered without either framing, pushing
`{"tail":1}` and then closing that client from the fake's side (R-FAKE-03)
yields, after
the read barrier, exactly one ended, no failure and no event. Setup, not
acceptance: each case waits until the fake has recorded the watch before
the first push.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:144-152`,
`plugin/lib/tailscale/LocalApiClient.cpp:310-331`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:227-244`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:326-342`.

### R-WATCH-04 · parity · A clean end differs from a failure

**Statement.** A watch whose stream ends normally emits "ended" once. Ending
normally means the peer closed after an accepted head (the watch had
emitted "started", R-WATCH-02), or the zero-size chunk of a 2xx stream
arrived. A watch that ends badly emits a failure, then "ended", once each. Bad
endings include a refused status, a transport error, bad framing, a close
before headers and the establishment deadline. A watch answered with a
status outside 200-299 always ends badly, whether its error body ends at a
close, at its zero chunk, at its declared length or at the deadline
(R-HTTP-09, R-WATCH-05).

**Acceptance.** On a chunked watch, `0\r\n\r\n` yields one ended and no
failure. On an established watch, destroying the fake yields one ended and no
failure. A watch answered 403 yields exactly failure, then ended. On a
chunked watch that has started and delivered one event, pushing `zz\r\n`
yields exactly one failure whose reason contains `zz`, then one ended, and no
ended before the failure. In a separate run, pushing `2\r\nabXY` after one
event likewise yields exactly one failure, then one ended. A watch whose fake
closes after recording the request and before sending any header yields
exactly one failure whose reason contains `before the response headers`, then
one ended. Each count is taken after the read barrier. Setup, not
acceptance: the first case waits until the fake has recorded the watch, the
second until the fake's client count is 1, and the framing cases until the
first event has been delivered.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:26-31`,
`plugin/lib/tailscale/LocalApiClient.h:112-115`,
`plugin/lib/tailscale/LocalApiClient.cpp:194-200`,
`plugin/lib/tailscale/LocalApiClient.cpp:273-279`,
`plugin/lib/tailscale/LocalApiClient.cpp:297-303`,
`plugin/lib/tailscale/LocalApiClient.cpp:346-354`,
`plugin/lib/tailscale/LocalApiClient.cpp:393-417`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:386-438`.

### R-WATCH-05 · parity · The watch deadline covers establishment only

**Statement.** A watch whose head misses the deadline emits a failure saying
the stream did not start, then "ended". It never emits "started". The
deadline is turned off only at an accepted head, the moment "started" fires
(R-WATCH-02). A non-2xx watch reply is a refused head, never an accepted
one, so the watch deadline (the request deadline, R-HTTP-13) stays on while
its error body is read. What is kept of that body is bounded by R-HTTP-09's
512-byte reason cap, and how long it is read is bounded by that deadline.
So a non-2xx watch whose body never finishes (it stalls, or has neither
framing and the peer keeps the connection open) still fails by the
deadline, with R-HTTP-09's reason and its status, then "ended"; one whose
body finishes earlier fails at the body's end the same way. R-HTTP-09 states
and tests that case, because in #286 such a watch fails as soon as its head
arrives and reads no body; this requirement's own acceptance covers only
the parity cases. An established watch may stay silent
indefinitely and still delivers later events.

**Acceptance.** With paused time and a 50 ms deadline, a watch the fake never
answers: after an advance of exactly 49 ms from the call and the read
barrier ("Transport outcomes"), no failure, no "ended" and no "started" has
been delivered. After a further advance of exactly 1 ms (50 ms in all) and
the read barrier, exactly one failure then exactly one "ended" have been
delivered, in that order, and no "started"; the reason contains
`did not start within 50 ms` (#286's text is
`the watch stream did not start within <N> ms`, with N the deadline in ms).
A watch answered `200` yields started. Advancing paused time by
3 600 000 ms after that, then the read barrier, yields 0 failures and
0 "ended" signals. A later line `{"State":6}` then yields, after the read
barrier, exactly one event, whose bytes are exactly `{"State":6}`.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:43-49`,
`plugin/lib/tailscale/LocalApiClient.cpp:142-147`,
`plugin/lib/tailscale/LocalApiClient.cpp:235-239`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:485-533`.

### R-WATCH-06 · parity · Stopping is silent and complete

**Statement.** Stopping or destroying the client closes every exchange and the
watch. Nothing is emitted afterwards for any of them. A request stopped before
its deferred connect never connects. A handler of "started" or of an event may
stop the client, and no later signal follows for that watch.

**Acceptance.** On an established watch, stopping drops the fake's client count
to 0. After the client barrier at 0 and the read barrier, no ended and no
failure was emitted. A GET stopped before the loop runs makes no connection and no outcome. Right
after the stop returns, the transport reports no exchange open and no connect
scheduled for that client (the read barrier's report, which counts a scheduled
connect as waiting). The read barrier then holds. A second client, created
after the stop, then GETs from the same fake and its reply arrives. Only after
that reply, which the event loop delivered after any connect the first client
had deferred, is the negative read: the fake (R-FAKE-07) has accepted exactly one client in
all, the second one, and the first client has delivered no reply and no
failure. A handler that stops
on the first of two lines in one read sees, after the read barrier, one event
and no ended. A handler of "started" that stops the client: the fake answers
the watch with `HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n`
followed, in the same push, by `8\r\n{"a":1}\n\r\n`. After the read barrier,
exactly one started was emitted, and no event, no ended and no failure, and
the fake's client count reads 0 after the client barrier at 0. Setup, not
acceptance: the first case waits until the fake's client count is 1 before
stopping, and the "started" case until the fake has recorded the watch
before it pushes.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:28-32`,
`plugin/lib/tailscale/LocalApiClient.h:106-107`,
`plugin/lib/tailscale/LocalApiClient.cpp:96-99`,
`plugin/lib/tailscale/LocalApiClient.cpp:118-123`,
`plugin/lib/tailscale/LocalApiClient.cpp:171-175`,
`plugin/lib/tailscale/LocalApiClient.cpp:312-320`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:588-606`.

### R-WATCH-07 · fix · Watch first, read once, then only the bus

**Statement.** Each connection attempt opens the watch before it reads. It then
issues one pass. After that, a pass (`GET` of `/status`, `/prefs` and
`/suggest-exit-node`, published as a snapshot) happens only for a
notification or for an accepted write: R-WRITE-08's confirmation is an
ordinary pass that a 2xx write outcome starts, as a notification does
(decision 5), except that a 2xx arriving while a reconnect is pending starts
no pass and is confirmed by the reconnect's opening pass (R-WRITE-08). A new watch opens only with a new connection attempt, that is
on a reconnect (R-CONN-06); neither a notification nor a write opens one.
Between notifications, the backend issues no request of its own except
R-CONN-13's liveness probe, a `GET /localapi/v0/prefs` every 30 000 ms whose
reply is never published, so it is not a snapshot read (decision 4).
Requests that a user action sends are not the backend's own and are not
limited by this rule: a prefs write (R-WRITE-02, R-WRITE-10) with its
confirmation pass (R-WRITE-08), and the login start (R-UI-17). A pass also
reads `/localapi/v0/check-ip-forwarding` exactly when R-WRITE-10 says so:
when the last published snapshot has `advertisingExitNode` true, or when the
pass is the confirmation pass of a `setAdvertiseExitNode(true)`, or, as one
follow-up check sent when the pass publishes, when the pass's own snapshot
has `advertisingExitNode` true and the pass sent no check; otherwise it does
not. With prefs that advertise no exit node, as in the acceptance below, no
check is ever sent. In #286 nothing at all is requested between notifications. The
tag is `fix` because of decisions 4 and 5: on `a38dbca` the hour below
records no probe, so the acceptance's count of 120 fails there.

**Acceptance.** Given a fake that answers everything, with prefs that
advertise no exit node, the backend reaches `Running`. After the idle barrier
that follows the opening pass, before paused time advances, the fake has
received exactly four requests: one watch and one GET each of `status`,
`prefs` and `suggest-exit-node`. Their arrival order at the fake is not
asserted: each opens its own connection, deferred separately (R-HTTP-11), so
it is not deterministic. The watch-first order is asserted on the client
side: the transport reports to its test the order in which it issued an
attempt's requests, through a test hook on the core crate like the read
barrier (decision 12), and in every attempt the watch is issued first.
Let P be the paused time at which the attempt became established (R-CONN-09).
Paused time then covers one hour, P to P + 3 600 000 ms, with no
notification and no action called, in 120 steps of exactly 30 000 ms each,
never in one jump: each probe is armed relative to the previous send, so a
single advance would fire only the timer already registered. After step k
(paused time at P + 30 000 × k ms) the idle barrier, then the read barrier
and the fake barrier ("Request counts") are taken, and the fake has
recorded exactly k probes since P, each a `GET /localapi/v0/prefs`, the
k-th recorded during step k, and no other request since P. After step 120
the fake has recorded exactly 120 requests in that hour. In all it has
recorded exactly one
watch and exactly one GET each of `status` and `suggest-exit-node`, and no
property change signal fired in that hour. Every reconnect attempt repeats
the same four. In a separate run with paused time and the shipped timings,
the fake closes the watch with `0\r\n\r\n` once the idle barrier holds after
each attempt's pass. After the retry barrier of attempt n, the fake has
recorded exactly n watches and n GETs each of `status`, `prefs` and
`suggest-exit-node`, 4n requests in all, for n = 1 to 4. Between attempts
paused time advances by exactly the delay just armed, and by nothing else:
500 ms after attempt 1, 1 000 ms after attempt 2 and 2 000 ms after attempt
3 (R-CONN-07). Those 3 500 ms stay far inside the 30 000 ms liveness interval
and settle period, so no probe falls due and the curve is not reset.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:15-22`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:244-296`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:944-960`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1062-1066`,
`pr286-body:11-12`, decisions 2 (when a pass reads `/check-ip-forwarding`), 4
and 5.

### R-WATCH-08 · parity · A notification starts a pass, and the replies are the truth

**Statement.** A notification that passes the filter (R-WATCH-09) starts one
pass. The pass publishes what its replies say. No snapshot property is rebuilt
from the notification body. The one exception is R-UI-17's `loginUrl`, set
from a notification's `BrowseToURL` field, which is not part of any snapshot
and has no read endpoint; it is a `new` member listed under "Contract
additions". The suggestion is re-read on every pass, not only on connect.

**Acceptance.** With the backend `Running` on the idle capture,
`exitNodeActive` reads false. The fake switches to the exit-node capture and
pushes `{"Prefs":{}}`. After the idle barrier,
`exitNodeActive` is true and `exitNodeName` is `pentest-exit-node`. Then,
after the fake barrier ("Request counts": the idle barrier includes the
read barrier), the fake has recorded, since the push, exactly one GET of
`/localapi/v0/status` and exactly one GET of
`/localapi/v0/suggest-exit-node`: two of each since construction, the
opening pass's and this notification's.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:275-296`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:311-325`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:849-863`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1195-1207`,
decision 1 (`loginUrl` from `BrowseToURL`, the statement's one exception).

### R-WATCH-09 · parity · Notifications are judged by content, not by the mask

**Statement.** tailscaled sends ongoing notifications to every watcher,
whatever the mask. The backend skips a notification only when it is a
non-empty JSON object whose every non-null field is `Version`, `SessionID` or
`Engine`. Anything else starts a pass. That includes an unknown field, non-JSON
text and `{}`. A notification carrying `ErrMessage`, tailscaled's own error
report, only starts a pass. Its text reaches no property: #286 drops it, and
the rewrite keeps dropping it (decision 18). Publishing it is follow-up
issue #299, outside epic #287, so no member is added for it.

**Acceptance.** The backend reaches `Running` on the idle capture. With one
GET of `/status` seen, the test pushes the live-bus
line that carries only `Version`, null fields and `Engine`, then
`{"State":null}`, then `{"Version":"1.104.1","State":6}`. After the idle
barrier, the fake has recorded exactly two GETs of `/status`. Three would mean
a skipped line started a pass, which coalescing would replay. Each of these
lines, pushed alone and followed by the idle barrier, adds exactly one GET:
a line with `"SomethingNewIn2027":{}`, a line that is not JSON, `{}`, and
`{"ErrMessage":"boom"}`. After the `ErrMessage` line, no property contains
`boom`.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:170-181`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:57-70`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:298-309`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1146-1193`,
`pr286-body:37-38`.

### R-WATCH-10 · parity · One pass at a time; notifications in flight coalesce

**Statement.** While a pass is out, notifications start no requests. They leave
one "stale" mark. When the pass publishes, a stale mark starts exactly one more
pass.

**Acceptance.** With the next `/status` held, one `{"Prefs":{}}` starts a pass.
Five more lines follow. After the read barrier, taken on every connection
(so it also rules out a connect scheduled on a new connection, and proves
the backend consumed all five lines), and then the fake barrier ("Request
counts"), the fake has recorded no new request, and `state` stays
`Running`. Releasing the held reply causes
exactly one more GET of `/status` and of `/suggest-exit-node`. After the idle
barrier, the counts are exactly those, so no further pass ran, and `state` is
still `Running`. Setup, not acceptance: the test waits until the fake holds
the `/status` request before pushing the five lines.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:302-322`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:311-325`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:411-432`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1101-1144`.

### R-WATCH-11 · parity · Status and prefs publish together

**Statement.** A pass publishes only when both its `/status` and its `/prefs`
replies have arrived. Neither half alone changes a property. Halves are never
paired across passes or attempts. An R-WRITE-08 confirmation is an ordinary
pass and obeys the same rule. R-CONN-13's probe reads `/prefs` but never
publishes it, so it is never a half of anything.

**Acceptance.** The backend is `Running` on the idle capture. The fake
switches to a status with a new state and holds the next `/prefs`. A
notification is pushed. The fake answers `/suggest-exit-node` with the same
reply as before, so `recommendedExitNodeId` does not move. Once the fake holds
that `/prefs` (held count 1) and has answered `/status` and
`/suggest-exit-node`, and the client barrier holds at 2 (the watch and the
held `/prefs`), the read barrier holds on every connection: none of #286's 24 properties'
change signals has fired since the
notification, and each of those properties reads its old value. The fake
then releases `/prefs`. After the idle barrier, every one of those
properties the new snapshot changes reads its new value, and its change
signal fired exactly once. The same clauses for the five members listed
under "Contract additions" are R-UI-18's, not this requirement's.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:24-34`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:237-251`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:259-262`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:411-422`,
decisions 4 (the probe reads `/prefs` but is never paired) and 5 (the
confirmation is an ordinary pass).

### R-WATCH-12 · parity · A straggler from an abandoned pass is ignored

**Statement.** A reply or failure from an abandoned pass never pairs with a
later pass. It never ends the current pass. A loss or a reconnect abandons a
pass. Watch failures always count. A loss stops the watch and the probe
(R-CONN-06) but leaves the abandoned pass's other reads connected, so their
outcomes can still arrive. A `/status` or `/prefs` outcome of the abandoned
pass, the snapshot halves, is ignored. Its `/suggest-exit-node` and
`/check-ip-forwarding` outcomes are not snapshot halves: they follow
R-PARSE-11 and R-WRITE-10, which apply or drop them by their own rules, and
they are dropped unconditionally only when a reconnect has closed their
connection, which then delivers no outcome at all. A reconnect closes every read
connection still open from earlier attempts before it opens the new watch,
silently, as #286's reconnect does
(`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:244-255`); it
never closes a write (R-WRITE-07).

**Acceptance.** Both runs use paused time and the shipped timings. The
backend shows exit node A. A pass's `/status` fails with 503 while its
`/prefs`, selecting B, is held; `state` then reads `NoState` (R-CONN-06;
that the loss also stops the watch is R-CONN-06's criterion, decision 24,
not this one's). After the retry barrier for that loss, whose
armed delay is the shipped first delay of 500 ms (the first loss after the
opening attempt was established, R-CONN-07), with paused time not advanced,
the fake's held count reads exactly 1 (the abandoned `/prefs` is still
connected). The fake then answers `/status` normally and selects C in
`/prefs` from then on.

- **The straggler arrives before the reconnect.** The fake completes the
  held request with B's prefs; the completion reaches exactly 1 client
  (R-FAKE-02). After the read barrier, with paused time still not advanced,
  `state` reads `NoState`, `exitNodeId` reads A and `exitNodeIdChanged` has
  fired 0 times since the loss. Paused time then advances exactly 500 ms, so
  the reconnect attempt opens a new watch and a new pass. After the idle
  barrier `state` is `Running`, `exitNodeId` is C and `exitNodeName` is C's
  display name (`host-1` for `gamma` in `status-idle.json`).
- **The straggler is still held at the reconnect.** The fake keeps B's
  `/prefs` held. Paused time advances exactly 500 ms. After the idle barrier
  the fake's held count reads 0 (the reconnect closed the abandoned
  connection, so the fake no longer counts it), `state` is `Running`,
  `exitNodeId` is C and `exitNodeName` is C's display name. Completing the
  held requests then reaches 0 clients.

In both runs a spy on `exitNodeIdChanged` shows `exitNodeId` went from A to
C once and never held B.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:308-321`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:354-379`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:453-463`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:497-506`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:491-554`,
`pr286-body:87-92`, the reconnect's closing of earlier reads at
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:244-255`.
Decision 24 moves the next pass onto the reconnect: #286 starts it from a
notification on the watch the loss left open (`:548-551`), which R-CONN-06
now forbids. #286 releases the straggler after the loss and before that next
pass (`:541`), as the first run does.

### R-WATCH-13 · fix · State and identity come from the snapshot

**Statement.** `state` maps `BackendState`: `NeedsMachineAuth`, `NeedsLogin`,
`Stopped`, `Starting` and `Running` map to themselves, and `NoState`, which
tailscaled itself reports while it starts up (`ipn.NoState`), maps to
`NoState`. These six are the known values. Any other value maps to
`NoState`. `selfName`, `selfIp4`, `selfIp6`, `selfDnsName`, `tailnet` and
`keyExpiry` come from the same snapshot. A `BackendState` of `"NoState"` is
known, not unknown: the pass publishes `state` `NoState` with an empty
`readError`, arms no retry and keeps the watch open, as #286 does, so the
view takes R-QML-01's path until the next notification brings the started
state. An unknown non-empty `BackendState`, one outside the six known values
(a real `ipn.State` such as `InUseOtherUser`, or a state a future tailscaled
adds) is named, not hidden (decision 23): the pass publishes its whole
snapshot with `state` `NoState` and `readError` set, in the same snapshot, to
exactly `tailscaled reported an unknown BackendState "<value>"`, with the
value verbatim. It arms no retry, because reconnecting cannot change the
answer, keeps the watch open, and counts as established (R-CONN-09). The next
notification starts a pass as usual, which re-evaluates the state: a known
`BackendState` publishes it and clears `readError` (R-CONN-05). The view
takes the R-QML-02 path: the slot is visible and dimmed, and the panel shows
the line `ts-read-error`. In #286 such a snapshot has an empty `readError`,
so a daemon that never reported a known state has no bar slot, exactly like a
machine without Tailscale, and one that was `Running` reads "no daemon".

**Acceptance.** The idle capture, served chunked, yields, after the idle
barrier, `state` `Running`, exactly 20 rows in `peers`,
`selfName` `host-6`, `selfIp4` `100.115.228.122`, `selfDnsName`
`host-6.example-tailnet.ts.net` and `tailnet` `example.com`. A first status
with `BackendState` `Weird` gives, after the idle barrier, `state` `NoState`,
`readError` equal to `tailscaled reported an unknown BackendState "Weird"`,
no armed reconnect (the retry hook's count is 0) and a client count of 1, the
watch. (`state` stays `NoState` in that run, so `stateChanged` does not
fire there; the same-snapshot clause is read in the run from `Running`
below.) In the QML suite, with `state` `NoState` and that `readError`, the
slot is visible with tint `Theme.textDisabled` and `ts-read-error` equals it
(R-QML-02). A backend that reached `Running` and then reads a status with
`BackendState` `Weird` gives, after the idle barrier, `NoState`, the same
`readError`, no armed reconnect and a client count of 1, and
`stateChanged` fired exactly once since the notification; inside that
`stateChanged` handler, `readError` already reads
`tailscaled reported an unknown BackendState "Weird"`. The fake then serves
`Running` again and pushes `{"Prefs":{}}`; after the idle barrier `state` is
`Running` and `readError` is empty. A first status with `BackendState`
`"NoState"` gives, after the idle barrier, `state` `NoState`, `readError`
empty, `readErrorChanged` fired 0 times, the retry hook's count 0 and a
client count of 1, the watch.

**Sources.** decision 23, tailscale `github.com/tailscale/tailscale` at tag `v1.102.5` (commit
`5fb2a81b065b0a0bbbfc67ab20a0d9c6a1108115`),
`ipn/backend.go:26-35` (`ipn.State`, whose `NoState` at `:28` is the
state tailscaled reports while it starts, and `InUseOtherUser` at `:29`),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:41-55` (#286 maps
an unknown value to `NoState` with nothing named),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:599-605`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:638`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:133-157`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:293-305`.

### R-WATCH-14 · parity · Reading the exit node fails closed

**Statement.** `exitNodeActive` is true when `/status` has `ExitNodeStatus` or
`/prefs` has a non-empty `ExitNodeID`. `exitNodeOnline` is true only when
`ExitNodeStatus` is present and online. The fallback is taken on whether
`ExitNodeStatus` is an object, never on whether its `ID` is empty: while
`ExitNodeStatus` is an object, `exitNodeId` is its `ID` and `exitNodeName` is
the R-PARSE-09 name, both empty when that object has no `ID` or an empty
one, whatever the prefs `ExitNodeID` holds (#286,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:614-627`: `resolved ? status.exitNode->id :
prefs.exitNodeId`). Only when `ExitNodeStatus` is absent, null or not an
object is `exitNodeId` the prefs `ExitNodeID` and `exitNodeName` the named
peer's display name, else that id. Id and name are empty when nothing is
active.

**Acceptance.** Each capture below is read after the idle barrier that
follows the backend reaching `Running` on it, and each value is exact. The
offline capture yields `exitNodeBlocked` true, `exitNodeActive` true,
`exitNodeOnline` false and `exitNodeName` `pentest-exit-node`. The reachable
capture yields `exitNodeActive` true, `exitNodeOnline` true,
`exitNodeBlocked` false and `exitNodeId` the peer's id. The idle status with
prefs `ExitNodeID` set reaches `Running` and yields `exitNodeActive` true,
`exitNodeOnline` false, `exitNodeBlocked` true, and `exitNodeId` and
`exitNodeName` that id and that peer's name.
The fake then serves prefs without `ExitNodeID` and pushes `{"Prefs":{}}`.
After the idle barrier, `exitNodeActive` and `exitNodeBlocked` read false,
`exitNodeId` and `exitNodeName` read empty, and each of their four change
signals fired exactly once since the push. A status
`{"BackendState":"Running","ExitNodeStatus":{"Online":true}}` (R-PARSE-09's
object with no `ID`) with prefs `ExitNodeID` `nX1CNTRL` reads, after the
idle barrier, `exitNodeActive` true, `exitNodeOnline` true, `exitNodeId`
exactly the empty string and `exitNodeName` exactly the empty string: the
prefs id is not used, because `ExitNodeStatus` is an object.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:540-552`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:607-629`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:307-399`.

### R-WATCH-15 · fix · A watch line is capped at 16 MiB

**Statement.** One notification line may take at most 16 777 216 bytes
(16 MiB) after de-framing, not counting its LF; network-map notifications can
be large, so the cap is generous. Once a line has reached 16 777 217 bytes
without an LF, the watch fails at once with the reason
`/localapi/v0/watch-ipn-bus sent a notification line longer than 16777216 bytes`,
then emits "ended" (R-WATCH-04). The backend treats that as a lost connection
with that `readError`, `NoState` and one reconnect (R-CONN-16). A line of
exactly 16 777 216 bytes is delivered as one event. The chunk-size line of a
chunked body (R-HTTP-04), its `;extension` included, is bounded too, since
it is buffered until its CRLF and a watch has no deadline once established:
it may take at most 1 024 bytes, not counting the CRLF. That 1 024-byte
value is this spec's concrete choice to implement decision 21, not a value
the owner set; the owner decided the two caps of 64 KiB for headers and
16 MiB per line. Once a size line has
reached 1 025 bytes without a CRLF, the exchange fails at once with the
reason `<path> sent a chunk size line longer than 1024 bytes`; on the watch
that failure is followed by "ended", and the backend treats it as the same
lost connection with that `readError` (R-CONN-16).

**Defect.** #286 caps no watch line, so a stream that never sends a newline
grows the buffer without bound and produces no event while `state` stays
`Running`. The owner decided to cap the line at 16 MiB (decision 21); the
chunk-size-line cap closes the same unbounded buffer one layer down, and
its 1 024-byte value is this spec's choice.

**Acceptance.** On an established watch, a line of 16 777 216 bytes followed
by LF yields, after the read barrier, exactly one event of that length and no
failure. In a separate
run, 16 777 217 bytes with no LF, followed by the read barrier, yield no
event, exactly one failure with that reason, then one "ended". Against the
backend from `Running`, the same push gives, after the retry barrier,
`state` `NoState`, `readError` equal to that reason and exactly one armed
retry. Size lines, on an established chunked watch: pushing `8;` followed
by 1 022 bytes of `x` (a 1 024-byte size line), then
`\r\n{"a":1}\n\r\n`, yields, after the read barrier, exactly one event
`{"a":1}` and no failure. In a separate run, pushing 1 025 bytes of `1` with
no CRLF yields, after the read barrier, no event, exactly one failure with
the reason
`/localapi/v0/watch-ipn-bus sent a chunk size line longer than 1024 bytes`,
then one "ended"; against the backend from `Running`, the same push gives,
after the retry barrier, `state` `NoState`, `readError` equal to that reason
and exactly one armed retry.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:310-331` (the line
buffer grows without a bound), `plugin/lib/tailscale/LocalApiClient.cpp:266-268`
(a chunk-size line is buffered until CRLF, without a bound), decision 21.

## R-CONN: connection lifecycle

### R-CONN-01 · parity · Socket path, start-up and injectable timings

**Statement.** The socket path is `$TS_SOCKET`, or
`/var/run/tailscale/tailscaled.sock` when it is unset. The backend starts
connecting when the singleton is created, without a call from QML. Tests can
inject the socket path, the first retry delay, the settle period, the
request deadline and the liveness interval (R-CONN-13). The shipped values
are 500 ms, 30 s, 10 s and 30 s.

**Acceptance.** With `TS_SOCKET` naming the socket of a fake that serves
`status-idle.json` and answers every other request normally, keeping the
watch open, creating the singleton through the QML factory brings it to
`Running`. After the idle barrier that follows, then the read barrier and
the fake barrier ("Request counts"), the fake has recorded exactly four
requests: the watch and one GET each of `status`, `prefs` and
`suggest-exit-node`. The
default is checked as a resolved value, never by connecting: with `TS_SOCKET`
removed from the test's environment, the socket path the backend resolves
equals `/var/run/tailscale/tailscaled.sock`, and the test opens no socket. The
rewrite exposes that resolution to its tests through a test hook on the core
crate (decision 12); #286 resolves it in one function
(`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:32-39`). With paused time, an injected
first retry delay of 700 ms and nothing listening at the socket, after the
retry barrier for the first connect, with paused time not advanced, exactly
one retry has been armed and the retry hook reports its delay as exactly
700 ms, the injected base. The shipped values are each pinned by a
criterion that runs on them: the 500 ms base by R-CONN-07, the 30 000 ms
settle by R-CONN-10's shipped-settle runs, the 10 000 ms deadline by
R-HTTP-13's shipped-deadline clause, and the 30 000 ms interval by
R-CONN-13.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:32-39`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:74-86`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:55-65`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:696-704`,
`plugin/tests/tst_module.cpp:100-116`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:728`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1081`,
`docs/superpowers/specs/2026-10-15-tailscale-module-design.md:157-161`,
decision 4 (the liveness interval).

### R-CONN-02 · parity · No tailscaled settles in NoState without a diagnosis

**Statement.** When nothing listens at the socket path at start-up, before any
snapshot was published, the backend reads `state` `NoState`, no peers,
`exitNodeActive` false and an empty `readError`. It arms one reconnect. A
machine without Tailscale looks exactly like this. After a snapshot was
published, a later connect that finds nothing at the path is a loss:
R-CONN-06 governs it, so of #286's members only `state`, `readError` and
`recommendedExitNodeId` move. `recommendedExitNodeId` moves because every
reconnect attempt asks `/suggest-exit-node` (R-WATCH-07), and with nothing
at the path that request fails and clears it (R-PARSE-11, R-CONN-11).
Identity, the models and the other exit-node fields keep their last values.
What such a loss does to the members added by decisions 1 and 2 is stated
by their own requirements, not by this parity one: R-UI-17 empties
`loginUrl` on any loss, and R-WRITE-10 sets `ipForwardingWarning` empty
when, with the last published snapshot's `advertisingExitNode` true, the
attempt's `/check-ip-forwarding` fails flagged socket-absent.

**Acceptance.** With no listener, after the retry barrier for the first
connect, with paused time not advanced, exactly one retry is armed. `state`
is `NoState`, `readError` is empty, `peers` has 0 rows and `exitNodeActive` is
false.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:477-488`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:189-194`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:437-452`,
`plugin/src/contracts/TailscaleBackend.h:322-338`,
`plugin/lib/tailscale/LocalApiClient.cpp:386-390`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:765-773`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:812-823`,
decisions 1 and 2 (named only to hand the added members to R-UI-17 and
R-WRITE-10).

### R-CONN-03 · fix · Each read failure from a present daemon has its own diagnosis

**Statement.** When a read fails while a daemon is present, `readError` holds a
non-empty reason. The reasons tell the failures apart. They cover a non-2xx
status with path and code (with the body's words, R-HTTP-09), a missed
deadline, a watch that never started, a bad chunk length, a short chunk, a
close before headers, a close mid-body, oversized headers or watch line
(R-HTTP-15, R-WATCH-15, decision 21), and any other socket error. `readErrorChanged` fires
once per change. One loss can report several failures. The first failure of
the attempt is the loss: it sets `readError`, abandons the pass and stops the
watch (R-CONN-06, decision 24). Every later failure of that attempt, a read's
or the watch's, is a straggler and changes nothing (R-WATCH-12), and a
stopped watch reports nothing at all (R-WATCH-06). So one loss sets
`readError` exactly once, to the first failure's reason. In #286 a failed
read leaves the watch open, so a watch failing after a read had failed
changed `readError` a second time, and the final value depended on which
socket ended first.

**Acceptance.** For each failure staged by the fake, `state` becomes `NoState`
and `readError` is non-empty. The stagings are: 403 to `/status` and
`/prefs`; `/status` and `/prefs` recorded and never answered, with paused
time and an injected 50 ms request deadline (R-CONN-01), after which paused
time advances exactly 50 ms from the instant the fake recorded them; a bad
chunk-length line; a short chunk; a close before headers; a close mid-body;
and a head whose status line is not `HTTP/x NNN`
(`garbage\r\nContent-Length: 2\r\n\r\n{}`, the shape of `TS_SOCKET` pointing
at some other listening socket). In the last staging `exitNodeBlocked` keeps
the value it had before the attempt, because no `/prefs` is read as
defaults. In each of these seven stagings the fake applies the failure to
`/status` and `/prefs` only, answers `/suggest-exit-node` normally and keeps
the watch open after its headers; the backend's own stop closes the watch,
so the client barrier reaches 0 without the fake dropping anything. The
first non-empty values of `readError`, one per staging, differ pairwise. The
403 case contains `403`. After the retry barrier and the client barrier at
0, with paused time not advanced any further so no new attempt has
connected, `readErrorChanged` has fired exactly once, and `readError` still
holds the first failure's reason. An eighth run, separate from the seven and
outside the rule above, answers the watch 403 as well as `/status` and
`/prefs`: at the same barriers the count is still exactly once.

**Sources.** `pr286-body:69-71`,
`plugin/src/contracts/TailscaleBackend.h:310-339`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:464-470`,
`plugin/lib/tailscale/LocalApiClient.cpp:143-146`,
`plugin/lib/tailscale/LocalApiClient.cpp:226-227`,
`plugin/lib/tailscale/LocalApiClient.cpp:276`,
`plugin/lib/tailscale/LocalApiClient.cpp:300`,
`plugin/lib/tailscale/LocalApiClient.cpp:349`,
`plugin/lib/tailscale/LocalApiClient.cpp:359`,
`plugin/lib/tailscale/LocalApiClient.cpp:389`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:775-805`,
decision 24 (#286 leaves the watch open after a read loss,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`, which
stops no watch), decision 21 (an oversized head or watch line is a lost
connection with its own `readError`).

### R-CONN-04 · fix · A /status without BackendState is not a status

**Statement.** A 2xx `/status` that does not parse, or that has no non-empty
`BackendState`, publishes nothing. `readError` names `/localapi/v0/status` and
says what was wrong, with one exact string per cause (decision 14):

- not JSON (the empty body included):
  `/localapi/v0/status answered something that is not JSON`;
- JSON that is not an object:
  `/localapi/v0/status answered JSON that is not an object`;
- an object with no `BackendState`, or an empty one:
  `/localapi/v0/status answered without a BackendState` (#286's string).

`state` is `NoState`, and a reconnect is scheduled. #286 reports the first two
causes with one string, `/localapi/v0/status answered something that is not a
status`.

**Acceptance.** With paused time and the shipped timings, given a fake
whose `/status` answers chunked `{}` and that answers every other request
normally, keeping the watch open on its side: after the retry barrier for
the first connect, with paused time not advanced, then the read barrier and
the fake barrier ("Request counts"), exactly one retry is armed, `state` is
`NoState`, `readError` equals
`/localapi/v0/status answered without a BackendState`, `readErrorChanged`
has fired exactly once, and `stateChanged` has fired 0 times since
construction: no snapshot was published, so `state` never left its initial
`NoState`. The transport's issue-order hook (R-WATCH-07) reports that the
attempt issued exactly four requests, the watch first and then one GET each
of `status`, `prefs` and `suggest-exit-node`: that is the exact count of
what the attempt issued. Of the fake's records, one count is a clause: at
the same barriers the fake has recorded exactly one GET of `status`. How
many of the other three requests reached the fake is not a clause of this
criterion and is not asserted, because the loss stops the watch (R-CONN-06,
decision 24), possibly before its deferred connect ran. A body of
`x` gives exactly `/localapi/v0/status answered something that is not JSON`,
and a body of `[]` gives exactly
`/localapi/v0/status answered JSON that is not an object`, each read at the
same barriers with one armed retry and `stateChanged` fired 0 times. #286
reads `state` once the fake has recorded four requests
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:940`);
under decision 24 the fake may record fewer, so that count maps here and is
replaced by the issue-order count above, and the negative is read after the
retry barrier.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:391-406`
(#286's two strings at `:401-402`),
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:925-942`,
decisions 14 and 24 (#286 leaves the watch open after a read loss,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`).

### R-CONN-05 · parity · readError clears only with a whole snapshot

**Statement.** A non-empty `readError` stays until one pass delivers both a
valid `/status` and its `/prefs`. It then becomes empty, together with the rest
of the snapshot. (What a snapshot whose `BackendState` the enum does not
name does to `readError` is R-WATCH-13's `fix`, not this requirement's.) A
`/prefs` reply alone, and a probe reply (R-CONN-13), does not clear it.

**Acceptance.** With paused time and the shipped timings, and every read of
the opening attempt answered 500, after the retry barrier `readError` is
non-empty and one retry is armed, with the first delay of 500 ms. For the
next attempt the fake serves the watch normally, answers `/prefs` and holds
`/status`, and paused time advances exactly 500 ms. Once the
fake holds that attempt's `/status` and the read barrier holds after its
`/prefs` reply, `readError` is still non-empty and `readErrorChanged` has fired
0 times since the attempt began. The fake then releases `/status` with a 500.
After the retry barrier of that attempt, `readError` is still non-empty,
`state` is `NoState`, and the retry armed is the second, with a delay of
1000 ms. The fake then answers `/status` normally too, and paused time
advances exactly 1000 ms. After the idle barrier `state` is `Running`,
`readError` is empty, and `readErrorChanged` has fired exactly once since
the start of that 1000 ms advance: the one change is the snapshot clearing
it.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:629-638`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:339-342`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:829-847`,
decision 23 (what an unrecognised `BackendState` does to `readError` is
R-WATCH-13's).

### R-CONN-06 · fix · Losing tailscaled changes only state, then reconnects

**Statement.** When a read fails, the watch ends or the liveness probe fails
(R-CONN-13), the backend abandons the pass, stops the watch and the probe,
and sets `state` to `NoState`. A read failure from a present daemon also
sets `readError` to its reason (R-CONN-03). A failure because nothing is at the
socket path sets `readError` to empty, clearing any earlier reason
(R-CONN-02). A clean watch end follows R-CONN-15.
Every other value is kept as tailscaled last reported it, with two
exceptions besides `loginUrl` (below). `recommendedExitNodeId` follows each attempt's suggestion outcome
(R-PARSE-11, R-CONN-11), so a reconnect attempt that finds nothing at the
path clears it. `ipForwardingWarning` follows each attempt's forwarding-check
outcome while the last published snapshot has `advertisingExitNode` true
(R-WRITE-10), so such an attempt clears it too (a check that fails because
nothing is at the path sets it empty); while `advertisingExitNode`
is false no check is sent and it stays empty.
The kept values include identity, the other exit-node fields, `exitNodeBlocked`,
`issues`, both models, `peersKnown` and the prefs read-backs. A fail-closed
`exitNodeBlocked` therefore stays visible. It then reconnects and publishes
the next snapshot. Every loss stops the watch, a failed snapshot read
included (decision 24), so one invariant holds: only a reconnect opens a
watch, and every reconnect opens the watch and then reads. A notification
can no longer arrive between a read loss and its reconnect, and a write's
2xx that arrives there starts no pass either (R-WRITE-08). A loss also sets
`loginUrl` empty (R-UI-17), since a login URL from a daemon that was lost
may no longer be valid. In #286 a failed
snapshot read leaves the watch open until the armed reconnect runs, up to
30 s, and a notification on it starts a pass that can publish `Running` and
clear `readError` before the reconnect tears it down.

**Acceptance.** All runs use paused time and the shipped timings, so the
first loss after an established attempt arms a 500 ms retry and the next
consecutive one 1000 ms (R-CONN-07). With the backend `Running`, an exit node
active and offline, two peers and `advertisingExitNode` false, the fake is
destroyed, closing every accepted connection, the
watch included. `stateChanged` fires and `state` is `NoState`. After the retry
barrier, with paused time not advanced so no reconnect attempt has run, no
other change signal has fired, and every other value, `recommendedExitNodeId`
included, is unchanged.
`readError` was empty before the loss and is empty after it. A separate run
starts fresh, from a new backend that has never been `Running`: its fake
answers `/status` 500 from the first connect and every other request
normally, so after the retry barrier for that first connect `readError` is
non-empty and the armed retry has the 500 ms delay. The fake is then
destroyed, and paused time advances exactly 500 ms. After the next retry
barrier, whose connect found nothing at the path and whose armed delay is
1000 ms, and the read barrier, `readError` is empty, and `readErrorChanged`
has fired exactly once since the fake was destroyed. `recommendedExitNodeId`
is empty too, because that attempt's suggestion failed. With
`advertisingExitNode` false in this run, no forwarding check was sent and
`ipForwardingWarning` was empty before and after, so `recommendedExitNodeId`
is the only value besides `state` and `readError` allowed to move. A new
fake serving the exit-node capture on the same path, plus advancing paused
time exactly 1000 ms, gives, after the idle barrier, `Running` and
`exitNodeActive` true. A third run, from
`Running`, has the fake answer `/status` 500 once and every later request
normally, and keep the watch open on its side. After the retry barrier, with
paused time not advanced, `state` is `NoState`, `readError` is non-empty,
and the client barrier holds at 0: the backend has closed the watch itself.
A notification pushed then reaches no client (the push returns 0). After the
read barrier the fake has recorded no further `/status` or `/prefs`, `state`
is still `NoState` and `readError` is unchanged. Paused time is then advanced
exactly 500 ms, the delay of the retry that loss armed. After the idle
barrier the fake has recorded exactly
one new watch and one new GET each of `status`, `prefs` and
`suggest-exit-node`, `state` is `Running`, `readError` is empty and the
connected-client count is 1. A fourth run is staged as #286 stages its
restart test
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:905-922`):
a fresh backend on a fake serving `status-idle.json` reaches `Running`, and
after the idle barrier `exitNodeActive` is false. The fake is destroyed;
after the retry barrier, with paused time not advanced, `state` is
`NoState` and the armed retry has the 500 ms delay. A new fake serving
`status-exitnode.json` is then made on the same path, with no `/status`
error in between, and paused time advances exactly 500 ms. After the idle
barrier `state` is `Running` and `exitNodeActive` is true.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:93-102`,
`plugin/src/contracts/TailscaleBackend.h:166-171`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:95-99`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:434-516`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:903-923`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:536-539`.
The socket-absent clearing is
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:477-488`. Each attempt's
`/suggest-exit-node` is issued at
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:292-295`, and its
failure clears `recommendedExitNodeId` at
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:437-452`. #286
keeps the watch open after a read loss
(`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`, which stops no watch), and
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:548-551`
relies on a notification on that watch; decision 24 changes it. Decision 2:
`ipForwardingWarning` follows each attempt's forwarding check.

### R-CONN-07 · parity · The reconnect curve doubles from 500 ms and caps at 30 s

**Statement.** The n-th consecutive reconnect delay, counting from 0, is
`min(30000, base × 2^min(n, 6))` ms. The base is 500 ms. The delays are 500,
1000, 2000, 4000, 8000, 16000, then 30000 for ever. Tests observe each armed
delay, and count armed retries (the "retry barrier"), through a test hook on
the core crate, not a Qt signal (decision 12), so the contract surface gains
nothing for it.

**Acceptance.** The delay function at base 500 gives 500, 1000, 2000, 16000,
30000 and 30000 for attempts 0, 1, 2, 5, 6 and 60. With no listener, paused
time and the shipped timings, after each retry barrier paused time advances
by exactly the delay just armed, and by nothing else, which starts the next
attempt. The first eight armed delays the hook observes are 500, 1000, 2000,
4000, 8000, 16000, 30000 and 30000 ms, in that order. No attempt is
established, so the settle period never starts.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:50-53`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:81-84`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:128-133`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:518-538`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:962-974`.
`pr286-body:87-92` only names "the reconnect backoff curve"; the 500 ms base
and the 30 000 ms cap come from the code and test cited.

### R-CONN-08 · fix · One lost connection arms one reconnect

**Statement.** One loss can report itself several times. Its first failure,
of the `/status` read, the `/prefs` read or the watch, is the loss: it stops
the watch (R-CONN-06, decision 24) and arms exactly one reconnect at the
current delay, advancing the curve one step. Every later failure of the same
attempt is a straggler (R-CONN-03, R-WATCH-12): the other snapshot read's
failure changes nothing, and a stopped watch reports nothing at all
(R-WATCH-06). A retry already pending absorbs any such report. A
`/suggest-exit-node` failure is never part of a loss (R-CONN-11); it only
clears `recommendedExitNodeId`. In #286 a failed read leaves the watch open,
so one loss reports up to three failed reads and then the watch's failure and
end, and the retry already pending absorbs them. The tag is `fix` because of
decision 24: #286's test waits for four recorded requests
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:991`),
and after the decided watch stop the fake may record fewer.

**Acceptance.** With paused time and an injected 20 000 ms retry base
(R-CONN-01), as #286's test injects, and the shipped deadline, settle and
liveness interval, given a fake that answers every request, the watch
included, `403` with `Content-Length: 0`: after the retry barrier for the
first connect, with paused time not advanced, then the client barrier at 0
and the read barrier, exactly one retry has been armed in all, with delay
20 000 ms. The client barrier at 0 proves that every socket of the attempt
has ended or been closed by the backend's own stop, and the read barrier
that nothing the attempt opened is still waiting, so every ending the
attempt will ever report has been reported. The transport's issue-order hook
(R-WATCH-07) reports that the attempt issued exactly four requests, the
watch first, then one GET each of `status`, `prefs` and `suggest-exit-node`.
How many of them reached the fake is not asserted, because the loss stops
the watch, possibly before its deferred connect ran. #286's
`requests().size() == 4`
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:991`)
maps here and is replaced by that issue-order count.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:518-530`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:976-998`,
decision 12 (the retry hook that counts armed reconnects), decision 24 (#286
leaves the watch open after a read loss,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`).

### R-CONN-09 · parity · An attempt is whole only when status, prefs and the watch all succeed

**Statement.** An attempt is established only when its status and prefs have
published a snapshot and the watch has started. `/suggest-exit-node` never
counts, and neither does `/check-ip-forwarding` (R-WRITE-10). If any of the three fails, the attempt failed and the next delay is
longer.

**Acceptance.** Given a fake whose `/prefs` answers 404 while the rest answer
normally, with paused time, an injected 1 ms retry base and the shipped
deadline and settle (R-CONN-01): after each retry barrier paused time
advances by exactly the delay just armed, and by nothing else, which starts
the next attempt. The first five armed delays the retry hook observes are 1,
2, 4, 8 and 16 ms, in that order. Each attempt fails on `/prefs`, so none is
established and the curve is never reset.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:139-159`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:327-335`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:381-386`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:423-427`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1000-1042`.
`pr286-body:87-92` only names "the OpeningRead wholeness bitmask"; the
404-prefs behaviour comes from the code and test cited. Decision 2:
`/check-ip-forwarding` does not count toward an attempt's wholeness.

### R-CONN-10 · parity · Only a connection that holds resets the curve

**Statement.** An established connection starts a settle period of 30 s. The
curve goes back to attempt 0 only when that period passes with no loss. A loss
during it cancels the reset, so the curve keeps rising.

**Acceptance.** With paused time, a 1 ms base and the shipped settle, four
attempts whose watch ends at once give delays 1, 2, 4, 8 ms: after each retry
barrier paused time advances by exactly the delay just armed, and no other
advance is made. With paused time, a 1 ms base and a 1 ms settle, and no
listener at the socket path: after the first retry barrier (delay 1 ms)
paused time advances exactly 1 ms; after the second (delay 2 ms) exactly
2 ms; after the third (delay 4 ms) the retry hook reads exactly three armed
reconnects, with delays 1, 2 and 4 ms, so the curve stands at attempt 3 and
the next delay would be 8 ms. A fake then appears at the path and paused time
advances exactly 4 ms. After the idle barrier the backend is `Running` and
the attempt is established. Paused time then advances exactly 1 ms, the
settle period, and the fake closes the watch with `0\r\n\r\n`. After the
retry barrier, exactly four reconnects have been armed in all, and the
fourth has a delay of 1 ms. Without the climb first, a reset and no change
would both read 1 ms, so the climb is part of the criterion.

The shipped settle period, with paused time and the shipped timings (500 ms
base, 30 000 ms settle, 10 000 ms deadline), on
a fake that answers every request: once the first attempt is established
(idle barrier), the fake closes the watch with `0\r\n\r\n`; after the
retry barrier the retry hook reads one armed reconnect with a delay of
500 ms. Paused time advances exactly 500 ms; after the idle barrier the
reconnect attempt is established, at an instant P the clock reads. In one
run paused time advances exactly 29 999 ms to P + 29 999 ms, the idle
barrier holds, and the fake closes the watch with `0\r\n\r\n`: after the
retry barrier, with the clock still at P + 29 999 ms, the newest armed
reconnect has a delay of exactly 1 000 ms. In a separate run paused time
advances exactly 30 000 ms to P + 30 000 ms (the settle period ends at
that instant), the idle barrier holds, and the fake closes the watch the same way: after the retry
barrier, with the clock still at P + 30 000 ms, the newest armed reconnect
has a delay of exactly 500 ms. A settle constant other than 30 000 ms fails
one of the two runs. Under the shipped timings the rewrite's liveness probe
(R-CONN-13, decision 4) also falls due at P + 30 000 ms; it is not a clause
of this criterion, and the run reads the same whether or not a probe is
sent, because the idle barrier holds only once any probe has been
answered.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:296-298`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:196-203`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:145-151`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:326-335`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-496`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1044-1099`,
the climb at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1080-1083`.

### R-CONN-11 · parity · A failing suggestion is not a lost connection

**Statement.** Any failure of `/suggest-exit-node` leaves
`recommendedExitNodeId` empty and changes nothing else. Failures include 404,
500, a timeout and an empty body; a malformed 2xx body clears it the same
way (R-PARSE-11). It does not set `NoState` or `readError`,
schedule a retry, or re-read `/status`.

**Acceptance.** For a 404, a 500 with `{"error":"no preferred DERP, try again
later"}` in `Running`, and the same 500 in `NeedsLogin`, each on a fresh
backend with paused time and an injected 1 ms retry base (R-CONN-01), as
#286's test injects, and the shipped deadline, settle and liveness interval:
`state` reaches the served state. After the idle barrier,
`recommendedExitNodeId` is empty and no retry is scheduled. Paused time then
advances by exactly 10 ms, ten times the injected base. After the idle
barrier again, `state` still equals the served state, no retry has been
scheduled and the fake has seen exactly one GET of `/status`. (10 ms is far
inside the 30 000 ms liveness interval, so no probe is sent either.)

Two further stagings, each on a fresh backend that the fake serves
`Running`:

- **Timeout.** With paused time and an injected 50 ms request deadline
  (R-CONN-01), the fake answers `/status`, `/prefs` and the watch, records
  `/suggest-exit-node` and never answers it. After paused time advances 50 ms
  past that request and the idle barrier holds, `recommendedExitNodeId` is
  empty, `state` is `Running`, `readError` is empty and no retry is scheduled.
- **Empty body.** `/suggest-exit-node` answers `200` with
  `Content-Length: 0`. After the idle barrier, `recommendedExitNodeId` is
  empty, `state` is `Running`, `readError` is empty and no retry is scheduled.

A fresh backend starts with `recommendedExitNodeId` empty (R-UI-05), so the
rows above pin only that a failure is not a loss. Clearing is pinned from a
published id: for each failure kind, 404, 500, timeout and an empty `200`
body, a separate run with paused time and an injected 50 ms request
deadline brings the backend to `Running` with `suggest-exit-node.json`
answered, so `recommendedExitNodeId` reads `nEwJFIats021CNTRL`. The fake
then stages that failure on `/suggest-exit-node` only and pushes
`{"Prefs":{}}`; in the timeout run paused time then advances exactly 50 ms
past the instant the fake recorded that request. After the idle barrier
`recommendedExitNodeId` is empty, `recommendedExitNodeIdChanged` has fired
exactly once since the push, `state` is `Running`, `readError` is empty and
the retry hook reads 0 retries armed since the push.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:145-153`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:437-452`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:340-351`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:677-690`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:556-623`.

### R-CONN-12 · parity · A wedged request ends and reconnects

**Statement.** A request that tailscaled accepts and never answers ends at the
deadline as a lost connection. `state` becomes `NoState` and a reconnect is
armed. A pass never stays in flight for ever.

**Acceptance.** With paused time, an injected 150 ms request deadline and a
20 000 ms retry base (R-CONN-01), as #286's test injects, the backend is
`Running` and every later `/status` is left unanswered. A notification makes
the fake record a second GET of `/status`, which it holds unanswered. Paused
time then advances exactly 150 ms from the instant the fake recorded it.
After the retry barrier, `state` is `NoState`, and exactly one retry has
been armed since the notification, with a delay of 20 000 ms.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:56-65`,
`plugin/lib/tailscale/LocalApiClient.cpp:135-149`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:701-736`,
the held second read at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:733`.

### R-CONN-13 · fix · A connected but silent daemon is detected

**Statement.** A watch can stay connected while tailscaled stops serving. The
backend detects this with an active liveness probe in the core crate
(decision 4): a `GET /localapi/v0/prefs`, sent every 30 000 ms (the liveness
interval, injectable per R-CONN-01) while a connection is established. The
first probe goes out 30 000 ms after the attempt became established
(R-CONN-09), and each later one 30 000 ms after the previous one was sent; a
loss stops the probe, and the next established attempt starts it afresh. A
loss also closes a probe request still in flight, silently: its connection
is closed and it delivers no outcome (R-HTTP-11's stopped exchange), so it
can never fail later, count as a second loss, or overwrite the `readError`
of the loss that stopped it. A
probe is an ordinary read under the request deadline (R-HTTP-13), so with the
shipped 30 000 ms interval and 10 000 ms deadline a daemon that stops
answering is detected within 40 000 ms, inside the 60 000 ms bound that the
shipped values may never exceed. A failed probe, for any reason R-CONN-03
lists, is a lost connection: `state` `NoState`, `readError` set to the
probe's failure reason as the transport words it, and one reconnect.
A 2xx probe reply is discarded unread: it publishes nothing, clears nothing
and moves no property, so a daemon that answers while its bus is quiet stays
`Running` with nothing re-announced. The probe never reads
`/localapi/v0/status`. Its requests are the only ones the backend issues of
its own accord between notifications (R-WATCH-07); requests a user action
sends, a prefs write with its confirmation pass (R-WRITE-02, R-WRITE-08,
R-WRITE-10) and the login start (R-UI-17), are not limited by that rule.

A watch that stalls while tailscaled still answers new requests is out of
scope (decision 4): the probe does not try to catch it, and no criterion
covers it.

**Defect.** "No liveness check. A watch that connects and then goes silent is
indistinguishable from a healthy quiet bus — and because `state` stays
`Running`, every `live` gate in the QML passes and the panel asserts a stale
snapshot is current. Needs an active probe, not a longer deadline."

**Acceptance.** With paused time and the shipped timings, the backend is
`Running` on a fake whose watch stays open and silent; let P be the instant
the attempt became established. Paused time always moves in the explicit
steps given, never in one jump past a re-armed timer. (a) Paused time
advances exactly 30 000 ms to P + 30 000 ms; the fake records the first
probe and answers it, and the idle barrier holds. Paused time advances
exactly 15 000 ms to T = P + 45 000 ms; from T the fake records every new
request and answers none. Paused time advances exactly 15 000 ms to
P + 60 000 ms; after the read barrier and the fake barrier ("Request
counts") the fake has recorded the second probe, a
`GET /localapi/v0/prefs`, and no other request since T. Paused time
advances exactly 9 999 ms to P + 69 999 ms; after the idle barrier and the
read barrier `state` is still `Running` and the retry hook reads 0 retries
armed since T. Paused time advances exactly 1 ms to P + 70 000 ms; after
the retry barrier `state` is `NoState`, `readError` is the deadline reason
(R-HTTP-13): it contains `10000 ms`, and exactly one retry has been armed
since T. So `state` leaves `Running` at exactly P + 70 000 ms, no later than
T + 40 000 ms. Retries armed after that by later attempts that also time
out are not counted. In a second run the probe is answered
`HTTP/1.1 503 Service Unavailable` instead; after the retry barrier `state`
is `NoState`, `readError` contains `/localapi/v0/prefs` and `503`, and one
retry is armed.
(b) On a fresh fake that answers every request, paused time covers
600 000 ms past P with no notification pushed, in 20 steps of exactly
30 000 ms each. After step k the idle barrier, then the read barrier and the
fake barrier, are taken, and the fake has recorded exactly k probes since P
(`GET /localapi/v0/prefs`, the k-th during step k) and nothing else. After
step 20 `state` is still `Running`, no retry is scheduled, no property
change signal fired, the fake recorded exactly 20 probes and no GET of
`/localapi/v0/status` or `/localapi/v0/suggest-exit-node` after the opening
pass. In a third run each probe is answered 200 with prefs whose `RouteAll`
differs from the published `acceptRoutes`: after the same 20 steps,
`acceptRoutes` is unchanged and `acceptRoutesChanged` fired 0 times.
(c) A probe in flight at a loss: with paused time, an injected 20 000 ms
retry base and the shipped deadline and interval, the fake arms a hold on
the next GET of `/localapi/v0/prefs`, and paused time advances exactly
30 000 ms past P; after the read barrier and the fake barrier the probe is
held (held count 1). The fake then closes the watch with `0\r\n\r\n`.
After the retry barrier and the client barrier at 0 (the held probe's
connection was closed by the loss), `state` is `NoState`; record `readError`
and the `readErrorChanged` count there. Paused time advances exactly
10 000 ms, the probe's deadline, and stays short of the 20 000 ms retry.
After the read barrier `readError` and `state` are unchanged,
`readErrorChanged` has fired 0 times since the retry barrier, and exactly
one retry has been armed since the watch closed.

**Sources.** `pr286-body:109-113`, decision 4,
`plugin/lib/tailscale/LocalApiClient.h:43-49`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:15-19`.

### R-CONN-14 · fix · A /prefs that is not a JSON object is a named read error

**Statement.** A 2xx `/prefs` body that is not JSON, or is JSON but not an
object, is not prefs (decision 16). It is treated as R-CONN-04 treats a bad
`/status`: the pass publishes nothing, `readError` is set to exactly
`/localapi/v0/prefs answered something that is not a JSON object`, `state`
becomes `NoState`, one reconnect is armed (R-CONN-06), and every other value
keeps what tailscaled last reported, so a fail-closed `exitNodeBlocked` stays
visible (R-WATCH-14). Inside an object, a known field of another type reads
as its default, as in #286. R-CONN-13's probe does not parse its reply, so
this rule does not apply to it. In #286 such a body reads as defaults: no
exit node selected and all four switches false, published as a successful
snapshot, so the fail-closed alarm goes quiet with no diagnosis.

**Acceptance.** The backend is `Running` on the idle status, with prefs
selecting an exit node the status does not resolve, so `exitNodeBlocked` is
true. The fake then answers `/prefs` 200 with `x` and pushes `{"Prefs":{}}`.
After the retry barrier, with paused time not advanced, `readError` equals
`/localapi/v0/prefs answered something that is not a JSON object`, `state`
is `NoState`, exactly one retry is armed, and `exitNodeBlocked`,
`exitNodeActive`, `exitNodeId` and the four switches hold the values they
had before the notification. A `/prefs` body of `[]` gives the same result.
A known field of another type reads as its default, as in #286: from
`Running` on the idle status with prefs
`{"WantRunning":true,"RouteAll":true,"CorpDNS":true}`, the fake answers
`/prefs` 200 with
`{"WantRunning":true,"RouteAll":"yes","CorpDNS":1,"ExitNodeID":5}` and
pushes `{"Prefs":{}}`. After the idle barrier `state` is `Running`,
`readError` is empty, no retry is armed, `wantRunning` is true,
`acceptRoutes` and `acceptDns` are false, `exitNodeId` is empty and
`exitNodeActive` is false.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:381-386`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:564-582` (#286
reads a non-object body as defaults),
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:633-638`,
decision 16.

### R-CONN-15 · fix · A clean watch end before the attempt's snapshot is diagnosed

**Statement.** A watch that ends cleanly is a lost connection. Ending cleanly
means a peer close after an accepted head, or the zero chunk of a 2xx
stream (R-WATCH-04); a watch answered with another status fails instead
(R-HTTP-09, R-CONN-16). The backend
sets `NoState`, abandons the pass and arms one reconnect. When the attempt
had not yet published its snapshot, a present daemon dropped the bus before
saying anything, which is not "no Tailscale here" (decision 19): `readError`
is set to exactly
`/localapi/v0/watch-ipn-bus ended before tailscaled sent a status`, replacing
any earlier reason, and the slot shows dimmed (R-QML-02). When the attempt
had already published its snapshot, the clean end leaves `readError` as that
snapshot left it and `readErrorChanged` does not fire for the end: empty
after a snapshot with a `BackendState` the enum names (the snapshot cleared
it, R-CONN-05), as R-CONN-16's contrast run pins, and exactly the R-WATCH-13
reason `tailscaled reported an unknown BackendState "<value>"` after a
snapshot whose `BackendState` it does not name (that snapshot set it,
decision 23). In #286 every clean end leaves `readError` as it was, so a
present daemon whose watch closes before any snapshot reads exactly like a
machine without Tailscale and has no bar slot (R-QML-01).

**Acceptance.** A fake answers the watch `200` chunked and holds `/status`. It
then sends `0\r\n\r\n` on the watch. After the retry barrier, `state` is
`NoState`, `readError` equals
`/localapi/v0/watch-ipn-bus ended before tailscaled sent a status`,
`readErrorChanged` fired exactly once, and exactly one retry is armed. The
held `/status` is then answered, and after the client barrier nothing
changes. View half: with `state` `NoState`, that `readError` and no other
state ever reported, the slot is visible with tint `Theme.textDisabled`
(R-QML-02). In a second run, `readError` was already non-empty from a 500 on
an earlier attempt; the clean end of the next attempt's watch, before its
snapshot, replaces it with the clean-end reason, and `readErrorChanged`
fires exactly once more. In a third run the attempt publishes a snapshot with
`BackendState` `Weird` (R-WATCH-13); after the idle barrier the fake sends
`0\r\n\r\n` on the watch. After the retry barrier, `state` is `NoState`,
`readError` still equals `tailscaled reported an unknown BackendState
"Weird"`, `readErrorChanged` has fired 0 times since the zero chunk, and
exactly one retry is armed.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:95-99`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516` (#286
sets no reason for a clean end),
`plugin/lib/tailscale/LocalApiClient.cpp:194-200`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:136-157`, decision 19.

### R-CONN-16 · parity · A watch that fails after it started has a diagnosis

**Statement.** A watch that has started and then fails, by bad chunk framing
or by any other failure R-WATCH-04 lists, is a lost connection with a
diagnosis. The backend sets `NoState`, puts the failure's reason in
`readError` and arms one reconnect. Only a clean end differs (R-CONN-15):
after the attempt's snapshot it leaves the empty `readError` empty.

**Acceptance.** The backend is `Running` with `readError` empty, and every
read of the attempt has been answered and published (idle barrier). The fake
pushes `zz\r\n` on the watch. After the retry barrier, `state` is `NoState`,
`readError` is non-empty and contains `zz`, `readErrorChanged` has fired
exactly once since the push, and exactly one retry is armed. In a contrast
run from the same start, the fake pushes `0\r\n\r\n` instead. After the
retry barrier, `state` is `NoState`, `readError` is empty and
`readErrorChanged` has fired 0 times since the push.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:273-279`,
`plugin/lib/tailscale/LocalApiClient.cpp:297-303`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:459-470`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`.

## R-WRITE: prefs writes

### R-WRITE-01 · parity · The four switches read back from /prefs

**Statement.** `wantRunning`, `exitNodeAllowLANAccess`, `acceptRoutes` and
`acceptDns` publish `WantRunning`, `ExitNodeAllowLANAccess`, `RouteAll` and
`CorpDNS` from each pass's `/prefs` reply. A missing field reads false. Each has
its own change signal. None is derived. `wantRunning` is what tailscaled was
told, so it can be true while `state` is `NeedsLogin` or `Starting`.

**Acceptance.** A `Running` status with prefs false, true, true, false gives,
after the idle barrier that follows the backend reaching `Running`,
those four values in that order. From all false, prefs flipped to all true plus
one `{"Prefs":{}}` give all true: after the idle barrier that follows that
notification, each of the four signals has fired exactly once since the
push.
With `WantRunning` true and `BackendState` `NeedsLogin`, after the idle
barrier that follows the backend reaching `NeedsLogin`, `state` is
`NeedsLogin` and `wantRunning` is true.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:182-222`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:554-582`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:640-653`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:401-489`,
`pr286-body:19-20`. The PR body says "all three switches"; the contract
(`plugin/src/contracts/TailscaleBackend.h:182-222`) declares four read-back properties, and the
contract governs.

### R-WRITE-02 · parity · Each action PATCHes one pref with its …Set sibling

**Statement.** Each action sends `PATCH /localapi/v0/prefs` with exactly two
keys: the pref and `<pref>Set: true`. tailscaled ignores a field without its
sibling. The mapping is `setWantRunning` to `WantRunning`,
`setExitNodeAllowLANAccess` to `ExitNodeAllowLANAccess`, `setAcceptRoutes` to
`RouteAll`, `setAcceptDns` to `CorpDNS` and `setExitNode` to `ExitNodeID`.

**Acceptance.** For each of `setWantRunning(true)`, `setWantRunning(false)`,
`setExitNodeAllowLANAccess(true)`, `setAcceptRoutes(true)`,
`setAcceptDns(false)`, `setExitNode(id)` and `setExitNode("")`, called by name
on the singleton once the backend has reached `Running` and the idle barrier
holds, the fake answers the PATCH 200. After the idle barrier, the read
barrier and the fake barrier ("Request counts"), the fake has recorded
exactly one PATCH since the call. Its request line starts with
`PATCH /localapi/v0/prefs HTTP/1.1`, and its JSON body equals
`{<field>: <argument>, <field>Set: true}`.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:155-195`,
`plugin/src/contracts/TailscaleBackend.h:256-274`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1209-1272`,
`pr286-body:41-44`.

### R-WRITE-03 · parity · An exit node is chosen by node ID; empty chooses none

**Statement.** `setExitNode` takes the string node ID that `exitNodeId` and the
`exitNodes` rows use. The body sets `ExitNodeID` and never contains
`ExitNodeIP`, `ExitNodeIPSet` or the peer's address. An empty string clears the
selection. There is no other way to clear it.

**Acceptance.** Given the id and IPv4 of `pentest-exit-node`, with the backend
`Running`, `setExitNode(id)` sends one body with `ExitNodeID` equal to id and
`ExitNodeIDSet` true: after the read barrier and the fake barrier ("Request
counts"), the fake has recorded exactly one PATCH since the call. It has no
`ExitNodeIP` key and no `ExitNodeIPSet` key, and its bytes do not contain the
IPv4. `setExitNode("")`
sends `ExitNodeID` `""`.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:258-264`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:160-163`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1429-1459`.

### R-WRITE-04 · fix · An action publishes nothing; the bus decides

**Statement.** An action returns nothing, before anything has happened. It
changes no property and emits no property signal synchronously. No property
ever takes the requested value merely because it was requested. A write's
outcome moves only `writable` and `writeError` (R-WRITE-06). The prefs
read-backs and the rest of the snapshot move only through a pass: one a
notification starts, or the confirmation pass a 2xx write outcome starts
(R-WRITE-08). Other paths move properties and never take a requested value:
a loss moves `state` and `readError` (R-CONN-02, R-CONN-03, R-CONN-06), a
suggestion outcome moves `recommendedExitNodeId` (R-PARSE-11), a
forwarding check moves `ipForwardingWarning` (R-WRITE-10), a published
snapshot moves `writeError` through R-WRITE-08's judgement and
reconciliation (setting `<setting> was not applied`, or clearing a stale
message), a published snapshot of a reconnect, or one whose
`OperatorUser` changed, re-arms `writable` and `writeError` (R-WRITE-11),
and a `setAdvertiseExitNode` call refused while the routes are unknown sets
`writeError` to `exit node routes are not known yet` after the call has
returned (R-WRITE-10). That refusal is the one path that sets `writeError`
with no request behind it. These paths are complete for the 24 #286 properties (R-UI-02) and for the
snapshot members the rewrite adds. One added member has a further path: `loginUrl` is set
directly from a `BrowseToURL` notification body, outside any snapshot
(R-WATCH-08, R-UI-17), and is cleared with a snapshot whose `state` is not
`NeedsLogin`, by a loss, and when `login()` sends its POST (R-UI-06,
R-UI-17). It carries the daemon's URL, never a requested value.
A pass shows what tailscaled reports, even when that differs from the
request. A refused write leaves a control at its previous value. In #286 the
accepted reply's body is not read, and only a notification moves properties;
R-WRITE-08 adds the confirmation pass. The 2xx body is still not read.
The tag is `fix` because of decision 5: on `a38dbca` nothing moves after an
accepted write until a notification arrives, so the acceptance's
confirmation-pass clauses fail there. Its clauses on what an action does
before the loop runs are #286 behaviour.

**Acceptance.** With paused time, once the backend has reached `Running` with
`exitNodeId` empty and `exitNodeActive` false, `setExitNode(id)` returning is
the barrier: at that point, before the loop runs, `exitNodeId` is still
empty, `exitNodeActive` is still false, and no property signal has fired.
The fake's `/prefs` then selects another peer B, and the PATCH gets 200 with
B's prefs as its body. After the read barrier and the fake barrier ("Request
counts"), the fake has recorded exactly one PATCH since the call. After the
PATCH client has closed and the idle barrier holds, with paused time not
advanced and no notification pushed, the confirmation pass has run: `exitNodeId` is B's id,
`writable` is true, and `writeError` is exactly `exit node was not applied`
(R-WRITE-08). A spy on `exitNodeIdChanged` shows that `exitNodeId` went from
empty to B's id once and never held the requested id. After `{"Prefs":{}}`
and the idle barrier, it is still B's id, not the requested one, and
`exitNodeIdChanged` fired 0 more times. #286 asserts `exitNodeId` empty and
`writeError` empty at the point the confirmation has run
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420-1421`);
those two assertions pin the R-WRITE-08 defect and map there, to its
"exit node imposed" run, which states the same corrected values.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:224-247`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:101-125`,
`plugin/tests/tst_tailscalebackend.cpp:91-106`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1381-1427`,
decisions 1 (`login()` and the `loginUrl` paths it names) and 5.

### R-WRITE-05 · parity · Repeated calls are not collapsed

**Statement.** Every call of #286's five prefs actions (R-UI-13) sends its
own request, in call order. A repeat of a value already in effect is still
sent. The same rule for the added `setAdvertiseExitNode`, and the one call
of it that sends nothing (R-WRITE-10), is R-UI-18's, not this
requirement's. The R-UI-17 `login()` action is not covered by this
rule.

**Acceptance.** With `acceptDns` true and the idle barrier holding, calling
`setAcceptDns(true)` twice, with the fake answering each PATCH 200, gives,
after the idle barrier, the read barrier and the fake barrier ("Request
counts"), exactly two PATCH requests recorded since the first call, in call
order, each with body `{"CorpDNS":true,"CorpDNSSet":true}`.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:155-178`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:165-175`.

### R-WRITE-06 · parity · Only a 403 revokes writable

**Statement.** `writable` starts true and is not a precondition. A 2xx sets
`writable` true and clears `writeError`. A 403 sets `writable` false and puts the
reason in `writeError`. Any other ending sets `writeError` and leaves `writable`
as it was. Examples are another status, a timeout and a dropped or absent
socket. Both values are stored before either change signal, and each fires
only on change. Each outcome replaces the previous one, in arrival order. With
two writes in flight, a failure of write A followed by a 200 for write B
clears A's message, and the later outcome still wins in the rewrite
(decision 5): the user is not told that change A did not happen. Two rules
beyond #286 also move these values, and each lives in its own `fix`
requirement: R-WRITE-08 sets `writeError` when an accepted write was not
applied and clears a stale `writeError` once a snapshot shows the change
applied after all, and R-WRITE-11 re-arms `writable` on a reconnect or an
operator change. In #286 a `writeError` from a non-2xx, timed-out or dropped
write persists until the next write outcome, and only a 2xx sets `writable`
true.

**Acceptance.** A non-2xx outcome starts no confirmation pass
(R-WRITE-08), so after it the client barrier proves the outcome consumed;
unless a clause below names another barrier, each value, each negative and
each signal count after a non-2xx or dropped write is read after the client
barrier and then the read barrier that follow that outcome, with paused time
not advanced, and each count is exact since the write named. A backend that
has reached `Running`, with the idle barrier holding, and has sent no write
reads `writable` true. A 403 gives `writable` false and a `writeError`
containing `403`. `writableChanged` and `writeErrorChanged` have each fired
exactly once since the write, and inside `writableChanged` the new
`writeError` is already readable. In one run a 200 follows the 403 directly:
it gives `writable` true and an empty `writeError`, and after the client
barrier `writableChanged` has fired exactly twice since the first write, once
for the refusal and once for the recovery. That run is staged as #286
stages it: both writes are `setAcceptRoutes(true)`, the 200's body is
`prefs-patched.json`, and the fake's `/prefs` keeps serving `prefs.json`, so
`RouteAll` is false throughout. Inside the `writableChanged` handler that
the 200 fires, `writable` reads true and `writeError` reads empty: the 200's
own outcome stores both before either signal. After the idle barrier
`writable` reads true and `writableChanged` has fired exactly twice since
the first write. What happens to `writeError` after that 200 is not this
requirement's: #286's assertion that it is empty once `writable` is true
again (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1313`)
holds only because #286 never confirms an accepted write, so it maps to
R-WRITE-08 (`fix`), whose "403 then 200, not applied" run names the
corrected value. In another run a 500 follows the
403: at the barriers above, `writable` is false, `writeError` contains `500`
and differs from the 403's message, `writeErrorChanged` has fired exactly
once since the second write and `writableChanged` 0 times. After a 403, a
PATCH held and then dropped by the fake: at the barriers above
`writeError` contains `connection closed`, `writable` is false and
`writableChanged` has fired 0 times since that PATCH. A fresh backend whose
PATCH gets 500 keeps, at the barriers above, `writable` true with a
non-empty `writeError`, and `writableChanged` has fired 0 times since the
write. A fresh backend whose fake vanishes with the PATCH held: the client
barrier does not apply because no fake remains, so the read barrier alone
is taken once `writeErrorChanged` has fired (it needs no fake, so it holds
after the fake vanished); then `writable` is true, `writeError` is
non-empty and `writableChanged` has fired 0 times since the write. Two
writes: the fake
holds PATCH A and answers PATCH B 200. Releasing A with a 500 leaves
`writeError` non-empty. In a second run A gets the 500 first and B the 200
after it, and `writeError` ends empty. Each count is read after the idle
barrier. In both runs A is `setAcceptDns(true)` and B is
`setAcceptRoutes(true)`. B's 200 body has `RouteAll` true and `CorpDNS` false,
and from B's 200 on the fake's `/prefs` holds those values too: B is applied,
so its confirmation pass sets nothing, and A is not, so no snapshot
reconciles A's 500 away (R-WRITE-08). Only the arrival order of the 500 and
the 200 decides `writeError`.

Socket-absent and deadline endings of a write, each on a fresh backend, so
`writable` starts true:

- The backend reaches `Running`, then the fake is destroyed so that nothing
  exists at the path. After the retry barrier for that loss, with paused time
  not advanced, a write yields exactly one `writeErrorChanged` and a
  non-empty `writeError`. A write to an absent socket is never silent, even
  though a read to one publishes no diagnosis (R-CONN-02). `writable` stays
  true, `writableChanged` has fired 0 times since the write, and `readError`
  and `state` hold the values they had before the write. Run once more after
  a 403, `writable` stays false.
- With paused time and an injected 50 ms request deadline (R-CONN-01), a
  backend that has reached `Running` sends a write that the fake records and
  never answers. Paused time advances exactly 49 ms past the instant the fake
  recorded the PATCH. After the read barrier, `writeError` is empty and
  `writeErrorChanged` has fired 0 times since the write. Paused time then
  advances exactly 1 ms more. After the read barrier, at 50 ms, `writeError`
  is non-empty and contains `50 ms`, `writable` is still true, and `state` and
  `readError` hold the values they had before the write. What a later
  snapshot does to that `writeError` is R-WRITE-08's reconciliation.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:249-254`,
`plugin/src/contracts/TailscaleBackend.h:276-308`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:210-235`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:22-26`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:197-217`,
`plugin/tests/tst_tailscalebackend.cpp:108-132`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1274-1379`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420`,
`plugin/lib/tailscale/LocalApiClient.cpp:349`,
`plugin/lib/tailscale/LocalApiClient.cpp:359`,
`plugin/lib/tailscale/LocalApiClient.cpp:135-150`,
`plugin/lib/tailscale/LocalApiClient.cpp:386-390`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:138-143`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:80-84`, `pr286-body:75-78`,
decisions 5 and 20 (re-arming `writable` is R-WRITE-11's).

### R-WRITE-07 · fix · Writes are isolated from the read side

**Statement.** A write's outcome is the PATCH's own reply or failure. It never
pairs into a snapshot and never counts as losing tailscaled. It leaves `state`, `readError`, the models and the reconnect
curve alone. A reconnect does not cancel a write in flight, and that write
still reports its outcome. R-WRITE-08's confirmation is not part of the
outcome: it is an ordinary pass, follows R-WATCH-11 and the read-side rules,
and may publish a whole snapshot or set `readError` like any pass. The one
read-side event that touches `writable` and `writeError` is R-WRITE-11's
re-arm, which a reconnect's snapshot performs. The tag is `fix` because of
decision 20: on `a38dbca` the reconnect leaves `writable` false, so the
acceptance's re-arm, and `writableChanged` firing exactly once on the second
403, fail there. Isolation itself is #286 behaviour.

**Acceptance.** With 20 peers and `Running`, a PATCH answered 403 leaves,
after the client barrier that follows the PATCH connection's close (count back
to 1, the watch), `state` `Running`, 20 rows, `readError` empty and no retry
scheduled. In a second run, a first PATCH answered 403 leaves `writable` false
and `writeError` non-empty. A second PATCH is then held while the fake closes
the watch. This run uses paused time and the shipped timings. After the
retry barrier (the loss is handled and a reconnect is armed, with the first
delay of 500 ms), paused time is advanced exactly 500 ms, so the reconnect
attempt runs: the fake records a second watch and that attempt's
`/status`, `/prefs` and `/suggest-exit-node`, and the idle barrier holds with
the client count at 2 (the new watch and the held PATCH). The reconnect has
re-armed `writable` (R-WRITE-11): it reads true and `writeError` is empty.
Only then does the fake answer the held PATCH 403. After that PATCH client
has closed and the read barrier holds, `writable` is false, `writeError`
contains `403`, `writableChanged` and `writeErrorChanged` have each fired
exactly once since the PATCH was answered, `state` is `Running`, `readError`
is empty and no retry is scheduled. Both PATCHes in this run are
`setAcceptRoutes(true)`.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:285-294`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:126-143`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:246-255`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1297-1303`,
decision 5 (the confirmation pass is not part of the write's outcome).

### R-WRITE-08 · fix · An accepted write that is not applied is reported

**Statement.** A 2xx outcome of a prefs write (any of the six prefs actions,
R-UI-13; not `login()`) starts a confirmation pass at once (decision 5). It
is an ordinary pass through the same machinery as a notification's: if a
pass is already in flight, the 2xx leaves the "stale" mark and the
confirmation is the pass that follows it (R-WATCH-10). It reads `/status`,
`/prefs` and `/suggest-exit-node` and publishes a whole snapshot
(R-WATCH-11), even when no notification follows, so the published value
comes to match what tailscaled holds without waiting for the bus. It is a
read, not the write's outcome (R-WRITE-07), so it may move the models and
`readError` as any pass does; a confirmation that fails is a loss with a
`readError` (R-CONN-03), never silent. No property ever takes the requested
value because it was requested. There is no dedicated property: `writeError`
carries the result (decision 5).

A 2xx that arrives while a reconnect is pending, that is after a loss
(R-CONN-06) and before the next attempt has issued its opening pass, starts
no pass of its own and leaves no "stale" mark. No watch is open then, and a
pass of its own could publish `Running` and clear `readError` before the
reconnect, the window decision 24 closed for notifications (R-CONN-06). The
reconnect attempt's opening pass is its confirmation: it started after the
2xx, so by the rule below the write is judged on that attempt's first
snapshot. A loss never drops a pending judgement either: when the
confirmation pass, or any later pass, fails before a snapshot is published,
the write is judged on the first snapshot that a later pass publishes,
normally the reconnect's opening snapshot. When that same snapshot also
re-arms `writable` (R-WRITE-11), the re-arm is applied first and the
judgement second, both stored with the snapshot before any change signal
(R-UI-06), so a differing read-back leaves `writeError` reading
`<setting> was not applied`.

The write is judged on the first snapshot published by a pass that started
after its 2xx arrived. When that snapshot's read-back differs from the
requested value, `writeError` is set to exactly `<setting> was not applied`
and `writable` keeps its value, so the panel's write note says the change did
not take. `<setting>` names the action's row:

| Action | Read-back compared | `<setting>` |
|---|---|---|
| `setWantRunning(v)` | `wantRunning` | `connection` |
| `setExitNode(id)` | prefs `ExitNodeID` | `exit node` |
| `setExitNodeAllowLANAccess(v)` | `exitNodeAllowLANAccess` | `allow local network access` |
| `setAcceptRoutes(v)` | `acceptRoutes` | `accept routes` |
| `setAcceptDns(v)` | `acceptDns` | `accept dns` |
| `setAdvertiseExitNode(v)` | `advertisingExitNode` | `use this device as an exit node` |

That result is one more write outcome, applied in arrival order like the
others (R-WRITE-06): a later outcome still replaces it, and it replaces an
earlier one. When the snapshot matches, the confirmation sets nothing. The
one exception is a judgement made while `writable` is false, that is on a
snapshot published after a 403 to any write and before a re-arm
(R-WRITE-11) or a 2xx sets `writable` true again: it sets nothing, whatever
the read-back, and the judgement is spent, never made again later.
`writeError` then keeps the 403's reason, which the write note quotes in
its refusal sentence, so that sentence never quotes `<setting> was not
applied`. When the same snapshot also re-arms `writable`, the re-arm is
applied first (see above), so `writable` is true when the judgement is
made and it applies.

A later write of the same setting supersedes an earlier one, so only the
newest accepted value per row of the table is judged. When the 2xx of a
prefs write arrives, any judgement still pending for another write of the
same row (whose 2xx arrived earlier) is dropped: that write is never
judged. Any remembered reconciliation pair of a write of the same row is
dropped with it; that 2xx also clears `writeError` (R-WRITE-06). So after
`setExitNode(A)` and then `setExitNode(B)`, both accepted, A is never judged
on a read-back that already shows B, and the panel never says
`exit node was not applied` while tailscaled holds exactly what the user
last asked for. Writes of different rows never supersede each other.

Reconciliation: while `writeError` holds the message of a prefs write that
ended in any way other than a 2xx or a 403 (another status, a deadline, a
dropped or absent socket), or holds a `... was not applied` message, the
backend remembers that write's read-back and requested value. The first
published snapshot whose read-back equals the requested value clears
`writeError`, stored with that snapshot before any change signal (R-UI-06),
and `writeErrorChanged` fires once. A 403's message is not reconciled: it is
not stale while `writable` is false, because it is the reason the panel is
read-only, and the write note (`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:36-40`, unchanged)
quotes it in the refusal sentence. It stays until the next write outcome or
a re-arm (R-WRITE-11), which sets `writable` true and clears it together.
More generally, reconciliation applies only while `writable` is true: while
it is false no snapshot clears `writeError`, whatever message it holds (for
example a 500 to a direct call after a 403, R-WRITE-06). Nor is
`exit node routes are not known yet` (R-WRITE-10) reconciled; it names no
read-back. So `writable` false with `writeError` empty is never published, and the
views never draw the refusal sentence with an empty `()`. A `login()`
failure is not reconciled either: `login-interactive` has no read-back, so
its `writeError` stays until the next write outcome or a re-arm. In #286 an
accepted write is never confirmed and no snapshot touches `writeError`.

**Defect.** "An accepted write that tailscaled does not apply produces no
feedback at all: no notification, so no refresh, so no motion and no message."
The reconciliation is the owner's decision 5.

**Acceptance.** With paused time and the shipped timings unless a run
injects others, the backend is `Running` with `acceptRoutes` false and
`writeError` empty. The test calls `setAcceptRoutes(true)`. Unless a run
says otherwise, the fake answers the PATCH 200 with its resulting prefs as
the body, and no notification is pushed. Each run states its own request
count: it is read with paused time not advanced past the point the run
names, after that run's closing barrier (the idle barrier, or the retry
barrier where the run ends in a loss) and then the read barrier and the
fake barrier ("Request counts"), and it counts GETs recorded since the
`setAcceptRoutes(true)` call unless the run names another starting point.
The runs:

- **Not applied, no notification.** The fake keeps `RouteAll` false.
  Exactly one more GET each of `status`, `prefs` and `suggest-exit-node`.
  `acceptRoutes` reads false and never read true. `writable` reads true.
  `writeError` is exactly `accept routes was not applied`, and
  `writeErrorChanged` fired exactly once since the 200.
- **403 then 200, not applied (#286's staging).** Staged as
  `plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1279-1313`
  stages it: the fake answers the first `setAcceptRoutes(true)` 403, the
  test calls `setAcceptRoutes(true)` again, and the fake answers that PATCH
  200 with `prefs-patched.json` as its body while its `/prefs` keeps
  serving `prefs.json`, so `RouteAll` is false throughout. After the idle
  barrier that follows the 200's confirmation pass, exactly one more GET
  each of `status`, `prefs` and `suggest-exit-node` has been recorded since
  the second call, `writable` reads true, `writeError` is exactly
  `accept routes was not applied`, and `writeErrorChanged` has fired
  exactly three times since the first call (set by the 403, cleared by the
  200, set by the judgement). This is the corrected value at the observable
  #286 asserts empty
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1313`),
  so that assertion maps here and this run fails on `a38dbca` for that
  reason. Paused time then advances exactly 30 000 ms (one liveness
  interval, whose probe publishes nothing, R-CONN-13); after the idle
  barrier `writeError` is still exactly `accept routes was not applied` and
  `writeErrorChanged` has fired 0 times since the advance. In a second
  variant the fake serves `RouteAll` true from the 200 on, in its body and
  in `/prefs`: after the same barriers `writeError` is empty, and
  `writeErrorChanged` has fired exactly twice since the first call and
  0 times since the advance.
- **Exit node imposed (#286's staging).** This run calls
  `setExitNode(id)` instead of `setAcceptRoutes(true)`, staged as R-WRITE-04
  stages it: `Running` with `exitNodeId` empty, the fake's `/prefs` selects
  another peer B, and the PATCH gets 200 with B's prefs as its body. After
  the PATCH client has closed and the idle barrier holds, with paused time
  not advanced and no notification pushed, exactly one more GET each of
  `status`, `prefs` and `suggest-exit-node` has been recorded since the
  call, `exitNodeId` is B's id, never the requested id, and `writeError` is
  exactly `exit node was not applied`. These are the corrected values at the
  observables #286 asserts empty
  (`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420-1421`),
  so both assertions map here and this run fails on `a38dbca` for that
  reason.
- **Applied, no notification.** The fake sets `RouteAll` true. Exactly one
  more GET each of `status`, `prefs` and `suggest-exit-node`.
  `acceptRoutes` reads true and `writeError` is empty, and
  `writeErrorChanged` fired 0 times since the call.
- **Applied, with a notification.** The fake sets `RouteAll` true and pushes
  `{"Prefs":{}}` right after the 200. Whichever of the two the backend
  handles first starts a pass and the other finds it in flight and leaves
  the "stale" mark (R-WATCH-10), so exactly two more GETs each of `status`,
  `prefs` and `suggest-exit-node` are recorded, in either order of handling.
  `acceptRoutes` reads true and `writeError` stays empty.
- **The confirmation fails.** The fake keeps `RouteAll` false, then answers
  every read after the PATCH with 500. The confirmation pass issues its three
  reads together, so exactly one more GET each of `status`, `prefs` and
  `suggest-exit-node` is recorded, and no reconnect has run because paused
  time has not advanced. After the retry barrier `readError`
  contains `500`, `state` is `NoState`, `writeError` is empty (the
  confirmation published no snapshot to judge), and `acceptRoutes` never
  read true. The run continues: the fake answers reads normally again and
  still keeps `RouteAll` false, and paused time advances exactly 500 ms, the
  delay that loss armed. After the idle barrier `state` is `Running`,
  `readError` is empty, `writeError` is exactly
  `accept routes was not applied` and `writeErrorChanged` has fired exactly
  once since the 200: the pending judgement survived the loss and was made
  on the reconnect's opening snapshot. In a second variant the fake sets
  `RouteAll` true before the advance: after the same barrier `writeError` is
  empty and `writeErrorChanged` has fired 0 times since the 200.
- **A 2xx between a loss and its reconnect.** The fake holds the PATCH of
  `setAcceptRoutes(true)` and then closes the watch with `0\r\n\r\n`. After
  the retry barrier (armed delay 500 ms), with paused time not advanced, the
  fake answers the held PATCH 200 and keeps `RouteAll` false. After the
  client barrier at 0, then the read barrier and the fake barrier ("Request
  counts"), the fake has recorded no GET since the 200, `state` is
  `NoState`, `readError` holds the value it had before the 200 (empty: the
  clean end followed a snapshot, R-CONN-15) and `readErrorChanged` and
  `stateChanged` have fired 0 times since the 200, and `writeError` is
  empty. Paused time then advances exactly 500 ms. After the idle barrier,
  counting from the 200, the fake has recorded exactly one watch and one GET
  each of `status`, `prefs` and `suggest-exit-node` (the reconnect's opening
  pass, and nothing else), `state` is `Running`, `writeError` is exactly
  `accept routes was not applied`, and `writeErrorChanged` has fired
  exactly once since the 200. In a second variant the fake sets `RouteAll`
  true before the advance: `writeError` stays empty and
  `writeErrorChanged` fires 0 times.
- **A pass already in flight.** The two passes are staged to disagree, so
  a judgement on the wrong one is visible, and only one request is ever
  held at a time, since the fake completes every held request with one
  reply (R-FAKE-02). This run starts before `setAcceptRoutes(true)` is
  called. The fake arms a hold on the next GET of `/localapi/v0/status`
  and pushes `{"Prefs":{}}`; the notification's pass gets its `/prefs`
  answered with `RouteAll` false and its `/suggest-exit-node` answered,
  while its `/status` is held. After the read barrier and the fake barrier
  the held count is 1 and the client count is exactly 2 (the watch and the
  held `/status`). The test then calls `setAcceptRoutes(true)`; the fake's
  handler answers the PATCH 200 and serves `RouteAll` true from then on.
  After the client barrier at 2, then the read barrier and the fake
  barrier, the PATCH's 200 has started no request of its own (it leaves the
  "stale" mark, R-WATCH-10): no GET is recorded since the call. The fake
  then completes the held `/status` with the status capture (the completion
  returns 1). After the idle barrier, counting from just before the push,
  the fake has recorded exactly two more GETs each of `status`, `prefs` and
  `suggest-exit-node` (the held pass and the confirmation), `acceptRoutes`
  reads true, `writeError` is empty and `writeErrorChanged` has fired 0
  times since the 200. An implementation that judges the write on the
  in-flight pass's snapshot (`RouteAll` false) sets `accept routes was not
  applied` and the confirmation then reconciles it away, firing
  `writeErrorChanged` twice. In a second variant the fake also holds the
  confirmation's `/status`: just before completing the in-flight `/status`
  it arms the hold on the next GET of `/localapi/v0/status` again, so the
  completion still returns 1 and reaches only the in-flight request, and the
  confirmation's `/status` is held when it arrives (R-FAKE-02: a hold armed
  while another request is held holds a further one). Once the in-flight
  pass has published (after the read barrier, `acceptRoutes` reads false,
  the held count is 1 and the client count is exactly 2, the watch and the
  confirmation's held `/status`), `writeError` is still empty and
  `writeErrorChanged` has fired 0 times since the 200; completing it then
  ends as the first variant does.
- **A later write of the same setting.** From `Running` with `exitNodeId`
  empty, A and B are two exit-capable peers of the served capture. The
  fake's handler answers each PATCH of `/localapi/v0/prefs` 200 and from
  then on serves that PATCH's `ExitNodeID` in `/prefs` and an
  `ExitNodeStatus` with that `ID` in `/status`. The fake arms a hold on the
  next GET of `/localapi/v0/prefs`. The test calls `setExitNode(A)`; its
  200 starts the confirmation pass, whose `/prefs` is held (after the read
  barrier and the fake barrier, the held count is 1). The test then calls
  `setExitNode(B)`; its 200 arrives while that pass is in flight and leaves
  the "stale" mark. After the client barrier at 2 (the watch and the held
  `/prefs`) and the read barrier, the fake completes the held `/prefs` with
  prefs selecting B, so A's confirmation pass publishes a read-back of B.
  After the idle barrier `exitNodeId` is B's id, `writeError` is empty, and
  `writeErrorChanged` has fired 0 times since the `setExitNode(A)` call;
  counting from that call the fake has recorded exactly two PATCHes and two
  GETs each of `status`, `prefs` and `suggest-exit-node` (A's confirmation
  and the pass the stale mark started). An implementation that judges A on
  that snapshot sets `exit node was not applied`, which B's matching
  confirmation never clears.
- **Reconciled after a deadline.** With an injected 50 ms request deadline,
  the fake records the PATCH and never answers it, so there is no 2xx and no
  confirmation pass. Paused time advances exactly 50 ms past the instant the
  fake recorded the PATCH; after the read barrier `writeError` contains
  `50 ms`, and the fake has recorded no GET since the call. The fake then
  serves `/prefs` with `RouteAll` true and pushes `{"Prefs":{}}`. After the
  idle barrier, counting from the push, exactly one more GET each of
  `status`, `prefs` and `suggest-exit-node` is recorded, `acceptRoutes` is
  true, `writeError` is empty and `writeErrorChanged` fired exactly once
  since the deadline. In a second run the fake answers the PATCH 403
  instead, which starts no confirmation pass, and serves the same `/prefs`
  and push: counting from the push, exactly one more GET of each is
  recorded, and that snapshot does not reconcile the 403's message:
  `acceptRoutes` is true, `writeError` still holds the 403's reason
  unchanged, `writable` is still false, and `writeErrorChanged` and
  `writableChanged` have each fired 0 times since the push. `writable`
  false with `writeError` empty is therefore unreachable from the shipped
  backend, so `ts-exit-write-error`, `ts-settings-write-error` and
  `ts-connect-tip` never draw the refusal sentence with an empty `()`, and
  no view criterion stages that pair (R-QML-20).
- **A judgement after a 403.** With the fake arming a hold on the next GET
  of `/localapi/v0/status` before the PATCH is answered, the PATCH of
  `setAcceptRoutes(true)` (write A) gets 200 and the fake keeps `RouteAll`
  false. After the read barrier and the fake barrier, A's confirmation
  `/status` is held (held count 1). The test then calls
  `setAcceptDns(true)` (write B), which the fake answers 403. After the
  client barrier at 2 (the watch and the held `/status`) and the read
  barrier, `writable` is false and `writeError` is the 403's reason; record
  it. The fake then completes the held `/status` with the status capture.
  After the idle barrier, with paused time not advanced, `acceptRoutes`
  reads false, `writable` is still false, `writeError` still equals the
  recorded 403 reason, and `writeErrorChanged` and `writableChanged` have
  each fired 0 times since the 403. A later `{"Prefs":{}}` push with
  `RouteAll` still false leaves, after the idle barrier, the same values and
  0 more signals: the spent judgement is not made again.
- **Reconciled after "not applied".** After the first run, the fake sets
  `RouteAll` true and pushes `{"Prefs":{}}`. After the idle barrier,
  counting from the push, exactly one more GET each of `status`, `prefs` and
  `suggest-exit-node` is recorded, and `writeError` is empty.
- **Whole snapshot.** A separate run stages "applied, no notification", but
  before the PATCH is answered the fake arms a hold on the next GET of
  `/localapi/v0/status` (R-FAKE-02), so the confirmation's `/status` is held
  unanswered. After the read barrier, with paused time not advanced, the
  fake has recorded that GET (held count 1), so paused time never reaches
  that GET's request deadline (R-HTTP-13). At that point `acceptRoutes` reads
  false and `acceptRoutesChanged` has fired 0 times since the PATCH. The fake
  then answers the held GET with the status capture. After the idle barrier,
  `acceptRoutes` reads true, `writeError` is empty and `acceptRoutesChanged`
  has fired exactly once, and exactly one more GET each of `status`, `prefs`
  and `suggest-exit-node` has been recorded since the call.

**Sources.** `pr286-body:114-115`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:109-121`,
`plugin/lib/testing/fakesocketserver.cpp:89-106` (one completion reaches
every held request, so the runs hold one request at a time),
the defect pinned by #286 (after a 200 for an exit node the daemon did not
select, `writeError` reads empty and `exitNodeId` has not moved) at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420-1421`,
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:36-40`,
decision 5.

### R-WRITE-09 · fix · Disconnecting is exercised end to end

**Statement.** `setWantRunning(false)` sends the disconnect write. The panel
follows tailscaled to `Stopped`, with the connect toggle off and still able to
reconnect. A test proves this against a fake tailscaled, never by ending a live
session.

**Defect.** "`tailscale down` is the one action here never exercised live:
clicking it on the test VM would end the session looking at it."

**Acceptance.** With the fake `Running`, `setWantRunning(false)` sends
`{"WantRunning":false,"WantRunningSet":true}`. The fake answers 200 and from
then on reports `WantRunning` false and `BackendState` `Stopped`, and
notifies. After the idle barrier `wantRunning` is false, `state` is
`Stopped`, `writeError` is empty (R-WRITE-08 finds the write applied) and
the toggle is enabled and unchecked. Toggling sends
`{"WantRunning":true,"WantRunningSet":true}`.

**Sources.** `pr286-body:130-131`. #286 covers the view half only, against the
QML stand-in: `tests/tailscale-qml-test.qml:1564-1578`.

### R-WRITE-10 · new · Use this device as an exit node

**Statement.** From the exit-node view, a user can offer this machine as an
exit node and stop offering it. The row shows what tailscaled holds, read
back, not the last click. Refusals and failures follow R-WRITE-06, and an
accepted write is confirmed by R-WRITE-08. #286 ships this as a disabled row
reading "not in this release". The design is decision 2, option (c): a
runtime check the panel reports, plus an opt-in bootstrap step (R-BOOT-07).

Contract members (listed under "Contract additions"):

- `advertisingExitNode` (bool, read-only, `advertisingExitNodeChanged`): true
  exactly when the published `/prefs` `AdvertiseRoutes` contains both
  `0.0.0.0/0` and `::/0`. A missing or null `AdvertiseRoutes` reads false.
- `setAdvertiseExitNode(bool)` (invokable): one
  `PATCH /localapi/v0/prefs` whose body is exactly
  `{"AdvertiseRoutes":[...],"AdvertiseRoutesSet":true}`. The list keeps the
  last published `AdvertiseRoutes` in order with every `0.0.0.0/0` and
  `::/0` removed, then, for true, appends `0.0.0.0/0` and `::/0` in that
  order. Subnet routes the user advertises are therefore kept; only the two
  exit-node routes are added or removed. The list is rebuilt only from a
  read-back that is both current and well formed. The routes are unknown,
  and the call refuses, in three cases: before any snapshot was published;
  while `state` is `NoState` (after a loss the kept prefs come from a
  daemon that may have restarted with other routes, R-CONN-06); and while
  the last published `AdvertiseRoutes` is present but neither null nor an
  array whose every entry is a string (for example `"x"` or
  `["172.16.9.0/24",5]`, which R-CONN-14 reads as its default, so
  `advertisingExitNode` reads false and rebuilding from it would overwrite
  every subnet route). A refused call sends nothing and, after it has
  returned (an action changes nothing synchronously, R-WRITE-04), sets
  `writeError` to exactly `exit node routes are not known yet`, with
  `writable` unchanged. This is the one prefs-action call that can send no
  request (R-WRITE-05). #286 avoided both hazards by writing one field per
  write (`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:188-190`); this refusal is how the
  rewrite keeps decision 2's "keep subnet routes" safe.
- `exitNodeAwaitingApproval` (bool, read-only,
  `exitNodeAwaitingApprovalChanged`): true exactly when
  `advertisingExitNode` is true and the `/status` `Self.AllowedIPs` is an
  array that does not contain `0.0.0.0/0`, so the tailnet admin has not
  approved the route yet. It is false whenever `advertisingExitNode` is
  false, and false when `Self` or `Self.AllowedIPs` is absent, null or not
  an array (as in a `NeedsLogin` or `Stopped` status without a netmap): a
  reply that never described approval makes no claim about it.
- `ipForwardingWarning` (string, read-only, `ipForwardingWarningChanged`):
  tailscaled's own IP-forwarding check. A pass also sends
  `GET /localapi/v0/check-ip-forwarding` when the last published snapshot
  has `advertisingExitNode` true, or when it is the confirmation pass of a
  `setAdvertiseExitNode(true)`; otherwise it does not. Every published
  snapshot that has `advertisingExitNode` true carries a check judged
  against it: when such a snapshot's own pass sent no check, the backend
  sends one follow-up `GET /localapi/v0/check-ip-forwarding` at once, when
  that snapshot is published. That happens for the opening pass of the
  first attempt on a machine already advertising (no earlier snapshot), and
  for a pass whose earlier snapshot had `advertisingExitNode` false while
  advertising was turned on outside the panel (for example with
  `tailscale set --advertise-exit-node`). The follow-up check belongs to
  that pass: its reference snapshot is that pass's snapshot, the pass has
  already ended, and its outcome is judged by the rules below like a check
  the pass sent itself. So `ipForwardingWarning` never stays empty without a
  check behind it while `advertisingExitNode` reads true. The value is the
  reply's `Warning` string verbatim, empty when tailscaled finds forwarding
  enabled. Like the suggestion (R-PARSE-11, R-CONN-11), its outcome moves
  only this property, never counts toward an attempt's wholeness (R-CONN-09),
  and is never a loss: no `readError`, no `NoState`, no retry. A check that
  did not run must not read like a check that passed, so a failed or
  malformed outcome sets a named value instead of empty: a failure sets
  exactly `could not check ip forwarding: <reason>`, where `<reason>` is the
  transport's failure reason (R-HTTP-09, R-HTTP-13, R-CONN-03); a 2xx reply
  that is not a JSON object with a string `Warning` sets exactly
  `could not check ip forwarding: the reply had no Warning string`. The one
  exception is a failure flagged socket-absent (R-HTTP-10), which sets it
  empty: nothing is there to check, `state` is `NoState`, the exit card is
  hidden, and R-CONN-02 publishes no diagnosis for an absent daemon. A check outcome is judged against its own
  pass, never against whichever snapshot happens to be the last published
  when its reply arrives, because the check and the pass's `/status` and
  `/prefs` travel on separate connections whose order is not deterministic
  (R-HTTP-11, R-WATCH-07). The outcome takes effect once both it has
  arrived and its pass has ended, whichever comes later. A pass ends when
  it publishes its snapshot, or when a loss abandons it (R-CONN-06). The
  reference snapshot is that pass's own snapshot. For a pass a loss
  abandoned, it is the last snapshot published before the outcome takes
  effect. The outcome is dropped and moves nothing when the reference
  snapshot has `advertisingExitNode` false. It is also dropped when a
  newer pass's check outcome has already taken effect, and when a snapshot
  newer than its reference snapshot has been published with
  `advertisingExitNode` false. Otherwise it sets
  `ipForwardingWarning`. When the outcome arrived before its pass
  published, it is stored with that snapshot, before any change signal
  (R-UI-06). A snapshot that publishes `advertisingExitNode` false sets
  `ipForwardingWarning` empty in that snapshot. So the confirmation pass of
  a `setAdvertiseExitNode(true)` that tailscaled applied always reports its
  own check, in either arrival order. The plugin reads no file for this:
  tailscaled runs the check.

`advertisingExitNode` and `exitNodeAwaitingApproval` are snapshot
properties (R-UI-06); `ipForwardingWarning` moves on its own outcome.

Accepted gap: `ipForwardingWarning` is as current as the last pass that
sent a check, and a pass runs only for a notification, an accepted write
or a reconnect (R-WATCH-07); the liveness probe sends no check
(R-CONN-13). So a change to forwarding made outside tailscaled, for example
`c7shell-bootstrap --tailscale-exit-node` (R-BOOT-07) run while the shell
is open on a quiet bus, shows only at the next pass, with no bound on how
long that takes. No criterion implies the warning is current between
passes.

The view: `ts-exit-advertise` is titled `use this device as an exit node`
and holds the switch `ts-exit-advertise-switch`, checked exactly when
`advertisingExitNode` is true. A click on the row or the switch calls
`setAdvertiseExitNode(!advertisingExitNode)` and moves nothing itself. The
row's subtitle reads exactly `awaiting approval` while
`exitNodeAwaitingApproval` is true and is the empty string otherwise,
whatever `writable` reads: #286's reason `not in this release` is gone,
because the row now has an action. While `ipForwardingWarning` is non-empty,
the line `ts-exit-advertise-warning` below the row shows it verbatim as
plain text (R-SEC-03). While `writable` is false, the row is dead like the
other controls (R-QML-20): its title is in `Theme.textDisabled`, it is not
hoverable, its switch is disabled, and a click calls nothing; the sub-card's
write-error line gives the reason. While `writable` is true the title is in
`Theme.alpha(Theme.text, 0.85)`, the colour of the other live control rows
(`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:292`).

**Acceptance.** Backend half, with the fake's `/prefs` `AdvertiseRoutes`
`["172.16.9.0/24"]` and the idle status: after the idle barrier
`advertisingExitNode` and `exitNodeAwaitingApproval` are false,
`ipForwardingWarning` is empty, and the opening pass sent no
`check-ip-forwarding`. Every request count below is read after the idle
barrier, the read barrier and the fake barrier ("Request counts").
`setAdvertiseExitNode(true)` makes the fake record
exactly one PATCH whose body, compared as JSON, is
`{"AdvertiseRoutes":["172.16.9.0/24","0.0.0.0/0","::/0"],"AdvertiseRoutesSet":true}`.
The fake answers 200 and from then on serves those routes in `/prefs`, a
`Self.AllowedIPs` without `0.0.0.0/0`, and `{"Warning":"IP forwarding is
disabled"}` from `check-ip-forwarding`. After the idle barrier, with no
notification pushed, `advertisingExitNode` is true,
`exitNodeAwaitingApproval` is true, `ipForwardingWarning` is
`IP forwarding is disabled`, and `writeError` is empty. The fake then adds
`0.0.0.0/0` and `::/0` to `Self.AllowedIPs`, answers the check with
`{"Warning":""}` and pushes `{"Prefs":{}}`; after the idle barrier
`exitNodeAwaitingApproval` is false and `ipForwardingWarning` is empty.
`setAdvertiseExitNode(false)` sends one PATCH whose body is exactly
`{"AdvertiseRoutes":["172.16.9.0/24"],"AdvertiseRoutesSet":true}`. With
`AdvertiseRoutes` null, `setAdvertiseExitNode(true)` sends
`{"AdvertiseRoutes":["0.0.0.0/0","::/0"],"AdvertiseRoutesSet":true}`. A fresh
backend whose fake holds the opening `/status`, so nothing has been
published: right after `setAdvertiseExitNode(true)` returns, `writeError` is
still empty. Once `writeErrorChanged` has fired, and after the read barrier
and the fake barrier, `writeError` is exactly
`exit node routes are not known yet`, `writable` is true, the fake has
recorded no PATCH, and the client count is exactly 2 (the watch and the held
`/status`). In a separate run a 403 to the first write leaves, after the
idle barrier, `advertisingExitNode` false and `writable` false. In another,
with `advertisingExitNode` true published, the check answers
`HTTP/1.1 500 Internal Server Error` with `Content-Length: 0` after a
`{"Prefs":{}}` push: after the idle barrier `ipForwardingWarning` is exactly
`could not check ip forwarding: /localapi/v0/check-ip-forwarding answered HTTP/1.1 500 Internal Server Error`,
`state` is `Running`, `readError` is empty, and the retry hook reads 0
retries armed since the push. Three more runs from the same start answer
the check 200 with the bodies `x`, `[]` and `{"Warning":5}`; after the idle
barrier `ipForwardingWarning` is exactly
`could not check ip forwarding: the reply had no Warning string` in each,
with `state` `Running`, `readError` empty and 0 retries armed since the
push.

Refused rebuilds, each in a separate run from `Running`, with every count
read after the read barrier and the fake barrier ("Request counts") once
`writeErrorChanged` has fired: with the fake's `/prefs` `AdvertiseRoutes`
`"x"`, and in another run `["172.16.9.0/24",5]`, after the idle barrier
`advertisingExitNode` reads false, and `setAdvertiseExitNode(true)` records
no PATCH and sets `writeError` to exactly `exit node routes are not known
yet`, with `writable` true. After a loss (the fake closes the watch with
`0\r\n\r\n`; the retry barrier, paused time not advanced), with
`AdvertiseRoutes` `["172.16.9.0/24"]` published before it,
`setAdvertiseExitNode(true)` likewise records no PATCH and sets that
`writeError`. Approval not described: with `AdvertiseRoutes`
`["0.0.0.0/0","::/0"]` and a `/status`
`{"BackendState":"NeedsLogin","Self":{"ID":"nSELF"}}` whose `Self` has no
`AllowedIPs`, after the idle barrier `advertisingExitNode` reads true and
`exitNodeAwaitingApproval` reads false.

Advertising that tailscaled already holds, in two separate runs, with the
check answering `{"Warning":"IP forwarding is disabled"}` and no
notification pushed beyond the one named. (1) A fresh backend whose first
`/prefs` has `AdvertiseRoutes` `["0.0.0.0/0","::/0"]`: after the idle
barrier, then the read barrier and the fake barrier, `advertisingExitNode`
is true, `ipForwardingWarning` is exactly `IP forwarding is disabled`, and
the fake has recorded exactly one `check-ip-forwarding` (the follow-up
check of the opening snapshot) and five requests in all: the watch, one GET
each of `status`, `prefs` and `suggest-exit-node`, and that check. (2) From
the idle staging above (`AdvertiseRoutes` `["172.16.9.0/24"]`,
`advertisingExitNode` false), the fake serves `AdvertiseRoutes`
`["172.16.9.0/24","0.0.0.0/0","::/0"]`, as `tailscale set
--advertise-exit-node` would leave it, and pushes `{"Prefs":{}}`. After the
idle barrier, then the read barrier and the fake barrier,
`advertisingExitNode` is true, `ipForwardingWarning` is exactly
`IP forwarding is disabled`, and counting from the push the fake has
recorded exactly one `check-ip-forwarding` and one GET each of `status`,
`prefs` and `suggest-exit-node`. In both runs paused time has not advanced,
so no probe has run.

The runs below start after the idle barrier, so any follow-up check of an
earlier snapshot has already been applied.

Arrival order of check outcomes, with `advertisingExitNode` true published
and the check answering `{"Warning":"W1"}` until stated: the fake holds pass
N's `check-ip-forwarding`, and that pass publishes its snapshot (its
`/status` and `/prefs` answered). The fake switches the check reply to
`{"Warning":"W2"}` and pushes `{"Prefs":{}}`, which starts pass N+1. Once
the read barrier holds with the client count at exactly 2 (the watch and
the held check), `ipForwardingWarning` reads `W2`. The held check is then
completed with `{"Warning":"W1"}`. After the client barrier at 1 and the
read barrier, `ipForwardingWarning` still reads `W2` and
`ipForwardingWarningChanged` has fired 0 times since it became `W2`. In a
second run the held check is completed with a 500 instead; it still reads
`W2`, with the same 0 count.

An older check after advertising stopped, in a separate run: the fake holds
pass N's `check-ip-forwarding` as above, and pass N publishes its snapshot
(`advertisingExitNode` true). The fake then serves `AdvertiseRoutes`
`["172.16.9.0/24"]` and pushes `{"Prefs":{}}`; pass N+1 publishes
`advertisingExitNode` false, and its own check, answered, is dropped. Once
the read barrier holds with the client count at exactly 2 (the watch and
the held check), the held check is completed with `{"Warning":"W1"}`. After
the idle barrier `advertisingExitNode` is false, `ipForwardingWarning` is
empty, and a spy on `ipForwardingWarningChanged` shows it never read `W1`
since the push.

Advertising stops while a warning shows, in a separate run: from the point
above where `ipForwardingWarning` reads `IP forwarding is disabled` (before
the fake adds the routes to `Self.AllowedIPs`), the fake serves `/prefs`
with `AdvertiseRoutes` `["172.16.9.0/24"]`, switches the check reply to a
different text, `{"Warning":"W3"}`, and pushes `{"Prefs":{}}`. That pass
sends the check, because the snapshot before it had `advertisingExitNode`
true. The check outcome is judged against its own pass's snapshot, which has
`advertisingExitNode` false, so it is dropped whichever of the snapshot and
the check outcome arrives first. Two runs control that order, as the
confirmation-pass runs below do. In the first the fake arms a hold on the
next GET of `/localapi/v0/check-ip-forwarding` before the push, and
completes it with `{"Warning":"W3"}` once the read barrier holds with the
client count at exactly 2 (the watch and the held check). In the second it
arms the hold on the next GET of `/localapi/v0/status` instead, and
completes it once the read barrier holds with the client count at exactly 2
(the watch and the held `/status`), the check reply having arrived. In each
run, after the idle barrier (which by its definition, "How to read", cannot
hold before that check's outcome has been applied or dropped),
`advertisingExitNode` is false, `ipForwardingWarning` is empty,
`ipForwardingWarningChanged` has fired exactly once since the push, and a
spy on it shows `ipForwardingWarning` never read `W3`.

Both arrival orders of the confirmation pass of `setAdvertiseExitNode(true)`,
each in a separate run staged as the first paragraph above (the fake answers
the PATCH 200 and then serves the advertised routes and `{"Warning":"IP
forwarding is disabled"}`). In the first run the fake arms a hold on the
next GET of `/localapi/v0/check-ip-forwarding` (R-FAKE-02) before the PATCH
is answered. Once the read barrier holds with the client count at exactly 2
(the watch and the held check), the confirmation's snapshot has been
published: `advertisingExitNode` is true and `ipForwardingWarning` is still
empty. The fake then completes the held check with `{"Warning":"IP
forwarding is disabled"}`. After the idle barrier
`ipForwardingWarning` is `IP forwarding is disabled`. In the second run the
fake instead arms the hold on the next GET of `/localapi/v0/status`. Once
the read barrier holds with the client count at exactly 2 (the watch and
the held `/status`), the check reply has arrived, `ipForwardingWarning` is
still empty and `ipForwardingWarningChanged` has fired 0 times since the
call. The fake then completes the held `/status` with the status it
serves in this staging (`Self.AllowedIPs` without `0.0.0.0/0`). After the
idle barrier
`advertisingExitNode` is true, `ipForwardingWarning` is `IP forwarding is
disabled`, and `ipForwardingWarningChanged` has fired exactly once since the
call. Neither run pushes a notification.

View half, on the QML stand-in with the advertise members present and the
exit-node view open, staged as #286 stages its dead-row checks (`writable`
true, `exitNodeAwaitingApproval` false, `advertisingExitNode` false, no call
recorded yet). The stand-in records calls synchronously, so the click
returning is the barrier for each recorded-call clause:

- `ts-exit-advertise` is visible (#286's `:1183`, unchanged).
- Its title colour equals `Theme.alpha(Theme.text, 0.85)`, not
  `Theme.textDisabled` (replaces `:1184`, which pins `Theme.textDisabled`).
- Its subtitle is exactly the empty string (replaces `:1186`, which pins a
  non-empty reason).
- A click records exactly one call, `setAdvertiseExitNode(true)` (replaces
  `:1188`, which pins no call), and leaves `ts-exit-advertise-switch`
  unchecked.

Setting `advertisingExitNode` true checks the switch, and a click then
records exactly one more call, `setAdvertiseExitNode(false)`. With
`exitNodeAwaitingApproval` true the subtitle reads `awaiting approval`, and
setting it false again makes the subtitle empty. With
`ipForwardingWarning` set to `<b>x</b>`, `ts-exit-advertise-warning` is
visible and shows those eight characters as plain text. After `writable`
goes false, the title is in `Theme.textDisabled`, the row is not hoverable,
the switch is disabled, the subtitle is still the empty string, and a click
records no call, like the other controls after a 403 (R-QML-20).

#286's dead-row checks (`tests/tailscale-qml-test.qml:1183-1188`) assert the
row on a contract that has no advertise action. Decision 2 adds that action,
so on the rewrite the row is live: `:1184`, `:1186` and `:1188` hold on
`a38dbca` only because the action is missing, and map here, to the
replacements above. This criterion's view half fails on `a38dbca` for that
reason. R-QML-29, which described the dead row, is withdrawn.

**Sources.** `pr286-body:22-24`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:314-333` (#286's
dead row: `Theme.textDisabled` title at `:329`, `not in this release` at
`:331`),
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:292` (the live rows'
title colour),
`tests/tailscale-qml-test.qml:1177-1189` (the dead-row checks at `:1183`,
`:1184`, `:1186` and `:1188`),
`docs/superpowers/specs/2026-10-15-tailscale-v2-design.md:114-118`,
`plugin/lib/tailscale/tests/fixtures/prefs.json` (`"AdvertiseRoutes": null`),
`plugin/lib/tailscale/tests/fixtures/status-idle.json` (`Self.AllowedIPs`),
decision 2.

### R-WRITE-11 · fix · writable re-arms on a reconnect and on an operator change

**Statement.** After a 403, `writable` is false and every control is dead
(R-QML-20), so the panel cannot send the accepted write that would set it
true again. The backend therefore re-arms it (decision 20): while `writable`
is false, it becomes true, and `writeError` becomes empty, when either

- an attempt that follows a loss publishes its first snapshot (a reconnect),
  or
- a published snapshot's `/prefs` `OperatorUser` differs from the previous
  published snapshot's (absent reads as empty), as when the user runs
  `c7shell-bootstrap` while the shell is open.

Both values are stored with that snapshot, before any change signal
(R-UI-06), and each signal fires once. Re-arming is a guess, not evidence:
the next write confirms it, and a 403 to it revokes `writable` again
(R-WRITE-06). While `writable` is true, neither event changes `writable` or
`writeError`. In #286 only a 2xx sets `writable` true and a reconnect does
not reset it, so after the user fixes the operator the panel stays read-only
for the life of the shell.

**Acceptance.** From `Running`, a 403 to `setAcceptRoutes(true)` leaves
`writable` false. (a) The fake then serves prefs with `OperatorUser`
`tester` and pushes `{"Prefs":{}}`. After the idle barrier `writable` is
true, `writeError` is empty, and `writableChanged` and `writeErrorChanged`
each fired exactly once since the push; inside `writableChanged`,
`writeError` already reads empty. (b) In a separate run, after the 403 the
fake closes the watch with `0\r\n\r\n`, and paused time advances
exactly 500 ms, the delay of the retry that loss armed (paused time and the
shipped timings, R-CONN-07). After the idle barrier of the reconnect attempt,
`writable` is true and `writeError` empty, each signal fired once since the
loss. Before that attempt published, after the retry barrier, `writable` was
still false. (c) A notification whose snapshot leaves `OperatorUser`
unchanged: after the idle barrier, `writable` is false, and
`writableChanged` and `writeErrorChanged` have each fired 0 times since the
push; the fake keeps `RouteAll` false (R-WRITE-08 never reconciles a
403's message, and the fake also keeps the refused write unapplied). (d) With
`writable` true, `setAcceptRoutes(true)` answered 500 leaves a
`writeError` containing `500`; the fake keeps `RouteAll` false in every
`/prefs` it serves from then on, so no snapshot shows that write applied and
R-WRITE-08's reconciliation does not apply. The fake then closes the watch
with `0\r\n\r\n` and paused time advances exactly 500 ms. After the idle
barrier of the reconnect attempt, `state` is `Running`, `writable` is true,
`writeError` still holds the 500's reason unchanged, and `writableChanged`
and `writeErrorChanged` have each fired 0 times since the watch closed.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:197-217`
(only a write outcome sets `writable`),
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1316-1327`
(the comment naming the lockout),
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:4-41`,
decision 20.

## R-UI: contract surface

### R-UI-01 · parity · The Tailscale singleton in module C7

**Statement.** Module `C7` exposes a QML singleton named `Tailscale`. Each engine
creates one and owns it. Its factory selects the backend, which today is always
the local-API backend.

**Acceptance.** With only the built or installed module directory on the import
path, resolving `Tailscale` from `C7` returns a non-null object whose
metaobject inherits the contract type. Resolving it twice in one engine
returns the same object. Two engines get two different objects. Setup, not
acceptance: the suite first checks that `C7/qmldir` exists under the module
directory.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:54-57`,
`plugin/src/contracts/TailscaleBackend.h:341-343`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:695-704`,
`plugin/tests/tst_module.cpp:27-33`. The #286 suite resolves the
singleton at `plugin/tests/tst_module.cpp:106-108`, `:127` and `:163-164`, and
checks `C7/qmldir` at `:75-79`; those checks are harness preconditions of the
module tests, listed in the traceability file.

### R-UI-02 · fix · The exact property set

**Statement.** Beyond the base object's own, the singleton exposes the 24
properties of #286 with these names and types. It also exposes exactly the
five properties listed under "Contract additions" (decisions 1, 2 and 6), and
no others: 29 in all. #286 exposes exactly the 24, and its exact-set test
pins that set, so the exact set is the part decisions 1, 2 and 6 change. The
24 are
`state` (enum); `selfName`, `selfIp4`, `selfIp6`,
`selfDnsName` and `tailnet` (string); `keyExpiry` (date-time); `exitNodeActive`
(bool); `exitNodeId` and `exitNodeName` (string); `exitNodeOnline` and
`exitNodeBlocked` (bool); `issues` (string list); `issueCount` (int); `peers`
and `exitNodes` (list models); `recommendedExitNodeId` (string); `writable`
(bool); `writeError` and `readError` (string); and `wantRunning`,
`exitNodeAllowLANAccess`, `acceptRoutes` and `acceptDns` (bool).

**Acceptance.** There are two checks. The parity check: the 24 names are a
subset of the property names, and each has the stated type and the same notify
signal as in #286. The exact-set check: the sorted property names, excluding
`objectName`, equal the 24 plus the five properties under "Contract
additions": `advertisingExitNode`, `exitNodeAwaitingApproval`,
`ipForwardingWarning`, `loginUrl` and `peersKnown`, 29 in all. No error-body
field and no unapplied-write property exist (decisions 3 and 5), and the
retry curve and the test barriers are core-crate test hooks, not properties
(decision 12). Each property reads from QML with the stated type. The parity
check holds on `a38dbca`. The exact-set check replaces #286's
`plugin/tests/tst_module.cpp:152`, which compares the sorted names with the
24 alone: on the rewrite that comparison would fail, and this check fails on
`a38dbca`, which lacks `advertisingExitNode`, `exitNodeAwaitingApproval`,
`ipForwardingWarning`, `loginUrl` and `peersKnown`.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:59-84`,
`plugin/tests/tst_module.cpp:35-45`, `plugin/tests/tst_module.cpp:118-153`
(the exact 24-name comparison at `:152`), decisions 1, 2 and 6.

### R-UI-03 · parity · Every property is read-only

**Statement.** QML cannot assign any property. State changes only when the
system reports a change, or when an action's outcome is published.

**Acceptance.** None of #286's 24 properties is writable. That the five
listed under "Contract additions" are read-only too is R-UI-18's, not this
requirement's.
`Tailscale.wantRunning = true` fails. The assignment is synchronous, so the
assignment statement returning is the barrier: right after it,
`wantRunning` reads the value it read before, and `wantRunningChanged` has
fired 0 times since just before the assignment.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:22-26`,
`plugin/src/contracts/TailscaleBackend.h:59-84`.

### R-UI-04 · parity · The State enum

**Statement.** `state` is an enum with exactly `NoState` = 0,
`NeedsMachineAuth` = 1, `NeedsLogin` = 2, `Stopped` = 3, `Starting` = 4 and
`Running` = 5. QML names the values on the singleton. A backend that has not
heard from tailscaled reports `NoState`, never `Stopped`. tailscaled's own
`"NoState"` is a value the enum names and reads `NoState` with no
`readError` (R-WATCH-13). A `BackendState` the enum does not name also reads
`NoState`; what `readError` reads with it is
R-WATCH-13's `fix`, not this requirement's.

**Acceptance.** `Tailscale.NoState` to `Tailscale.Running` evaluate to 0 to 5 in
that order. A fresh backend reads 0.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:87-104`,
`plugin/tests/tst_module.cpp:109`, decision 23 (a `BackendState` the enum does
not name, R-WATCH-13).

### R-UI-05 · parity · A fresh backend reads as nothing known yet

**Statement.** Before any reply, `state` is `NoState`. All of #286's string
properties are empty. `keyExpiry` is invalid. All of #286's booleans are
false, except `writable`, which is true. `issues` is empty and `issueCount` is 0. `peers`
and `exitNodes` are non-null and empty.

**Acceptance.** A backend created with its socket path in an isolated directory
reads these values. After the retry barrier for the first connect, `state` is
0, `exitNodeBlocked` false, there are 0 peer rows and `readError` is empty. The
C++ test's `qWait(250)` becomes that barrier.

The test-only fake backend (R-UI-14) starts in the same values. A freshly
constructed fake, read through the contract before any setter or action is
called (construction returning is the barrier; the fake has no asynchronous
work), reads `state` `NoState`, `selfDnsName` empty, `keyExpiry` invalid,
`exitNodeActive` false, `exitNodeBlocked` false, `issueCount` 0, `peers`
and `exitNodes` non-null, `recommendedExitNodeId` empty, `writable` true,
`writeError` empty and `readError` empty. The fresh values of the five
members listed under "Contract additions" are R-UI-18's, not this
requirement's.

**Sources.** `plugin/tests/tst_tailscalebackend.cpp:19-43` (the fresh-fake
values, asserted at `:23-31`, `:37`, `:38` and `:42`),
`plugin/tests/tst_module.cpp:89-116`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:176-205`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:259-283`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:333-351`.

### R-UI-06 · parity · Store everything, then announce each change once

**Statement.** Each non-constant property has a change signal, except
`issueCount`, which is announced on `issuesChanged` (R-UI-11). A change signal
fires only when the value it announces changes, with two declared exceptions:
`exitNodeBlockedChanged` fires whenever either input changes, even when the
derived value does not move (R-UI-09), and `issuesChanged` fires when `issues`
changes even when `issueCount` does not (R-UI-11). This requirement covers
#286's 24 properties; the same rules for the five members listed under
"Contract additions", and the outcomes of the two added actions, are
R-UI-18's, not this requirement's. A snapshot stores every snapshot property (all
of the 24 except `recommendedExitNodeId`, `writable` and `writeError`,
which move on their own outcomes per R-PARSE-11 and R-WRITE-06) and fills
both models before any property change signal fires.
A change to `writable` or `writeError`
that a snapshot itself causes (R-WRITE-08's result and reconciliation,
R-WRITE-11's re-arm) is stored with that snapshot, before any of its change
signals. Their own outcomes (a `/suggest-exit-node` reply or failure, which
moves `recommendedExitNodeId`, R-PARSE-11, and a write's ending, which moves
`writable` and `writeError`, R-WRITE-06) move them outside any snapshot;
for #286's properties and actions that list is complete. A handler on any property
change signal therefore reads the whole new snapshot. `exitNodeBlocked` is
never announced from half an update. The models' own row signals fire while
they are filled, before the property signals: `peers` is filled first and
`exitNodes` second, so a row-signal handler on `peers` reads the new property
values but may still see the previous `exitNodes` rows.

**Acceptance.** The backend first reaches `Running` on the idle capture, and
the idle barrier holds. Spies are then attached to the change signal of
every one of #286's 24 properties. A notification that changes `state`,
`selfName` and `exitNodeOnline`
at once is followed by the idle barrier. At that point each of those three
signals has fired exactly once. Every other of those change signals has fired
once if its property's value differs from the value read before the
notification and 0 times if it does not, with the two exceptions the
Statement declares (`exitNodeBlockedChanged` per R-UI-09, `issuesChanged` per
R-UI-11).
Inside every handler, all three already hold their new values, and `peers`
and `exitNodes` already hold their new rows. The spies are then cleared and
the same notification is pushed again with the fake serving the same replies.
After the fake has recorded a further GET of `/localapi/v0/status` and the
idle barrier holds, each of those change signals has fired 0 times. Moving
from idle to a reachable exit node never shows `exitNodeBlocked` true to a
handler; this is read after the idle barrier that follows that pass.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:45-47`,
`plugin/src/contracts/TailscaleBackend.h:345-367`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:36-41`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:584-675`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:19-20`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:878-901`,
`docs/architecture.md:249-255`.

### R-UI-07 · parity · selfDnsName has no trailing root dot

**Statement.** `selfDnsName` is this machine's MagicDNS name without the root
dot, spelled like peer names. The contract does this whatever the backend
stored, so no backend can skip it. A name of only `.` reads as empty.

**Acceptance.** Self `DNSName` `laptop.example-tailnet.ts.net.` reads
`laptop.example-tailnet.ts.net`. The same name without the dot reads the same.
`.` reads as the empty string.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:41-43`,
`plugin/src/contracts/TailscaleBackend.h:129-135`,
`plugin/src/contracts/TailscaleBackend.h:369-378`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:81-87`,
`plugin/tests/tst_tailscalebackend.cpp:134-149`.

### R-UI-08 · parity · exitNodeBlocked is exitNodeActive and not exitNodeOnline

**Statement.** `exitNodeBlocked` is true exactly when an exit node is selected
and unreachable. tailscaled then drops all egress. The contract derives it, and
a backend publishes only its two inputs. A backend has no setter for it. The
contract's header names one escape: a subclass that redeclares the property
shadows the rule. No shipped backend may redeclare it, so QML always reads the
contract's own derivation. `exitNodeOnline` is false whenever no exit node is
selected.

**Acceptance.** Active/online inputs false/false, false/true, true/true and
true/false give `exitNodeBlocked` false, false, false and true. This holds read
directly and through QML, on the selected backend and on the test-only fake
backend alike. The singleton's metaobject has exactly one property named
`exitNodeBlocked`. On the shipped backend, driven from a fake tailscaled
through the three reachable combinations (false/false, true/true and
true/false), `exitNodeBlocked` always equals
`exitNodeActive && !exitNodeOnline`, read in every handler of every change
signal. false/true stays a direct, QML and test-only-fake check: the shipped
backend cannot produce it, because its `exitNodeOnline` requires a resolved
`ExitNodeStatus`, which also makes `exitNodeActive` true. No fake reply makes
the shipped backend read `exitNodeActive` false with `exitNodeOnline` true.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:28-30`,
`plugin/src/contracts/TailscaleBackend.h:49-53`,
`plugin/src/contracts/TailscaleBackend.h:151-159`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:21-23`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:612-623`,
`plugin/tests/tst_tailscalebackend.cpp:151-173`.

### R-UI-09 · parity · exitNodeBlockedChanged fires when either input changes

**Statement.** `exitNodeBlockedChanged` fires whenever `exitNodeActive` or
`exitNodeOnline` changes. It may fire when the derived value did not move. It
never misses a move.

**Acceptance.** On the test-only fake, with `exitNodeActive` and
`exitNodeOnline` both false: setting `exitNodeActive` true fires
`exitNodeBlockedChanged` exactly once; then setting `exitNodeOnline` true
fires it exactly once; then setting `exitNodeOnline` false fires it exactly
once, and `exitNodeBlocked` then reads true. The fake's setters emit
synchronously, so each count is read when its setter returns and counts
from just before that call, as the stand-in's recorded calls are ("Two
halves"); no other barrier applies.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:36-39`,
`plugin/src/contracts/TailscaleBackend.h:106-116`,
`plugin/src/contracts/TailscaleBackend.h:357-358`,
`plugin/tests/tst_tailscalebackend.cpp:175-192`.

### R-UI-10 · parity · Exit-node identity is joined on the ID

**Statement.** `exitNodeId` is the selected exit node's string node ID. It
matches one `exitNodes` row's `nodeId`. It is empty when none is selected, and
so is `exitNodeName`. A view marks the row in use by `exitNodeId`, never by
name.

**Acceptance.** On the backend, against the fake, with inline data (the
committed captures do not hold these ids). The fake serves the status
`{"BackendState":"Running","Peer":{"k1":{"ID":"nABC123CNTRL","HostName":"relay","DNSName":"relay.example.ts.net.","ExitNodeOption":true},"k2":{"ID":"nDEF456CNTRL","HostName":"relay","DNSName":"relay-1.example.ts.net.","ExitNodeOption":true}}}`,
whose two exit rows share the hostname `relay` and which has no
`ExitNodeStatus`, and prefs `{"ExitNodeID":"nDEF456CNTRL"}`. After the idle
barrier that follows the backend reaching `Running`, `exitNodeId` is exactly
`nDEF456CNTRL`, `exitNodes` has exactly 2 rows, and exactly one of them has
`nodeId` `nDEF456CNTRL`. In a separate run with the same status and prefs
`{}` (none selected), after the same barrier `exitNodeId` and `exitNodeName`
are exactly empty and `exitNodeOnline` is false.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:137-153`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:607-627`.

### R-UI-11 · parity · issueCount shares the issues signal

**Statement.** `issues` is tailscaled's health text after R-PARSE-12. It is
empty when tailscaled reports nothing. `issueCount` is its length and is
announced on `issuesChanged`. It has no signal of its own.

**Acceptance.** On the test-only fake backend (R-UI-14), as #286 runs it:
setting two warnings fires `issuesChanged` exactly once, with `issueCount` 2,
read directly and through the metaobject. Setting none fires it exactly once
more, with `issueCount` 0. The fake's setters are synchronous, so each
setter returning is the barrier for these counts. The metadata of
`issueCount` names `issuesChanged` as its notify signal. The shipped
backend's half of this rule is R-UI-06's criterion, read after the idle
barrier.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:33-35`,
`plugin/src/contracts/TailscaleBackend.h:71-72`,
`plugin/src/contracts/TailscaleBackend.h:161-164`,
`plugin/tests/tst_tailscalebackend.cpp:194-209`.

### R-UI-12 · parity · peers and exitNodes are constant, distinct models

**Statement.** `peers` and `exitNodes` never change identity and are never null.
They are two distinct objects of one model type. Their rows behave as R-GROUP
describes.

**Acceptance.** Given peers `laptop` and `c7-exit-ams`, only the second an exit
option, `peers` has 2 rows and `exitNodes` 1. The objects differ. Both are the
same objects before and after an update, and both properties are constant.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:73-74`,
`plugin/src/contracts/TailscaleBackend.h:166-173`,
`plugin/tests/tst_tailscalebackend.cpp:211-232`,
`plugin/tests/tst_module.cpp:110-111`.

### R-UI-13 · fix · The exact set of actions

**Statement.** QML can call the five methods of #286 on the singleton:
`setWantRunning(bool)`, `setExitNode(string)`,
`setExitNodeAllowLANAccess(bool)`, `setAcceptRoutes(bool)` and
`setAcceptDns(bool)`. It can also call exactly the two invokables listed under
"Contract additions": `login()` (R-UI-17, decision 1) and
`setAdvertiseExitNode(bool)` (R-WRITE-10, decision 2). There are no other
public invokables: seven in all. #286 exposes exactly the five, and its
exact-set test pins that set, so the exact set is the part decisions 1 and 2
change.

**Acceptance.** The five signatures are a subset of the invokable signatures
(this holds on `a38dbca`). The sorted signatures equal the five plus
`login()` and `setAdvertiseExitNode(bool)`, seven in all. That exact-set
check replaces #286's `plugin/tests/tst_module.cpp:171`, which compares the
signatures with the five alone; it fails on `a38dbca`, which lacks the two.
On the test-only fake backend (R-UI-14), calling each of the five by name
with the rows #286 uses (`setWantRunning` with true and with false,
`setExitNode` with `nABC123CNTRL` and with `""`,
`setExitNodeAllowLANAccess(true)`, `setAcceptRoutes(false)` and
`setAcceptDns(true)`) succeeds, and the fake's recorded calls are then
exactly that one call with that argument, for example
`setExitNode(nABC123CNTRL)`. The same holds for the two added invokables:
on a fresh fake, `login()` and, separately, `setAdvertiseExitNode(true)`
each succeed when called by name, and the recorded calls are then exactly
that one call, `login()` or `setAdvertiseExitNode(true)`, with no property
change signal fired. The fake records synchronously, so the call
returning is the barrier.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:256-274`,
`plugin/tests/tst_module.cpp:47-63`, `plugin/tests/tst_module.cpp:155-172`
(the exact five-signature comparison at `:171`),
`plugin/tests/tst_tailscalebackend.cpp:45-89`, decisions 1 and 2.

### R-UI-14 · parity · A test-only fake backend that never ships

**Statement.** A fake backend satisfies the whole contract without a socket.
The UI therefore depends only on the contract. A test sets each input and each
pref read-back separately. Setting an unchanged value emits nothing. Actions are
recorded in order, repeats included, and change no property. The derived values
cannot be set directly. The fake exists only in test builds.

**Acceptance.** The installed module's library and `qmldir` contain no fake
type, and `Tailscale` resolves to the real backend. On the fake,
`setExitNodeOnline(false)` from false fires nothing. A fresh fake reads
`writable` true. `setWritable(false)` and then `setWriteError` with a text
containing `403` each fire their own change signal exactly once, and read
through the metaobject, as QML reads them, `writable` is false and
`writeError` contains `403`. `setWritable(true)` and `setWriteError("")` then
fire each signal once more, and the two read true and empty. After `setExitNode("x")` and
`setWantRunning(true)`, the recorded calls are exactly two: `setExitNode(x)`
then `setWantRunning(true)`. With `exitNodeId` preset on the fake to
`nDEF456CNTRL`, `setExitNode("nABC123CNTRL")` and `setWantRunning(false)`
record exactly two calls, `exitNodeId` still reads `nDEF456CNTRL`, and
`exitNodeIdChanged` has fired 0 times. The fake has no asynchronous work, so
the calls returning is the barrier for these negatives. A `recommendedExitNodeId` the fake sets reads back
unchanged through the contract. How the fake carries the members listed
under "Contract additions" is R-UI-19's, not this requirement's.

**Sources.** `plugin/src/backends/tailscale/FakeTailscaleBackend.h:6-23`,
`plugin/tests/tst_tailscalebackend.cpp:91-106`,
`plugin/tests/tst_tailscalebackend.cpp:113-132`,
`plugin/tests/tst_tailscalebackend.cpp:230-231`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:52-75`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:131-145`,
`plugin/src/contracts/TailscaleBackend.h:16-20`,
`plugin/tests/tst_tailscalebackend.cpp:10-14`,
`docs/architecture.md:257-260`.

### R-UI-15 · parity · The six bar-slot states are reachable

**Statement.** The design's six icons map onto contract values. Plain is
`Running` with no issues and no exit node. Dimmed is any other state.
Error-online is `Running` with `issueCount` > 0, drawn as one amber dot.
Error-offline is dimmed plus the amber dot. Default-router-online is an active,
online exit node: accent fill, accent icon and the exit-node name. Default-router-offline is
`exitNodeBlocked`: a crimson ✕ badge and a slot outline in
`Theme.accentBorder`, with no amber dot. No other state draws the outline. A backend
reaches each from daemon replies alone.

**Acceptance.** Two halves. Backend half: for each of six stagings, each in
its own run with prefs `{}` unless named, a fake serves the status named
below; after the idle barrier that follows the backend publishing it, the
contract reads exactly these values. `issueCount` 0 means `issues` is empty;
`issueCount` 1 means `issues` is exactly `["DNS is not working"]`. A
"health entry" below is that string appended to the capture's `Health`
list, whose own suppressed warning (R-PARSE-12) never counts.

| # | Status served | `state` | `issueCount` | `exitNodeActive` | `exitNodeOnline` | `exitNodeBlocked` | `exitNodeName` |
|---|---|---|---:|---|---|---|---|
| 1 | `status-idle.json` | `Running` | 0 | false | false | false | empty |
| 2 | `{"BackendState":"Stopped"}` | `Stopped` | 0 | false | false | false | empty |
| 3 | `status-idle.json` plus a health entry | `Running` | 1 | false | false | false | empty |
| 4 | `{"BackendState":"Stopped","Health":["DNS is not working"]}` | `Stopped` | 1 | false | false | false | empty |
| 5 | `status-exitnode.json` | `Running` | 0 | true | true | false | `pentest-exit-node` |
| 6 | `status-exitnode-offline.json` plus a health entry | `Running` | 1 | true | false | true | `pentest-exit-node` |

View half: the stand-in is set to the values of each row, and after the
layout barrier the slot reads as the bullet of the same number below. The
view colours and visibility are view-half clauses only; the backend half
asserts only the table. Every reading has the slot visible.

1. `Running`, no issues, no exit node: slot colour transparent, slot border
  transparent, icon tint `Theme.text`, no visible label text.
2. `Stopped`, no issues: icon tint `Theme.textDisabled`, slot border
  transparent.
3. `Running` with one health entry: exactly one visible item in
  `Theme.warning`, none in `Theme.accentSoft`, slot border transparent.
4. `Stopped` with one health entry: icon tint `Theme.textDisabled`, exactly
  one visible item in `Theme.warning`, slot border transparent.
5. `Running` with an active, online exit node: slot colour `Theme.accentFill`,
  icon tint `Theme.accentSoft`, the exit node's name visible, no `✕`, slot
  border transparent.
6. `Running` with an active, offline exit node: a visible `✕` in
  `Theme.accentSoft`, slot colour `Theme.accentFill`, slot border
  `Theme.accentBorder`, the name visible, and no item in `Theme.warning` even
  with a health entry present.

**Sources.** `tests/tailscale-qml-test.qml:244-299`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:126-216`, `pr286-body:16`.
The 2026-10-15 design and plan describe the six icons but predate the
visibility rule; R-QML-01 and R-QML-03 hold that rule.

### R-UI-16 · fix · One designed explanation when a read and a write both failed

**Statement.** `readError` and `writeError` are independent, and both can be
non-empty. The contract keeps publishing both. The panel shows one
explanation of that combined state, not two: the read error wins (decision
7). While `readError` is non-empty, the panel shows `ts-read-error` with
`readError` verbatim (R-QML-02), and no visible Text and no tooltip Text
carries `writeError`: `ts-exit-write-error`, `ts-settings-write-error` and
R-UI-17's `ts-login-error` are hidden, and `ts-connect-tip` reads its no-note text for the current state
(R-QML-22). While reads fail, the state is suspect and the controls are moot.
Once `readError` clears, the write error shows again where R-QML-20 and
R-QML-22 put it, if `writeError` is still non-empty.

**Defect.** "`readError` and `writeError` can now both be non-empty at once,
which draws two explanations on one panel. Both are true; nobody has designed
that state."

**Acceptance.** Backend half, with paused time and the shipped timings: the
backend reaches `Running` and the idle barrier holds. The test calls
`setAcceptRoutes(true)` and the fake refuses the PATCH with 403, which starts
no confirmation pass (R-WRITE-08). After the client barrier and the read
barrier, `writable` is false and `writeError` contains `403`. The fake then
answers every later `/status` with 403 and pushes `{"Prefs":{}}`, which
starts a pass (R-WATCH-08). After the retry barrier for that loss, with
paused time not advanced, and the read barrier, `state` is `NoState`,
`readError` is non-empty and contains `403`, and `writeError` still holds
the PATCH's message, unchanged since the refusal, with
`writeErrorChanged` fired 0 times since the push: both properties are
non-empty and readable at once.

View half: set those values on the stand-in (`state` `NoState`, both
errors non-empty, `writable` false) and open the panel. Count the
explanations, headlessly, as two sets. The first set is the panel's Texts whose
effective visibility is true. The second set is the Text inside each hover
tooltip, counted by its `text` alone, because the harness's `Tooltip` stand-in
is never visible (`tests/test-tailscale.sh:104-119`) and a hover would show
exactly that text. Today the only such Text is `ts-connect-tip`. In both sets,
count the Texts whose text contains `readError` or `writeError`. The total is
exactly 1, and that Text is `ts-read-error`, equal to `readError`.
`ts-connect-tip` reads `tailscaled is not answering, so there is nothing to
ask`. At `a38dbca` the total is 2: `ts-read-error` and `ts-connect-tip`. On
the stand-in, setting `readError` empty while `writeError` stays non-empty
and `state` returns to `Running` makes `ts-connect-tip` contain `writeError`
again and hides `ts-read-error`. This requirement governs the state where both
errors are non-empty; R-QML-02's `ts-read-error` clause and R-QML-22's
`ts-connect-tip` clause apply only while the other error is empty.

**Sources.** `pr286-body:125-126`, decision 7,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:307`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:322-327`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:366-382`,
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:36-40`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:297-330`,
`tests/test-tailscale.sh:104-119`.

### R-UI-17 · new · Log in from the panel

**Statement.** When `state` is `NeedsLogin`, a user can start a Tailscale login
from the panel and finish it in a browser. No terminal `tailscale up` is
needed. The panel then follows `state` as tailscaled reports it. #286 leaves
this out because it needs a browser flow. The design is decision 1, option
(a):

- `login()` (invokable) sends `POST /localapi/v0/login-interactive` with no
  body (R-HTTP-14). tailscaled answers `204`. While one login start is
  outstanding, a further call sends nothing: the contract owns that rule, not
  the view, and R-WRITE-05 does not apply. The guard is released when the
  login start delivers its outcome, whatever that outcome is: a 2xx, a 403,
  any other status, the deadline, or a dropped or absent socket (a reconnect
  does not cancel it, R-WRITE-07, so its outcome still arrives). The next
  `login()` after that sends a POST again. The outcome moves `writable` and
  `writeError` like any write (R-WRITE-06); a 2xx starts no confirmation
  pass (R-WRITE-08). A failed login start's `writeError` is never
  reconciled, because `login-interactive` has no read-back (R-WRITE-08): it
  stays until the next write outcome or a re-arm (R-WRITE-11).
- `loginUrl` (string, read-only, `loginUrlChanged`) holds the URL from the
  latest notification that carries an acceptable `BrowseToURL`, byte for
  byte. A `BrowseToURL` is acceptable only when it is a JSON string that
  starts with `https://`, the scheme compared ASCII case-insensitively.
  Any other value (a non-string, an empty string, or another scheme such as
  `http:`, `file:` or `javascript:`) leaves `loginUrl` unchanged and fires
  nothing, so a URL handler is never handed a scheme a Tailscale login does
  not use, whatever answers at `TS_SOCKET`. The cost is that a self-hosted
  control server reached over plain `http://` cannot be logged in to from
  the panel; `tailscale up` in a terminal still works.
  That is the one property set from a notification body (R-WATCH-08). It
  survives a view that binds late, because it is state, not a signal. It is
  emptied in three ways, so it never holds a URL a click did not ask for or
  a lost daemon issued: every published snapshot whose `state` is not
  `NeedsLogin` stores it empty, with that snapshot before any of its change
  signals (R-UI-06), so a `stateChanged` handler already reads it empty
  (a `BrowseToURL` that arrives while `state` is `Running` or `Starting` is
  therefore emptied by the next such snapshot, normally that of the pass
  the same notification starts); a loss empties it (R-CONN-06); and when
  `login()` sends its POST it is emptied after the call has returned and
  before the POST's request bytes are written, so the next `BrowseToURL`
  always changes it, even when tailscaled repeats the same URL.
- The view opens the browser, not the plugin, and only for the user's own
  click: activating `ts-login` calls `Tailscale.login()` and arms the panel's
  opener. While armed, the first change of `loginUrl` to a non-empty value
  after the click opens it with `Qt.openUrlExternally` and disarms, so one
  click opens one URL once. A `loginUrl` that was already set at the click
  is never opened: it predates the request. The opener disarms too when
  `state` leaves `NeedsLogin`. Closing the panel does not disarm it: the
  click was the consent, and the URL often arrives a moment later. The call
  goes through one call site the QML harness replaces with a recording
  stand-in, as it replaces the clipboard (R-QML-10). What is guaranteed is
  this: no QML file contains `Process` or `execDetached`, the plugin starts
  nothing (R-SEC-01), and the one external launch is this user-initiated
  `Qt.openUrlExternally`, which decision 1 chose. In the shipped shell that
  call hands the URL to the desktop's URL handler, which may itself start a
  program (for example `xdg-open`) or use the OpenURI portal; in tests the
  recording stand-in replaces it, so nothing is launched. A URL that
  arrives without a click is never opened. `Qt.openUrlExternally`
  returns false when no URL handler or browser is configured. Then the
  panel shows the plain-text line `ts-login-url-error` below `ts-login`,
  reading exactly `Could not open a browser. Open this address to log in: `
  followed by `loginUrl` verbatim (R-SEC-03), so the user can copy it. It
  stays visible while `state` is `NeedsLogin` and `loginUrl` still holds the
  URL whose open failed, and is hidden otherwise, and whenever an open
  succeeded. It carries no `writeError`, so R-UI-16 does not count it.
- After an accepted login start, a login that tailscaled itself rejects (for
  example because the control server is unreachable) is reported only
  through `ErrMessage`, which this epic does not publish (decision 18,
  R-WATCH-09). No `BrowseToURL` arrives, the opener stays armed, and the
  panel stays as it was. This is an accepted gap, not new behaviour:
  follow-up issue #299 decides how `ErrMessage` is published.
- `ts-login` is shown only while `state` is `NeedsLogin`. Like every other
  control (R-QML-20), it is dead while `writable` is false, because
  tailscaled guards `login-interactive` as it guards prefs writes: its text
  is drawn in `Theme.textDisabled`, it is not hoverable, and a click calls
  nothing and arms nothing. While `writable` is true its text is in
  `Theme.alpha(Theme.text, 0.85)`, as the other live control rows.
- A failed login start is shown on the root card itself, because in
  `NeedsLogin` the sub-cards' write-error lines may be folded away and the
  connect tooltip is shown only on hover: while `state` is `NeedsLogin`,
  `readError` is empty and `writeError` is non-empty, the plain-text line
  `ts-login-error` below `ts-login` shows the write note's sentence
  (`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml`, unchanged), which quotes `writeError`. It is
  hidden otherwise; while `readError` is non-empty R-UI-16 governs and the
  read error wins.
- `NeedsMachineAuth` is shown as text only, the header phrase "waiting for
  machine approval" (R-QML-05), with no control.

**Acceptance.** Given a fake reporting `NeedsLogin`, with the opening pass
answered:

- Backend half. The fake holds the login start. `login()` makes the fake
  record a `POST /localapi/v0/login-interactive HTTP/1.1` with the Host
  header and no body (setup: the test waits for that record). A second
  `login()` follows. After the read barrier and the fake barrier ("Request
  counts"), with the client count at exactly 2 (the watch and the held
  start), the fake has recorded exactly one request since the first call,
  that POST. The fake answers `204`; after the client
  barrier `writable` is true and `writeError` empty; after the read barrier
  and then the fake barrier ("Request counts"), the fake has recorded no
  further `/status`. The fake then pushes the watch line
  `{"BrowseToURL":"https://login.tailscale.com/a/c7test"}`. After the idle
  barrier, `loginUrl` equals `https://login.tailscale.com/a/c7test` byte for
  byte and `loginUrlChanged` fired once. When the fake then reports
  `Running` and notifies, after the idle barrier `loginUrl` is empty and
  `loginUrlChanged` fired exactly once more; inside the `stateChanged`
  handler for `Running`, `loginUrl` already reads empty. When
  the fake answers the login start with 403, `writable` is false and
  `writeError` contains `403`, as R-WRITE-06 pins for any write. In
  separate runs from `NeedsLogin` with `writable` true, the login start is
  answered `HTTP/1.1 500 Internal Server Error`, and, with paused time and
  an injected 50 ms request deadline, recorded and never answered while
  paused time advances exactly 50 ms past the instant the fake recorded
  it; after the client barrier and the read barrier, `writeError` is
  non-empty in each (containing `500`, and `50 ms`, respectively),
  `writable` is still true and `writableChanged` has fired 0 times since
  the call. In each, a later notification whose snapshot is still
  `NeedsLogin` leaves `writeError` unchanged after the idle barrier (no
  reconciliation).
- Backend half, the guard is released. In each of the 204, 403, 500 and
  50 ms-deadline runs above, and in a run where the fake closes the held
  POST's client (R-FAKE-03) instead of answering it, the test calls
  `login()` again after the client barrier and the read barrier that follow
  the outcome. After the read barrier and the fake barrier ("Request
  counts"), the fake has recorded exactly one more
  `POST /localapi/v0/login-interactive` since that call.
- Backend half, clearing. (1) From `NeedsLogin` with `loginUrl` set from a
  `BrowseToURL` push, `login()` makes the fake record the POST; after the
  read barrier and the fake barrier `loginUrl` is empty and
  `loginUrlChanged` has fired exactly once since the call. The fake then
  pushes the same URL again; after the idle barrier `loginUrl` equals it
  and `loginUrlChanged` has fired exactly twice since the call. (2) From
  `NeedsLogin` with `loginUrl` set, the fake closes the watch with
  `0\r\n\r\n`, with paused time and the shipped timings; after the retry
  barrier, with paused time not advanced, `loginUrl` is empty and
  `loginUrlChanged` has fired exactly once since the close. Paused time
  advances exactly 500 ms and the reconnect publishes `NeedsLogin` again;
  after the idle barrier `loginUrl` is still empty and `loginUrlChanged`
  has fired exactly once since the close. (3) From `Running`, the fake
  pushes `{"BrowseToURL":"https://login.tailscale.com/a/c7reauth"}` and
  keeps reporting `Running`; after the idle barrier `loginUrl` is empty and
  `loginUrlChanged` has fired exactly twice since the push (set by the
  notification, emptied by the `Running` snapshot of the pass it started).
- Backend half, unacceptable URLs. From `NeedsLogin` with `loginUrl` empty,
  the fake pushes, each in a separate run,
  `{"BrowseToURL":"file:///etc/passwd"}`, `{"BrowseToURL":5}`,
  `{"BrowseToURL":"javascript:alert(1)"}` and
  `{"BrowseToURL":"http://login.example/a/c7test"}`. After the idle barrier
  `loginUrl` is empty and `loginUrlChanged` has fired 0 times since the
  push. In a further run, from `loginUrl` set to
  `https://login.tailscale.com/a/c7test`, a push of
  `{"BrowseToURL":"file:///etc/passwd"}` leaves it equal to that URL, with 0
  fires since the push. `{"BrowseToURL":"HTTPS://login.tailscale.com/a/c7up"}`
  sets it, byte for byte.
- View half, on the stand-in with `state` `NeedsLogin`. The stand-in records
  each call, and the opener stand-in each URL, synchronously, and the panel
  reacts to a property change in the same turn, so the click, the property
  set, or the panel's creation returning is the barrier for every "records"
  clause below; each count and each "records nothing" counts from just
  before that click, set or creation. Visibility and text are read after the
  layout pass that follows it. `ts-login` is
  visible; a click records exactly one `login()` call and no URL. Setting
  `loginUrl` to `https://login.tailscale.com/a/c7test` then makes the opener
  stand-in record that URL exactly once; setting it to another URL records
  nothing more. Without a click, setting `loginUrl` records nothing. With
  `loginUrl` already set before the panel is created, opening the panel
  records nothing, and clicking `ts-login` records exactly one `login()`
  call and no URL; setting `loginUrl` to a different URL then records that
  URL exactly once. After a click, closing the panel and then setting
  `loginUrl` records that URL exactly once. After a click, setting `state`
  to `Running` and back to `NeedsLogin` and then setting `loginUrl` records
  nothing. The opener stand-in returns a configurable bool, true by default;
  with it returning true, `ts-login-url-error` is not visible after a click
  and a `loginUrl` set. With it returning false, a click on `ts-login` and
  then setting `loginUrl` to `https://login.tailscale.com/a/c7test` makes it
  record that URL exactly once, and `ts-login-url-error` is visible, has
  plain-text format and its text is exactly
  `Could not open a browser. Open this address to log in: https://login.tailscale.com/a/c7test`;
  setting `state` to `Running` hides it, and so does setting `loginUrl` to
  empty. With `<b>x</b>` as the failed URL it shows those eight characters
  literally. With `writable` false and `writeError` set to a 403 reason,
  `ts-login` is visible, its text colour equals `Theme.textDisabled`, it is
  not hoverable, a click records no call, and a later `loginUrl` set
  records nothing; with `writable` true again its colour equals
  `Theme.alpha(Theme.text, 0.85)`. With `writable` true, `readError` empty
  and `writeError` set to `boom`, `ts-login-error` is visible and its text
  contains `boom` and lacks `c7shell-bootstrap`; with `writable` false and
  that `writeError` it contains `boom` and `c7shell-bootstrap`; with
  `readError` also non-empty it is not visible; with `writeError` empty it
  is not visible; with `<b>x</b>` as `writeError` it shows those eight
  characters as plain text. With `state`
  `NeedsMachineAuth`, `ts-login` is not shown and `ts-state` reads "waiting
  for machine approval". With `state` `Running`, `ts-login` is not shown and
  the header reads "connected". The fake program stand-ins record no process
  (R-SEC-01).

**Sources.** `pr286-body:25`, decision 1,
`plugin/src/contracts/TailscaleBackend.h:103`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:62-73`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:57-58`,
the `BrowseToURL` notification field at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1170`.

### R-UI-18 · fix · The added members read as nothing known yet and keep the contract's rules

**Statement.** Split from R-UI-05, which keeps #286's members. Before any
reply, the five properties added by decisions 1, 2 and 6 (listed under
"Contract additions") read their fresh values: `loginUrl` and
`ipForwardingWarning` empty, and `peersKnown`, `advertisingExitNode` and
`exitNodeAwaitingApproval` false. The test-only fake backend (R-UI-14,
R-UI-19) starts in the same values. The tag is `fix` because the members
exist only by those decisions; the test fails on `a38dbca`, which has none
of them.

The rules the parity requirements state for #286's members hold for the
added members too, and those clauses live here, moved out of the parity
requirements because #286 lacks the members:

- read-only (from R-UI-03): QML cannot assign any of the five;
- store, then announce (from R-UI-06 and R-WATCH-11): `peersKnown`,
  `advertisingExitNode` and `exitNodeAwaitingApproval` are snapshot
  properties, stored with the snapshot and announced once on change, and
  neither half of a pass alone moves them. `ipForwardingWarning` and
  `loginUrl` move on their own outcomes (a forwarding check's reply,
  R-WRITE-10; a `BrowseToURL` notification, a loss or a `login()` POST,
  R-UI-17), and a refused `setAdvertiseExitNode` call sets `writeError`
  after the call has returned with no request sent (R-WRITE-10). A change
  to `ipForwardingWarning` or `loginUrl` that a snapshot itself causes
  (R-WRITE-10's clearing, R-UI-17's clearing of `loginUrl`) is stored with
  that snapshot, before any of its change signals. Together with R-UI-06's
  list, that list of outcomes outside a snapshot is complete;
- repeated calls are not collapsed (from R-WRITE-05): every call of
  `setAdvertiseExitNode` that sends a request sends its own, in call order,
  and a repeat of a value already in effect is still sent. The one call
  that sends nothing is R-WRITE-10's `setAdvertiseExitNode` while its
  advertised routes are not known (before any snapshot was published, while
  `state` is `NoState`, or while the published `AdvertiseRoutes` is
  malformed); it sets `writeError` instead;
- no process and nothing blocks (from R-SEC-01): `login()` and
  `setAdvertiseExitNode` start no process and return without waiting on the
  socket.

**Acceptance.** A backend created with its socket path in an isolated
directory, after the retry barrier for the first connect, reads `loginUrl`
and `ipForwardingWarning` empty and `peersKnown`, `advertisingExitNode` and
`exitNodeAwaitingApproval` false. A freshly constructed fake, read through
the contract before any setter or action is called (construction returning
is the barrier; the fake has no asynchronous work), reads the same five
values.

Read-only: `Tailscale.peersKnown = true` and `Tailscale.loginUrl = "x"` each
fail, and none of the five is writable through the metaobject; the
assignment returning is the barrier, and right after it each reads the
value it read before and its change signal has fired 0 times since just
before the assignment.

Store, then announce: in R-UI-06's staging, spies are attached to the five
added members' change signals too. After the idle barrier that follows the
notification, each has fired exactly once if its value differs from the
value read before the notification and 0 times if it does not, and inside
every handler of R-UI-06's three signals `peersKnown`,
`advertisingExitNode` and `exitNodeAwaitingApproval` already hold their
new values; after the repeated notification each of the five has fired
0 times. In R-WATCH-11's staging, while `/prefs` is held and the read
barrier holds, none of the five change signals has fired since the
notification and each reads its old value.

Not collapsed: with the fake's `/prefs` `AdvertiseRoutes`
`["172.16.9.0/24"]`, the idle status and the idle barrier holding, the test
calls `setAdvertiseExitNode(true)` twice, back to back, and the fake answers
each PATCH 200. After the idle barrier, the read barrier and the fake
barrier ("Request counts"), exactly two PATCH requests have been recorded
since the first call, in call order, each with a body that, compared as
JSON, is
`{"AdvertiseRoutes":["172.16.9.0/24","0.0.0.0/0","::/0"],"AdvertiseRoutesSet":true}`
(both are built from the routes published before the first call).

No process and nothing blocks: R-SEC-01's full scenario also calls
`login()` and `setAdvertiseExitNode(true)` after a snapshot, and both
stubs still record zero invocations. In R-SEC-01's nothing-blocks run,
after #286's five actions the test calls `login()`; it returns while its
POST is held, with no outcome delivered and paused time not advanced, and
after the 10 000 ms advance and the read barrier `writeError` contains
`10000 ms`.

**Sources.** R-UI-05's sources for the fresh-value pattern
(`plugin/tests/tst_tailscalebackend.cpp:19-43`,
`plugin/tests/tst_module.cpp:89-116`), "Contract additions", decisions 1, 2
and 6.

### R-UI-19 · fix · The test-only fake carries the added members

**Statement.** Split from R-UI-14, which keeps #286's members. The
test-only fake backend carries the five properties and the two invokables
added by decisions 1, 2 and 6, by R-UI-14's rules: each property has its own
setter, setting an unchanged value emits nothing, and an action is recorded
and changes no property. The tag is `fix` because the members exist only by
those decisions; the test fails on `a38dbca`.

**Acceptance.** On a fresh fake, setting `peersKnown`,
`advertisingExitNode` and `exitNodeAwaitingApproval` to true and
`loginUrl` and `ipForwardingWarning` to `x` fires each one's own change
signal exactly once and no other property's, and each reads the set value
back through the metaobject; setting each to the value it already holds
fires nothing. With `advertisingExitNode` set true, `login()` and
`setAdvertiseExitNode(false)` record exactly those two calls, in that
order, and fire no property change signal: `advertisingExitNode` still
reads true. The fake has no asynchronous work, so each call returning is
the barrier, and each count is read then.

**Sources.** R-UI-14's sources for the fake's rules
(`plugin/src/backends/tailscale/FakeTailscaleBackend.h:52-75`,
`plugin/src/backends/tailscale/FakeTailscaleBackend.h:131-145`), "Contract
additions", decisions 1, 2 and 6.

## R-QML: views

### R-QML-01 · parity · No bar slot on a machine without tailscaled

**Statement.** The slot `tailscale` is hidden while `state` is `NoState`,
`readError` is empty, and no other state was ever reported. No exit-node label
is drawn then, whatever the exit-node properties hold. When `readError` is
non-empty instead, R-QML-02 governs; which daemon behaviours set it is
stated by R-CONN-03, and by the `fix` requirements R-WATCH-13 and
R-CONN-15, not by this one.

**Acceptance.** With no listener, the shipped 500 ms base and paused time,
the retry barrier is taken three times. The first is taken at start-up,
with paused time at 0, once the opening attempt has failed and armed a
reconnect with a delay of 500 ms. Paused time then advances by exactly
500 ms, the delay just armed; the reconnect attempt runs and fails, and the
second retry barrier is taken, with a delay of 1 000 ms armed. Paused time
then advances by exactly 1 000 ms more (1 500 ms in all); that attempt runs
and fails, and the third retry barrier is taken. Paused time advances by
nothing else. At each of those three retry barriers `state` is `NoState`,
`readError` is empty, and the number of armed reconnects is exactly 1, 2
and 3 respectively.
In the QML suite, with `state` `NoState`, `readError` empty and an active,
online exit node named `pentest-exit-node` set underneath, the slot is not
visible and no visible text equals `pentest-exit-node`.

**Sources.** `tests/tailscale-qml-test.qml:183-209`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:812-823`
(one armed reconnect in #286; the criterion extends it to three),
`quickshell/c7shell/Modules/Bar/StatusPill.qml:109-157`,
`plugin/src/contracts/TailscaleBackend.h:87-103`,
`plugin/src/contracts/TailscaleBackend.h:336-338`, decisions 19 and 23 (a
clean watch end before any snapshot, R-CONN-15, and an unrecognised
`BackendState`, R-WATCH-13, set `readError`, so R-QML-02's dimmed slot shows
instead of none).

### R-QML-02 · parity · A dimmed slot for a daemon that is present but unreadable

**Statement.** While `state` is `NoState` and `readError` is non-empty, the slot
is visible with a disabled-tint icon. The panel shows "tailscaled is not
responding" and the line `ts-read-error` with `readError` verbatim. When
`writeError` is non-empty too, what else the panel shows is R-UI-16's
`fix`, not this requirement's. When `readError` clears and nothing ever answered, the line
and the slot go away.

**Acceptance.** Backend half of the 403: with paused time and the shipped
timings, a fake answering `/status` with 403 and every other request
normally, with no write sent, gives, after the retry barrier for that first
connect, with paused time not advanced, `state` `NoState` and a `readError`
containing `403`. View half of the 403: with `state` `NoState` and
`readError` set to that same string on the stand-in, after the layout
barrier the slot is visible with tint `Theme.textDisabled`, and
`ts-read-error` is visible and its text equals `readError`.
Backend half of the clearing, with paused time and the shipped timings:
after the retry barrier for the 403 loss, whose delay is 500 ms, the fake
is destroyed so that nothing exists at the path. Paused time advances
exactly 500 ms, the reconnect attempt finds nothing at the path, and after
its retry barrier `state` is `NoState`, `readError` is empty (R-CONN-02,
R-CONN-06) and `readErrorChanged` fired exactly once since the advance.
View half: with `state` `NoState`, `readError` set from that string to
empty and no other state ever reported, after the layout barrier the slot
and `ts-read-error` are both not visible.

**Sources.** `tests/tailscale-qml-test.qml:211-242`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:143-157`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:338-383`,
`pr286-body:72-74`, decision 7 (when `writeError` is non-empty too, the read
error wins, R-UI-16).

### R-QML-03 · parity · The blocked badge survives the daemon's death

**Statement.** After any state other than `NoState` was reported, a later
`NoState` keeps the slot visible and dims the icon. The crimson ✕ and the
exit-node label stay. This relies on R-CONN-06.

**Acceptance.** Two halves. Backend half: a fake reports an active, offline
exit node, the backend reaches `Running`, and the fake closes. After the
retry barrier, with paused time not advanced so no reconnect has run,
`state` is `NoState`, and `exitNodeActive`, `exitNodeOnline`,
`exitNodeBlocked`, `exitNodeId` and `exitNodeName` read what they read
before the close, with their change signals fired 0 times since the close.
View half: with those values and `state` `NoState` set on the stand-in after
`Running`, the slot is visible and dimmed, and the ✕ and the name are drawn.

**Sources.** `tests/tailscale-qml-test.qml:301-318`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:133-141`,
`plugin/src/contracts/TailscaleBackend.h:93-103`.

### R-QML-04 · parity · The bar's exit-node label is capped and elided

**Statement.** The label is at most 90 px wide and elides on the right. A long
name widens the slot up to the cap. A longer name does not widen it further. A
short name shrinks it back without eliding.

**Acceptance.** With names `sierra`, a 55-character MagicDNS name
(`yankee-with-a-long-magicdns-name.example-tailnet.ts.net`) and that name
doubled: the slot widens from the first to the second and the label truncates.
The doubled name gives the same width. `sierra` restores the first width
without truncation.

**Sources.** `tests/tailscale-qml-test.qml:320-343`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:200-223`, the cap and the elide
at `quickshell/c7shell/Modules/Bar/StatusPill.qml:219-220`.

### R-QML-05 · parity · The panel shows nothing last-known while NoState

**Statement.** In `NoState` the panel hides identity, addresses, the device
list, both sub-cards, the health list and the blocked alert. The header reads
"no daemon". Other states read "waiting for machine approval", "logged out",
"not connected", "starting…" and "connected". `exitNodeBlocked` reads "exit
node unreachable".

**Acceptance.** A fake that reported `Running` with peers and a blocked exit
node and then closed gives no visible `ts-self-ip4` or `ts-blocked-alert`,
and `ts-state` reads "no daemon". Each other `BackendState` gives its phrase.
Every hidden part is staged visible and non-empty before `NoState`, so the
check cannot pass because it was never shown (R-QML-09 and R-QML-12 keep
`ts-peer` rows and the sub-cards out of view while folded):

- With `ts-devices-row` clicked open and peers seeded, `NoState` shows no
  visible `ts-peer` and no visible `ts-devices-card`.
- With the exit sub-card open (`ts-exit-row-entry` clicked), `NoState` shows no visible `ts-exit-card`.
- With the settings sub-card open (`ts-settings-row` clicked), `NoState` shows no visible
  `ts-settings-card`.
- With one health entry that R-PARSE-12 does not suppress, `NoState` shows no
  visible `ts-issue` and no visible `ts-issue-count`.

Each case is checked as visible in `Running` first, as setup.

**Sources.** `tests/tailscale-qml-test.qml:524-540`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:23-28`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:47`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:62-73`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:385-476`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:429`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:597`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:774`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:813`,
`plugin/src/contracts/TailscaleBackend.h:98-102`.

### R-QML-06 · parity · The key-expiry line

**Statement.** `ts-expiry` shows only when `keyExpiry` is valid, in the disabled
colour. It reads whole average months (days ÷ 30.436875, rounded) above one
month, then "1 month", then days, then "under a day". A past instant reads
"session expired".

**Acceptance.** The view is unchanged: it reads "now" from the wall clock
(`Date.now()`), as #286 does, and the rewrite adds no clock seam to it (the
QML stays; no decision changes it). The criterion is independent of the
clock's value instead. The test reads `Date.now()` once, as N, and sets each
`keyExpiry` to N plus an offset that lies in the middle of a whole day, so
the view's floored day count, `Math.floor(ms / 86400000)`, is the same for
any evaluation of the binding within 12 hours of N. The criterion is
therefore valid for any clock whose reading at evaluation lies within that
margin of N, whatever value the clock has: every expected string below
depends only on the floored day count, and each offset keeps that count
fixed across the whole margin (N + 0.5 days floors to 0 and N − 0.5 days
reads as past for any evaluation inside it). That is why no seam is needed:
the view reads one wall clock, and the criterion does not depend on what
that clock reads. The binding is re-evaluated synchronously when
`keyExpiry` is set, so it is read well inside the margin. The margin is
checked, not assumed: after reading each text the test reads `Date.now()`
again, as N2, and asserts that the absolute value of N2 − N is under 12
hours, so
a wall clock that stepped outside the margin fails the test instead of
passing it on a wrong day count. The wall clock is the one host input this
criterion reads, and only under these bounds: its value never decides the
outcome, and the one way it can affect a run, a step of 12 hours or more
between the two reads, is a reported failure of the check, never a pass. Unset (`keyExpiry` invalid, as for a Self without
`KeyExpiry`): the line is hidden. N + 548.5 days (548 whole days, 18.004
average months) reads "expires in 18 months" in `Theme.textDisabled`.
N + 30.5 days (30 days, 0.986 average months) reads "expires in 1 month".
N + 5.5 days reads "expires in 5 days". N + 1.5 days reads "expires in 1
day". N + 0.5 days reads "expires in under a day". N − 0.5 days reads
"session expired".

**Sources.** `tests/tailscale-qml-test.qml:542-562`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:75-104` (the
strings and `Date.now()`, the clock the view reads),
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:548-560`.

### R-QML-07 · parity · Health issues on the panel

**Statement.** While live with `issueCount` > 0, the panel shows a count row and
one plain-text line per issue, verbatim. The count row reads "1 issue
detected…" or "N issues detected…".

**Acceptance.** With one non-suppressed health string, exactly one `ts-issue`
shows that text as plain text. `ts-issue-count` reads "1 issue detected…".

**Sources.** `tests/tailscale-qml-test.qml:564-578`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:425-468`.

### R-QML-08 · parity · The blocked-egress alert

**Statement.** While live and blocked, `ts-blocked-alert` sits above "this
device". Its plain text names `exitNodeName` and says traffic is blocked until
the exit node is disabled or changed.

**Acceptance.** With an offline `pentest-exit-node`, the alert is visible, its
text contains the name as plain text, and it sits above `ts-self-name`.

**Sources.** `tests/tailscale-qml-test.qml:580-602`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:385-423`.

### R-QML-09 · parity · The device list: DNS labels in three sections

**Statement.** The device list folds out of "network devices". It draws one
`ts-peer` row per model row, titled by `displayName`. Sections read "my
devices", "tagged devices" and "other users", by group. Only group 2 rows show
`ownerName`. An empty group draws no heading. This requirement describes the
list while `state` is `Running`, the state #286's checks stage; what the list
draws in any other state is R-GROUP-12's (a `fix`).

**Acceptance.** With four peers, including another user's `HostName`
`localhost` with DNS label `workstation`, 4 rows show and none reads
`localhost`. `workstation` shows its owner and `tango` no subtitle. Headings by
y read my devices, tagged devices, other users. Dropping that peer leaves 2
headings. Before `ts-devices-row` is clicked, no `ts-peer` row is shown: the
list is not on the root card.

**Sources.** `tests/tailscale-qml-test.qml:420-447`,
`tests/tailscale-qml-test.qml:604-651`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml:19-60`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:562-709`, decision
25 (the list outside `Running` is R-GROUP-12's).

### R-QML-10 · parity · Copying addresses uses the clipboard, not a process

**Statement.** Left-clicking a peer copies its `ip4` and shows local "copied"
feedback. Only a right-click opens `ts-copy-menu`, headed by the display name.
Its entries copy IPv4, IPv6 or the MagicDNS name and close the menu. An entry
with an empty value stays in place, is disabled, draws its label in
`Theme.textDisabled` and copies nothing. No process starts.

**Acceptance.** Clicking `tango` sets the clipboard to its IPv4, and the row's
local `copied` feedback then reads true. Clicking
the `bravo` delegate sets it to `100.64.0.2`. The row has one
right-button-only area. A right-click on `tango` opens `ts-copy-menu` with
`displayName` `tango`. Its three entries copy the IPv4, the IPv6 and
`tango.example-tailnet.ts.net`, and after each one the menu is closed. A
right-click on the `workstation` row, whose `HostName` is `localhost`, heads the
menu `workstation`. On `yankee`, without IPv6, `ts-copy-ip6` is
visible, disabled, labelled in `Theme.textDisabled` and leaves the clipboard
alone. Every entry whose value is non-empty is enabled: on `tango`,
`ts-copy-ip4`, `ts-copy-ip6` and `ts-copy-dns` each read enabled before
they are activated. No process starts: copying goes through the harness's
clipboard stand-in, which every copy clause above reads, and
`tests/test-native-boundary.sh`'s spawner scan (no `Process {` and no
`execDetached(` in any QML file) passes over
`quickshell/c7shell/Modules/Popovers/PeerRow.qml` and
`quickshell/c7shell/Modules/Popovers/CopyMenu.qml`. That scan is static, so it needs no barrier.

**Sources.** `tests/tailscale-qml-test.qml:653-726`,
`tests/tailscale-qml-test.qml:1693-1697`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml:62-97`,
`quickshell/c7shell/Modules/Popovers/CopyMenu.qml:19-161`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:169-191`.

### R-QML-11 · parity · Exit-node list: none, recommended and the check mark

**Statement.** `none` is checked and never dimmed when no exit node is active.
A "recommended" heading and row appear once when `recommendedExitNodeId`
matches a row. Then every exit row shows, titled by `displayName`. A row's
check shows only when active and its `nodeId` equals `exitNodeId`.

**Acceptance.** With three exit peers, two sharing `pentest-exit-node`, and the
suggestion `nCCC1CNTRL`: `ts-exit-none` is checked and live. One
`ts-exit-recommended` reads `pentest-exit-node`. Before the twin `nFFF1CNTRL`
is added, with only `host-5` (`nEEE1CNTRL`) and `pentest-exit-node`
(`nCCC1CNTRL`) seeded, `ts-exit-row` shows exactly 2 rows. Titles include `host-5`, never
`ip-172-31-0-10`. Selecting `nCCC1CNTRL` checks exactly that row. Setting
`exitNodeActive` false and `exitNodeId` empty then leaves no `ts-exit-row`
checked. An unknown suggestion shows no recommended row or heading. Setting the
suggestion back to `nCCC1CNTRL` shows exactly one
`ts-exit-recommended-label` heading again.

**Sources.** `tests/tailscale-qml-test.qml:728-823`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:121-200`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:335-378`,
`plugin/src/contracts/TailscaleBackend.h:166-180`.

### R-QML-12 · parity · Sub-cards fold out and keep their rows

**Statement.** The panel is the popover named `tailscale`; the bar slot opens
and closes it by that name. One of devices, exit and settings folds out at a
time, so opening one folds the others. Root rows stay, the panel grows, and the
chevron turns. The sub-card sits between its row and the next. Clicking again
folds it shut, turns the chevron back and restores the height. There is no
back navigation: the panel has no `ts-back` element. Devices and exit focus
their search. Re-opening devices reuses the same delegates. The panel reopens
folded, with the copy menu closed.

**Acceptance.** Toggling the popover manager with the name `tailscale` opens
the panel. No element named `ts-back` exists. Clicking `ts-devices-row` keeps
the four root rows, draws all four seeded `ts-peer` rows (R-QML-09), grows
the panel, turns `ts-devices-chevron`, and focuses `ts-peer-search-input`. The top of `ts-devices-card` lies strictly below
`ts-devices-row` and above `ts-exit-row-entry`. After `tango` is clicked,
clicking `ts-devices-row` again folds the card shut: no `ts-peer` row is shown
and `ts-devices-chevron` is back at its folded rotation. Reopening returns the
identical delegate, still "copied". Height returns within 1 px. With devices folded
out, clicking `ts-exit-row-entry` keeps the root row `ts-self-name` visible,
hides every `ts-peer` (opening exit folds devices away) and focuses
`ts-exit-search-input`. Separately, with every sub-card folded shut, no
`ts-settings-routes` row is shown: the settings rows are not on the root card.
Clicking `ts-settings-row` then keeps the root row `ts-self-name` visible,
shows no `ts-peer` row, grows the panel past its folded height and turns
`ts-settings-chevron`. #286 stages this settings case with devices shut, so the
settings click does not show settings folding devices away; the one-at-a-time
rule is checked through the exit case.
The top of `ts-settings-card` lies below `ts-settings-row`. Clicking it again
hides `ts-settings-routes`, turns the chevron back and restores the folded
height within 1 px.

**Sources.** `tests/tailscale-qml-test.qml:517-522`,
`tests/tailscale-qml-test.qml:604-611`,
`tests/tailscale-qml-test.qml:826-910`,
`tests/tailscale-qml-test.qml:1005-1014` (the exit case, staged with devices
open),
`tests/tailscale-qml-test.qml:1311-1320` (the settings staging, with
`pop.expanded = ""` at :1316, so every sub-card is shut),
`tests/tailscale-qml-test.qml:1322-1340`,
`tests/tailscale-qml-test.qml:1490-1498`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:158-164`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:32`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:36-39`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:106-129`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:594-618`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:821-853`,
`quickshell/c7shell/Common/SearchField.qml:17-29`.

### R-QML-13 · parity · Device search tells "no match" from "empty"

**Statement.** Device search matches a case-insensitive substring of
`displayName`. Failing rows collapse, and emptied sections hide their heading.
`ts-devices-count` shows the total, or the match count while searching.
"no matches" shows for a query that matches nothing in a non-empty list, and
never for an empty model. Two parts of this list are `fix` requirements of
their own and are not restated here: how the match count is taken
(R-QML-15, decision 8), and which message an empty model shows, which
depends on whether the peer set is known (R-GROUP-11, decision 6).

**Acceptance.** With four peers, the count reads 4. `TANGO` leaves one row, the
count 1 and only the "my devices" heading, and `ts-peer-no-match` is not
shown. `workstation` leaves only the "other
users" heading. A query matching nothing shows no `ts-peer` row and no
`ts-section` heading, shows `ts-peer-no-match` and not `ts-peer-empty`.
Clearing the query and seeding zero peers shows no `ts-peer-no-match`; which
empty-list message shows then is R-GROUP-11's criterion. Seeding the four
peers again then shows 4 rows and the count 4. Over 50 peers, `node-49`
leaves one row, titled `node-49`, under only the "other users" heading. The
stand-in and the views are synchronous after the harness's layout pass, so
each layout pass is the barrier for these checks. Setup, not acceptance: on
the rewrite's stand-in the test first sets `peersKnown` true, a member
#286's stand-in lacks, so the list is in the known state #286's checks
assume (R-GROUP-11).

**Sources.** `tests/tailscale-qml-test.qml:912-969`,
`tests/tailscale-qml-test.qml:987-999`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:131-167`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:574-585`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:632-658`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:711-741`.

### R-QML-14 · parity · Long lists are capped, clipped and scroll

**Statement.** The device list and the exit list each cap at 180 px, clip and
scroll. Growing the tailnet past the cap does not change the panel height. The
exit search stays above the scrolling area.

**Acceptance.** With 25 peers the device list overflows and clips. 50 peers
leave the panel height within 1 px. With 20 exit nodes the exit list overflows
and clips. 40 leave the height within 1 px. `ts-exit-search` sits above
`ts-exit-scroll`.

**Sources.** `tests/tailscale-qml-test.qml:971-985`,
`tests/tailscale-qml-test.qml:1016-1045`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:41-45`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:611-618`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:202-238`.

### R-QML-15 · fix · The device count counts matching rows

**Statement.** While searching, the device count reflects every matching
row, including rows the view has not built. The count comes from the plugin
(decision 8): module `C7` registers a creatable QML type `PeerFilter`, a
filter proxy over a peer model, with the properties `source` (the model,
`Tailscale.peers` in the panel), `query` (string) and `count` (int,
read-only, `countChanged`). Its rows are the source rows whose `displayName`
contains the query, trimmed of surrounding whitespace, compared
case-insensitively, in source order. An empty query matches every row.
The matching is the one the unchanged QML row filter uses
(`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:133-138`: `trim()`, `toLowerCase()` and `indexOf`),
because rows still collapse by that filter while the count comes from
`PeerFilter`, and the two must agree or "no matches" could show over a
visible row. Trimming removes exactly ECMAScript's `trim()` set (WhiteSpace
and LineTerminator: U+0009, U+000A, U+000B, U+000C, U+000D, U+0020,
U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000
and U+FEFF) from both ends of the query. Both the trimmed query and the
display name are then lowercased, and containment is a substring test on
the results. For ASCII letters the lowercasing is exact and the two agree
exactly, trim included, for any text. Beyond ASCII letters the folding is
the full Unicode lowercase mapping per scalar value, as R-GROUP-03 defines,
and it may differ from QML's JavaScript engine for the few characters whose
lowercase depends on context or on the engine's tables (for example a
word-final `Σ`): this is accepted as the same deliberate difference beyond
ASCII as decision 10's, so in such a case `count` may disagree with the
rows drawn. `count` is its row count, updated whenever the
source's rows or roles or the query change. `PeerFilter` is not a member of
`Tailscale`, so R-UI-02 and R-UI-13 are unchanged. This requirement's QML
change is limited to binding to that count: `ts-devices-count` reads
`count`, and in `ts-peer-no-match`'s visibility `count === 0` replaces
#286's `deviceMatchCount === 0`; this requirement changes no other part of
that visibility. Its other two
conditions stay: the query is non-empty and the peer model has at least one
row (#286's `peerList.count > 0`), so an empty model never shows "no
matches", with or without a query. Separately, R-GROUP-11's and
R-GROUP-12's own changes add a further condition, stated there and not
here, to the same two elements: both
`ts-devices-count` (on the root card's `ts-devices-row`, not in the list)
and `ts-peer-no-match` show only while `state` is `Running` and
`peersKnown` is true. `PeerFilter` updates `count` synchronously, inside the
handling of the source's row and data signals and inside the `query`
setter, so `countChanged` has fired before the source mutation or the
query set returns. The rows, their collapsing and the
section headings stay as in #286 (R-QML-13).

**Defect.** "`deviceMatchCount` tallies instantiated delegates rather than
matching rows, so a filtered long list under-reports."

**Acceptance.** Plugin half: a `PeerFilter` over a model of 200 own peers
`node-0` to `node-199` with query `node-1` has `count` 111; query ` NODE-1 `
gives 111 too, and so do `\u{FEFF}node-1\u{3000}` and `\tnode-1\n`
(ECMAScript's trim set); query `node-199` gives 1; an empty query gives 200. Removing
`node-10` from the source makes `count` 110 for `node-1`, and `countChanged`
fired once. Every plugin-half value is read right after the call that set
the query or mutated the source returns, which is the barrier, and the
`countChanged` total counts from just before that call, as R-GROUP-06
reads its model signals. View half, on the stand-in, with `state` `Running` and
`peersKnown` true set first as setup (R-GROUP-11; a fresh stand-in has
`peersKnown` false, which hides `ts-devices-count`): with 200 own peers and
the query `node-1` typed into `ts-peer-search-input`, `ts-devices-count` is
visible and reads 111 without scrolling. A query matching only the last row
reads 1 and hides `ts-peer-no-match`. A query matching nothing shows
`ts-peer-no-match` and `ts-devices-count` reads 0. Seeding zero peers with
that query still set hides `ts-peer-no-match` (the empty-model guard). With
`peersKnown` set false again and the 200 peers and the `node-1` query
restored, neither `ts-devices-count` nor `ts-peer-no-match` is visible.

**Sources.** `pr286-body:121-122`, decision 8,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:133-138` (the
row filter `PeerFilter` must agree with), decision 10 (the accepted
difference beyond ASCII),
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:140-167`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:579-585`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:718` (the
no-match guard), R-GROUP-11 and decision 6 (the `peersKnown` gating).

### R-QML-16 · follow-up · Long lists show a scrollbar, and there is one search pill

Moved to a follow-up, not in this epic (decision 9). The rewrite does not
implement it, and no gate of the rewrite checks it: Phase 2 writes no test for
it and the rewrite's coverage, mutation and 50-run gates do not include one.
`quickshell/c7shell/Common/SearchField.qml` stays as #286 ships it, and R-QML-14 (parity) keeps
covering the capped, clipped, scrolling lists. Follow-up issue #298
carries the decided design: delete `quickshell/c7shell/Common/SearchField.qml`, promote the Settings
sidebar's search pill to the shared component used by both panel searches,
and give the device list and the exit list a themed `ScrollIndicator` that
shows only when their content exceeds the 180 px cap. No #286 assertion maps
here: #286 has no scrollbar and no shared pill to test.

**Defect.** "Neither list has a scrollbar; `quickshell/c7shell/Common/SearchField.qml` duplicates
the Settings sidebar pill and has already diverged from it."

**Sources.** `pr286-body:123-124`, decision 9,
`quickshell/c7shell/Common/SearchField.qml:4-16`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:209-238`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:611-618`.

### R-QML-17 · parity · Exit rows request by node ID

**Statement.** While `writable`, every exit row is live and drawn live: no
row's title is in `Theme.textDisabled`. A click calls
`setExitNode` with that row's own `nodeId`. Of two rows sharing a hostname, only
the clicked one is requested. `none` requests `""`. The recommended row
requests `recommendedExitNodeId`. A click checks nothing by itself.

**Acceptance.** With `writable` true and no write refused, no exit row's title
is drawn in `Theme.textDisabled` and every exit row is hoverable. Neither is
`ts-exit-none`'s title. With the three exit peers seeded, `ts-exit-row` shows
exactly 3 rows. Clicking the `nFFF1CNTRL` row sends one PATCH
with `ExitNodeID` `nFFF1CNTRL`. No row is checked until the fake reports it.
`ts-exit-none` sends `""`. Exactly one `ts-exit-recommended` is shown, and it
sends `nCCC1CNTRL`.
Barriers. This criterion runs in two halves ("How to read"). In the view
half the stand-in records each action synchronously, so the click returning
is the barrier for every recorded-call count, every "sends one", "sends
nothing" and "no PATCH" clause, which reads the stand-in's recorded calls;
a control's checked, enabled or hoverable state, and any element's
visibility, is read after the layout pass that follows the last click or
property set. Each "until the fake reports" clause is read in the view half
before the stand-in's property is set to the reported value, and again after
the layout pass that follows that set. In the backend half each PATCH body,
PATCH count and "no PATCH" is read after the read barrier and the fake
barrier ("Request counts"), counting from just before the action, and the
contract value the fake reports is read after the idle barrier that follows
its notification.

**Sources.** `tests/tailscale-qml-test.qml:800-801`,
`tests/tailscale-qml-test.qml:1062-1129`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:21-28`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:63-68`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:121-151`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:335-378`.

### R-QML-18 · parity · The LAN-access switch reads back

**Statement.** `ts-exit-lan-switch` binds to `exitNodeAllowLANAccess`. A click
asks for the opposite value. The switch moves only when the property changes.

**Acceptance.** With the pref true, the switch is checked. A click sends
`{ExitNodeAllowLANAccess:false, ExitNodeAllowLANAccessSet:true}`. The switch stays
checked until the fake reports false. With the pref now false and the switch
unchecked, a second click sends
`{ExitNodeAllowLANAccess:true, ExitNodeAllowLANAccessSet:true}` (on the QML
stand-in, it records `setExitNodeAllowLANAccess(true)`), so the two clicks ask
for opposite values. A write the fake never applies leaves the switch unmoved:
after that second click, with the pref still false, the switch is unchecked.
Barriers. This criterion runs in two halves ("How to read"). In the view
half the stand-in records each action synchronously, so the click returning
is the barrier for every recorded-call count, every "sends one", "sends
nothing" and "no PATCH" clause, which reads the stand-in's recorded calls;
a control's checked, enabled or hoverable state, and any element's
visibility, is read after the layout pass that follows the last click or
property set. Each "until the fake reports" clause is read in the view half
before the stand-in's property is set to the reported value, and again after
the layout pass that follows that set. In the backend half each PATCH body,
PATCH count and "no PATCH" is read after the read barrier and the fake
barrier ("Request counts"), counting from just before the action, and the
contract value the fake reports is read after the idle barrier that follows
its notification.

**Sources.** `tests/tailscale-qml-test.qml:1131-1175`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:70-83`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:276-312`.

### R-QML-19 · parity · Exit-node search

**Statement.** Exit search matches a case-insensitive substring of
`displayName`, over node rows and the recommended row. `none` is never
filtered. "no matches" shows for a query matching nothing in a non-empty list.
"no exit nodes on this tailnet" shows only when `exitNodes` is empty.

**Acceptance.** `HOST` leaves one row, `host-5`, no recommended row, no
`ts-exit-no-match` and `none` visible. A query matching nothing shows
no `ts-exit-row`, exactly one `ts-exit-no-match`, titled `no matches`, and not
`ts-exit-empty`. Clearing it restores 3 rows and
hides `ts-exit-no-match`. No exit peers shows
`ts-exit-empty` only. Seeding the three exit peers again restores 3 rows.

**Sources.** `tests/tailscale-qml-test.qml:1191-1237`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:39-61`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:174-179`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:240-269`.

### R-QML-20 · parity · Controls go dead after a 403 and come back

**Statement.** While `writable` is false, both sub-cards show a write-error line
naming `c7shell-bootstrap`. Headings read "(read-only)". Control rows are
disabled and clicks request nothing. The same rule for R-UI-17's login
control is R-UI-17's (`new`), not this requirement's.
When `writable` returns to true, they come back. The write note's refusal
sentence always quotes a non-empty `writeError`: the shipped backend never
publishes `writable` false with `writeError` empty (R-WRITE-08 does not
reconcile while `writable` is false), so no criterion stages that pair.
Any other failure keeps them live and shows a "try again" note without
`c7shell-bootstrap`. This requirement states what the views draw while
`readError` is empty; what they draw while `readError` is non-empty is
R-UI-16's `fix`. How the shipped backend sets `writable` true again is
R-WRITE-11's `fix`. Neither is restated here.

**Acceptance.** While `writable` is true and nothing is refused,
`ts-exit-all-label` does not contain `read-only`, no `ts-exit-write-error` is
shown, and `ts-settings-routes-switch` is enabled with its row hoverable.
After a 403, `ts-exit-all-label` contains `read-only`, and
`ts-exit-write-error` and `ts-settings-write-error` contain `writeError` and
`c7shell-bootstrap`. `ts-exit-row` still shows exactly 3 rows. Every exit row,
the routes row and the DNS row has its title in `Theme.textDisabled` and is not hoverable. Every switch is disabled,
and clicks send no PATCH. After the stand-in sets `writable` true and
`writeError` empty, they are live and the lines hidden. R-WRITE-11's backend
half shows the shipped backend producing those values.
After a close before headers, `writable` stays true and
`ts-settings-write-error` shows one line that contains the `writeError` text
and lacks `c7shell-bootstrap`. The switches stay enabled, and a click sends a
PATCH.
Barriers. This criterion runs in two halves ("How to read"). In the view
half the stand-in records each action synchronously, so the click returning
is the barrier for every recorded-call count, every "sends one", "sends
nothing" and "no PATCH" clause, which reads the stand-in's recorded calls;
a control's checked, enabled or hoverable state, and any element's
visibility, is read after the layout pass that follows the last click or
property set. Each "until the fake reports" clause is read in the view half
before the stand-in's property is set to the reported value, and again after
the layout pass that follows that set. In the backend half each PATCH body,
PATCH count and "no PATCH" is read after the read barrier and the fake
barrier ("Request counts"), counting from just before the action, and the
contract value the fake reports is read after the idle barrier that follows
its notification.

**Sources.** `tests/tailscale-qml-test.qml:802-803`,
`tests/tailscale-qml-test.qml:1088-1096`,
`tests/tailscale-qml-test.qml:1239-1281`,
`tests/tailscale-qml-test.qml:1342-1348`,
`tests/tailscale-qml-test.qml:1415-1485`,
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:4-41`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:85-104`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:195-200`,
`quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml:32-70`,
`pr286-body:75-78`, decisions 7 (the read error wins over the write note,
R-UI-16) and 20.

### R-QML-21 · parity · The settings sub-card

**Statement.** Settings folds out of its own row. The routes and DNS switches
bind to `acceptRoutes` and `acceptDns`, ask for the opposite value, and move
only on change. While `acceptRoutes` is false, `ts-settings-routes-why` explains
why the accept-routes warning is missing from the issues. It sits below the
routes row. It hides once `acceptRoutes` is true. It does not go dead with the
controls: after a 403 it is still shown, because it explains the issue list,
not an offer.

**Acceptance.** Before `ts-settings-row` is clicked, no `ts-settings-routes`
row is shown. With `RouteAll` false, `CorpDNS` true and only that warning,
`ts-issue` is absent and the plain-text explanation `ts-settings-routes-why`
mentions "route". Its top lies below `ts-settings-routes`. Setting
`acceptRoutes` true hides it; setting it false again shows it. After a 403
disables the switches, exactly one `ts-settings-routes-why` is still shown.
With `acceptRoutes` false, after the layout barrier that follows opening
the sub-card and before any routes click, `ts-settings-routes-switch` is
unchecked. A
routes click sends `{RouteAll:true, RouteAllSet:true}` and the switch waits for
the fake. When `acceptRoutes` becomes true the switch is checked, and a second
routes click asks for `false`. With `acceptDns` true the DNS switch is
checked, and a DNS click sends `{CorpDNS:false, CorpDNSSet:true}`. The DNS
switch is still checked after its own click, and is unchecked once `acceptDns`
becomes false.
Barriers. This criterion runs in two halves ("How to read"). In the view
half the stand-in records each action synchronously, so the click returning
is the barrier for every recorded-call count, every "sends one", "sends
nothing" and "no PATCH" clause, which reads the stand-in's recorded calls;
a control's checked, enabled or hoverable state, and any element's
visibility, is read after the layout pass that follows the last click or
property set. Each "until the fake reports" clause is read in the view half
before the stand-in's property is set to the reported value, and again after
the layout pass that follows that set. In the backend half each PATCH body,
PATCH count and "no PATCH" is read after the read barrier and the fake
barrier ("Request counts"), counting from just before the action, and the
contract value the fake reports is read after the idle barrier that follows
its notification.

**Sources.** `tests/tailscale-qml-test.qml:1291-1413`,
`tests/tailscale-qml-test.qml:1440-1444`,
`tests/tailscale-qml-test.qml:1490-1498`,
`quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml:1-152`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:783-818`.

### R-QML-22 · parity · The connect toggle follows wantRunning, not state

**Statement.** `ts-connect-toggle` is checked when live and `wantRunning`. It
stays checked through `Starting` and `NeedsLogin`. It is enabled only when live
and `writable`. Toggling asks for `!wantRunning` and moves nothing itself. Its
plain-text tooltip carries the write note after a failure, while `readError`
is empty; when both errors are non-empty, R-UI-16 governs. With no write
note, it reads "tailscaled is not answering, so there is nothing to ask" when
not live, warns that disconnecting ends a session reached over Tailscale when
live and `wantRunning`, and reads "connect to the tailnet" otherwise.

**Acceptance.** On opening the panel while live, with `writable` true,
`writeError` empty and `wantRunning` true, the toggle is enabled and checked.
With `WantRunning` true, the toggle stays checked through
`Starting` and `NeedsLogin`. In `Running`, toggling sends
`{WantRunning:false, WantRunningSet:true}`, and the toggle is still checked
after that click. When `wantRunning` then becomes false, the toggle is
unchecked, and toggling again sends `{WantRunning:true, WantRunningSet:true}`.
In `NoState` it is disabled and sends nothing. When `state` returns to a live
state with `wantRunning` true, the toggle is enabled and checked again. After a
403 to a write, with `readError` empty, it is disabled, sends nothing, and
`ts-connect-tip` contains `writeError`. When `writable` comes back true and
`writeError` empty, the toggle is enabled, `ts-connect-tip` no longer contains
the refusal, and toggling records exactly one request again. A live toggle's
`ts-connect-tip` is non-empty. With `writeError` empty: live with
`wantRunning` false, `ts-connect-tip` reads `connect to the tailnet`; live
with `wantRunning` true, it contains `a session reached over tailscale ends
with it`; in `NoState`, it reads `tailscaled is not answering, so there is
nothing to ask`.
Barriers. This criterion runs in two halves ("How to read"). In the view
half the stand-in records each action synchronously, so the click returning
is the barrier for every recorded-call count, every "sends one", "sends
nothing" and "no PATCH" clause, which reads the stand-in's recorded calls;
a control's checked, enabled or hoverable state, and any element's
visibility, is read after the layout pass that follows the last click or
property set. Each "until the fake reports" clause is read in the view half
before the stand-in's property is set to the reported value, and again after
the layout pass that follows that set. In the backend half each PATCH body,
PATCH count and "no PATCH" is read after the read barrier and the fake
barrier ("Request counts"), counting from just before the action, and the
contract value the fake reports is read after the idle barrier that follows
its notification.

**Sources.** `tests/tailscale-qml-test.qml:1515-1642`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:49-60`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:236-335`, decision 7
(the read error wins over the write note, R-UI-16).

### R-QML-23 · parity · This device's identity rows

**Statement.** While live, the root card shows "this device" with `selfName` as
plain text. A row titled `selfIp4` copies it on click. Right-clicking opens the
copy menu for `selfName`, `selfIp4`, `selfIp6` and `selfDnsName`. No QML reads
`tailnet`, `hostName` or `exitNodeOption`, which stay on the contract.

**Acceptance.** With Self `omega`, IPs `100.115.228.122` and
`fd7a:115c:a1e0::fd27:82d8`, and DNS name `omega.example-tailnet.ts.net`
(set without a root dot, as `tests/tailscale-qml-test.qml:511` sets it):
`ts-self-name` shows `omega` as plain text. `ts-self-ip4` is titled with the
IPv4, and clicking it copies the IPv4. A scan of every `.qml` file under
`quickshell/c7shell/` finds no `tailnet`, `hostName` or `exitNodeOption`
identifier outside comments and string literals; planting `Tailscale.tailnet` in a scanned file makes the scan
fail.

**Sources.** `tests/tailscale-qml-test.qml:505-515`,
`tests/tailscale-qml-test.qml:675`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:478-546`. The "no
reader" clause rests on a search of `quickshell/c7shell/` at `a38dbca`
(`grep -rnwE 'tailnet|hostName|exitNodeOption' quickshell/c7shell --include=*.qml`
prints 37 lines, all of them `//` comments or `qsTr(...)` strings, such as
`quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml:69` and
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:268`; piping it through
`grep -vE '^[^:]+:[0-9]+:\s*//' | grep -v 'qsTr('` prints nothing); the contract declares the three at
`plugin/src/contracts/TailscaleBackend.h:59-64` and
`plugin/lib/tailscale/PeerModel.h:23-38`.

### R-QML-24 · parity · The QML stand-in cannot drift from the contract

**Statement.** The shell test drives the views against a stand-in for
`Tailscale`. Its property set is compared mechanically with the contract's. The
test fails if the two sets differ, or if the contract scan finds fewer than 15
properties.

**Acceptance.** Renaming or adding a property on one side only fails
`tests/test-tailscale.sh` and prints the difference. An unreadable contract fails it
with a message. The Rust port reads the contract's property list by
introspecting the built module at test time (decision 13): a small loader
loads the built `C7` module's registration and prints the property names of
the metaobject registered for `Tailscale`, excluding `objectName`. That is
the list QML sees. The loader reads that metaobject from the type
registration without creating the singleton, so no backend is built and
nothing connects (R-CONN-01 starts connecting when the singleton is
created). As a second guard, `tests/test-tailscale.sh` makes a private temporary
directory and runs the loader with `TS_SOCKET` set to a path in it that does
not exist, as R-SEC-02's harness does for the C++ tests, so even a loader
that did create the singleton could not reach the host's
`/var/run/tailscale/tailscaled.sock`.
It parses no Rust attribute and greps no generated C++. That the same check
covers `PeerFilter` (R-QML-15) against its stand-in, and that the stand-in
carries the members listed under "Contract additions", is R-QML-30's, not
this requirement's. Adding a property to the built
module only, with the stand-in unchanged, fails the check and names that
property. The loader's run creates no `Tailscale` instance: it reports,
through R-CONN-01's socket-path hook, every socket path a backend resolved
in its process, and that report is empty. Its environment has `TS_SOCKET`
under the script's temporary directory, naming no file, and the directory
is removed afterwards.

**Sources.** `tests/test-tailscale.sh:159-265`,
`tests/fixtures/harness.sh` (sets no `TS_SOCKET`, so the script must),
`tests/test-tailscale.sh:267-289` (#286 greps `Q_PROPERTY` in the header),
decision 13.

### R-QML-25 · parity · The stand-in behaves like the contract

**Statement.** The stand-in starts in `NoState` with `writable` true. Its
actions record calls and move no property. `state` is a QML enum with the six
values. `peers` and `exitNodes` are list models. An in-place edit, move,
insert or remove emits that row signal and no reset, as the real models do
(R-GROUP-06). A test can also rebuild them on purpose: clearing a model and
refilling it, as the harness's `seedPeers` does, discards every delegate. The
R-GROUP-06 control stages its rebuild that way. Like the contract, it derives `exitNodeBlocked` as `exitNodeActive`
and not `exitNodeOnline`, and `issueCount` as the length of `issues`; neither
is written by a test. How it carries the contract additions, and the
harness's further stand-ins, is R-QML-30's, not this requirement's.

**Acceptance.** A fresh stand-in reads `state === Tailscale.NoState` and
`writable === true`. Each of its five actions of #286 records one call and
changes no property. With `exitNodeActive` true and `exitNodeOnline` false, the stand-in's
`exitNodeBlocked` reads true. On `peers` with three rows, `setProperty`,
`move`, `insert` and `remove` each emit their row signal and no
`modelReset`. `clear()` leaves 0 rows, and refilling after it gives every row
a new delegate (the R-GROUP-06 control).

**Sources.** `tests/tailscale-qml-test.qml:286-287`,
`tests/tailscale-qml-test.qml:453-456`,
`tests/tailscale-qml-test.qml:1706-1764`,
`tests/test-tailscale.sh:156`, `tests/test-tailscale.sh:175-177`,
`tests/test-tailscale.sh:164-168`,
`tests/test-tailscale.sh:193-214`,
`tests/test-tailscale.sh:216-262`,
`docs/superpowers/plans/2026-10-15-tailscale-v2.md:173-177`.

### R-QML-26 · parity · The QML suite runs headless and clean

**Statement.** The bar-slot and panel suite runs offscreen, with no compositor
and no tailscaled. It loads the real slot, popover and common components into
a private temporary directory. The QML runtime it uses comes from
`qt6-declarative`, a package dependency, so it is part of the build, not host
state. The suite ends itself: it exits 1 at the first failed check and 0 after
the last, so its result never depends on a timer. It passes only if the runner
exits 0, prints the pass marker, prints no fail marker, and emits no warning
naming a `.qml` file. The runner's timeout only guards against a hang and is
never a pass condition.

**Acceptance.** Whether the suite runs is decided by declared dependencies
and by the script, not by the host. `PKGBUILD`'s `depends` array lists
`qt6-declarative`, so the package's `check()` environment has the runner. With a
`PATH` holding no `qml6`, the script prints
`SKIP: qml6 not installed (package: qt6-declarative)` and exits 0. With a stub
`qml6` first on `PATH` that exits 0 and prints no `TAILSCALE-TEST-PASS`, the
script exits non-zero. With the declared runner and
`QT_QPA_PLATFORM=offscreen`, the runner exits 0. Its log contains
`TAILSCALE-TEST-PASS`, no `TAILSCALE-TEST-FAIL` and no line matching `\.qml:`.
A stand-in whose first check fails makes the runner exit non-zero with a
`TAILSCALE-TEST-FAIL` line naming that check.

A SKIP never satisfies this criterion. The criterion is met only by a run in
which `qml6` is present, resolving to the runner `qt6-declarative`
provides; no other run can meet it. A run that prints the SKIP line is a
reported failure of this gate: the script itself exits 0 on that branch,
so that the rest of a developer's suite still runs, but the gate (the
`PKGBUILD` `check()` run and every CI run that counts toward the gates)
reads the script's output, and when it contains
`SKIP: qml6 not installed` the gate reports R-QML-26 as failed, never as
passed and never as not run. The headless clause holds only when the
log contains `TAILSCALE-TEST-PASS`. It is judged by the test's own output, not
by which machine runs it: any run of the script in which `qml6` resolves to
the runner `qt6-declarative` provides, `QT_QPA_PLATFORM` is `offscreen`, and
`WAYLAND_DISPLAY` and `DISPLAY` are unset, decides it. The runner's presence is
a declared dependency (`PKGBUILD:24`), not host state, so a CI job that installs
`PKGBUILD`'s `depends` (`PKGBUILD:11-24`) before running the suite meets that
condition without any particular build tool, chroot or root access. A run that
SKIPs proves nothing either way and leaves the clause unmet; it is never
counted as a pass. The SKIP and stub clauses are separate checks of the
script's own branches, each staged by a `PATH` the test builds, and are not
evidence that the suite ran. At `a38dbca`, `tests/fixtures/harness.sh:31-33`
still says `qt6-declarative` is not a dependency; that comment is stale against `PKGBUILD:24`, and the
rewrite's harness states the dependency correctly.

**Sources.** `tests/test-tailscale.sh:1-26`, `tests/test-tailscale.sh:32-62`,
`tests/test-tailscale.sh:124-130`, `tests/test-tailscale.sh:361-380`,
`tests/fixtures/harness.sh:30-38`, `tests/tailscale-qml-test.qml:167-177`,
`PKGBUILD:11-24`, `PKGBUILD:129`, `PKGBUILD:152`.

### R-QML-27 · parity · The theme tokens the views read exist

**Statement.** The theme provides `accentFillActive`, `accentFillSoft`,
`accentBorderSoft`, `powerHover`, `radiusSlot`, `radiusMenu`, `radiusMenuRow`,
`pillHeight` and `pillRadius`. The test theme stand-in carries the same names.

**Acceptance.** Loading the views over the stand-in theme emits no `.qml:`
warning, so no binding reads an undefined token. A property scan of the real
`quickshell/c7shell/Theme/Theme.qml`, done like the R-QML-24 stand-in check,
finds a declaration of each of the nine tokens. Removing one from the real
theme fails the test.

**Sources.** `tests/fixtures/theme-stub.sh:61-66`,
`tests/fixtures/theme-stub.sh:92-97`,
`quickshell/c7shell/Theme/Theme.qml:52-53`,
`quickshell/c7shell/Theme/Theme.qml:59-61`,
`quickshell/c7shell/Theme/Theme.qml:96-97`,
`quickshell/c7shell/Theme/Theme.qml:101-102`.

### R-QML-28 · withdrawn · The views' test hooks are unique

Withdrawn: it described the QML suite's own lookups, not product behaviour.
The checks it held (exactly one slot label and one slot icon, one element per
addressed `ts-` name, a peer row per seeded display name, at
`tests/tailscale-qml-test.qml:146`, `:154`, `:398` and `:480`) are harness
preconditions. The traceability file lists them under "Harness
preconditions". The Rust rewrite keeps the QML, so the hooks stay as they
are.

### R-QML-29 · withdrawn · A row with no action behind it is drawn dead and says why

Withdrawn: decision 2 gives the row `ts-exit-advertise` an action
(`setAdvertiseExitNode`, R-WRITE-10), so the rewrite never has the row
without one, and a requirement that it is drawn dead could never hold on the
rewrite. It described #286's row
(`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:314-333`): title in
`Theme.textDisabled`, the reason `not in this release`, and a click that asks
for nothing. #286's checks of it (`tests/tailscale-qml-test.qml:1183`,
`:1184`, `:1186` and `:1188`) map to R-WRITE-10, whose view half states the
replacement for each: the row stays visible, its title is live, its subtitle
is empty, and a click records `setAdvertiseExitNode(true)`.

### R-QML-30 · fix · The stand-in carries the contract additions

**Statement.** Split from R-QML-25, which keeps #286's members. The QML
stand-in carries every member listed under "Contract additions"
(`peersKnown`, `loginUrl`, `advertisingExitNode`,
`exitNodeAwaitingApproval`, `ipForwardingWarning`, `login()`,
`setAdvertiseExitNode(bool)`; decisions 1, 2 and 6), by R-QML-25's rules:
it starts at R-UI-18's fresh values, and its actions record calls and move
no property. The harness also provides a `PeerFilter` stand-in (R-QML-15,
decision 8) and a recording stand-in for the URL opener (R-UI-17, decision
1), which returns a configurable bool, true by default, so a failed open
can be staged. The tag is `fix` because these members and stand-ins exist
only by those decisions; the test fails on `a38dbca`.

**Acceptance.** A fresh stand-in reads `peersKnown`, `advertisingExitNode`
and `exitNodeAwaitingApproval` false and `loginUrl` and
`ipForwardingWarning` empty. `login()` and, separately,
`setAdvertiseExitNode(true)` each record exactly one call and change no
property. A fresh opener stand-in, asked to open a URL, records exactly
that URL and returns true; set to fail, it records the next URL and returns
false. Each recorded call is read when the call returns, as "Two halves"
states. R-QML-24's mechanical comparison also covers the added members and
`PeerFilter`, moved here from R-QML-24 because #286 has neither: the
stand-in gains every member listed under "Contract additions" in the same
change that adds it to the contract, so the comparison stays exact, and
`tests/test-tailscale.sh` compares the `PeerFilter` stand-in's property set with
the property names of the metaobject the built module registers for
`PeerFilter`, by R-QML-24's loader, failing and printing the difference when
they differ. Adding one of the five added properties to the built module
only, with the stand-in unchanged, fails the check and names that property;
so does adding a property to the built `PeerFilter` only.

**Sources.** R-QML-25's sources (`tests/tailscale-qml-test.qml:286-287`,
`tests/test-tailscale.sh:193-214`), "Contract additions", decisions 1, 2, 6
and 8.

## R-SEC: untrusted input and isolation

R-WATCH-01 also belongs here: the watch always asks tailscaled to strip
private keys.

### R-SEC-01 · parity · No process, and nothing blocks

**Statement.** All Tailscale state is read and written over the local-API
socket. The system side never starts `tailscale` or any other process. It never
blocks the QML thread waiting on the socket.

**Acceptance.** A full backend scenario runs with recording stubs of
`tailscale` and `sh` first on `PATH`, built with the testing kit's fake
program: connect, one pass, a notification pass, each of #286's five
actions, a 403 and a reconnect. The scenario ends with the idle barrier and the read barrier.
The backend is then destroyed, and the test reaps its own child processes
until the operating system reports that it has none left, so any stub that
was started has exited and written its record. Only then are the records
read: both stubs record zero invocations. A source scan of the Tailscale
library and backend finds no `QProcess`, `std::process::Command`,
`posix_spawn`, `fork` or `exec*` call, and a selftest case proves the scan
catches a planted call. `tests/test-native-boundary.sh` is not this check: it
scans only QML. Nothing blocks: with paused time, the shipped 10 000 ms
request deadline and a fake that holds every request, the test calls the
factory and then each of #286's five actions in turn.
Each call returns to the test while its request is still held, and at that
point no outcome for it has been delivered and paused time has not advanced.
After the last call, the read barrier holds with no failure delivered:
`readError` and `writeError` are empty. The test then advances paused time
exactly 10 000 ms, and after the read barrier `state` is `NoState`,
`readError` contains `10000 ms` and `writeError` contains `10000 ms`. A call that blocked on the socket could not return
before the deadline fired. The same two clauses for the added actions
`login()` and `setAdvertiseExitNode` are R-UI-18's, not this
requirement's.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:19-23`,
`tests/test-native-boundary.sh:5-9`,
`plugin/lib/testing/fakeprogram.h:48-100`.

### R-SEC-02 · parity · Tests never reach the host's tailscaled

**Statement.** The test harness points `TS_SOCKET` at a non-existent path in
its private directory before any test runs. A backend built by a test fails to
connect instead of reaching the host daemon. Each transport and backend test
also gets its own fresh temporary directory, created before the test runs, and
puts its fake tailscaled's socket there. No test sees another test's socket.

**Acceptance.** With `TS_SOCKET` set to `/var/run/tailscale/tailscaled.sock`
before isolation, the isolated process's `TS_SOCKET` lies in the private
directory and names no file. It is listed among the variables the harness
sets. A backend built there, with paused time, after the retry barrier
for its first connect and with paused time not advanced, has armed exactly
one retry and reads `NoState` with an empty `readError`: its connect found
nothing at that path (R-CONN-02), so it reached no daemon. Each
transport or backend test's temporary directory differs from the previous
test's directory, and that test's socket path does not exist in it. Setup,
not acceptance: each test first checks its temporary directory is valid, and
the module suite checks `TS_SOCKET` lies under the isolation root before it
creates the singleton.

**Sources.** `plugin/tests/tst_module.cpp:100-104`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:20-25`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:611-614`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:285-291`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1462-1465`,
`plugin/lib/testing/testmain.cpp:72-78`,
`plugin/lib/testing/testmain.cpp:93-103`,
`plugin/lib/testing/tests/tst_isolation.cpp:62-70`,
`docs/superpowers/specs/2026-10-15-tailscale-module-design.md:157-161`,
`docs/superpowers/plans/2026-10-15-tailscale-v2.md:33`.

### R-SEC-03 · parity · Network strings are drawn literally, never as markup

**Statement.** Every string from tailscaled reaches only plain-text `Text`
elements. That covers names, owners, addresses, health strings, both error
texts and `selfName`, in the bar, rows, the copy menu, issue lines, alerts,
error lines and the connect tooltip. The same rule for R-UI-17's login
error lines is R-UI-17's (`new`), not this requirement's. The backend passes them through verbatim.
`<b>a</b>` draws as eight characters, and no remote `<img>` is fetched.

**Acceptance.** A peer named `<b>a</b>` and a health entry `<img
src=http://x/>` reach QML byte for byte. The bar label for `<b>a</b>` is more
than twice as wide as for `a`. Every `Text` inside each element checked has
plain-text format, and the issue `Text`
holds the literal `<img src=http://x/>`. A plain-text `Text` never loads an
image, so plain-text format is the observable proof that nothing is fetched;
no network listener is needed. Setup, not acceptance: each element checked
holds at least one `Text`, and a peer row holds at least three, so the check
reaches the shared row component's own title and subtitle and cannot pass on
an empty element (traceability, "Harness preconditions",
`tests/tailscale-qml-test.qml:467` and `:670`).

**Sources.** `tests/tailscale-qml-test.qml:345-367`,
`tests/tailscale-qml-test.qml:458-473`,
`tests/tailscale-qml-test.qml:670-675`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:205-212`,
`quickshell/c7shell/Common/ListRow.qml:97-122`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml:99-106`,
`quickshell/c7shell/Modules/Popovers/CopyMenu.qml:77-88`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:369-382`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:92-104`,
`quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml:53-65`,
`pr286-body:65-68`.

### R-SEC-04 · parity · The native boundary does not grow

**Statement.** No QML file imports a Quickshell integration module for
Tailscale, and copying never starts `wl-copy`. Tailscale adds nothing to the
boundary debt tables.

**Acceptance.** `tests/test-native-boundary.sh` passes. No debt entry names a
file only Tailscale uses: `quickshell/c7shell/Modules/Popovers/Tailscale*.qml`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml`,
`quickshell/c7shell/Modules/Popovers/CopyMenu.qml` or `quickshell/c7shell/Common/SearchField.qml`.
No entry for a shared file, such as
`quickshell/c7shell/Modules/Bar/StatusPill.qml`, names a Tailscale
module or a Tailscale program. Its existing entries
(`tests/test-native-boundary.sh:124-126`) are not Tailscale's. Each table's count is at most its count at `a38dbca`:
33, 40 and 21. The debt tables only shrink, so the pin stays valid. The clipboard stand-in receives every copy.

**Sources.** `tests/test-tailscale.sh:132-143`,
`docs/superpowers/plans/2026-10-15-tailscale-backend.md:656`,
`docs/superpowers/specs/2026-10-15-tailscale-v2-design.md:15`,
`pr286-body:49-50`.

### R-SEC-05 · parity · Committed captures are redacted

**Statement.** Every committed tailscaled capture keeps its keys, types, array
lengths and string shapes. Logins, the MagicDNS suffix, the tailnet name, node
keys, IDs, the captured `10.0.0.0/8` routes (remapped into `172.16.0.0/12`)
and cloud hostnames are fixed placeholders. One private address is kept as
captured: the self endpoint `192.168.1.129:41641` in `Self.Addrs`, which the
redaction mapping does not cover. It is a generic home-LAN address and
identifies no network. New scenarios follow the same rule.

**Acceptance.** A scan of every Tailscale fixture finds no login domain other
than `example.com`, no tailnet suffix other than `example-tailnet.ts.net`, no
`10.0.0.0/8` address, and no `ip-A-B-C-D` hostname other than
`ip-172-31-0-10`. Every `192.168.0.0/16` string in the fixtures is exactly
`192.168.1.129:41641` inside `Self.Addrs`: one per status capture, three in
all.

**Sources.** `docs/superpowers/specs/2026-10-15-tailscale-module-design.md:149-152`,
`docs/superpowers/plans/2026-10-15-tailscale-backend.md:78-91`,
`docs/superpowers/specs/2026-10-15-tailscale-v2-design.md:134-135`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:11`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:27-30`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode.json:29`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode-offline.json:29`,
`pr286-body:52-53`.

## R-BOOT: bootstrap

### R-BOOT-01 · parity · The desktop user becomes the operator when none is set

**Statement.** tailscaled authorises prefs writes by its operator. When a
client is installed, tailscaled answers with prefs of the recognised shape
(R-BOOT-08), and those prefs carry no `OperatorUser`, `c7shell-bootstrap`
runs `tailscale set --operator=<user>` as root. `<user>` is
`id -un`, never `$USER`, which is root under sudo.

**Acceptance.** With a stub `tailscale` whose prefs lack `OperatorUser`, `id -un`
printing `tester` and `USER=root`, `--dry-run` prints `would run (root):
tailscale set --operator=tester` and never `operator=root`. A real run through a
stub sudo logs `sudo tailscale set --operator=tester`.

**Sources.** `bin/c7shell-bootstrap:549-555`,
`bin/c7shell-bootstrap:584-591`, `bin/c7shell-bootstrap:601-604`,
`tests/test-bootstrap.sh:397-436`, `tests/test-bootstrap.sh:449-454`,
`pr286-body:41-44`, decision 26 (only prefs of the recognised shape count, R-BOOT-08).

### R-BOOT-02 · parity · No client or no daemon: the step is silent

**Statement.** With no `tailscale` on `PATH`, the bootstrap runs no operator
step and says nothing about an operator. The same holds when
`tailscale debug prefs` fails on the one ask the bootstrap makes, that is
under `--dry-run` or in a real run that did not itself enable
`tailscaled.service` (R-BOOT-03). This holds whether or not Tailscale is a
package dependency. The one failing case that is not silent is a real run
that enabled the unit and whose 20 asks all failed: R-BOOT-03 (decision 15)
warns there.

**Acceptance.** With no client, `--dry-run` output contains neither `operator`
nor `naming the tailscale operator`. With `debug prefs` exiting 1, `--dry-run`
output contains no `operator`.

**Sources.** `bin/c7shell-bootstrap:562-567`, `bin/c7shell-bootstrap:584`,
`tests/test-bootstrap.sh:386-395`, `tests/test-bootstrap.sh:421-424`,
`pr286-comments:3-7`, `pr286-comments:24-26`.

### R-BOOT-03 · fix · The operator is named after the services step

**Statement.** The operator step runs after system services are enabled. When
this real run enabled `tailscaled.service`, the bootstrap asks `debug prefs` up
to 20 times, 0.5 s apart. Otherwise, and always under `--dry-run`, it asks once.

If all 20 asks fail in a run that enabled the unit, the bootstrap says so
(decision 15): it warns
`tailscaled did not answer, so the tailscale operator is not named yet` and
adds the closing note
`the tailscale panel stays read-only until you run c7shell-bootstrap again once tailscaled answers`.
Neither stops the run (R-BOOT-06). When one ask fails because the unit was
already enabled, or under `--dry-run`, the step stays silent (R-BOOT-02). In
#286 an exhausted wait is silent too, so the panel comes up read-only at 403
and nothing tells the user to run the script again, which is what is left of
the defect the reviewer named (`pr286-comments:13`).

**Acceptance.** `--dry-run` prints `== enabling system services` before `==
naming the tailscale operator`. With `sleep` stubbed and `debug prefs` failing k
< 20 times, a real run that enabled the unit names the operator after k + 1
asks. With the unit already enabled, it asks once. With `debug prefs` failing
every time, a real run that enabled the unit asks exactly 20 times, sleeps 19
times, prints no `naming the tailscale operator`, prints the warning above,
its notes contain the closing note above, and it reaches the user-services
step. With the unit already enabled and the one ask failing, the output
contains no `operator`.

**Sources.** `bin/c7shell-bootstrap:536`, `bin/c7shell-bootstrap:557-583`,
`bin/c7shell-bootstrap:584` (#286 skips the step in silence),
`tests/test-bootstrap.sh:438-447`, `pr286-comments:13-21`, decision 15.

### R-BOOT-04 · parity · The operator step is idempotent

**Statement.** When the operator already is the login user, the bootstrap
prints `already the operator: <user>` and runs no `tailscale set`. A second run
writes nothing and prompts for nothing.

**Acceptance.** With `OperatorUser` `tester`, a real run logs no `tailscale set`
and prints `already the operator: tester`. Two runs from an unset operator write
once.

**Sources.** `bin/c7shell-bootstrap:594-595`,
`tests/test-bootstrap.sh:449-458`.

### R-BOOT-05 · parity · Another user's operator is left alone

**Statement.** When the operator is another user, the bootstrap leaves it. It
warns `tailscale's operator is "<other>", not you; leaving it alone`. It adds a
closing note with `sudo tailscale set --operator=<user>`.

**Acceptance.** With `OperatorUser` `other-user`, a real run logs no `tailscale
set`. The output contains `operator is "other-user", not you`, and the notes
contain `sudo tailscale set --operator=tester`.

**Sources.** `bin/c7shell-bootstrap:596-600`,
`tests/test-bootstrap.sh:460-465`.

### R-BOOT-06 · parity · Operator failures are warnings

**Statement.** If the login user is unknown, the bootstrap warns and leaves the
operator. If `tailscale set` fails, it warns that the panel stays read-only.
Neither stops the run.

**Acceptance.** With `id -un` failing, the output contains `cannot tell who logs
in here` and no `tailscale set` is logged. With `tailscale set` exiting 1, the
output contains `the tailscale panel stays read-only`, and the run reaches the
user-services step.

**Sources.** `bin/c7shell-bootstrap:591-593`,
`bin/c7shell-bootstrap:603-604`, `bin/c7shell-bootstrap:607-611`.

### R-BOOT-07 · new · An opt-in step enables IP forwarding for an exit node

**Statement.** An exit node needs the kernel to forward IP traffic, which
needs root, so the bootstrap offers it as an opt-in step (decision 2, with
R-WRITE-10's runtime check). Only with the flag `--tailscale-exit-node` does
`c7shell-bootstrap` run the step `== enabling ip forwarding for a tailscale
exit node`. Its file is `$etc_root/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf`,
where `$etc_root` is the bootstrap's existing `C7SHELL_ROOT` prefix
(`bin/c7shell-bootstrap:132-135`), as `SDDM_DROPIN` is: empty in normal use,
so the path is `/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf`, and the
test root under the test suite. Below, FILE is that prefixed path, and every
write, read, `sysctl -p` argument and message uses FILE as it stands. The
step writes FILE holding exactly the two lines `net.ipv4.ip_forward = 1`
and `net.ipv6.conf.all.forwarding = 1`, as root, and then runs
`sysctl -p FILE` as root. It runs after the operator step
(`== naming the tailscale operator`, when that step runs, and so after
`== enabling system services`, when that runs) and before
`== enabling user services`, in every run with the flag, including one
where neither earlier step runs. When FILE already holds exactly those lines, it writes nothing and checks the
live values instead, without root: `sysctl -n net.ipv4.ip_forward` and
`sysctl -n net.ipv6.conf.all.forwarding`. When both print `1` it runs
nothing more. When either prints anything else or fails (an earlier
`sysctl -p` failed, or a later `sysctl.d` file overrides the values), it
runs the same `sysctl -p` as root, so a rerun before a reboot does not pass
over forwarding that is still off. A failing `sysctl -p` is a warning,
`could not enable ip forwarding now; it applies at the next boot`, and does
not stop the run. A failed write of the file (sudo refused, a read-only
`/etc`) is a warning too, exactly
`could not write FILE; ip forwarding is not enabled`:
the step then runs no `sysctl` and does not stop the run. Without the flag the bootstrap writes no such file, runs no
`sysctl` and prints nothing about forwarding. `--help` lists the flag.

**Acceptance.** Every run sets `C7SHELL_ROOT` to the test root R, so FILE
is `R/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf`, and no run touches
the host's `/etc`. Without the flag, a real (stubbed) run leaves no
`99-c7shell-tailscale-exit-node.conf` under R, logs no `sysctl`,
and its output contains no `ip forwarding`. With the flag, `--dry-run`
prints the step and changes nothing; a real run leaves FILE with exactly
those two lines and logs `sudo sysctl -p R/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf`
(R written out as the test's root path) exactly once, and in its output the
line `== enabling ip forwarding for a tailscale exit node` comes after
`== naming the tailscale operator` (staged with a stub `tailscale` whose
`debug prefs` prints prefs) and before `== enabling user services`. A
second real run with the flag, with a `sysctl -n` stub printing `1` for both
keys, logs both `sysctl -n` reads, logs no `sysctl -p`, prints no warning
and rewrites nothing. The same second run with a `sysctl -n` stub printing
`0` for `net.ipv4.ip_forward` rewrites nothing and logs
`sudo sysctl -p R/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf` exactly
once; with that stub and a `sysctl -p` stub exiting 1, the output contains
the warning `could not enable ip forwarding now; it applies at the next boot`
and the run reaches the user-services step. With a
`sysctl` stub exiting 1, the output contains the warning and the run reaches
the user-services step. With a stub whose write of the file exits 1, the
output contains exactly
`could not write R/etc/sysctl.d/99-c7shell-tailscale-exit-node.conf; ip forwarding is not enabled`,
no `sysctl` is logged, and the run
reaches the user-services step. `--help` output contains `--tailscale-exit-node`.

**Sources.** decision 2, `bin/c7shell-bootstrap:60-70` (the flag parser the
step joins), `bin/c7shell-bootstrap:132-135` (the `etc_root` prefix and
`SDDM_DROPIN`), `bin/c7shell-bootstrap:536`, `:585` and `:608` (the
system-services, operator and user-services steps the new step sits
between), `docs/superpowers/specs/2026-10-15-tailscale-v2-design.md:114-118`.

### R-BOOT-08 · fix · Operator prefs the bootstrap cannot read leave the operator alone

**Statement.** The bootstrap reads `OperatorUser` with a line-oriented match,
which is only sound for the shape `tailscale debug prefs` prints: a JSON
object indented one key per line. It acts on the operator only when the
output has that recognised shape (decision 26): the first line is exactly
`{`, the last non-empty line is exactly `}`, and every line that contains
`"OperatorUser"` matches `^[[:space:]]*"OperatorUser":[[:space:]]*"[^"]*",?$`.
With the recognised shape, R-BOOT-01, R-BOOT-04 and R-BOOT-05 apply. Empty
output from a `debug prefs` that exited 0 is not "other output": it carries
nothing that could be misread, and the step is skipped silently, as #286's
`[[ -n $ts_prefs ]]` (`bin/c7shell-bootstrap:584`) skips it and as R-BOOT-02
describes a failing ask, with no `operator` in the output and no warning.
With any other non-empty output from a `debug prefs` that exited 0, it does not run
`tailscale set`, and warns exactly
`cannot read tailscale's prefs, so the tailscale operator is left alone`. It
adds no dependency: the check is `sed`/`grep`, not `jq` (vmtest commit
`958a907` avoided `jq` deliberately). In #286 a one-line
`{"OperatorUser":"other-user","WantRunning":true}` finds no operator, so the
bootstrap runs `tailscale set --operator=<user>` and takes over another
user's operator, which R-BOOT-05 exists to prevent.

**Acceptance.** With a stub whose `debug prefs` prints the one line
`{"OperatorUser":"other-user","WantRunning":true}`, a real run logs no
`tailscale set` and its output contains the warning above. So does a stub
printing `{\n\t"OperatorUser": null\n}`, and one printing `not json`. The
stub of `tests/test-bootstrap.sh:397-416`, which prints the indented shape,
still gets R-BOOT-01's `tailscale set --operator=tester` without the key and
R-BOOT-05's warning with `other-user`. A stub whose `debug prefs` prints
nothing and exits 0: `--dry-run` output contains no `operator`, and a real
run that did not enable `tailscaled.service` logs no `tailscale set` and its
output contains neither `operator` nor `cannot read tailscale's prefs`.

**Sources.** `bin/c7shell-bootstrap:584-600` (the match at `:588`; the
empty-output skip at `:584`),
`tests/test-bootstrap.sh:397-416`, decision 26.

## R-PKG: packaging and gates

### R-PKG-01 · parity · Every suite runs, and runs 50 times in a row

**Statement.** The plugin gate runs suites for status parsing, the peer model,
the local-API client, the contract against the fake, the real backend and
module loading. It fails if any is missing. Every registered test is in the
50-run loop, and the gate names any test that is not.

**Acceptance.** The gate lists each Tailscale suite. A test registered outside
the loop fails the gate by name. Every test passes 50 consecutive runs. In Rust,
every workspace test runs under the 50-run loop.

**Sources.** `tests/test-c7-plugin.sh:14-15`,
`tests/test-c7-plugin.sh:150-190`, `docs/architecture.md:262-267`,
`docs/superpowers/plans/2026-10-15-tailscale-v2.md:34`.

### R-PKG-02 · parity · The architecture document lists the contract

**Statement.** `docs/architecture.md` lists `TailscaleBackend` (`Tailscale`)
against "tailscaled's local API socket". It states the rules a contract owns
for every backend.

**Acceptance.** The contracts table in `docs/architecture.md` has the Tailscale
row. The section on contract-owned rules names derived and normalised values.

**Sources.** `docs/architecture.md:144`, `docs/architecture.md:249-260`.

## R-FAKE: the fake tailscaled (extra area)

The plan ports `plugin/lib/testing/` to Rust. Every acceptance above depends on
the fake, so its behaviour is a requirement too.

### R-FAKE-01 · parity · The fake frames requests, bodies included

**Statement.** With a delimiter set, a request that declares `Content-Length`
is incomplete until its body has arrived. It is recorded as head, delimiter and
body. The next request is framed after the body. A request without a body is
recorded as its head only.

**Acceptance.** A client connects to the fake. Writing
`PATCH /p HTTP/1.1\r\nContent-Length: 10\r\n\r\n{"a":` records nothing. After `true}`, exactly one request equals the whole message,
and the client receives `ok`. A following `GET /q HTTP/1.1\r\n\r\n` records as
`GET /q HTTP/1.1`. The negative is checked after the fake barrier: the fake has
consumed every byte of the partial PATCH and recorded nothing.

**Sources.** `plugin/lib/testing/fakesocketserver.h:38-54`,
`plugin/lib/testing/fakesocketserver.cpp:11-30`,
`plugin/lib/testing/fakesocketserver.cpp:132-161`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:116-148`.

### R-FAKE-02 · parity · The fake pushes exact bytes and holds a request

**Statement.** The fake pushes exact bytes, or a line plus LF, to every
connected client that is not held. It returns how many clients took them. It
can hold the next request matching a fragment: recorded, unanswered and
connected. It reports how many are held. It later completes all held requests
with a reply and returns how many it reached. A hold is one-shot, and holds
accumulate: arming the hold again while a request is held holds a further
matching request, and a completion reaches every request held at the moment
it runs, never one held after it. Completing one chosen held request while
another stays held is not offered; a test that needs two requests answered
separately holds them one at a time.

**Acceptance.** With one client connected, pushing `{"half":` returns 1 and the client
reads exactly those bytes. Pushing `1}\n` then also returns 1, and the
client has then read exactly `{"half":1}\n` in all. With a hold on
`/status ` and the held client the only one connected, a GET is recorded and
one is held. A push then returns 0, and the fake's bytes-pushed report for
the held client still reads 0; the push's return value, which the fake
computes before it returns, is the barrier. Completing returns 1, and the
held client then receives the completion reply. A second GET of `/status `,
sent after that without re-arming the hold, is answered by the handler: its
client receives the reply (the barrier), and at that point the held count
reads 0. Arming the hold again and sending a third GET makes the held count
read 1 once the fake has recorded it. With that GET still held, arming the
hold again and sending a fourth GET of `/status ` makes the held count read
2 once the fake has recorded it. With one GET held, arming the hold again and
completing returns 1 (the barrier); a fifth GET sent after that is held when
the fake records it (held count 1), and its client has received nothing
after the read barrier.

**Sources.** `plugin/lib/testing/fakesocketserver.h:56-84`,
`plugin/lib/testing/fakesocketserver.cpp:74-116`,
`plugin/lib/testing/fakesocketserver.cpp:163-177`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:186-201`. The backend
tests use the hold at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:540-541`,
`:1117-1120` and `:1140`; their checks of it are harness preconditions, not
this requirement's tests.

### R-FAKE-03 · fix · The fake drops one chosen client

**Statement.** The fake closes one chosen client on demand, such as a held
request or the watch. It keeps listening and serving the others. A test can
then stage "tailscaled went away with one request in flight" without losing
the read side. Closing a held PATCH sets `writeError`, keeps `writable` true,
and leaves `state` and the watch alone.

**Defect.** "`FakeSocketServer` cannot close a single client on demand
(`AfterReply` is per-fixture), so 'tailscaled went away with one request in
flight' can only be staged by destroying the whole server, which takes the
read side with it."

**Acceptance.** With a held GET of `/status` and an established watch, closing
only the held client yields one failure for `/status`. A later pushed line
still yields an event, and a new GET is answered. After that reply and the
read barrier, the watch has emitted no failure and no "ended", and exactly
one failure was reported in all. With a held PATCH on a backend that is
`Running`, closing it sets `writeError`. After `writeErrorChanged` has fired,
the read barrier and the client barrier at 1 (the watch), `writable` is
true, `state` is `Running` and unchanged since the close, `stateChanged` has
fired 0 times since the close, and the retry hook reads 0 retries armed
since the close.

**Sources.** `pr286-body:127-129`,
`plugin/lib/testing/fakesocketserver.h:29`,
`plugin/lib/testing/fakesocketserver.h:54`,
`plugin/lib/testing/fakesocketserver.cpp:95-106`.

### R-FAKE-04 · withdrawn · Tests read node ids and addresses out of the capture they serve

Withdrawn: it described how tests stage their data, not behaviour of the
product or the fake. Its checks that fixture ids and addresses are non-empty
and distinct
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:344`,
`:505`, `:506`, `:874`, `:1392`, `:1393`, `:1394`, `:1438` and `:1439`) are
harness preconditions, listed in the traceability file. Its rule that a test
never names a peer by literal conflicted with requirements whose acceptance
pins literal ids from the committed captures (R-PARSE-06, R-PARSE-08,
R-PARSE-11, R-UI-10, R-QML-17). Those literals stand: the captures are
committed and redacted (R-SEC-05), so a literal from one is as stable as the
capture itself.

### R-FAKE-05 · parity · The fake says whether it bound its socket

**Statement.** The fake reports whether it is listening, and a reason when it
is not. It refuses to bind over anything already at the path, a live socket
included, and creates the parent directory when it is missing. A destroyed
fake frees its path for the next one.

**Acceptance.** A fake on a fresh path under the test's private directory
reports listening. After it is destroyed, a new fake on the same path reports
listening. A fake on a path already taken reports not listening, with a reason
containing `already exists`, and leaves what is there in place. The path can be
taken by a live fake, which still accepts connections afterwards, by a file,
or by a dangling symlink.

**Sources.** `plugin/lib/testing/fakesocketserver.h:34-35`,
`plugin/lib/testing/fakesocketserver.cpp:32-50`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:236-269`. The backend
tests' own `isListening()` checks
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:908`,
`:919`, `:1332` and `:1364`) are harness preconditions, not this
requirement's tests.

### R-FAKE-06 · parity · The fake's behaviour from before #286

**Statement.** The Tailscale acceptances also rely on behaviour the fake had
before #286. The Rust port keeps all of it:

- It listens at the given path for this user only, with no group or other
  access, and creates missing parent directories.
- It reports, rather than throws, a directory it cannot create and a path
  too long to listen on.
- By default it replies and then closes the client. With keep-open, the
  client stays connected across requests.
- With a delimiter, requests are framed however the reads split them. Bytes
  without a delimiter are not a request yet.
- After a close-after-reply reply, a second request in the same read is
  neither answered nor recorded.
- Without a handler, a request is recorded and the client stays connected,
  unanswered.
- A pushed line reaches every connected client, and a push with no client
  returns 0.
- Destroying the fake disconnects every client and removes the socket file.

**Acceptance.** Each `plugin/lib/testing/tests/tst_fakesocketserver.cpp` test listed for R-FAKE-06 in
the traceability tables is ported as one acceptance test with the same
assertions, using barriers instead of waits. Phase 2b of the rewrite plan
ports these tests; the plan is committed on branch `docs/tailscale-rust-plan`
of the main repository
(`docs/superpowers/plans/2026-10-19-tailscale-rust-rewrite.md` on that
branch), not in the #286 checkout and not on `main`, so it is context and not
a source.
The other fakes in the testing kit (the fake service, the private bus and the
fake program) are outside this document. Their own suites trace them.

**Sources.** `plugin/lib/testing/fakesocketserver.h:17-35`,
`plugin/lib/testing/fakesocketserver.cpp:32-88`,
`plugin/lib/testing/fakesocketserver.cpp:118-177`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:44-121`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:150-184`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:203-234`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:271-285`.

### R-FAKE-07 · kit · The fake reports what the barriers read

**Statement.** The fake barrier, the read barrier, the client barrier and
R-WATCH-06's count rest on reports from the fake, so the fake's reports are
a requirement too. Per client, in accept order, it reports the bytes it has
consumed from that client (received, whether or not they form a request
yet) and the bytes it has written to that client (by a handler reply, a
completion or a push). It reports the connected-client count, which drops by
one when a client disconnects, and the total number of clients accepted
since it was created, which never drops. #286's fake reports only the
connected-client count (`plugin/lib/testing/fakesocketserver.h:88`); the
byte reports and the accepted total are added for the barriers that replace
`qWait` (decision 12).

**Acceptance.** With keep-open and a handler that replies `ok`, client 1
connects and writes `GET /q HTTP/1.1\r\n\r\n` (19 bytes). Once client 1
has received `ok` (the barrier), the fake reports exactly 19 bytes received
and exactly 2 written for client 1, connected count 1 and accepted total 1.
A push of the line `abc` returns 1; once client 1 has read `abc\n`, the
written report for client 1 reads exactly 6. Client 1 then writes `GET /`
(5 bytes, no delimiter): once the received report for client 1 reads 24, no
further request has been recorded. Client 2 connects and writes the same
GET; once it has received `ok`, the connected count is 2, the accepted
total is 2, and client 2's reports read 19 received and 2 written. Client 1
disconnects; once the fake has handled that disconnect (its disconnect
event, the barrier), the connected count is exactly 1 and the accepted
total is still exactly 2.

**Sources.** `plugin/lib/testing/fakesocketserver.h:86-88` (the request log
and the client count), "How to read" (barriers), decision 12.

## Contract additions

R-UI-02 and R-UI-13 check the contract surface against the #286 set plus the
members listed here, all decided on 2026-10-21. Each is added to the contract
and to the QML stand-in (R-QML-30, checked by R-QML-24's comparison) in the
same change.

| Member | Kind | Added by | Name and type |
|---|---|---|---|
| Login URL carrier | property | R-UI-17, decision 1 | `loginUrl`: string, read-only, notify `loginUrlChanged` |
| Login action | invokable | R-UI-17, decision 1 | `login()` |
| Advertise-exit-node read-back | property | R-WRITE-10, decision 2 | `advertisingExitNode`: bool, read-only, notify `advertisingExitNodeChanged` |
| Advertise-exit-node action | invokable | R-WRITE-10, decision 2 | `setAdvertiseExitNode(bool)` |
| Awaiting admin approval | property | R-WRITE-10, decision 2 | `exitNodeAwaitingApproval`: bool, read-only, notify `exitNodeAwaitingApprovalChanged` |
| IP-forwarding check | property | R-WRITE-10, decision 2 | `ipForwardingWarning`: string, read-only, notify `ipForwardingWarningChanged` |
| Peers-known flag | property of `Tailscale` | R-GROUP-11, decision 6 | `peersKnown`: bool, read-only, notify `peersKnownChanged` |
| Error body field | — | decision 3 | does not exist: the body's text is appended to `readError`/`writeError` (R-HTTP-09) |
| Unapplied-write property | — | R-WRITE-08, decision 5 | does not exist: `writeError` carries `<setting> was not applied` |
| Retry curve, barriers, socket-path resolution | — | decision 12 | not on the contract: test hooks on the core crate |
| tailscaled's `ErrMessage` | — | decision 18 | not added: follow-up issue #299, outside epic #287 |

So the singleton has 29 properties (24 + 5) and 7 invokables (5 + 2).

One plugin type sits beside the singleton, not on it: `PeerFilter`
(R-QML-15, decision 8), a creatable type in module `C7` with `source`,
`query` and a read-only `count`. It does not change R-UI-02 or R-UI-13, and
R-QML-24's check covers it against its own stand-in.

## Decisions (2026-10-21)

The 27 questions of Phase 1 were put to the owner, who accepted every
recommendation, with the scope rulings on questions 8, 9 and 18 noted below.
Each decision names the requirements it settles; those requirements now
state the decided behaviour, and a decision that changes #286's behaviour
made its requirement `fix` (or `new`, or `follow-up` for question 9).
A tag in parentheses after a requirement ID is that requirement's heading
tag, never a different label.

1. **In-panel login.** A read-only `loginUrl` property, filled from the bus's
   `BrowseToURL` notification, plus a `login()` action that POSTs
   `/localapi/v0/login-interactive`; QML opens the URL with
   `Qt.openUrlExternally` through a harness stand-in, and `NeedsMachineAuth`
   is shown as text only. — R-UI-17, R-HTTP-14 (new), R-HTTP-02, R-WATCH-08,
   R-WRITE-04, R-WRITE-05, R-UI-02 and R-UI-13 (fix: the exact sets grow),
   R-UI-18, R-UI-19 and R-QML-30 (fix: the added members' fresh values, fake
   and stand-in), R-CONN-02 (parity: hands `loginUrl` to R-UI-17).
2. **Advertise exit node.** Option (c): an opt-in bootstrap step enables IP
   forwarding, and a runtime check (tailscaled's
   `/localapi/v0/check-ip-forwarding`) is reported on the panel as
   `ipForwardingWarning`. Writes keep subnet routes by rewriting
   `AdvertiseRoutes` from the read prefs, adding or removing only
   `0.0.0.0/0` and `::/0`; "awaiting approval" shows while this device's
   `AllowedIPs` lack `0.0.0.0/0`. Names, as the owner chose them:
   `advertisingExitNode` and `setAdvertiseExitNode(bool)`. The names
   `exitNodeAwaitingApproval` and `ipForwardingWarning` for the two further
   members the decision needs are this spec's concrete choices, not the
   owner's. — R-WRITE-10, R-BOOT-07 (new), R-WATCH-07, R-CONN-09,
   R-CONN-02 and R-CONN-06 (`ipForwardingWarning` follows each attempt's
   check), R-WRITE-05, R-UI-02 and R-UI-13 (fix: the exact sets grow),
   R-UI-18, R-UI-19 and R-QML-30 (fix);
   R-QML-29 is withdrawn, because the row it described now has an action.
3. **Error body format.** Take `error` from a `{"error":…}` body, otherwise
   the trimmed body text; cap it at 512 bytes and append it to the reason in
   `readError`/`writeError`. No separate field. — R-HTTP-09, R-UI-02.
4. **Liveness probe.** A `GET /localapi/v0/prefs` from the core crate every
   30 s, under the 10 s request deadline, so detection takes at most 40 s,
   inside the 60 s bound. A watch that stalls while tailscaled still answers
   requests is out of scope. — R-CONN-13, R-WATCH-07 (fix), R-CONN-01,
   R-WATCH-11.
5. **Unapplied-write feedback.** A whole pass runs after each accepted write
   (through the coalescing machinery). No dedicated property; `writeError`
   reads `<setting> was not applied`. The later outcome still wins, as in
   #286, and a stale `writeError` is reconciled when a snapshot shows the
   value applied. A 403's message is not stale while `writable` is false
   (it is why the panel is read-only), so it is cleared by a re-arm
   (decision 20) or the next write outcome, never by reconciliation. A 2xx
   that arrives while a reconnect is pending is confirmed by that
   reconnect's opening pass. — R-WRITE-08, R-WRITE-04 (fix), R-WRITE-06, R-WRITE-07,
   R-WATCH-07 (fix), R-WATCH-11, R-UI-02.
6. **Peers-known flag.** A property on `Tailscale` named `peersKnown`; the
   panel shows `Devices not known yet` while it is false. — R-GROUP-11,
   R-UI-02 (fix: the exact set grows), R-UI-18, R-UI-19 and R-QML-30 (fix),
   R-PARSE-07 (fix: the Peer section that sets it), R-QML-15 (fix: the
   `peersKnown` gating of the count); R-QML-13 (parity) leaves the
   empty-list message to R-GROUP-11.
7. **Read and write failure together.** The read error wins; the write error
   shows once the read error clears. — R-UI-16, R-QML-02, R-QML-20, R-QML-22.
8. **Device count source.** A filter/proxy model in the plugin with a match
   count (`PeerFilter`), kept in this epic; the QML change is limited to
   binding to that count. — R-QML-15, R-QML-30 (the `PeerFilter` stand-in);
   R-QML-13 (parity) leaves how the
   count is taken to R-QML-15.
9. **Scrollbar and shared search pill.** Moved out of this epic to
   follow-up issue #298, with the decided design: promote the Settings pill to
   the shared component, delete `Common/SearchField`, and use a themed
   `ScrollIndicator`. R-QML-16 keeps its ID, is marked `follow-up`, and has
   no gate in the rewrite. — R-QML-16.
10. **Sort order across languages.** An ASCII guarantee plus a defined Rust
    total order (full Unicode lowercase mapping, then scalar values), pinned
    by a non-ASCII fixture and recorded as a deliberate difference beyond
    ASCII. — R-GROUP-03, R-QML-15.
11. **Accepted ISO-8601 forms.** RFC 3339, which matches Go's output, with
    fractional seconds and `Z` or an offset, pinned by a real tailscaled
    capture. — R-PARSE-04.
12. **Exposing the retry curve.** A test hook on the core crate, not a Qt
    signal, so R-UI-02's property set stays #286's plus the contract
    additions; the idle and read barriers, the request order and the
    resolved socket path use the same kind of hook. — R-CONN-07, R-CONN-08,
    R-CONN-01, R-WATCH-07, R-FAKE-07 (the fake's reports the barriers read),
    R-UI-02, "How to read" (barriers and the clock hook).
13. **Property list for the stand-in check.** Introspect the built module's
    metaobject at test time. — R-QML-24.
14. **`readError` wording for an unparsable status.** A distinct string per
    cause: not JSON, not an object, no BackendState. — R-CONN-04 (fix),
    R-PARSE-01 (fix).
15. **Operator wait runs out.** A warning and a closing note telling the user
    to run the script again. — R-BOOT-03, R-BOOT-02.
16. **A `/prefs` that is not prefs.** Treated like R-CONN-04: a named
    `readError`, `NoState`, one retry, last values kept. Inside a prefs
    object a field of another type still reads as its default. — R-CONN-14,
    R-PARSE-14 (parity: the decision does not reach `/status` fields).
17. **Suggestion order.** An older pass never replaces a newer outcome
    (a generation check like R-WATCH-12). — R-PARSE-11.
18. **tailscaled's `ErrMessage`.** Keep dropping it, as #286 does (parity).
    Follow-up: issue #299, outside epic #287, decides whether
    and where tailscaled's `ErrMessage` is published (a new message property,
    with its own lifetime, since a snapshot must not clear it the way it
    clears `readError`). No member is added in this epic. — R-WATCH-09,
    R-UI-17.
19. **Clean watch end before any snapshot.** A diagnosis in `readError` and a
    retry: a present daemon is not "no Tailscale". — R-CONN-15, R-QML-01.
20. **How `writable` recovers.** Re-arm on reconnect and when `OperatorUser`
    changes; the next write confirms it. — R-WRITE-11 (fix), R-QML-20,
    R-WRITE-06, R-WRITE-07 (fix).
21. **Header and watch-line size caps.** 64 KiB for response headers and
    16 MiB per watch line, each overflow a named failure; for the watch, a
    lost connection with `readError`. The 1 024-byte cap on a chunk-size
    line (R-WATCH-15) is this spec's concrete choice to implement the
    decision, not a value the owner set. — R-HTTP-15 (fix), R-WATCH-15 (fix),
    R-CONN-03.
22. **Exit node without an ID.** Never join on an empty id. — R-PARSE-09.
23. **Unrecognised BackendState.** A `readError` naming the value, the slot
    dimmed (R-QML-02 path), no retry, re-evaluated on the next notification.
    — R-WATCH-13, R-UI-04, R-QML-01, R-CONN-05, R-CONN-15, R-PARSE-14
    (parity: a `BackendState` of another type reads as empty, which is the
    no-BackendState rule, not this decision).
24. **The watch after a read loss.** Stop the watch on any read loss, so a
    reconnect always restarts watch-then-read. — R-CONN-06, R-CONN-03,
    R-CONN-08 (fix), R-CONN-04, R-WATCH-12, R-WRITE-08.
25. **Rows from an earlier session.** Rows are kept for a quick resume and
    replaced by the next `Running` status; the views hide the device and
    exit lists outside `Running`. "The next `Running` status" includes one
    with `"Peer": null`, tailscaled's shape for an empty tailnet, which
    clears the rows (R-PARSE-07). — R-GROUP-12, R-GROUP-10 (fix), R-PARSE-07;
    R-QML-09 (parity) covers the list in `Running` and leaves other states
    to R-GROUP-12.
26. **Unreadable operator prefs.** Fail safe: set the operator only when the
    output has the recognised shape and the key is absent; otherwise warn and
    leave it alone. No `jq`. — R-BOOT-08 (fix), R-BOOT-01.
27. **A Peer entry that is not an object.** Drop the entry. — R-PARSE-07.

## Defects fixed by the rewrite

Each entry quotes the defect as #286 states it, then gives the corrected
behaviour.

- **R-CONN-13.** "No liveness check. A watch that connects and then goes silent
  is indistinguishable from a healthy quiet bus" (`pr286-body:109-113`).
  Corrected: a `GET /localapi/v0/prefs` probe every 30 s detects a silent
  daemon within 40 s and publishes `NoState` with a `readError`. A quiet but
  healthy bus stays `Running`.
- **R-WRITE-08.** "An accepted write that tailscaled does not apply produces no
  feedback at all" (`pr286-body:114-115`). Corrected: each accepted write
  starts a confirmation pass, and a change that did not take sets
  `writeError` to `<setting> was not applied`.
- **R-GROUP-11.** "A `/status` carrying `BackendState` and no `Peer` key makes
  the panel state 'no other devices on this tailnet'" (`pr286-body:116-118`).
  Corrected: the panel makes that claim only once `peersKnown` is true, and
  shows `Devices not known yet` before.
- **R-HTTP-09.** "The HTTP error body is discarded where the contract promises
  'the words of whatever refused it'" (`pr286-body:119-120`). Corrected:
  `readError` and `writeError` carry the daemon's `error` text, or the
  trimmed body, capped at 512 bytes, after the status line.
- **R-QML-15.** "`deviceMatchCount` tallies instantiated delegates rather than
  matching rows" (`pr286-body:121-122`). Corrected: the count is the plugin's
  `PeerFilter` count over every matching row.
- **R-UI-16.** "`readError` and `writeError` can now both be non-empty at once,
  which draws two explanations on one panel" (`pr286-body:125-126`). Corrected:
  the read error wins, so exactly one Text on the panel carries either error.
- **R-FAKE-03.** "`FakeSocketServer` cannot close a single client on demand"
  (`pr286-body:127-129`). Corrected: the fake closes one chosen client while it
  keeps serving the rest.
- **R-WRITE-09.** "`tailscale down` is the one action here never exercised
  live" (`pr286-body:130-131`). Corrected: a fake-daemon test covers disconnect
  and reconnect end to end.

Not fixed in this epic:

- **R-QML-16** (`follow-up`). "Neither list has a scrollbar;
  `quickshell/c7shell/Common/SearchField.qml` duplicates the Settings sidebar pill"
  (`pr286-body:123-124`). Moved to follow-up issue #298 by decision 9.

Changed by an owner decision (2026-10-21), where #286 named no defect:
R-HTTP-15 and R-WATCH-15 (decision 21), R-PARSE-04 (11), R-PARSE-07 (27,
and 6 and 25: `"Peer": null` under `Running` is an empty Peer section),
R-PARSE-09 (22), R-PARSE-11 (17), R-GROUP-03 (10), R-GROUP-10 and R-GROUP-12
(25),
R-WATCH-13 (23), R-CONN-03, R-CONN-06 and R-CONN-08 (24), R-CONN-04 (14
and 24), R-PARSE-01 (14), R-CONN-14
(16), R-CONN-15 (19), R-WRITE-11 (20), R-WRITE-07 (20), R-WRITE-04 (5),
R-WATCH-07 (4 and 5), R-BOOT-03 (15), R-BOOT-08 (26),
R-UI-02 (decisions 1, 2 and 6: 29 properties, where #286's
`plugin/tests/tst_module.cpp:152` pins 24) and R-UI-13 (decisions 1 and 2:
7 invokables, where `plugin/tests/tst_module.cpp:171` pins 5), R-UI-18 and
R-UI-19 (decisions 1, 2 and 6: the added members' fresh values, rules and
fake setters) and R-QML-30 (decisions 1, 2, 6 and 8: the stand-in's added
members and the `PeerFilter` and URL-opener stand-ins). R-QML-29 is
withdrawn by decision 2.
New behaviour #286 left out: R-UI-17 and R-HTTP-14 (decision 1), R-WRITE-10
and R-BOOT-07 (decision 2). Test-kit infrastructure (tag `kit`): R-FAKE-07
(the fake's reports that the barriers read, decision 12).
