# Tailscale backend: requirements for the Rust rewrite

**Status:** draft for #289 (Phase 1 of epic #287).

**Source pin:** branch `feat/tailscale-backend` (PR #286) at commit `a38dbca`.
Every requirement comes from that branch, its PR description and its PR
comments. None comes from memory.

**Plan:** `docs/superpowers/plans/2026-10-19-tailscale-rust-rewrite.md`, Phase 1.
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
  - `fix`: #286 names this as a defect. The statement gives the corrected
    behaviour. The source names the defect. A #286 assertion that pins the
    defect itself (it holds on `a38dbca` only because of the defect) maps to
    the fix requirement. That requirement's acceptance names the corrected
    value at the same observable, and its test fails on `a38dbca` for that
    reason. Every other #286 assertion maps to a requirement whose acceptance
    covers it in the state #286 asserts it.
  - `new`: #286 deliberately left this out. The statement gives the
    user-visible goal. The design is an open question.
- **Statement.** Observable behaviour only: bytes on the wire, QML-visible
  properties, signals and invokables, model rows and model signals, process
  exit codes and file contents. It names no internal class or method, except
  the public contract surface (`Tailscale` and its members).
- **Acceptance.** A test that needs no sleep and no host state. It uses a fake
  tailscaled on a Unix socket under the test's private directory, and paused or
  fake time.
- **Sources.** `file:line` in the #286 checkout, relative to the repository
  root. `pr286-body:N` is line N of the PR #286 description. `pr286-comments:N`
  is line N of its review comments. Both are line-numbered as captured for
  Phase 1.

Terms used throughout:

- **Fake tailscaled.** A test server on a Unix socket. It records request
  bytes, replies from scripted data, pushes watch lines and can hold a request
  unanswered.
- **Pass.** One refresh: `GET /localapi/v0/status`, `GET /localapi/v0/prefs` and
  `GET /localapi/v0/suggest-exit-node`.
- **Snapshot.** What one pass publishes: the status and prefs replies, applied
  together.
- **Live.** The contract's `state` is not `NoState`.
- **Barrier.** A positive event that proves the exchange under test has been
  consumed. It replaces #286's `qWait` and any "drain the events" that has no
  end condition. One of:
  - **client barrier:** the fake's connected-client count returns to its
    expected value, usually 1, the watch alone. Every read and write closes
    its own connection (R-HTTP-11), so this proves its outcome was consumed;
  - **retry barrier:** a reconnect has been armed (R-CONN-07's test hook).
    It follows the stored diagnosis, so it proves a loss was fully handled;
  - **idle barrier:** the backend reports to its test that no pass is in
    flight and no notification is waiting to start one, and the client
    barrier holds. The rewrite exposes this to tests like the retry hook
    (open question 12);
  - **fake barrier:** the fake has consumed every byte a client wrote. The
    fake reports bytes received per client. It runs from client to fake only:
    it proves nothing about bytes the fake pushed;
  - **read barrier:** the client side has consumed every byte the fake pushed
    to it, and holds no outcome or event it has not yet delivered. The fake
    reports bytes pushed per client. The transport reports to its test, per
    connection, the bytes it has consumed, and whether an outcome or event is
    waiting to be delivered. The barrier holds when every connection's
    consumed count equals the fake's pushed count for that client and nothing
    is waiting. An exchange whose connect has been scheduled but has not yet
    run counts as waiting, so the barrier cannot hold before a deferred
    connect has run or been cancelled. With no connection left, as after a
    stop, it holds once nothing is waiting. The rewrite exposes this to tests like the idle
    barrier (open question 12). The idle barrier includes the read barrier on
    the watch.

  Every negative ("nothing changed", "no request", "fired exactly N times")
  is measured after a named barrier. A count is stated as an exact value at
  that point.
- **Setup is not acceptance.** A step that only makes the test's own staging
  true (the fake bound its socket, a client connected, the fake recorded the
  watch before a push, the fixture holds the expected entry) is a
  precondition of the test, not a clause of the criterion. The traceability
  file lists every such #286 assertion in its "Harness preconditions" table.
- **An accepted write is applied unless stated.** Unless a criterion says
  otherwise, a fake that answers a PATCH 2xx has applied it: its later
  `/prefs` reads hold the requested value, and the 2xx body is the resulting
  prefs. Such a write counts as applied under every design in open question
  5, so R-WRITE-08 leaves `writeError` empty. Criteria that stage a 2xx the
  daemon did not apply (R-WRITE-04, R-WRITE-08) say so.
- **Two halves.** An acceptance that names both a fake tailscaled and `ts-`
  elements or `Theme` colours runs as two tests. The backend half drives the
  contract from the fake and asserts contract values. The view half sets those
  same values on the QML stand-in (R-QML-25) and asserts the `ts-` elements and
  the recorded actions. Both halves together are the criterion. No harness
  loads the real module in `qml6` against a fake socket.

## R-HTTP: LocalAPI transport

### R-HTTP-01 · parity · Request line and Host header

**Statement.** Every request is HTTP/1.1 over the Unix socket. It starts with
`<METHOD> <path> HTTP/1.1` and carries `Host: local-tailscaled.sock`. tailscaled
rejects any other Host. A request without a body carries no other header.

**Acceptance.** Given a fake tailscaled that frames requests on CRLFCRLF, when
the client GETs `/localapi/v0/status`, then the fake records exactly
`GET /localapi/v0/status HTTP/1.1\r\nHost: local-tailscaled.sock` and nothing
else before CRLFCRLF. A fake that answers `200` with `{}` gets exactly one
reply back, so tailscaled would accept that request.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:152-160`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:84-99`, `pr286-body:35-36`.

### R-HTTP-02 · parity · A PATCH carries a JSON body under its own length

**Statement.** A write is `PATCH <path>` with the Host header,
`Content-Type: application/json` and `Content-Length` equal to the body's byte
length. The body bytes follow verbatim. A PATCH ends in the same reply or
failure outcomes as a read.

**Acceptance.** Given a fake that answers `200` with `Content-Length: 2` and `{}`,
when the client PATCHes `/localapi/v0/prefs` with
`{"RouteAllSet":true,"RouteAll":true}`, then the recorded request starts with
`PATCH /localapi/v0/prefs HTTP/1.1\r\n`. It contains the Host header and
`Content-Length: 36`, and ends with CRLFCRLF plus the exact body. Exactly one
reply arrives, with body `{}`.

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
GETs a path, then exactly one reply arrives. Its body equals the 11 bytes
`{"ok":true}`, compared exactly. No failure is reported.

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
`6\r\n{"a":1\r\n`, `7\r\n,"b":2}\r\n` and `0\r\n\r\n`, the reply body is exactly
`{"a":1,"b":2}`, and no failure is reported for that exchange. On a chunked
watch, pushing `1` alone and then the read barrier yields no event and no
failure. Pushing `1\r\n{"chunk":"size"}\n\r\n` then yields exactly one event, whose
bytes are exactly `{"chunk":"size"}`. Pushing
`4\r\n{"ha\r\n` and then the read barrier yields no event. Pushing
`7\r\nlf":1}\n\r\n` then yields exactly one event `{"half":1}`. A size line
`a;ext=1` reads as 10 bytes.

Split headers, on a watch the fake has recorded and not answered: pushing
`HTTP/1.1 200 OK\r\nTransfer-Enc` and then the read barrier yields no started
and no failure. Pushing `oding: chunked\r\n\r` and the read barrier still
yields no started. Pushing `\n` yields exactly one started. Then
`8\r\n{"a":1}\n\r\n` yields exactly one event `{"a":1}`. A GET whose
`Content-Length: 11` header line arrives split over two pushes, followed by
`{"ok":true}`, yields exactly one reply with that 11-byte body. A GET framed by
`content-length: 11`, and a watch framed by `TRANSFER-ENCODING: Chunked`,
behave exactly as their canonical spellings do. Setup, not acceptance: each watch case waits
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
failure reasons contain `/localapi/v0/status`.

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
by `{}` and a close, a GET yields exactly one reply `{}` and no failure.

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
its zero chunk behaves the same.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:333-363`,
`plugin/lib/tailscale/LocalApiClient.cpp:365-385`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:52-82`.

### R-HTTP-08 · parity · A non-2xx status fails with its status code

**Statement.** Any status outside 200-299 ends the exchange in failure, never
in a reply. So does a status line that is not `HTTP/x NNN`. The failure carries
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
`Content-Length: 2` and `{}`, give the same result.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:112-134`,
`plugin/lib/tailscale/LocalApiClient.cpp:46-64`,
`plugin/lib/tailscale/LocalApiClient.cpp:221-230`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:396-400`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:141-160`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:210-225`.

### R-HTTP-09 · fix · An error reply keeps the daemon's own words

**Statement.** tailscaled may answer a non-2xx status with a body. The failure
reason then carries that body as plain text, bounded in length, next to the
status line. `writeError` and `readError` therefore publish the words of
whatever refused the request. The failure still yields no reply. The status
code from accepted headers always survives an error body that is cut short,
stalls past the deadline or ends mid-chunk. The failure then carries that
status, with whatever body arrived, and never becomes a status-0 failure. A
403 therefore always revokes `writable` (R-WRITE-06).

**Defect.** "The HTTP error body is discarded where the contract promises 'the
words of whatever refused it'; only the status line survives."

**Acceptance.** Given a fake that answers a PATCH of `/localapi/v0/prefs` with
`HTTP/1.1 403 Forbidden` and the body `prefs write access denied`, then
`writeError` contains `403` and `prefs write access denied`. The same holds for
a chunked error body. Given a GET of `/status` answered 500 with
`{"error":"boom"}`, `readError` contains `500` and `boom`. No reply is
delivered in either case.

Bounds and incomplete bodies, each with paused time and a 50 ms deadline:

- An error body of 65 536 bytes yields exactly one failure whose reason
  contains the body's first 64 bytes and is shorter than the body itself.
  This holds for any cap, so it is executable now. When open question 3 pins
  the cap N, the clause tightens to: the reason is no longer than N bytes
  plus the path and the status line.
- A PATCH answered `403` with `Content-Length: 100`, 20 body bytes and a
  close yields exactly one failure with status 403. `writable` becomes false.
- The same 403 with its body stalled past the deadline yields exactly one
  failure with status 403 that carries the 20 bytes.
- A chunked 403 cut before its zero chunk yields exactly one failure with
  status 403.

**Sources.** `pr286-body:119-120`,
`plugin/src/contracts/TailscaleBackend.h:303-304` (the promise to publish "the
words of whatever refused it"),
`plugin/src/contracts/TailscaleBackend.h:305-311`,
`plugin/src/contracts/TailscaleBackend.h:250-252` (only the measured 403 body
`prefs write access denied` that the acceptance replays),
`plugin/lib/tailscale/LocalApiClient.cpp:221-230`.

### R-HTTP-10 · parity · An absent socket is told apart from an unreadable daemon

**Statement.** A connect that fails because nothing exists at the socket path
is a failure flagged socket-absent. Every other transport error is a failure
with that flag false. Refused, permission denied and reset are examples.
Neither case hangs.

**Acceptance.** Given a socket path with nothing at it, a GET yields exactly one
failure, delivered asynchronously, with status 0 and socket-absent true. Given
a path that exists but refuses connections, the flag is false.

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
and a watch yield one reply. The held exchange and the watch stay open. Right
after any call returns, before the event loop runs, no outcome has been
delivered. This holds for a socket path with nothing at it too. Against the
backend, once a pass has been answered, the fake's connected-client count is
exactly 1: every read has closed its own connection and only the watch stays.

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
less disables it. The reason names the deadline in ms. The deadline starts
before the connect and covers connect, headers and body.

**Acceptance.** With paused time and a 50 ms deadline, a fake that records
`GET /localapi/v0/status` and never answers yields nothing after 49 ms. After
50 ms it yields one failure for that path, containing `50 ms`, and no reply. A
fake that sends `Content-Length: 99` and 9 bytes, then stalls, also yields one
failure and no reply after 50 ms. A PATCH of `/localapi/v0/prefs` that the
fake records and never answers likewise yields nothing after 49 ms and, after
50 ms, one failure for that path containing `50 ms`, with status 0 and no
reply.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:34-49`,
`plugin/lib/tailscale/LocalApiClient.h:60-69`,
`plugin/lib/tailscale/LocalApiClient.cpp:135-150`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:440-483`.

## R-PARSE: status parsing

### R-PARSE-01 · parity · Only a JSON object is a status

**Statement.** A `/status` body that is not valid JSON, is empty, or is not a
JSON object yields no status. It never crashes and never yields a partial
status. Any JSON object parses, and each missing key leaves its field empty.
`{}` yields an empty backend state.

**Acceptance.** The bodies `{"Self":`, the empty string and `[]` each yield no
status. `{}` yields a status with an empty backend state, no peers and no exit
node. No input ends the process.

**Sources.** `plugin/lib/tailscale/StatusParser.h:13-16`,
`plugin/lib/tailscale/StatusParser.cpp:99-104`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:158-162`.

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

### R-PARSE-04 · parity · Key expiry is an ISO-8601 instant; absent means never

**Statement.** `keyExpiry` is `Self.KeyExpiry` read as an ISO-8601 UTC instant.
An absent or unparsable value means the key never expires. The contract then
reads an invalid date-time. A tagged node and a node with expiry disabled both
look like this.

**Acceptance.** `status-idle.json` yields `2027-04-11T09:06:08Z`. A Self without
`KeyExpiry` yields an invalid `keyExpiry`, and QML sees an invalid Date.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:117-118`,
`plugin/lib/tailscale/Types.h:67`,
`plugin/lib/tailscale/tests/fixtures/status-idle.json:116`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:107-133`,
`plugin/src/contracts/TailscaleBackend.h:125-127`.

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

### R-PARSE-07 · parity · A present Peer section differs from an absent one

**Statement.** The status records whether the reply carried a `Peer` object.
An empty object means a tailnet with no other devices. An absent key or null
means the reply did not describe the tailnet. Both yield an empty peer list.

**Acceptance.** `status-idle.json` has a Peer section.
`{"BackendState":"Running"}` and `{"BackendState":"Running","Peer":null}` have
none, and each yields an empty peer list. `{"BackendState":"Running","Peer":{}}`
has one, with no peers. A `Peer` of another JSON type is no Peer section:
`{"BackendState":"Running","Peer":[]}`, `"Peer":"x"` and `"Peer":5` each have
none and yield an empty peer list. A Peer entry that is not an object still
yields a row: `{"BackendState":"Running","Peer":{"k":5}}` has a Peer section
and exactly one peer whose `nodeId`, `hostName`, `dnsName` and `displayName`
are empty, with no addresses, `online` false and `exitNodeOption` false. Open
question 27 asks whether the rewrite drops such an entry instead.

**Sources.** `plugin/lib/tailscale/Types.h:72-77`,
`plugin/lib/tailscale/StatusParser.cpp:126-131`,
`plugin/lib/tailscale/StatusParser.cpp:132-150`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:135-156`.

### R-PARSE-08 · parity · The exit node comes from ExitNodeStatus

**Statement.** An exit node is reported only when `ExitNodeStatus` is an
object. Its id is `ExitNodeStatus.ID`. Its online flag is
`ExitNodeStatus.Online`, never the peer's own `Online`. Its IPv4 is the first
IPv4 of `ExitNodeStatus.TailscaleIPs`, with the mask removed.

**Acceptance.** `status-exitnode.json` yields id `nEwJFIats021CNTRL`, online true
and ip4 `100.124.183.145`. `status-exitnode-offline.json` yields online false,
although the peer reads `Online`. `status-idle.json` and `"ExitNodeStatus":null`
yield no exit node.

**Sources.** `plugin/lib/tailscale/Types.h:37-47`,
`plugin/lib/tailscale/StatusParser.cpp:155-166`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode.json:118`,
`plugin/lib/tailscale/tests/fixtures/status-exitnode-offline.json:118-124`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:229-235`, `pr286-body:39-40`.

### R-PARSE-09 · parity · The exit node is named through its peer, else by its id

**Statement.** `ExitNodeStatus` carries no name. The exit node's name is the
display name of the peer whose `nodeId` equals the exit node's id. When no such
peer is listed, the name is the id itself, never empty while the id is
non-empty. An `ExitNodeStatus` object with no `ID` (or an empty one) yields
an empty id. With no peer whose `nodeId` is empty, its name is then empty
too. Whether such an id may be joined to a peer listed with an empty `nodeId`
(R-PARSE-06), as #286 does, is open question 22; no criterion pins that join.

**Acceptance.** `status-exitnode.json` names the exit node `pentest-exit-node`.
Pointing `ExitNodeStatus` at peer `ip-172-31-0-10` names it `host-5`. Removing
the exit peer names it by its id. `{"BackendState":"Running","ExitNodeStatus":
{"Online":true}}` yields an exit node with an empty id and an empty name.
Through the contract, `exitNodeName` reads the same strings.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:159-175`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:54-88`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:229-269`, `pr286-body:39-40`.

### R-PARSE-10 · parity · Mask stripping

**Statement.** Removing a CIDR mask returns the text before the first `/`. An
address without `/` is returned unchanged. IPv4 and IPv6 behave alike.

**Acceptance.** `100.101.102.103/32` gives `100.101.102.103`.
`fd7a:115c:a1e0::aaaa:bbbb/128` gives `fd7a:115c:a1e0::aaaa:bbbb`.
`100.101.102.103` is unchanged.

**Sources.** `plugin/lib/tailscale/Types.h:44-47`,
`plugin/lib/tailscale/StatusParser.cpp:93-97`,
`plugin/lib/tailscale/tests/tst_statusparser.cpp:271-277`.

### R-PARSE-11 · parity · The recommended exit node is the suggestion's ID

**Statement.** `recommendedExitNodeId` is the `ID` field of the latest
`/suggest-exit-node` reply, not its `Name`. It matches a `nodeId` in
`exitNodes`. A failed or empty reply clears it. `recommendedExitNodeIdChanged`
fires only when the value changes. "Latest" means the last outcome to arrive,
not the last one asked for. Suggestion outcomes are not tied to a pass, so a
late outcome from an earlier pass, a failure included, overwrites a newer one.
Open question 17 asks whether the rewrite keeps that.

**Acceptance.** Given `suggest-exit-node.json`, `recommendedExitNodeId` is
`nEwJFIats021CNTRL` and its signal fired once. When the fake then answers 500
and a notification arrives, after the idle barrier it is empty, `state` is
`Running` and no retry has been scheduled. Arrival order: the fake holds pass N's
`/suggest-exit-node`. A notification starts pass N+1, whose suggestion is
answered with id X, and `recommendedExitNodeId` reads X. The held request is
then completed with a 500. After the client barrier, `recommendedExitNodeId`
is empty.

**Sources.** `plugin/lib/tailscale/tests/fixtures/suggest-exit-node.json:1`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:340-352`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:677-694`,
`plugin/src/contracts/TailscaleBackend.h:75-76`,
`plugin/src/contracts/TailscaleBackend.h:175-180`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:625-652`.

### R-PARSE-12 · parity · One health warning is suppressed

**Statement.** `issues` is the status's health list minus any message
containing `advertising routes but --accept-routes is false`. Every other
message is published verbatim.

**Acceptance.** A fake serving `status-idle.json`, whose only health entry is
that warning, brings the backend to `Running` with empty `issues` and
`issueCount` 0. That warning plus `DNS is not working`
yields `issues` equal to `["DNS is not working"]`. The suppression policy is not
empty: the first case proves it through `issues`, which is the observable form
of #286's direct check on its internal list
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:762`). The rewrite need not expose the list
itself.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:67-79`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:219-242`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:631`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:738-763`.

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

### R-GROUP-03 · parity · One total order for the device list

**Statement.** Peers sort by group, then online before offline, then display
name case-insensitively, then host name case-insensitively, then `nodeId`. The
JSON member order carries no meaning.

**Acceptance.** `status-idle.json` puts a group-0 row first, and the last
group-0 row is offline. Two online peers with the same name, `nAAA1CNTRL` and
`nBBB1CNTRL`, sort `nAAA1CNTRL` first. Hand-built peers in any input order come
out in the defined order. The set includes names equal except for case, empty
names, and peers equal except for `nodeId`.

**Sources.** `plugin/lib/tailscale/Types.h:49-55`,
`plugin/lib/tailscale/StatusParser.cpp:70-91`,
`plugin/lib/tailscale/StatusParser.cpp:151-153`,
`plugin/lib/tailscale/PeerModel.h:46-48`,
`plugin/lib/tailscale/PeerModel.cpp:94-97`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:99-105`,
`plugin/lib/tailscale/tests/tst_peermodel.cpp:120-125`.

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

**Acceptance.** With rows nAAA and nBBB both online, nAAA going offline keeps 2
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

**Acceptance.** Setting the same three peers again emits 0 `dataChanged`.
Setting an empty list leaves 0 rows, one `rowsRemoved` and no reset. Changing
one row's ownerName emits one `dataChanged` for that row only. With rows
`nAAA1CNTRL` and `nBBB1CNTRL` online, `nAAA1CNTRL` going offline emits at least
one `dataChanged`, keeps 2 rows and emits no reset.

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

**Acceptance.** Over two peers with empty ids, alpha and bravo, setting alpha
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

**Acceptance.** Given a fake serving `status-idle.json`, the backend reaches
`Running` and `exitNodes` has 2 rows,
each with exitNodeOption true. It is a different object from `peers`. Its rows
equal the `peers` rows filtered on exitNodeOption, in the same order.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:166-173`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:665-671`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:865-876`.

### R-GROUP-10 · parity · Rows change only from a status that describes the tailnet

**Statement.** `peers` and `exitNodes` change only from a `/status` that has a
Peer section. A status without one leaves both models as they were. An empty
Peer object clears them.

**Acceptance.** With 20 peers shown, a notification that brings a status
without a `Peer` key makes the fake record a second GET of `/status`. After the
idle barrier, 20 rows remain, with no `rowsRemoved`, and `state`
`Running`. A later status with `"Peer":{}` leaves 0 rows in both models.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:655-671`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:654-699`,
the second read at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:677`.

### R-GROUP-11 · fix · "No other devices" needs a reply that described the peers

**Statement.** The panel claims "no other devices on this tailnet" only after a
`/status` reply carried a Peer section that was empty. Until any reply has
described the peer set, the peer set is unknown. The panel then makes no claim
about the device count. The contract carries "the peer set is known" to QML
through one boolean member, listed under "Contract additions": a property of
`Tailscale` or of the `peers` model. It is false until a `/status` reply
carries a Peer section and true from then on. A later status without a Peer
section leaves it as it was, like the rows (R-GROUP-10).

**Defect.** "A `/status` carrying `BackendState` and no `Peer` key makes the
panel state 'no other devices on this tailnet' — a positive claim about a
tailnet from a reply that never described it." At `a38dbca` the backend keeps
earlier rows (R-GROUP-10). The claim still appears when no reply has ever
carried a Peer section, because the empty-row test is `peerList.count === 0`.

**Acceptance.** Open question 6 pins only the member's name and where it
lives, and what the panel shows while the set is unknown. Every clause below
names an observable that any answer produces, so both halves are executable
now.

- **Backend half.** Given a fake whose first `/status` is
  `{"BackendState":"Running","Self":{...}}` with no `Peer` key, after the idle
  barrier `state` is `Running`, `peers` has 0 rows and the peers-known member
  reads false. The fake then serves the same status with `"Peer":{}` and
  pushes `{"Prefs":{}}`. After the idle barrier the member reads true and
  `peers` still has 0 rows. A third status without a `Peer` key, after a
  notification and the idle barrier, leaves it true.
- **View half.** On the QML stand-in (R-QML-25) with `state` `Running`, 0
  peers and the device list open: with the member false, `ts-peer-empty` and
  `ts-peer-no-match` are not visible, and `ts-devices-count` is not visible or
  does not read `0`. Setting the member true shows `ts-peer-empty`.

**Sources.** `pr286-body:116-118`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:659-671`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:729-741`,
`plugin/lib/tailscale/StatusParser.cpp:126-131`.

### R-GROUP-12 · parity · Rows from an earlier session survive a non-Running status without a Peer section

**Statement.** R-GROUP-10 holds in every state. A `/status` that reports
`NeedsLogin`, `NeedsMachineAuth` or `Stopped` with no Peer section, as
tailscaled sends once it has no netmap, leaves `peers` and `exitNodes` as an
earlier status described them. The panel gates the device list and the exit
sub-card on live alone, so it keeps showing those rows, with their last
online dots, and keeps offering those exit nodes. No error is shown. Open
question 25 asks whether the rewrite keeps this.

**Acceptance.** Two halves. Backend half: from `Running` with 20 peers and 2
exit nodes, a notification brings `{"BackendState":"NeedsLogin","Peer":null}`
as the next `/status`. After the idle barrier, `state` is `NeedsLogin`,
`peers` has 20 rows, `exitNodes` has 2, and no `rowsRemoved` fired on either
model. View half: on the stand-in with `state` `NeedsLogin` and 20 seeded
peers, clicking `ts-devices-row` shows 20 `ts-peer` rows.

**Sources.** `plugin/lib/tailscale/StatusParser.cpp:126-131`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:655-671`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:47`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:597`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:774`.

## R-WATCH: IPN bus

### R-WATCH-01 · parity · The watch asks for mask 18, so private keys are stripped

**Statement.** The watch is `GET /localapi/v0/watch-ipn-bus?mask=18`. That is
NotifyInitialState (2) plus NotifyNoPrivateKeys (16). The engine-updates bit (1)
is never requested. tailscaled therefore strips private key material from
every notification.

**Acceptance.** When the client starts a watch, the fake records one request,
`GET /localapi/v0/watch-ipn-bus?mask=18 HTTP/1.1`, with the Host header. Read as
an integer, the mask has bit 16 set and bit 1 clear.

**Sources.** `plugin/lib/tailscale/LocalApiClient.cpp:11-41`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:302-324`.

### R-WATCH-02 · parity · The watch says when it is established

**Statement.** A watch emits "started" exactly once, when 2xx headers are
accepted, before any event. A read never emits it. A refused watch, or one that
fails before its headers, never emits it.

**Acceptance.** A watch answered `200` that then gets two lines emits started,
event, event, with one started. A watch answered 403 ends with no started. A GET
answered 200 emits no started.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:135-143`,
`plugin/lib/tailscale/LocalApiClient.cpp:235-245`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:246-300`.

### R-WATCH-03 · parity · One event per complete notification line

**Statement.** After de-framing, the watch body splits on LF. Each complete,
non-empty line becomes one event, in order, without a trailing CR. A partial
line waits for its newline. Empty lines emit nothing. Bytes after the last
newline at stream end are discarded.

**Acceptance.** Pushing `{"a":1}\n{"b":2}\n` yields two events in order. Pushing
`{"half":` and then the read barrier yields no event. Pushing `1}\n` then
yields exactly one event, whose bytes are exactly `{"half":1}`. `\n\r\n` followed by the read barrier yields no event.
`{"c":3}\r\n` yields `{"c":3}`. Setup, not acceptance: each case waits until
the fake has recorded the watch before the first push.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:144-152`,
`plugin/lib/tailscale/LocalApiClient.cpp:310-331`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:227-244`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:326-342`.

### R-WATCH-04 · parity · A clean end differs from a failure

**Statement.** A watch whose stream ends normally emits "ended" once. Ending
normally means the peer closed after accepted headers, or the zero-size chunk
arrived. A watch that ends badly emits a failure, then "ended", once each. Bad
endings include a refused status, a transport error, bad framing, a close
before headers and the establishment deadline.

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

**Statement.** A watch whose headers miss the deadline emits a failure saying
the stream did not start, then "ended". It never emits "started". Once headers
are accepted, the deadline is off. An established watch may stay silent
indefinitely and still delivers later events.

**Acceptance.** With paused time and a 50 ms deadline, a watch never answered
yields failure then ended at 50 ms, with `did not start` in the reason. A watch
answered `200` yields started. Advancing paused time by 3 600 000 ms after
that, then the read barrier, yields 0 failures and 0 "ended" signals. A later
line `{"State":6}` yields one event.

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
had deferred, is the negative read: the fake has accepted exactly one client in
all, the second one, and the first client has delivered no reply and no
failure. A handler that stops
on the first of two lines in one read sees, after the read barrier, one event
and no ended. Setup, not acceptance: the first case waits until the fake's
client count is 1 before stopping.

**Sources.** `plugin/lib/tailscale/LocalApiClient.h:28-32`,
`plugin/lib/tailscale/LocalApiClient.h:106-107`,
`plugin/lib/tailscale/LocalApiClient.cpp:96-99`,
`plugin/lib/tailscale/LocalApiClient.cpp:118-123`,
`plugin/lib/tailscale/LocalApiClient.cpp:171-175`,
`plugin/lib/tailscale/LocalApiClient.cpp:312-320`,
`plugin/lib/tailscale/tests/tst_localapiclient.cpp:588-606`.

### R-WATCH-07 · parity · Watch first, read once, then only the bus

**Statement.** Each connection attempt opens the watch before it reads. It then
issues one pass. After that, no snapshot read (`/status`, `/prefs` or
`/suggest-exit-node`) and no new watch happens without a notification. There
are two exceptions: the R-CONN-13 liveness check and an R-WRITE-08
confirmation. Neither is a poll of the snapshot. In #286 nothing at all is
requested between notifications. The R-CONN-13 fix adds the liveness check's
requests.

**Acceptance.** Given a fake that answers everything, the backend reaches
`Running`. After the idle barrier that follows the opening pass, before paused
time advances, the fake has received exactly four requests: one watch and one
GET each of `status`, `prefs` and `suggest-exit-node`. Their arrival order at the fake is
not asserted: each opens its own connection, deferred separately (R-HTTP-11),
so it is not deterministic. The watch-first order is asserted on the client
side: the transport reports to its test the order in which it issued an
attempt's requests, like the read barrier (open question 12), and in every
attempt the watch is issued first. Paused time then advances by
one hour (3 600 000 ms) with no notification and no action called. After the
idle barrier, the fake has recorded exactly one watch and exactly one GET of
`status` in all. No request recorded in that hour is a watch or a GET of
`/localapi/v0/status`, and no property change signal fired in that hour. Any
request recorded in that hour is R-CONN-13's liveness check, whose endpoint
open question 4 leaves open, so this clause sets no count on GETs of `prefs`
or `suggest-exit-node` made in that hour. When open question 4 pins the
check's endpoint and interval, the clause tightens to: every request in that
hour is that endpoint, at that interval, and a GET of `prefs` or
`suggest-exit-node` that is not that endpoint was recorded exactly once in
all. Every reconnect attempt repeats the same four: with a watch
that ends after each pass, the fake has recorded, after the retry barrier of
attempt n, exactly n watches and n GETs of `status`, and at least n GETs each
of `prefs` and `suggest-exit-node`, for n = 1 to 4. The same tightening
applies: once open question 4 pins the check's endpoint, each of those two
that is not that endpoint was recorded exactly n times, so 4n requests in all
apart from the check's.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:15-22`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:244-296`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:944-960`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1062-1066`,
`pr286-body:11-12`.

### R-WATCH-08 · parity · A notification starts a pass, and the replies are the truth

**Statement.** A notification that passes the filter (R-WATCH-09) starts one
pass. The pass publishes what its replies say. No snapshot property is rebuilt
from the notification body. The one exception is R-UI-17's login URL
(`BrowseToURL`), which is not part of any snapshot and has no read endpoint;
it is a `new` member listed under "Contract additions". The suggestion is
re-read on every pass, not only on connect.

**Acceptance.** With the backend `Running` on the idle capture,
`exitNodeActive` reads false. The fake switches to the exit-node capture and
pushes `{"Prefs":{}}`. After the idle barrier,
`exitNodeActive` is true and `exitNodeName` is `pentest-exit-node`. The fake has
seen a second GET of `/status` and of `/suggest-exit-node`.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:275-296`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:311-325`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:849-863`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1195-1207`.

### R-WATCH-09 · parity · Notifications are judged by content, not by the mask

**Statement.** tailscaled sends ongoing notifications to every watcher,
whatever the mask. The backend skips a notification only when it is a
non-empty JSON object whose every non-null field is `Version`, `SessionID` or
`Engine`. Anything else starts a pass. That includes an unknown field, non-JSON
text and `{}`. A notification carrying `ErrMessage`, tailscaled's own error
report, only starts a pass. Its text reaches no property: #286 drops it, and
open question 18 asks whether to publish it.

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
Five more lines follow. After the read barrier on the watch, which proves the
backend consumed all five, and then the fake barrier, the fake has recorded
no new request, and `state` stays `Running`. Releasing the held reply causes
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
paired across passes or attempts. An R-WRITE-08 confirmation obeys the same
rule: whatever it reads is published as a whole snapshot, never as a `/prefs`
half alone.

**Acceptance.** The backend is `Running` on the idle capture. The fake
switches to a status with a new state and holds the next `/prefs`. A
notification is pushed. The fake answers `/suggest-exit-node` with the same
reply as before, so `recommendedExitNodeId` does not move. Once the fake holds
that `/prefs` (held count 1) and has answered `/status` and
`/suggest-exit-node`, and the client barrier holds at 2 (the watch and the
held `/prefs`), the read barrier holds on every connection: no property change signal has fired since the
notification, and every property reads its old value. The fake then releases
`/prefs`. After the idle barrier, every property the new snapshot changes
reads its new value, and its change signal fired exactly once.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:24-34`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:237-251`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:259-262`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:411-422`.

### R-WATCH-12 · parity · A straggler from an abandoned pass is ignored

**Statement.** A reply or failure from an abandoned pass never pairs with a
later pass. It never ends the current pass. A loss or a reconnect abandons a
pass. Watch failures always count.

**Acceptance.** The backend shows exit node A. A pass's `/status` fails with
503 while its `/prefs`, selecting B, is held; `state` then reads `NoState`
(R-CONN-06). The held reply is released, and a notification starts a pass
whose `/prefs` selects C. Then `state` is `Running`, `exitNodeId` is C and
`exitNodeName` is C's display name (`host-1` for `gamma` in
`status-idle.json`). B is never published.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:308-321`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:354-379`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:453-463`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:497-506`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:491-554`,
`pr286-body:87-92`.

### R-WATCH-13 · parity · State and identity come from the snapshot

**Statement.** `state` maps `BackendState`: `NeedsMachineAuth`, `NeedsLogin`,
`Stopped`, `Starting` and `Running` map to themselves. Any other value maps to
`NoState`. `selfName`, `selfIp4`, `selfIp6`, `selfDnsName`, `tailnet` and
`keyExpiry` come from the same snapshot. An unknown non-empty `BackendState`
(a real `ipn.State` such as `InUseOtherUser`, or a state a future tailscaled
adds) is not a failure in #286: the pass publishes its whole snapshot with
`state` `NoState` and an empty `readError`, arms no retry and keeps the watch
open. Through R-QML-01 a daemon that never reported a known state therefore
has no bar slot, exactly like a machine without Tailscale, and through
R-QML-05 a daemon that was `Running` reads "no daemon" while its watch is
open. Unlike a missing `BackendState` (R-CONN-04), nothing names the value.
Open question 23 asks whether it should.

**Acceptance.** The idle capture, served chunked, yields `Running`, 20 peers,
`selfName` `host-6`, `selfIp4` `100.115.228.122`, `selfDnsName`
`host-6.example-tailnet.ts.net` and `tailnet` `example.com`. A first status
with `BackendState` `Weird` gives, after the idle barrier, `state` `NoState`,
an empty `readError`, no armed reconnect (the retry hook's count is 0) and a
client count of 1, the watch. In the QML suite, with `state` `NoState`,
`readError` empty and no other state ever reported, the slot is not visible
(R-QML-01). A backend that reached `Running` and then reads a status with
`BackendState` `Weird` gives, after the idle barrier, `NoState`, an empty
`readError`, no armed reconnect and a client count of 1.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:41-55`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:599-605`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:638`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:133-157`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:293-305`.

### R-WATCH-14 · parity · Reading the exit node fails closed

**Statement.** `exitNodeActive` is true when `/status` has `ExitNodeStatus` or
`/prefs` has a non-empty `ExitNodeID`. `exitNodeOnline` is true only when
`ExitNodeStatus` is present and online. `exitNodeId` is `ExitNodeStatus.ID`,
else the prefs `ExitNodeID`. `exitNodeName` is the R-PARSE-09 name, else the
named peer's display name, else the id. Id and name are empty when nothing is
active.

**Acceptance.** The offline capture yields blocked, active, not online and
name `pentest-exit-node`. The reachable capture yields active, online, not
blocked and the peer's id. The idle status with prefs `ExitNodeID` set
reaches `Running` and yields active, not online, blocked, the id and the name. Prefs without `ExitNodeID` then clear
active, blocked, id and name.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:540-552`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:607-629`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:307-399`.

## R-CONN: connection lifecycle

### R-CONN-01 · parity · Socket path, start-up and injectable timings

**Statement.** The socket path is `$TS_SOCKET`, or
`/var/run/tailscale/tailscaled.sock` when it is unset. The backend starts
connecting when the singleton is created, without a call from QML. Tests can
inject the socket path, the first retry delay, the settle period and the
request deadline. The shipped values are 500 ms, 30 s and 10 s.

**Acceptance.** With `TS_SOCKET` naming a fake's socket, creating the singleton
through the QML factory makes the fake receive the four opening requests. The
default is checked as a resolved value, never by connecting: with `TS_SOCKET`
removed from the test's environment, the socket path the backend resolves
equals `/var/run/tailscale/tailscaled.sock`, and the test opens no socket. The
rewrite exposes that resolution to its tests; #286 resolves it in one function
(`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:32-39`). With injected timings, the first retry
delay equals the injected base.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:32-39`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:74-86`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:55-65`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:696-704`,
`plugin/tests/tst_module.cpp:100-116`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:728`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1081`,
`docs/superpowers/specs/2026-10-15-tailscale-module-design.md:157-161`.

### R-CONN-02 · parity · No tailscaled settles in NoState without a diagnosis

**Statement.** When nothing listens at the socket path at start-up, before any
snapshot was published, the backend reads `state` `NoState`, no peers,
`exitNodeActive` false and an empty `readError`. It arms one reconnect. A
machine without Tailscale looks exactly like this. After a snapshot was
published, a later connect that finds nothing at the path is a loss:
R-CONN-06 governs it, so only `state`, `readError` and
`recommendedExitNodeId` move. The last moves because every reconnect attempt
asks `/suggest-exit-node` (R-WATCH-07), and with nothing at the path that
request fails and clears it (R-PARSE-11, R-CONN-11). Identity, the models and
the other exit-node fields keep their last values.

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
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:812-823`.

### R-CONN-03 · parity · Each read failure from a present daemon has its own diagnosis

**Statement.** When a read fails while a daemon is present, `readError` holds a
non-empty reason. The reasons tell the failures apart. They cover a non-2xx
status with path and code, a missed deadline, a watch that never started, a
bad chunk length, a short chunk, a close before headers, a close mid-body, and
any other socket error. `readErrorChanged` fires once per change. One loss can
report several failures. The first failure of the attempt sets `readError`.
Later failures of the same attempt's snapshot reads are stragglers and change
nothing (R-WATCH-12). A watch failure always counts, so when the watch fails
after a read has, `readError` changes again, to the watch's reason. The final
value therefore depends on which socket ends first. It is always one of that
loss's reasons. A close mid-body is a read failure for a get only: a watch
whose headers were accepted and that is then closed ends cleanly
(R-WATCH-04, R-CONN-15), leaves `readError` as it was and closes the pass, so
a snapshot-read failure arriving after that clean end is a straggler.

**Acceptance.** For each failure staged by the fake, `state` becomes `NoState`
and `readError` is non-empty. The stagings are: 403 to every request, a
request never answered past the deadline, a bad chunk-length line, a short
chunk, a close before headers, a close mid-body, and a head whose status line
is not `HTTP/x NNN` (`garbage\r\nContent-Length: 2\r\n\r\n{}`, the shape of
`TS_SOCKET` pointing at some other listening socket). In the last staging
`exitNodeBlocked` keeps the value it had before the attempt, because no
`/prefs` is read as defaults. In every staging except the close mid-body the
fake applies the failure to every request, the watch included, so the watch
fails too and no connection of that attempt stays open (in #286 a failed read
does not stop the watch, so a staging that spared it would never reach a
count of 0). In the close mid-body staging the watch does not fail: the fake
accepts the watch and holds it open after its headers, closes `/status` and
`/prefs` mid-body, and the read barrier is taken. Then `state` is `NoState`
and `readError` is non-empty. Only then does the fake drop the watch
(R-FAKE-03), and the client barrier is taken at 0; that clean end leaves
`readError` unchanged. The first non-empty values of `readError`, one per staging, differ
pairwise. The 403 case contains `403`. At the moment `readError` first becomes
non-empty, `readErrorChanged` has fired exactly once. After the retry barrier
and the client barrier at 0, with paused time not advanced so no new attempt
has connected, it has fired at most twice. `readError` is
non-empty, and in the 403 case it contains `403`.

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
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:775-805`.

### R-CONN-04 · parity · A /status without BackendState is not a status

**Statement.** A 200 `/status` that does not parse, or that has no non-empty
`BackendState`, publishes nothing. `readError` names `/localapi/v0/status` and
says what was wrong. `state` is `NoState`, and a reconnect is scheduled.

**Acceptance.** Given a fake whose `/status` answers chunked `{}`, after the
four opening requests `state` is `NoState`. `readError` names the path and says
it answered without a BackendState. After the retry barrier, with paused time
not advanced, exactly one retry is armed. A body of `x` gives a different
reason.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:391-406`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:925-942`.

### R-CONN-05 · parity · readError clears only with a whole snapshot

**Statement.** A non-empty `readError` stays until one pass delivers both a
valid `/status` and its `/prefs`. It then becomes empty, together with the rest
of the snapshot. A `/prefs` reply alone does not clear it.

**Acceptance.** With every read answered 500, `readError` is non-empty. For
the next attempt the fake serves the watch normally, answers `/prefs` and
holds `/status`, and fake time is advanced past the next retry delay. Once the
fake holds that attempt's `/status` and the read barrier holds after its
`/prefs` reply, `readError` is still non-empty and `readErrorChanged` has fired
0 times since the attempt began. The fake then releases `/status` with a 500.
After the retry barrier of that attempt, `readError` is still non-empty and
`state` is `NoState`. When `/status` also
answers and fake time passes the next retry, after the idle barrier `state` is `Running`, `readError`
is empty and `readErrorChanged` fired again.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:629-638`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:339-342`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:829-847`.

### R-CONN-06 · parity · Losing tailscaled changes only state, then reconnects

**Statement.** When a read fails or the watch ends, the backend abandons the
pass and sets `state` to `NoState`. A read failure from a present daemon also
sets `readError` to its reason (R-CONN-03). A failure because nothing is at the
socket path sets `readError` to empty, clearing any earlier reason
(R-CONN-02). A clean watch end leaves `readError` as it was (R-CONN-15).
Every other value is kept as tailscaled last reported it, with one exception:
`recommendedExitNodeId` follows each attempt's suggestion outcome (R-PARSE-11,
R-CONN-11), so a reconnect attempt that finds nothing at the path clears it.
The kept values include identity, the other exit-node fields, `exitNodeBlocked`,
`issues`, both models and the four prefs. A fail-closed `exitNodeBlocked`
therefore stays visible. It then reconnects and publishes the next snapshot.
A failed snapshot read does not stop the watch. Until the armed reconnect
runs, a notification on that still-open watch starts a pass like any other
(R-WATCH-10), and a whole snapshot from it publishes as usual, `state` and an
empty `readError` included. The reconnect then stops that watch and opens a
new one. Open question 24 asks whether a read loss should stop the watch.

**Acceptance.** With the backend `Running`, an exit node active and offline,
and two peers, the fake is destroyed, closing every accepted connection, the
watch included. `stateChanged` fires and `state` is `NoState`. After the retry
barrier, with paused time not advanced so no reconnect attempt has run, no
other change signal has fired, and every other value, `recommendedExitNodeId`
included, is unchanged.
`readError` was empty before the loss and is empty after it. A separate run
has the fake answer `/status` 500, so after the retry barrier `readError` is
non-empty. The fake is then destroyed. After the next retry barrier, whose
connect found nothing at the path, and the read barrier, `readError` is empty,
and `readErrorChanged` has fired exactly once since the fake was destroyed.
`recommendedExitNodeId` is empty too, because that attempt's suggestion failed;
it is the only value besides `state` and `readError` allowed to move. A new fake
serving the exit-node capture on the same path, plus advancing past
the retry delay, gives `Running` and `exitNodeActive` true. A third run, from
`Running`, has the fake answer `/status` 500 once and every later request
normally, and keep the watch open. After the retry barrier, with paused time
not advanced, `state` is `NoState` and `readError` is non-empty. One
notification is pushed on that watch. After the idle barrier the fake has
recorded exactly one more `/status` and one more `/prefs`, `state` is
`Running` and `readError` is empty. Paused time is then advanced past the
retry delay. After the idle barrier the fake has recorded one ended watch and
one new one, and its connected-client count is 1.

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
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:437-452`.

### R-CONN-07 · parity · The reconnect curve doubles from 500 ms and caps at 30 s

**Statement.** The n-th consecutive reconnect delay, counting from 0, is
`min(30000, base × 2^min(n, 6))` ms. The base is 500 ms. The delays are 500,
1000, 2000, 4000, 8000, 16000, then 30000 for ever. Tests can observe each armed
delay.

**Acceptance.** The delay function at base 500 gives 500, 1000, 2000, 16000,
30000 and 30000 for attempts 0, 1, 2, 5, 6 and 60. With no listener and paused
time, the observed delays are 500, 1000, 2000, 4000, 8000, 16000, 30000, 30000.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:50-53`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:81-84`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:128-133`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:518-538`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:962-974`.
`pr286-body:87-92` only names "the reconnect backoff curve"; the 500 ms base
and the 30 000 ms cap come from the code and test cited.

### R-CONN-08 · parity · One lost connection arms one reconnect

**Statement.** One loss can report itself several times: three failed reads,
then the watch's failure and end. It arms exactly one reconnect at the current
delay and advances the curve one step. A retry already pending absorbs further
reports.

**Acceptance.** Given a fake that answers every request 403, with a 20 000 ms
base, all four requests fail. Then the client barrier holds at 0: the fake's
connected-client count reaches 0, because every socket of the attempt, the
watch included, has failed and been dropped, so every ending the attempt will
report has been reported. At that point exactly one retry is scheduled, with
delay 20 000.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:518-530`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:976-998`.

### R-CONN-09 · parity · An attempt is whole only when status, prefs and the watch all succeed

**Statement.** An attempt is established only when its status and prefs have
published a snapshot and the watch has started. `/suggest-exit-node` never
counts. If any of the three fails, the attempt failed and the next delay is
longer.

**Acceptance.** Given a fake whose `/prefs` answers 404 while the rest answer
normally, with a 1 ms base, five reconnects use 1, 2, 4, 8 and 16 ms.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:139-159`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:327-335`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:381-386`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:423-427`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1000-1042`.
`pr286-body:87-92` only names "the OpeningRead wholeness bitmask"; the
404-prefs behaviour comes from the code and test cited.

### R-CONN-10 · parity · Only a connection that holds resets the curve

**Statement.** An established connection starts a settle period of 30 s. The
curve goes back to attempt 0 only when that period passes with no loss. A loss
during it cancels the reset, so the curve keeps rising.

**Acceptance.** With a 1 ms base and the shipped settle, four passes whose
watch ends at once give delays 1, 2, 4, 8 ms. With a 1 ms base and a 1 ms
settle, and no listener at the socket path, the backend first arms at least
three reconnects, with delays 1, 2 and 4 ms, so the curve stands at attempt 3
or later and the next delay would be at least 8 ms. A fake then appears, the
backend reaches `Running`, and paused time passes the settle. When the watch
then drops, the reconnect armed next has a delay of 1 ms. Without the climb
first, a reset and no change would both read 1 ms, so the climb is part of
the criterion.

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
500, a timeout and an empty body. It does not set `NoState` or `readError`,
schedule a retry, or re-read `/status`.

**Acceptance.** For a 404, a 500 with `{"error":"no preferred DERP, try again
later"}` in `Running`, and the same 500 in `NeedsLogin`: `state` reaches the
served state. After the idle barrier, `recommendedExitNodeId` is empty and no retry is
scheduled. Fake time then advances by exactly ten times the retry base. After
the idle barrier again, no retry has been scheduled and the fake has seen
exactly one GET of `/status`.

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

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:145-153`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:437-452`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:340-351`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:677-690`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:556-623`.

### R-CONN-12 · parity · A wedged request ends and reconnects

**Statement.** A request that tailscaled accepts and never answers ends at the
deadline as a lost connection. `state` becomes `NoState` and a reconnect is
armed. A pass never stays in flight for ever.

**Acceptance.** With the backend `Running` and every later `/status` left
unanswered, a notification makes the fake record a second GET of `/status`,
which it holds unanswered. Paused time past the deadline then gives `NoState`
and at least one scheduled retry.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:56-65`,
`plugin/lib/tailscale/LocalApiClient.cpp:135-149`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:701-736`,
the held second read at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:733`.

### R-CONN-13 · fix · A connected but silent daemon is detected

**Statement.** A watch can stay connected while tailscaled stops serving. The
backend detects this with an active liveness check. Detection takes at most
60 000 ms from the moment the daemon stops answering; the design (open
question 4) may choose a shorter bound, never a longer one. A failed check is a
lost connection: `state` `NoState`, a non-empty `readError` and a reconnect. A
daemon that answers the check while its bus is quiet stays `Running`. The check
is not a refresh: it republishes nothing unchanged and never re-reads
`/localapi/v0/status`. Its requests are the only ones R-WATCH-07 allows between
notifications, apart from an R-WRITE-08 confirmation. A watch that stalls while
tailscaled still answers new requests is a separate case. Open question 4
decides whether the check must catch it. Until then, the acceptance does not
cover it.

**Defect.** "No liveness check. A watch that connects and then goes silent is
indistinguishable from a healthy quiet bus — and because `state` stays
`Running`, every `live` gate in the QML passes and the panel asserts a stale
snapshot is current. Needs an active probe, not a longer deadline."

**Acceptance.** With paused time, the backend is `Running` on a fake whose watch
stays open and silent. (a) From some instant T the fake records every new
request and answers none. The test records the instant L at which `state`
first leaves `Running`. L is no later than T + 60 000 ms. At L, `state` is
`NoState` and `readError` is non-empty. Exactly one retry has been armed since
T, and it was armed no later than T + 60 000 ms. Retries armed after L by
later attempts that also time out are not counted.
(b) On a fresh fake that answers every request, paused time advances
600 000 ms with no notification pushed. `state` is still `Running`, no retry is
scheduled, no property change signal fired, and the fake recorded no GET of
`/localapi/v0/status` after the opening pass.

**Sources.** `pr286-body:109-113`,
`plugin/lib/tailscale/LocalApiClient.h:43-49`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:15-19`.

### R-CONN-14 · parity · A /prefs that is not a JSON object reads as defaults

**Statement.** A 2xx `/prefs` body that is not a JSON object, or whose fields
have other types, reads as defaults. No exit node is selected and all four
switches are false. The pass then publishes like any other: `state` follows
the status and `readError` clears. If the status has not resolved an exit node,
`exitNodeActive` and `exitNodeBlocked` become false. #286 relies on tailscaled
never sending such a body with a 2xx. This is a silent-failure risk: the
fail-closed alarm goes quiet with no diagnosis. Open question 16 asks whether
the rewrite treats it as R-CONN-04 treats a bad `/status`.

**Acceptance.** The backend is `Running` on the idle status, with prefs
selecting an exit node the status does not resolve, so `exitNodeBlocked` is
true. The fake then answers `/prefs` 200 with `x` and pushes `{"Prefs":{}}`.
After the idle barrier, `exitNodeBlocked`, `exitNodeActive` and the four
switches are false, `state` is `Running` and `readError` is empty. If open
question 16 is answered with "a named read error", this criterion is replaced:
`readError` names `/localapi/v0/prefs`, `state` is `NoState`, one retry is
armed, and `exitNodeBlocked` is still true.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:381-386`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:564-582`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:633-638`.

### R-CONN-15 · parity · A clean watch end is a loss without a diagnosis

**Statement.** A watch that ends cleanly is a lost connection, but no read
failed, so `readError` is left as it was. Ending cleanly means a peer close
after accepted headers, or the zero chunk. The backend sets `NoState`, abandons
the pass and arms one reconnect. `readError` is empty if it was empty, and
keeps an earlier reason if it had one. A present daemon whose watch closes
cleanly before any snapshot has been published therefore reads like a machine
without Tailscale: `NoState` with an empty `readError`, and no bar slot
(R-QML-01). Open question 19 asks whether that is kept.

**Acceptance.** A fake answers the watch `200` chunked and holds `/status`. It
then sends `0\r\n\r\n` on the watch. After the retry barrier, `state` is
`NoState`, `readError` is empty and exactly one retry is armed. The held
`/status` is then answered, and after the client barrier nothing changes. View
half: with `state` `NoState`, `readError` empty and no other state ever
reported, the slot is not visible. In a second run, `readError` was already
non-empty from a 500 on an earlier attempt. A clean watch end leaves it
unchanged, and `readErrorChanged` does not fire.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:95-99`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:490-516`,
`plugin/lib/tailscale/LocalApiClient.cpp:194-200`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:136-157`.

### R-CONN-16 · parity · A watch that fails after it started has a diagnosis

**Statement.** A watch that has started and then fails, by bad chunk framing
or by any other failure R-WATCH-04 lists, is a lost connection with a
diagnosis. The backend sets `NoState`, puts the failure's reason in
`readError` and arms one reconnect. Only a clean end leaves `readError` as it
was (R-CONN-15).

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

**Acceptance.** A `Running` status with prefs false, true, true, false gives
those four values in that order. From all false, prefs flipped to all true plus
one `{"Prefs":{}}` give all true. Each of the four signals fired exactly once.
With `WantRunning` true and `BackendState` `NeedsLogin`, `wantRunning` is true.

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
on the singleton once the backend has reached `Running`, the fake receives
exactly one PATCH. Its request line starts with
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
`Running`, `setExitNode(id)` sends one body with `ExitNodeID` equal to id and `ExitNodeIDSet` true. It has no
`ExitNodeIP` key and no `ExitNodeIPSet` key, and its bytes do not contain the
IPv4. `setExitNode("")`
sends `ExitNodeID` `""`.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:258-264`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:160-163`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1429-1459`.

### R-WRITE-04 · parity · An action publishes nothing; the bus decides

**Statement.** An action returns nothing, before anything has happened. It
changes no property and emits no property signal synchronously. No property
ever takes the requested value merely because it was requested. A write's
outcome moves only `writable` and `writeError` (R-WRITE-06). The prefs
read-backs and the rest of the snapshot move only through a pass: one a
notification starts, or an R-WRITE-08 confirmation. Two other paths move
properties and never take a requested value: a loss moves `state` and
`readError` (R-CONN-02, R-CONN-03, R-CONN-06), and a suggestion outcome moves
`recommendedExitNodeId` (R-PARSE-11). These paths are complete for the 24 #286
properties (R-UI-02). One member added by the rewrite has a further path: the
R-UI-17 login-URL carrier is set directly from a `BrowseToURL` notification
body, outside any snapshot (R-WATCH-08). It carries the daemon's URL, never a
requested value. A pass shows what tailscaled reports, even when that differs from
the request. A refused write leaves a control at its previous value. In #286
the accepted reply's body is not read, and only a notification moves
properties. R-WRITE-08 adds the confirmation.

**Acceptance.** Once the backend has reached `Running` with `exitNodeId`
empty, `setExitNode(id)` leaves it empty before the loop runs, and no property signal fires. The fake's `/prefs` then
selects another peer B, and the PATCH gets 200 with B's prefs as its body.
After the PATCH client has closed and the idle barrier holds, `writable` is
true. A spy on `exitNodeIdChanged` shows that `exitNodeId` never held the
requested id. `exitNodeId` is either still empty or already B's id, depending
on R-WRITE-08's design. After `{"Prefs":{}}` and the idle barrier, it is B's
id, not the requested one. This criterion sets nothing about `writeError`:
the requested id was not applied, so R-WRITE-08 governs it, and it is
non-empty no later than 10 000 ms of paused time past the 200. #286 asserts it
empty at this point
(`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420`);
that assertion pins the R-WRITE-08 defect and maps there.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:224-247`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:101-125`,
`plugin/tests/tst_tailscalebackend.cpp:91-106`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1381-1427`.

### R-WRITE-05 · parity · Repeated calls are not collapsed

**Statement.** Every call of the five prefs actions (R-UI-13) is its own
request, in call order. A repeat of a value already in effect is still sent.
The R-UI-17 login action is not covered by this rule.

**Acceptance.** With `acceptDns` true, calling `setAcceptDns(true)` twice makes
the fake receive two PATCH requests in that order.

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
clears A's message. The user is not told that change A did not happen. Open
question 5 covers that case together with R-WRITE-08. A `writeError` from a
non-2xx, timed-out or dropped write persists until the next write outcome,
even when a later snapshot shows the change was applied after all: R-WRITE-08's
confirmation runs only after a 2xx, and no snapshot touches `writeError`.
Open question 5 also asks whether the rewrite reconciles it.

**Acceptance.** A backend that has reached `Running` and has sent no write
reads `writable` true. A 403 gives `writable` false and a `writeError`
containing `403`. Each signal fired once, and inside `writableChanged` the new
`writeError` is already readable. In one run a 200 follows the 403 directly:
it gives `writable` true and an empty `writeError`, and after the client
barrier `writableChanged` has fired exactly twice since the first write, once
for the refusal and once for the recovery. Both writes in that run are
`setAcceptRoutes(true)`. The 200 has `RouteAll` true in its body, and from the
200 on the fake's `/prefs` has `RouteAll` true too, so the write is applied
under any R-WRITE-08 design and `writeError` stays empty after the read
barrier at any later point of paused time. In another run a 500 follows the
403: it leaves `writable` false and changes `writeError`. After a 403, a PATCH
held and then dropped by the fake sets a `writeError` containing
`connection closed` and leaves `writable` false. A fresh backend whose PATCH
gets 500, or whose fake vanishes with the PATCH held, keeps `writable` true
with a non-empty `writeError`. Once `writeError` is non-empty and the read
barrier holds (it needs no fake, so it also holds after the fake vanished),
`writableChanged` has fired 0 times since the write. Two writes: the fake
holds PATCH A and answers PATCH B 200. Releasing A with a 500 leaves
`writeError` non-empty. In a second run A gets the 500 first and B the 200
after it, and `writeError` ends empty. In both runs A is `setAcceptDns(true)`
and B is `setAcceptRoutes(true)`. B's 200 body has `CorpDNS` and `RouteAll`
both true, and from B's 200 on the fake's `/prefs` holds both values too, so
B counts as applied under any R-WRITE-08 design and only the 500's
ordering decides `writeError`.

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
  never answers. At 49 ms past the write `writeError` is empty. At 50 ms it is
  non-empty and contains `50 ms`, `writable` is still true, and `state` and
  `readError` hold the values they had before the write. The write is
  `setAcceptRoutes(true)`. The fake then serves `/prefs` with `RouteAll` true
  and pushes `{"Prefs":{}}`. After the idle barrier `acceptRoutes` is true,
  `writeError` still holds the deadline reason, and `writeErrorChanged` has
  fired 0 times since the deadline.

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
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:80-84`, `pr286-body:75-78`.

### R-WRITE-07 · parity · Writes are isolated from the read side

**Statement.** A write's outcome is the PATCH's own reply or failure. It never
pairs into a snapshot and never counts as losing tailscaled. It leaves `state`, `readError`, the models and the reconnect
curve alone. A reconnect does not cancel a write in flight, and that write
still reports its outcome. An R-WRITE-08 confirmation is not part of the
outcome: it is a read, follows R-WATCH-11 and the read-side rules, and may
publish a whole snapshot or set `readError` like any pass.

**Acceptance.** With 20 peers and `Running`, a PATCH answered 403 leaves,
after the client barrier that follows the PATCH connection's close (count back
to 1, the watch), `state` `Running`, 20 rows, `readError` empty and no retry
scheduled. In a second run, a first PATCH answered 403 leaves `writable` false
and `writeError` non-empty. A second PATCH is then held while the fake closes
the watch. After the retry barrier (the loss is handled and a reconnect is
armed), paused time is advanced past the retry delay until the reconnect
attempt has run: the fake records a second watch and that attempt's
`/status`, `/prefs` and `/suggest-exit-node`, and the idle barrier holds with
the client count at 2 (the new watch and the held PATCH). Only then does the
fake answer the held PATCH 200. After that PATCH client has closed and the
read barrier holds, `writable` is true, `writeError` is empty, and
`writableChanged` and `writeErrorChanged` have each fired exactly once since
the PATCH was answered. Both PATCHes in this run are `setAcceptRoutes(true)`.
The fake has served `/prefs` with `RouteAll` true from the reconnect attempt
on, and the held PATCH's 200 body has `RouteAll` true, so the write counts as
applied under any R-WRITE-08 design, including one that confirms at once.

**Sources.** `plugin/src/backends/tailscale/LocalApiTailscaleBackend.h:285-294`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:126-143`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:246-255`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1297-1303`.

### R-WRITE-08 · fix · An accepted write that is not applied is reported

**Statement.** After a 2xx write, the published value must come to match what
tailscaled holds within 10 000 ms, even when no notification follows. The
design (open question 5) may choose a shorter bound, never a longer one. If the
daemon did not apply the change, `writeError` becomes non-empty and `writable`
keeps its value, so the panel's existing write note says the change did not
take. A design may add a dedicated property as well, but `writeError` always
carries it. The control never claims the requested value. A confirmation that
reads state publishes a whole snapshot (R-WATCH-11). It
is a read, not the write's outcome (R-WRITE-07), so it may move the models and
`readError` as any pass does. It is one of the two
exceptions R-WATCH-07 allows between notifications. A confirmation that itself
fails is never silent: `writeError` or `readError` becomes non-empty, and no
property takes the requested value.

**Defect.** "An accepted write that tailscaled does not apply produces no
feedback at all: no notification, so no refresh, so no motion and no message."

**Acceptance.** With paused time, the backend is `Running` with `acceptRoutes`
false and `writeError` empty. In every run the fake answers the PATCH 200 with
its resulting prefs as the body, so each design in open question 5 sees the
same evidence. The test calls `setAcceptRoutes(true)` and, in every run but
the last ("whole snapshot", which sets its own timing), advances paused time
10 000 ms past the 200 and waits for the idle barrier. Then:

- **Not applied, no notification.** The fake keeps `RouteAll` false and pushes
  nothing. `acceptRoutes` reads false and never read true. `writable` reads
  true. `writeError` is non-empty, and `writeErrorChanged` fired once.
- **Applied, no notification.** The fake sets `RouteAll` true and pushes
  nothing. `acceptRoutes` reads true and `writeError` is empty.
- **Applied, with a notification.** The fake sets `RouteAll` true and pushes
  `{"Prefs":{}}`. `acceptRoutes` reads true and `writeError` stays empty.
- **The confirmation fails.** The fake keeps `RouteAll` false, then answers
  every read after the PATCH with 500. `writeError` or `readError` is
  non-empty, and `acceptRoutes` never read true.
- **Whole snapshot.** A separate run stages "applied, no notification", but
  the fake holds every GET of `/localapi/v0/status` that arrives after the
  PATCH's 200, unanswered. Every design in open question 5 reads `/status`,
  because the confirmation publishes a whole snapshot (R-WATCH-11). Paused
  time advances in steps of 100 ms, each followed by the read barrier, until
  the fake has recorded such a GET. The test fails if none is recorded by
  10 000 ms past the 200. Paused time then stops advancing, so the held GET
  never reaches its request deadline (R-HTTP-13). At that point, after the
  read barrier, `acceptRoutes` reads false and `acceptRoutesChanged` has fired
  0 times since the PATCH. The fake then answers the held GET with the status
  capture. After the idle barrier, with no further advance of paused time,
  `acceptRoutes` reads true, `writeError` is empty and `acceptRoutesChanged`
  has fired exactly once.

**Sources.** `pr286-body:114-115`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:109-121`,
the defect pinned by #286 (an accepted write the daemon did not apply leaves
`writeError` empty) at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1420`,
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:36-40`.

