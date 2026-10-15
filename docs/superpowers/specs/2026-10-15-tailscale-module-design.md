# Tailscale: a C7 backend and a bar module

## Goal

c7shell says, at a glance, whether this machine is on the tailnet and where its
traffic leaves from, and the one failure that silently stops all egress —
an exit node that has gone away — is visible the moment it happens.

Success criteria:

- The bar carries a Tailscale slot whose appearance alone distinguishes
  connected, not connected, has-issues, routing through an exit node, and
  exit-node-unreachable.
- The popover shows this device, its peers grouped as the Tailscale apps group
  them, and the available exit nodes.
- Clicking a device copies its tailnet IPv4; right-clicking offers IPv6 and the
  MagicDNS name.
- `tests/test-c7-plugin.sh` and `tests/test-native-boundary.sh` pass, and
  neither the spawner nor the import debt table grows.

## Why a C++ backend and not a QML service

`docs/architecture.md` decides this, not taste:

> If a capability talks to the system, then a C7 backend owns the capability.
> No QML file starts a process.

`tests/test-native-boundary.sh` enforces it with a ratchet whose spawner check
has **no `allowed` table at all** — every QML spawner is debt, and the header
says the tables only shrink. A `TailscaleService.qml` would be a new debt entry
in the direction the repo is moving away from. `docs/architecture.md` names
`Services/NetworkService.qml` as "the shape to avoid"; that file is the one a
QML Tailscale service would be modelled on.

This is the **first backend in the plugin**. `plugin/src/` contains only
`build.h`; `contracts/` and `backends/` do not exist. The 21 rows in the
architecture document's contracts table are all unimplemented, and every one of
them replaces an existing QML service. Tailscale is the first that was never a
QML service, so it cannot be validated by diffing against old behaviour — which
is a reason to keep the contract commit separate from the UI commits so they
can be reviewed independently.

## The data, as measured

All three endpoints answer **HTTP 200 unprivileged** over
`/var/run/tailscale/tailscaled.sock` (mode `srw-rw-rw-`), verified on
`c7-test-2`. No process is spawned and nothing polls.

| Endpoint | Carries |
|---|---|
| `GET /localapi/v0/status` | peers, health, exit node, self |
| `GET /localapi/v0/prefs` | `WantRunning`, `ExitNodeID`, `ExitNodeAllowLANAccess`, `RouteAll` |
| `GET /localapi/v0/suggest-exit-node` | the "Recommended" row: `{"ID":…,"Name":…}` — 73 bytes, no metric |
| `GET /localapi/v0/watch-ipn-bus?mask=1` | a newline-delimited stream of change notifications |

`watch-ipn-bus` is the reason nothing polls: it is Tailscale's equivalent of
NetworkManager's `PropertiesChanged`, so the backend is event-driven exactly as
`NmNetworkBackend` is in the architecture document.

### `ExitNodeStatus`, captured live

Captured on `c7-test-2` with `pentest-exit-node` actually selected, because
every earlier reading was `null` and the shape could not be guessed:

```json
{"ID":"nWqTQFdqb121CNTRL","Online":true,
 "TailscaleIPs":["100.111.18.72/32","fd7a:115c:a1e0::5101:1248/128"]}
```

Three consequences, each of which would otherwise be a bug:

- **There is no hostname in it.** The name shown in the alert must be joined:
  `ExitNodeStatus.ID` → the matching `Peer[].ID`. Binding to the struct alone
  produces a panel that names a node ID.
- **The IPs carry `/32` and `/128` masks**, while the peer's own `TailscaleIPs`
  are bare. They will not compare equal without stripping the prefix.
- **`ExitNodeStatus.Online` is the blocked flag.** Not peer `Online`, and not
  `Active` — the selected peer read `Active: false, CurAddr: ""` while healthy.

### Peer grouping

Tailscale assigns every tagged node to one synthetic user, so the three sections
the apps show are a plain group-by on `UserID` with no special casing:

```
User[peer.UserID].LoginName == "tagged-devices"  → Tagged Devices
peer.UserID == Self.UserID                       → My Devices
otherwise                                        → Other Users (owner = DisplayName)
```

Section labels are the shipping app's own strings (`myDevicesSectionTitle`,
`td_taggedDevicesHeader`, `td_OtherUsers`). On `c7-test-2` this is 10 / 8 / 2.

Hostnames are **not unique** — `C7-LAP-G1157C6M` and `localhost` each appear
twice on this tailnet — so a row without its IP is ambiguous. Rows key on
`NodeID`.

### State

The macOS app's menu renders one of eight named states as a subtitle under a
fixed title; that is the vocabulary to reproduce, not "running or not":

`Tailscale is starting…` · `Waiting for Network…` · `Log In…` ·
`Login Required` · `Waiting for Admin Approval…` · `Waiting for Admin Signing…` ·
`Not Connected` · `Connected`

### Icon states

`Assets.car` in Tailscale.app 1.104.1 ships exactly six status-bar icons plus a
16-frame spinner: `StatusBarIcon`, `…Dimmed`, `…ErrorOnline`, `…ErrorOffline`,
`…DefaultRouterOnline`, `…DefaultRouterOffline`, `…Dot1`–`Dot16`. Error is an
orthogonal modifier rather than a state of its own. The slot is therefore
**permanently visible** — an absent icon cannot distinguish "fine" from
"tailscaled is dead".

## Health, and the one warning this machine always has

`c7-test-2` reports, permanently:

```
"Some peers are advertising routes but --accept-routes is false"
```

That is the deliberate configuration that stops the VM's advertised subnet
routes from blackholing the laptop's own LAN. Surfaced naively, the module
warns forever on the only machine it runs on, so health needs a suppression
list with this message in it by default. The macOS app has no equivalent
because it has no equivalent of this deliberate `RouteAll: false`.

## Out of scope

- **Writes.** `tailscale set` refuses as a non-root, non-operator user, so
  changing the exit node, toggling `WantRunning` or `ExitNodeAllowLANAccess`
  needs a `c7tailscale-root` helper and a third polkit action, built to the
  shape of `bin/c7power-root`. That is a separate spec and a separate plan.
  v1 is read-only; the mock's toggles render disabled.
- **Latency.** No endpoint carries per-peer RTT, and the real menu shows no
  numbers. `suggest-exit-node` is a server answer, not a measurement.
- **`PrimaryRoutes`, `Tags`, `CurAddr`/`Relay`.** Present and useful — the
  Proxmox fleet advertises four /18s — but absent from the Tailscale apps, so
  out of a module scoped to their equivalent.
- **Taildrop, Tailscale SSH, Services, the exit-node search field.**

## Constraints

- **The repository is public** (`Crimson7research/c7shell`). Captured JSON
  contains colleagues' login names, node public keys, internal RFC1918 ranges
  and an AWS hostname. Every fixture committed must be redacted: structure and
  field shapes preserved exactly, identifiers replaced.
- `plugin/lib/` may not include a QML, Quick or Quickshell header, link a QML
  or Quick target, or declare a QML module — `tests/test-c7-plugin.sh` check 2
  enforces it. Parsing and the socket client live there; only
  `plugin/src/` knows about QML.
- Every plugin test uses `C7_TEST_MAIN` (check 2b), which cuts it off from the
  host's buses, sockets and directories. No test may read the real
  `tailscaled.sock`.
- The socket path is `${TS_SOCKET:-/var/run/tailscale/tailscaled.sock}`, so
  tests point it at a `FakeSocketServer`.
- The visual reference is `docs/tailscale-mock.html`, built against
  `palette.json` and `Theme.qml`.
