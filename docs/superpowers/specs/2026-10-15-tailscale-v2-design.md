# Tailscale v2: the panel becomes a control

## Goal

The Tailscale module stops being a viewer. It names devices the way Tailscale
names them, it exposes the controls the macOS app exposes, and it changes
tailnet state instead of only reporting it.

Success criteria:

- Every device reads with the name the admin console shows, not its OS hostname.
- The connect toggle, exit-node selection, local network access, accept-routes
  and accept-DNS all work from the panel.
- A fresh install can do all of that without the user running anything by hand.
- `tests/test-native-boundary.sh` debt tables stay at 33 / 40 / 21.

## What v1 got wrong, measured

### Devices are named wrong — 6 of 20 on this tailnet

The panel binds `hostName`, which is the peer's **OS hostname**. Tailscale —
the admin console, the macOS app, MagicDNS — uses the **DNS label**. On the
reference tailnet they differ for six of twenty peers:

| `HostName` | DNS label |
|---|---|
| `ip-172-31-0-10` | `delta` |
| `localhost` | `phone-a` |
| `localhost` | `phone-b` |
| `WIN-7K2Q4X` | `gamma` |
| `EPSILON` | `epsilon` |
| `LAP-4F2A91` | `lap-4f2a91` |

This also retires a "finding" recorded during v1: the claim that two machines
saw different exit-node sets, logged as probable ACL filtering. They did not.
One node, `HostName ip-172-31-0-10` and DNS label `delta`, was being read
under two names by two different readers.

It also softens the duplicate-hostname problem that shaped `PeerModel`: both
iPhones answer to `localhost`, but their DNS labels are distinct. Rows still
key on `nodeId` — identity is not the display name — but the *display* stops
being ambiguous.

**Rule:** show the DNS label; fall back to `hostName` when MagicDNS is off or
`DNSName` is empty.

### The controls the mock drew and v1 dropped

The mock's exit-node panel carried `Allow Local Network Access` and `Use this
device as an exit node…`; both lists carried a search field. v1 shipped none
of them — the toggles because writes were believed impossible, the search
because the spec put it out of scope. Dropping local-network-access is the
worst of these: it is the one control that matters when an exit node is
blackholing the LAN, which is the failure this project hit on its own test VM.

## Writes are possible, and polkit is the wrong tool

v1's spec asserted that writes needed a `c7tailscale-root` helper and a polkit
action, on the evidence that `tailscale set` refuses. Measured, that is half
right and the conclusion was wrong.

NetworkManager ships `org.freedesktop.NetworkManager.policy` and delegates to
polkit, which grants the active local user network control — that is why wifi
and bluetooth toggle freely in this shell. **tailscaled ships zero polkit
actions.** It authorises by peer credentials: root, or one configured operator
user. There is no policy file to add, so a polkit helper would be a second,
parallel mechanism beside the one tailscale already provides.

Measured on a VM running this branch:

```
tailscale set / PATCH /localapi/v0/prefs   as the desktop user   -> 403
  "prefs write access denied" / "checkprefs access denied"

sudo tailscale set --operator=$USER        once, as root         -> exit 0
PATCH /localapi/v0/prefs                   as the desktop user   -> 200
  the change persists
```

**Rule:** `c7shell-bootstrap` sets the operator. That is tailscale's own
equivalent of NetworkManager's permissive policy, and the same trade the shell
already accepts for wifi: anything running as the desktop user can change
tailnet state without a prompt. The alternative — a polkit prompt per egress
change — stays available as a later option and is not this spec.

## What v2 adds

Three prefs drive everything new, all reachable through `PATCH /localapi/v0/prefs`:

| Pref | Panel control |
|---|---|
| `WantRunning` | the connect toggle in the header |
| `ExitNodeID` | exit-node selection, and `none` |
| `ExitNodeAllowLANAccess` | `allow local network access`, inside the exit-node view |
| `RouteAll` | `accept routes`, in settings |
| `CorpDNS` | `accept dns`, in settings |

`accept routes` is pointed: `RouteAll: false` is the pref behind the standing
health warning v1 suppresses. With it exposed, the warning becomes explicable
rather than hidden — the panel can say why it is suppressed and offer the
switch that changes it.

### Navigation

v1 replaces the panel contents and offers a `‹` to go back. v2 folds a
sub-card out of the main card, as the macOS app does. Both device and exit-node
views gain a search field, which is what makes a twenty-peer list usable and a
hundred-peer list possible at all.

## Out of scope

- A polkit helper and `c7tailscale-root`. See above: the operator is the
  mechanism tailscale provides.
- Running *this* device as an exit node. It was listed as in scope beside
  "advertising routes ... not", which contradicted itself: running as an exit
  node IS advertising a route (`0.0.0.0/0`, `::/0`) through `AdvertiseRoutes`.
  The panel shows the row disabled so the capability is visible and honestly
  marked, and no action is invented for it.
- Tailnet lock, Taildrop and Tailscale SSH.
- Per-peer latency. No endpoint carries it and the macOS app shows none.

## Constraints

- Writes are `PATCH /localapi/v0/prefs` with the `…Set` sibling field for each
  value changed. A 403 means the operator is not configured; the panel must say
  so rather than failing silently, and must not pretend the write succeeded.
- A write is optimistic in the UI only until the next notification: the bus is
  the authority, as it is for every other value.
- `plugin/lib/` stays Qt Core and Network. Contract actions are
  `Q_INVOKABLE virtual … = 0` on `TailscaleBackend`, per `docs/architecture.md`.
- v1's deferred residual lands here: the half-finished-pass skew needs a
  pass-generation token on `LocalApiClient::replied`, which v2's write path
  touches anyway.
- The repository is public. Fixtures stay redacted; the measured names above
  are illustrative and must not reach a committed fixture.