### R-WRITE-09 · fix · Disconnecting is exercised end to end

**Statement.** `setWantRunning(false)` sends the disconnect write. The panel
follows tailscaled to `Stopped`, with the connect toggle off and still able to
reconnect. A test proves this against a fake tailscaled, never by ending a live
session.

**Defect.** "`tailscale down` is the one action here never exercised live:
clicking it on the test VM would end the session looking at it."

**Acceptance.** With the fake `Running`, `setWantRunning(false)` sends
`{"WantRunning":false,"WantRunningSet":true}`. The fake then reports
`WantRunning` false and `BackendState` `Stopped` and notifies. `wantRunning` is
false, `state` is `Stopped` and the toggle is enabled and unchecked. Toggling
sends `{"WantRunning":true,"WantRunningSet":true}`.

**Sources.** `pr286-body:130-131`. #286 covers the view half only, against the
QML stand-in: `tests/tailscale-qml-test.qml:1564-1578`.

### R-WRITE-10 · new · Use this device as an exit node

**Statement.** From the exit-node view, a user can offer this machine as an
exit node and stop offering it. The row shows what tailscaled holds, read back,
not the last click. Refusals and failures follow R-WRITE-06. #286 ships this as
a disabled row reading "not in this release".

**Acceptance.** Every clause names an observable that any answer to open
question 2 produces; the answer pins only the exact field names and the
read-back member's name. Given a fake whose `/prefs` advertises neither
`0.0.0.0/0` nor `::/0`, plus one subnet route `172.16.9.0/24`, the row
`ts-exit-advertise` is live and off. Activating it makes the fake record
exactly one new request: a `PATCH /localapi/v0/prefs` whose JSON body is an
object holding at least one key ending in `Set` with the value true, and a
route list that contains `0.0.0.0/0`, `::/0` and `172.16.9.0/24`. After the
idle barrier the row still reads off. The fake then reports both routes in
`/prefs` and pushes `{"Prefs":{}}`; after the idle barrier the row reads on.
Activating it again sends one PATCH whose route list is exactly
`172.16.9.0/24`. In a separate run, a 403 to the first write leaves the row
off and dead, like the other controls (R-QML-20).

View half, on the QML stand-in with the advertise action present: while
`writable` is true, `ts-exit-advertise` is visible, its title is not in
`Theme.textDisabled`, and a click records exactly one call of the advertise
action. After `writable` goes false, the title is in `Theme.textDisabled`, the
subtitle is non-empty and a click records no call, like the other controls
after a 403 (R-QML-20).

#286's dead-row checks (`tests/tailscale-qml-test.qml:1183-1188`) assert the
row on a contract that has no advertise action. R-QML-29 covers them in that
state. The two requirements never apply to the same contract surface: R-QML-29
holds while the contract has no advertise action, and this requirement holds
once it has one.

**Sources.** `pr286-body:22-24`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:314-333`,
`tests/tailscale-qml-test.qml:1177-1189`,
`docs/superpowers/specs/2026-10-15-tailscale-v2-design.md:114-118`.

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

### R-UI-02 · parity · The exact property set

**Statement.** Beyond the base object's own, the singleton exposes the 24
properties of #286 with these names and types. It also exposes exactly the
properties listed under "Contract additions", and no others. The 24 are
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
`objectName`, equal the 24 plus the property rows under "Contract additions".
That list changes only when R-WRITE-10, R-UI-17, R-GROUP-11 (if open question
6 puts its member on `Tailscale`) or an answer to open question 3 or 5 adds a
member. Each property reads from QML with the stated type.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:59-84`,
`plugin/tests/tst_module.cpp:35-45`, `plugin/tests/tst_module.cpp:118-153`.

### R-UI-03 · parity · Every property is read-only

**Statement.** QML cannot assign any property. State changes only when the
system reports a change, or when an action's outcome is published.

**Acceptance.** None of the 24 properties, and none listed under "Contract
additions", is writable.
`Tailscale.wantRunning = true` fails, and the value and its signal stay
untouched.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:22-26`,
`plugin/src/contracts/TailscaleBackend.h:59-84`.

### R-UI-04 · parity · The State enum

**Statement.** `state` is an enum with exactly `NoState` = 0,
`NeedsMachineAuth` = 1, `NeedsLogin` = 2, `Stopped` = 3, `Starting` = 4 and
`Running` = 5. QML names the values on the singleton. A backend that has not
heard from tailscaled reports `NoState`, never `Stopped`. A `BackendState` the
enum does not name also reads `NoState` (R-WATCH-13, open question 23).

**Acceptance.** `Tailscale.NoState` to `Tailscale.Running` evaluate to 0 to 5 in
that order. A fresh backend reads 0.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:87-104`,
`plugin/tests/tst_module.cpp:109`.

### R-UI-05 · parity · A fresh backend reads as nothing known yet

**Statement.** Before any reply, `state` is `NoState`. All string properties are
empty. `keyExpiry` is invalid. All booleans are false, except `writable`, which
is true. `issues` is empty and `issueCount` is 0. `peers` and `exitNodes` are
non-null and empty.

**Acceptance.** A backend created with its socket path in an isolated directory
reads these values. After the retry barrier for the first connect, `state` is
0, `exitNodeBlocked` false, there are 0 peer rows and `readError` is empty. The
C++ test's `qWait(250)` becomes that barrier.

**Sources.** `plugin/tests/tst_tailscalebackend.cpp:19-43`,
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
changes even when `issueCount` does not (R-UI-11). A snapshot stores every snapshot property (all
except `recommendedExitNodeId`, `writable` and `writeError`, which move on
their own outcomes per R-PARSE-11 and R-WRITE-06) and fills both models before
any property change signal fires. A handler on any property
change signal therefore reads the whole new snapshot. `exitNodeBlocked` is
never announced from half an update. The models' own row signals fire while
they are filled, before the property signals: `peers` is filled first and
`exitNodes` second, so a row-signal handler on `peers` reads the new property
values but may still see the previous `exitNodes` rows.

**Acceptance.** The backend first reaches `Running` on the idle capture, and
the idle barrier holds. Spies are then attached to every property change
signal. A notification that changes `state`, `selfName` and `exitNodeOnline`
at once is followed by the idle barrier. At that point each of those three
signals has fired exactly once. Every other property change signal has fired
once if its property's value differs from the value read before the
notification and 0 times if it does not, with the two exceptions the
Statement declares (`exitNodeBlockedChanged` per R-UI-09, `issuesChanged` per
R-UI-11).
Inside every handler, all three already hold their new values, and `peers`
and `exitNodes` already hold their new rows. The spies are then cleared and
the same notification is pushed again with the fake serving the same replies.
After the fake has recorded a further GET of `/localapi/v0/status` and the
idle barrier holds, every property change signal has fired 0 times. Moving
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

**Acceptance.** It fires when `exitNodeActive` becomes true. It fires again
when `exitNodeOnline` becomes true. It fires when `exitNodeOnline` returns to
false, and `exitNodeBlocked` then reads true.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:36-39`,
`plugin/src/contracts/TailscaleBackend.h:106-116`,
`plugin/src/contracts/TailscaleBackend.h:357-358`,
`plugin/tests/tst_tailscalebackend.cpp:175-192`.

### R-UI-10 · parity · Exit-node identity is joined on the ID

**Statement.** `exitNodeId` is the selected exit node's string node ID. It
matches one `exitNodes` row's `nodeId`. It is empty when none is selected, and
so is `exitNodeName`. A view marks the row in use by `exitNodeId`, never by
name.

**Acceptance.** With prefs selecting `nDEF456CNTRL` and two exit rows sharing a
hostname, `exitNodeId` is `nDEF456CNTRL` and exactly one row has that id. With
none selected, `exitNodeId` and `exitNodeName` are empty and `exitNodeOnline`
is false.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:137-153`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:607-627`.

### R-UI-11 · parity · issueCount shares the issues signal

**Statement.** `issues` is tailscaled's health text after R-PARSE-12. It is
empty when tailscaled reports nothing. `issueCount` is its length and is
announced on `issuesChanged`. It has no signal of its own.

**Acceptance.** A snapshot with two warnings fires `issuesChanged` once, with
`issueCount` 2. A snapshot with none fires it again, with `issueCount` 0. The
metadata of `issueCount` names `issuesChanged` as its notify signal.

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

### R-UI-13 · parity · The exact set of actions

**Statement.** QML can call the five methods of #286 on the singleton:
`setWantRunning(bool)`, `setExitNode(string)`,
`setExitNodeAllowLANAccess(bool)`, `setAcceptRoutes(bool)` and
`setAcceptDns(bool)`. It can also call exactly the invokables listed under
"Contract additions". There are no other public invokables.

**Acceptance.** The five signatures are a subset of the invokable signatures.
The sorted signatures equal the five plus the invokable rows under "Contract
additions". Calling each of the five by name with true, false, `nABC123CNTRL`
and `""` succeeds and causes one request with that argument.

**Sources.** `plugin/src/contracts/TailscaleBackend.h:256-274`,
`plugin/tests/tst_module.cpp:47-63`, `plugin/tests/tst_module.cpp:155-172`,
`plugin/tests/tst_tailscalebackend.cpp:45-89`.

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
unchanged through the contract.

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

**Acceptance.** Two halves. Backend half: for each of six fake captures,
after the idle barrier the contract reads the values named below. View half:
the stand-in is set to those values, and the slot reads as below. Every
reading has the slot visible.

- `Running`, no issues, no exit node: slot colour transparent, slot border
  transparent, icon tint `Theme.text`, no visible label text.
- `Stopped`, no issues: icon tint `Theme.textDisabled`, slot border
  transparent.
- `Running` with one health entry: exactly one visible item in
  `Theme.warning`, none in `Theme.accentSoft`, slot border transparent.
- `Stopped` with one health entry: icon tint `Theme.textDisabled`, exactly
  one visible item in `Theme.warning`, slot border transparent.
- `Running` with an active, online exit node: slot colour `Theme.accentFill`,
  icon tint `Theme.accentSoft`, the exit node's name visible, no `✕`, slot
  border transparent.
- `Running` with an active, offline exit node: a visible `✕` in
  `Theme.accentSoft`, slot colour `Theme.accentFill`, slot border
  `Theme.accentBorder`, the name visible, and no item in `Theme.warning` even
  with a health entry present.

**Sources.** `tests/tailscale-qml-test.qml:244-299`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:126-216`, `pr286-body:16`.
The 2026-10-15 design and plan describe the six icons but predate the
visibility rule; R-QML-01 and R-QML-03 hold that rule.

### R-UI-16 · fix · One designed explanation when a read and a write both failed

**Statement.** `readError` and `writeError` are independent, and both can be
non-empty. The contract keeps publishing both. The panel shows one designed
presentation of that combined state, not two explanations.

**Defect.** "`readError` and `writeError` can now both be non-empty at once,
which draws two explanations on one panel. Both are true; nobody has designed
that state."

**Acceptance.** A fake refuses a PATCH with 403 and then answers `/status` with
403. Both properties are non-empty and readable. Open the panel. Count the
explanations, headlessly, as two sets. The first set is the panel's Texts whose
effective visibility is true. The second set is the Text inside each hover
tooltip, counted by its `text` alone, because the harness's `Tooltip` stand-in
is never visible (`tests/test-tailscale.sh:104-119`) and a hover would show
exactly that text. Today the only such Text is `ts-connect-tip`. In both sets,
count the Texts whose text contains `readError` or `writeError`. The total is
exactly 1. At `a38dbca` it is 2: `ts-read-error` and `ts-connect-tip`. This
requirement governs the state where both errors are non-empty; R-QML-02's
`ts-read-error` clause and R-QML-22's `ts-connect-tip` clause apply only while
the other error is empty. Open
question 7 decides that Text's wording; its answer adds a pinned string to this
criterion and does not change the count.

**Sources.** `pr286-body:125-126`,
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
this out because it needs a browser flow.

**Acceptance.** Open question 1 decides the request bytes, the contract
member and the opener. Every clause below is executable before it is answered,
because each names an observable that any answer produces. Given a fake
reporting `NeedsLogin`, with the opening pass answered:

- The panel shows a login control with `objectName` `ts-login`.
- Activating it makes the fake record exactly one new request. That request is
  not the watch and not a GET of `status`, `prefs` or `suggest-exit-node`, and
  its path starts with `/localapi/v0/`. A second activation before the fake
  answers records no further request. The contract owns that rule, not the
  view: a login start is system state, so calling the login action while one
  is outstanding sends nothing. R-WRITE-05 does not apply to it.
- The fake then pushes the watch line
  `{"BrowseToURL":"https://login.tailscale.com/a/c7test"}`. After the idle
  barrier, exactly one QML-visible member of `Tailscale` that is not among the
  24 properties of R-UI-02 carries that string byte for byte. That member is
  listed under "Contract additions". It is a property read
  through the metaobject, or the sole argument of one emission of a signal.
- The URL is opened through Qt's external-URL opener, which the test
  intercepts by registering a recording handler for the `https` scheme. The
  handler records that URL exactly once, and no process is started.
- When the fake reports `Running`, the login control is not shown and the
  header reads "connected".
- When the fake answers the login-start request with 403, `writable` is false
  and `writeError` is non-empty, as R-WRITE-06 pins for any write.

**Sources.** `pr286-body:25`,
`plugin/src/contracts/TailscaleBackend.h:103`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:62-73`,
`plugin/src/backends/tailscale/LocalApiTailscaleBackend.cpp:57-58`,
the `BrowseToURL` notification field at
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:1170`.

## R-QML: views

### R-QML-01 · parity · No bar slot on a machine without tailscaled

**Statement.** The slot `tailscale` is hidden while `state` is `NoState`,
`readError` is empty, and no other state was ever reported. No exit-node label
is drawn then, whatever the exit-node properties hold. A present daemon whose
every `BackendState` so far was one the enum does not name meets these
conditions too, so it has no slot (R-WATCH-13, open question 23).

**Acceptance.** With no listener, the shipped 500 ms base and paused time,
the retry barrier is taken three times: the first reconnect is armed at
start-up (paused time 0), the second once paused time passes 500 ms and the
first attempt has failed, and the third once paused time passes 1500 ms
(500 + 1000) and the second attempt has failed. At each of those three retry
barriers `state` is `NoState`, `readError` is empty, and the number of armed
reconnects is exactly 1, 2 and 3 respectively.
In the QML suite, with `state` `NoState`, `readError` empty and an active,
online exit node named `pentest-exit-node` set underneath, the slot is not
visible and no visible text equals `pentest-exit-node`.

**Sources.** `tests/tailscale-qml-test.qml:183-209`,
`plugin/src/backends/tailscale/tests/tst_localapitailscalebackend.cpp:812-823`
(one armed reconnect in #286; the criterion extends it to three),
`quickshell/c7shell/Modules/Bar/StatusPill.qml:109-157`,
`plugin/src/contracts/TailscaleBackend.h:87-103`,
`plugin/src/contracts/TailscaleBackend.h:336-338`.

### R-QML-02 · parity · A dimmed slot for a daemon that is present but unreadable

**Statement.** While `state` is `NoState` and `readError` is non-empty, the slot
is visible with a disabled-tint icon. The panel shows "tailscaled is not
responding". While `writeError` is empty, it also shows the line
`ts-read-error` with `readError` verbatim; when both errors are non-empty,
R-UI-16 governs. When `readError` clears and nothing ever answered, the line
and the slot go away.

**Acceptance.** A fake answering `/status` with 403, with no write sent, gives
`NoState`, a `readError` containing `403`, a visible slot with tint
`Theme.textDisabled`, and a visible `ts-read-error` equal to `readError`. When
the fake stops listening, the next connect finds nothing at the path and
`readError` becomes empty (R-CONN-02, R-CONN-06); then both are hidden.

**Sources.** `tests/tailscale-qml-test.qml:211-242`,
`quickshell/c7shell/Modules/Bar/StatusPill.qml:143-157`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:338-383`,
`pr286-body:72-74`.

### R-QML-03 · parity · The blocked badge survives the daemon's death

**Statement.** After any state other than `NoState` was reported, a later
`NoState` keeps the slot visible and dims the icon. The crimson ✕ and the
exit-node label stay. This relies on R-CONN-06.

**Acceptance.** A fake reports an active, offline exit node, reaches `Running`
and closes. Then `state` is `NoState`, the exit-node values are unchanged, the
slot is visible and dimmed, and the ✕ and the name are drawn.

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

**Acceptance.** The view reads "now" from a clock the test sets. It defaults
to the wall clock, so the shipped text is unchanged. #286 has no such seam and
measures against the host's wall clock; the rewrite adds it, because a
criterion may not depend on host clock state. With the clock pinned at
`2026-01-01T00:00:00Z`: a Self without `KeyExpiry` hides the line.
`keyExpiry` `2027-07-03T00:00:00Z` (548 days later, 18.004 average months)
reads "expires in 18 months" in `Theme.textDisabled`. `2026-01-31T00:00:00Z`
(30 days) reads "expires in 1 month". `2026-01-06T00:00:00Z` reads "expires
in 5 days". `2026-01-02T12:00:00Z` reads "expires in 1 day".
`2026-01-01T06:00:00Z` reads "expires in under a day". `2025-12-31T00:00:00Z`
reads "session expired".

**Sources.** `tests/tailscale-qml-test.qml:542-562`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:75-104` (the
strings and `Date.now()`, the clock the seam replaces in tests),
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
`ownerName`. An empty group draws no heading.

**Acceptance.** With four peers, including another user's `HostName`
`localhost` with DNS label `workstation`, 4 rows show and none reads
`localhost`. `workstation` shows its owner and `tango` no subtitle. Headings by
y read my devices, tagged devices, other users. Dropping that peer leaves 2
headings. Before `ts-devices-row` is clicked, no `ts-peer` row is shown: the
list is not on the root card.

**Sources.** `tests/tailscale-qml-test.qml:420-447`,
`tests/tailscale-qml-test.qml:604-651`,
`quickshell/c7shell/Modules/Popovers/PeerRow.qml:19-60`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:562-709`.

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
alone. No child process is spawned.

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
`ts-devices-count` shows the total, or the match count while searching. "no
matches" shows for a query that matches nothing in a non-empty list. "no other
devices on this tailnet" shows for an empty model whose peer set is known
(R-GROUP-11).

**Acceptance.** With four peers, the count reads 4. `TANGO` leaves one row, the
count 1 and only the "my devices" heading, and `ts-peer-no-match` is not
shown. `workstation` leaves only the "other
users" heading. A query matching nothing shows no `ts-peer` row and no
`ts-section` heading, shows `ts-peer-no-match` and not `ts-peer-empty`. Zero
peers with the peer set known show `ts-peer-empty` only. On the stand-in,
"known" is R-GROUP-11's peers-known member set true. Seeding the four peers again then shows 4 rows and the count 4. Over 50 peers, `node-49` leaves one row,
titled `node-49`, under only the "other users" heading.

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

**Statement.** While searching, the device count and the section headings
reflect every matching row. Rows the view has not built count too.

**Defect.** "`deviceMatchCount` tallies instantiated delegates rather than
matching rows, so a filtered long list under-reports."

**Acceptance.** With 200 own peers `node-0` to `node-199`, the query `node-1`
makes `ts-devices-count` read 111 without scrolling. A query matching only the
last row reads 1 and hides "no matches".

**Sources.** `pr286-body:121-122`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:140-167`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:579-585`.

### R-QML-16 · fix · Long lists show a scrollbar, and there is one search pill

**Statement.** The device list and the exit list show a scroll indicator when
their content exceeds the cap. The panel's search pill and the Settings
sidebar's search pill are one shared component.

**Defect.** "Neither list has a scrollbar; `Common/SearchField.qml` duplicates
the Settings sidebar pill and has already diverged from it."

**Acceptance.** With 25 peers an indicator is visible in `ts-peer-list`. With 3
peers none is. `ts-exit-scroll` behaves the same with 20 and 3 exit nodes. The
Settings sidebar search and both panel searches are one QML type.

**Sources.** `pr286-body:123-124`,
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
disabled and clicks request nothing. When `writable` returns to true, they come
back. Any other failure keeps them live and shows a "try again" note without
`c7shell-bootstrap`. In #286 the shipped backend sets `writable` true only on
an accepted write (R-WRITE-06), and a reconnect does not reset it. Every
control is dead, so the panel cannot send that write. After the user runs
`c7shell-bootstrap` as the note says, the panel stays read-only for the life
of the shell. The "come back" clause is reachable only through the stand-in or
the test-only fake backend. Open question 20 asks how `writable` should
recover.

**Acceptance.** While `writable` is true and nothing is refused,
`ts-exit-all-label` does not contain `read-only`, no `ts-exit-write-error` is
shown, and `ts-settings-routes-switch` is enabled with its row hoverable.
After a 403, `ts-exit-all-label` contains `read-only`, and
`ts-exit-write-error` and `ts-settings-write-error` contain `writeError` and
`c7shell-bootstrap`. `ts-exit-row` still shows exactly 3 rows. Every exit row,
the routes row and the DNS row has its title in `Theme.textDisabled` and is not hoverable. Every switch is disabled,
and clicks send no PATCH. View half only: after the stand-in sets `writable`
true and `writeError` empty, they are live and the lines hidden. The backend
half does not claim that the shipped backend recovers.
After a close before headers, `writable` stays true and
`ts-settings-write-error` shows one line that contains the `writeError` text
and lacks `c7shell-bootstrap`. The switches stay enabled, and a click sends a
PATCH.

**Sources.** `tests/tailscale-qml-test.qml:802-803`,
`tests/tailscale-qml-test.qml:1088-1096`,
`tests/tailscale-qml-test.qml:1239-1281`,
`tests/tailscale-qml-test.qml:1342-1348`,
`tests/tailscale-qml-test.qml:1415-1485`,
`quickshell/c7shell/Modules/Popovers/TailscaleWriteNote.qml:4-41`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:85-104`,
`quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:195-200`,
`quickshell/c7shell/Modules/Popovers/TailscaleSettings.qml:32-70`,
`pr286-body:75-78`.

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
disables the switches, exactly one `ts-settings-routes-why` is still shown. A
routes click sends `{RouteAll:true, RouteAllSet:true}` and the switch waits for
the fake. When `acceptRoutes` becomes true the switch is checked, and a second
routes click asks for `false`. With `acceptDns` true the DNS switch is
checked, and a DNS click sends `{CorpDNS:false, CorpDNSSet:true}`. The DNS
switch is still checked after its own click, and is unchecked once `acceptDns`
becomes false.

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

**Sources.** `tests/tailscale-qml-test.qml:1515-1642`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:49-60`,
`quickshell/c7shell/Modules/Popovers/TailscalePopover.qml:236-335`.

### R-QML-23 · parity · This device's identity rows

**Statement.** While live, the root card shows "this device" with `selfName` as
plain text. A row titled `selfIp4` copies it on click. Right-clicking opens the
copy menu for `selfName`, `selfIp4`, `selfIp6` and `selfDnsName`. No QML reads
`tailnet`, `hostName` or `exitNodeOption`, which stay on the contract.

**Acceptance.** With Self `omega`, IPs `100.115.228.122` and
`fd7a:115c:a1e0::fd27:82d8`, and DNS name `omega.example-tailnet.ts.net.`:
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
`test-tailscale.sh` and prints the difference. An unreadable contract fails it
with a message. The Rust port reads the property list from the built module.
The stand-in gains every member listed under "Contract additions" in the same
change that adds it to the contract, so the comparison stays exact.

**Sources.** `tests/test-tailscale.sh:159-265`,
`tests/test-tailscale.sh:267-289`.

### R-QML-25 · parity · The stand-in behaves like the contract

**Statement.** The stand-in starts in `NoState` with `writable` true. Its
actions record calls and move no property. `state` is a QML enum with the six
values. `peers` and `exitNodes` are list models. An in-place edit, move,
insert or remove emits that row signal and no reset, as the real models do
(R-GROUP-06). A test can also rebuild them on purpose: clearing a model and
refilling it, as the harness's `seedPeers` does, discards every delegate. The
R-GROUP-06 control stages its rebuild that way. Like the contract, it derives `exitNodeBlocked` as `exitNodeActive`
and not `exitNodeOnline`, and `issueCount` as the length of `issues`; neither
is written by a test.

**Acceptance.** A fresh stand-in reads `state === Tailscale.NoState` and
`writable === true`. Each of the five actions records one call and changes no
property. With `exitNodeActive` true and `exitNodeOnline` false, the stand-in's
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

A SKIP never satisfies this criterion. The headless clause holds only when the
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

### R-QML-29 · parity · A row with no action behind it is drawn dead and says why

**Statement.** While the contract has no action for advertising this machine
as an exit node, the exit-node view still shows the row
`ts-exit-advertise`. It is drawn dead whatever `writable` reads: its title is in
`Theme.textDisabled`, its subtitle gives a non-empty reason, and activating it
asks the contract for nothing. A row wired to nothing would look like one
whose write is being refused. Once R-WRITE-10 adds the advertise action, that
requirement governs the row instead, and Phase 4 records the change as `new`.

**Acceptance.** On the QML stand-in with the #286 action set (R-UI-13, no
advertise action) and `writable` true, with the exit-node view open:
`ts-exit-advertise` is visible, its title colour equals `Theme.textDisabled`,
its subtitle is non-empty, and a click records no call. With `writable`
false the same four hold.

**Sources.** `quickshell/c7shell/Modules/Popovers/ExitNodeList.qml:314-333`,
`tests/tailscale-qml-test.qml:1177-1189`, `pr286-body:24`.

## R-SEC: untrusted input and isolation

R-WATCH-01 also belongs here: the watch always asks tailscaled to strip
private keys.

### R-SEC-01 · parity · No process, and nothing blocks

**Statement.** All Tailscale state is read and written over the local-API
socket. The system side never starts `tailscale` or any other process. It never
blocks the QML thread waiting on the socket.

**Acceptance.** A full backend scenario runs with recording stubs of
`tailscale` and `sh` first on `PATH`, built with the testing kit's fake
program: connect, one pass, a notification pass, every action, a 403 and a
reconnect. Both stubs record zero invocations. A source scan of the Tailscale
library and backend finds no `QProcess`, `std::process::Command`,
`posix_spawn`, `fork` or `exec*` call, and a selftest case proves the scan
catches a planted call. `tests/test-native-boundary.sh` is not this check: it
scans only QML. Nothing blocks: with paused time and a fake that holds every
request, the test calls the factory and then each action in turn. Each call
returns to the test while its request is still held, and at that point no
outcome for it has been delivered and paused time has not advanced. The test
then advances paused time past the deadline, and only then is each failure
delivered. A call that blocked on the socket could not return before the
deadline fired.

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
sets. A backend built there reads `NoState` with an empty `readError`. Each
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
error lines and the connect tooltip. The backend passes them through verbatim.
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
file only Tailscale uses: `Popovers/Tailscale*.qml`, `Popovers/ExitNodeList.qml`,
`Popovers/PeerRow.qml`, `Popovers/CopyMenu.qml` or `Common/SearchField.qml`.
No entry for a shared file, such as `Bar/StatusPill.qml`, names a Tailscale
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
client is installed, tailscaled answers, and its prefs carry no `OperatorUser`,
`c7shell-bootstrap` runs `tailscale set --operator=<user>` as root. `<user>` is
`id -un`, never `$USER`, which is root under sudo.

**Acceptance.** With a stub `tailscale` whose prefs lack `OperatorUser`, `id -un`
printing `tester` and `USER=root`, `--dry-run` prints `would run (root):
tailscale set --operator=tester` and never `operator=root`. A real run through a
stub sudo logs `sudo tailscale set --operator=tester`.

**Sources.** `bin/c7shell-bootstrap:549-555`,
`bin/c7shell-bootstrap:584-591`, `bin/c7shell-bootstrap:601-604`,
`tests/test-bootstrap.sh:397-436`, `tests/test-bootstrap.sh:449-454`,
`pr286-body:41-44`.

### R-BOOT-02 · parity · No client or no daemon: the step is silent

**Statement.** With no `tailscale` on `PATH`, or a failing `tailscale debug
prefs`, the bootstrap runs no operator step and says nothing about an operator.
This holds whether or not Tailscale is a package dependency.

**Acceptance.** With no client, `--dry-run` output contains neither `operator`
nor `naming the tailscale operator`. With `debug prefs` exiting 1, it contains no
`operator`.

**Sources.** `bin/c7shell-bootstrap:562-567`, `bin/c7shell-bootstrap:584`,
`tests/test-bootstrap.sh:386-395`, `tests/test-bootstrap.sh:421-424`,
`pr286-comments:3-7`, `pr286-comments:24-26`.

### R-BOOT-03 · parity · The operator is named after the services step

**Statement.** The operator step runs after system services are enabled. When
this real run enabled `tailscaled.service`, the bootstrap asks `debug prefs` up
to 20 times, 0.5 s apart. Otherwise, and always under `--dry-run`, it asks once.

If all 20 asks fail, the step is silent, as in R-BOOT-02: no operator step, no
warning and no closing note. The panel then comes up read-only at 403, and
nothing tells the user to run the script again. That is what is left of the
defect the reviewer named (`pr286-comments:13`). It is kept as parity here, and
open question 15 asks whether the rewrite adds a closing note.

**Acceptance.** `--dry-run` prints `== enabling system services` before `==
naming the tailscale operator`. With `sleep` stubbed and `debug prefs` failing k
< 20 times, a real run that enabled the unit names the operator after k + 1
asks. With the unit already enabled, it asks once. With `debug prefs` failing
every time, a real run that enabled the unit asks exactly 20 times, sleeps 19
times, prints no `naming the tailscale operator`, and its notes contain no
`operator`.

**Sources.** `bin/c7shell-bootstrap:536`, `bin/c7shell-bootstrap:557-583`,
`bin/c7shell-bootstrap:584`,
`tests/test-bootstrap.sh:438-447`, `pr286-comments:13-21`.

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
with a reply and returns how many it reached.

**Acceptance.** With one client connected, pushing `{"half":` returns 1 and the client
reads exactly those bytes. `1}\n` completes the line. With a hold on
`/status `, a GET is recorded and one is held. A push skips it, and completing
returns 1. A second match is not held unless re-armed.

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
only the held client yields one failure for `/status`. The watch gets no end,
a later pushed line still yields an event, and a new GET is answered. With a
held PATCH, closing it sets `writeError`, keeps `writable` true and leaves
`state` unchanged with no reconnect.

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

**Acceptance.** Each `tst_fakesocketserver.cpp` test listed for R-FAKE-06 in
the traceability tables is ported as one acceptance test with the same
assertions, using barriers instead of waits. Phase 2b of the rewrite plan
ports these tests; the plan lives in the main repository, not in the #286
checkout, so it is context and not a source.
The other fakes in the testing kit (the fake service, the private bus and the
fake program) are outside this document. Their own suites trace them.

**Sources.** `plugin/lib/testing/fakesocketserver.h:17-35`,
`plugin/lib/testing/fakesocketserver.cpp:32-88`,
`plugin/lib/testing/fakesocketserver.cpp:118-177`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:44-121`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:150-184`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:203-234`,
`plugin/lib/testing/tests/tst_fakesocketserver.cpp:271-285`.

## Contract additions

R-UI-02 and R-UI-13 check the contract surface against the #286 set plus the
members listed here. A row is added in the same change that adds the member to
the contract and to the QML stand-in (R-QML-24). Names stay pending until the
open question that owns them is answered.

| Member | Kind | Added by | Name and type |
|---|---|---|---|
| Login URL carrier | property or signal | R-UI-17, open question 1 | pending |
| Login action | invokable | R-UI-17, open question 1 | pending |
| Advertise-exit-node read-back | property | R-WRITE-10, open question 2 | pending |
| Advertise-exit-node action | invokable | R-WRITE-10, open question 2 | pending |
| Error body field, if separate | property | open question 3 | pending, may not exist |
| Unapplied-write property, if any | property | R-WRITE-08, open question 5 | pending, may not exist |
| Peers-known flag | boolean property of `Tailscale` or of the `peers` model | R-GROUP-11, open question 6 | pending |

## Open questions

Each question names the requirements it blocks or shapes.

1. **In-panel login flow** (plan, Decisions: "#286 non-goals"). Which local-API
   calls start an interactive login, and how does the browse-to URL reach QML?
   Is it a property or a signal? Who opens the browser without a QML process,
   and what stand-in records that opening in the QML harness?
   How is `NeedsMachineAuth` presented? Can the transport issue the request,
   when it only supports GET and PATCH today? R-UI-17's acceptance already
   fixes the observables (one non-read request, the URL on one new contract
   member, one interceptable open). The answer pins the exact bytes and names,
   and may replace Qt's external-URL opener only with an equally interceptable
   one. — R-UI-17, R-HTTP-02.
2. **AdvertiseRoutes privileges and IP forwarding** (plan, Decisions: "#286
   non-goals"). An exit node may need IP forwarding, which needs root. Is that
   the bootstrap's job or a runtime check, and how does the panel say so? How
   are existing subnet routes kept, when a masked write replaces the whole
   list? How is "awaiting admin approval" shown? What are the new property and
   action names? — R-WRITE-10, R-BOOT.
3. **Error body formatting.** Is the body shown raw, trimmed, or parsed from
   `{"error":…}`? What is the length cap? Is it a separate field or appended
   text? Whether the failure waits for the error body is already decided:
   R-HTTP-09's stalled-body case needs the 20 bytes that arrive after the
   headers, so the failure waits for the body, bounded by `Content-Length`,
   the zero chunk, the peer's close or the request deadline, whichever comes
   first. #286 fails at the headers and cannot meet that case. Whatever the
   answer, the status from accepted headers survives an incomplete body
   (R-HTTP-09). The answer pins N in R-HTTP-09's oversize case. — R-HTTP-09.
4. **Liveness probe design.** Which endpoint and interval? Does it live in
   the transport or the lifecycle layer, or the core crate? R-CONN-13 already
   fixes the observables (`NoState`, a non-empty `readError`, one retry), an
   upper bound of 60 000 ms, and no `/status` re-read. The design may only
   tighten the bound. Its requests are the ones R-WATCH-07 allows between
   notifications. Must the check also catch a watch stream that stalls while
   tailscaled still answers new requests? If yes, R-CONN-13 gains a case: the
   fake answers every request but delivers nothing on the watch while its
   state changes, and within the bound the change is published or a loss is
   reported. If no, that case is out of scope and recorded as such. —
   R-CONN-13, R-WATCH-07.
5. **Unapplied-write feedback.** Run a whole pass after every accepted write,
   or compare the PATCH reply's prefs body and pair it with a `/status`?
   Waiting for a notification alone cannot meet R-WRITE-08, because the
   value must match "even when no notification follows". R-WRITE-08 already
   fixes `writeError` as the carrier, 10 000 ms as the upper bound and a whole
   snapshot (R-WATCH-11). Is a dedicated property added beside it, and what
   does the write note say? With two writes in flight, does a later success
   still clear an earlier failure (R-WRITE-06)? Should a `writeError` from a
   non-2xx, timed-out or dropped write be reconciled when a later snapshot
   shows the value applied after all, where #286 keeps it until the next
   write outcome (R-WRITE-06)? — R-WRITE-08, R-WRITE-04, R-WRITE-06.
6. **Unknown peer set.** Is the "peers known" member a property of `Tailscale`
   or of the `peers` model, and what is its name? What does the panel show in
   that state? R-GROUP-11 already fixes the observables (one boolean member,
   false until a `/status` carries a Peer section; no `ts-peer-empty`, no
   `ts-peer-no-match` and no count of `0` while it is false). The answer pins
   the name and place and the panel's wording. — R-GROUP-11, R-QML-13.
7. **Combined read and write failure.** Which explanation wins, or what one
   merged sentence says both? R-UI-16 already fixes that exactly one Text
   carries either error; the answer pins its wording. — R-UI-16.
8. **Device count source.** A count or filter on the contract, such as a query
   property or a filtered proxy model, or a QML count over model roles? The
   ownership rule favours the plugin. — R-QML-15.
9. **Scrollbar and shared pill.** The scrollbar style is undesigned. Does the
   Settings pill or `Common/SearchField` become the shared component? —
   R-QML-16.
10. **Sort order across languages.** #286 compares per UTF-16 unit with Qt case
    folding. Does parity mean Qt's exact order, or only an ASCII guarantee? Pin
    it with a non-ASCII fixture. — R-GROUP-03.
11. **Accepted ISO-8601 forms.** Qt's ISO parser and an RFC 3339 parser accept
    different forms. Pin the accepted set with tailscaled's real output. —
    R-PARSE-04.
12. **Exposing the retry curve.** The reconnect hook exists only for tests.
    Should the Rust backend expose it as a Qt signal or as a test hook on the
    core crate? — R-CONN-07, R-CONN-08.
13. **Contract property list for the stand-in check.** The C++ check greps
    `Q_PROPERTY`. The Rust contract needs a machine-readable source, such as the
    built module's metaobject. — R-QML-24.
14. **Wording of `readError` for an unparsable status.** #286 reports only
    absent or present from the parser. Phase 2 pins the exact strings. —
    R-PARSE-01, R-CONN-04.
15. **The operator wait runs out.** When this run enabled `tailscaled.service`
    and all 20 `debug prefs` asks fail, the bootstrap says nothing, and the
    panel comes up read-only. Should it add a closing note telling the user
    to run the script again once tailscaled answers? — R-BOOT-03, R-BOOT-02.
16. **A `/prefs` that is not prefs.** #286 reads a non-object 2xx `/prefs` as
    defaults, which can silence `exitNodeBlocked` with no diagnosis
    (R-CONN-14). Should the rewrite treat it like R-CONN-04: a named
    `readError`, `NoState`, one retry and the last values kept? — R-CONN-14.
17. **Suggestion order.** A late suggestion outcome from an earlier pass
    overwrites a newer one (R-PARSE-11). Keep that, or never let an older
    pass's outcome replace a newer one? — R-PARSE-11.
18. **tailscaled's own error reports.** A notification's `ErrMessage` starts
    a pass and is then dropped (R-WATCH-09). Should its text be published,
    and where? If it is, a member is added under "Contract additions". —
    R-WATCH-09.
19. **A clean watch end before any snapshot.** It reads as "no Tailscale here"
    and hides the slot (R-CONN-15). Should a clean end from a present daemon
    carry a diagnosis? — R-CONN-15, R-QML-01.
20. **How `writable` recovers.** After a 403 the controls are dead, and only an
    accepted write sets `writable` true again, so the shipped panel stays
    read-only after the user fixes the operator (R-QML-20). Options include
    re-checking on reconnect or on a `Prefs` notification, or leaving one
    control live. — R-QML-20, R-WRITE-06.
21. **Header and watch-line size limits.** #286 caps neither the header
    buffer nor a watch line. A stream that never sends a newline grows the
    buffer and produces no event, while `state` stays `Running`. Should the
    rewrite cap both, and report an overflow as a named failure, which for the
    watch is a lost connection with a `readError`? #286 names no such defect,
    so no requirement exists until this is answered. — R-HTTP-04, R-WATCH-03,
    R-WATCH-05.
22. **An exit node without an ID.** In #286 an `ExitNodeStatus` with no `ID`
    gets an empty id, and its name is then taken from the first listed peer
    whose `nodeId` is also empty (R-PARSE-06 lists such peers), so the bar
    label and the blocked alert can name an unrelated device. Keep that join,
    or never join on an empty id? #286 names no such defect. R-PARSE-09 pins
    only the case with no empty-`nodeId` peer. — R-PARSE-09, R-QML-04,
    R-QML-08.
23. **An unrecognised BackendState.** #286 maps every unknown non-empty
    `BackendState`, such as the real `InUseOtherUser` or a state a future
    tailscaled adds, to `NoState` and publishes it as a whole, successful
    snapshot: `readError` empty, no retry, the watch open (R-WATCH-13). A
    present daemon then has no bar slot, or reads "no daemon" after an
    earlier `Running`. Should it carry a diagnosis, for example a `readError`
    naming the value, the way R-CONN-04 handles a missing one? #286 names no
    such defect. — R-WATCH-13, R-UI-04, R-QML-01, R-QML-05.
24. **The watch after a read loss.** In #286 a failed snapshot read leaves the
    watch open until the armed reconnect runs, so a notification during the
    retry delay, up to 30 s, starts a pass that can publish `Running` and
    clear `readError` before the reconnect tears it down (R-CONN-06). Keep
    that, drop the orphan's notifications, or stop the watch on any read
    loss? #286 names no such defect. — R-CONN-06, R-WATCH-10, R-CONN-03.
25. **Rows from an earlier session.** A status reporting `NeedsLogin`,
    `NeedsMachineAuth` or `Stopped` with no Peer section keeps the previous
    session's devices and exit nodes on the panel as if current (R-GROUP-12),
    and R-GROUP-11's peers-known flag stays true through it. Should such a
    status clear the rows, or should the views hide the device and exit lists
    outside `Running`? #286 names no such defect. — R-GROUP-10, R-GROUP-11,
    R-GROUP-12, R-QML-05, R-QML-09.
26. **Unreadable operator prefs.** The bootstrap finds `OperatorUser` with a
    line-oriented match that needs the key at the start of a line
    (`bin/c7shell-bootstrap:588`). If `tailscale debug prefs` exits 0 with
    another shape, such as one-line `{"OperatorUser":"other-user",
    "WantRunning":true}`, #286 finds no operator and runs `tailscale set
    --operator=<user>`, taking over another user's operator, which R-BOOT-05
    exists to prevent. Should the rewrite parse the prefs as JSON, and leave
    the operator alone with a warning when they cannot be read? #286 names no
    such defect, so no requirement pins the one-line case. — R-BOOT-01,
    R-BOOT-05.
27. **A Peer entry that is not an object.** #286 lists it as a row with
    every field empty (R-PARSE-07). Keep that, or drop the entry? #286 names
    no such defect. — R-PARSE-07, R-GROUP-08.

## Defects fixed by the rewrite

Each entry quotes the defect as #286 states it, then gives the corrected
behaviour.

- **R-CONN-13.** "No liveness check. A watch that connects and then goes silent
  is indistinguishable from a healthy quiet bus" (`pr286-body:109-113`).
  Corrected: an active check detects a silent daemon within 60 s at most and
  publishes `NoState` with a `readError`. A quiet but healthy bus stays
  `Running`.
- **R-WRITE-08.** "An accepted write that tailscaled does not apply produces no
  feedback at all" (`pr286-body:114-115`). Corrected: the backend confirms the
  daemon's value within 10 s at most and reports a change that did not take in
  `writeError`.
- **R-GROUP-11.** "A `/status` carrying `BackendState` and no `Peer` key makes
  the panel state 'no other devices on this tailnet'" (`pr286-body:116-118`).
  Corrected: the panel makes that claim only after a reply described an empty
  peer set.
- **R-HTTP-09.** "The HTTP error body is discarded where the contract promises
  'the words of whatever refused it'" (`pr286-body:119-120`). Corrected:
  `readError` and `writeError` carry the daemon's body text with the status.
- **R-QML-15.** "`deviceMatchCount` tallies instantiated delegates rather than
  matching rows" (`pr286-body:121-122`). Corrected: the count covers every
  matching row.
- **R-QML-16.** "Neither list has a scrollbar; `Common/SearchField.qml`
  duplicates the Settings sidebar pill" (`pr286-body:123-124`). Corrected:
  overflowing lists show a scroll indicator, and one search component serves
  both places.
- **R-UI-16.** "`readError` and `writeError` can now both be non-empty at once,
  which draws two explanations on one panel" (`pr286-body:125-126`). Corrected:
  exactly one Text on the panel carries either error.
- **R-FAKE-03.** "`FakeSocketServer` cannot close a single client on demand"
  (`pr286-body:127-129`). Corrected: the fake closes one chosen client while it
  keeps serving the rest.
- **R-WRITE-09.** "`tailscale down` is the one action here never exercised
  live" (`pr286-body:130-131`). Corrected: a fake-daemon test covers disconnect
  and reconnect end to end.
