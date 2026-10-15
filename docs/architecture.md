# c7shell architecture: who owns what

c7shell runs as one Quickshell process (`qs -c c7shell`) with one QML engine.
Inside it, work splits into two sides:

| Side | Language | Owns |
|---|---|---|
| `C7` plugin (`plugin/`) | C++ | Every integration with something c7shell does not control, all state that comes from the system, everything that talks to the system, and pure logic |
| The shell (`quickshell/c7shell/`) | QML + JS | Interaction and presentation only: layout, bindings, signal handlers, animation, view state (open, hovered, selected, typing), display formatting, drag geometry |

QML knows "the person clicked here" or "the person hovers this". All it does
with that is bind to C7 state and dispatch a C7 action.

Qt and Quickshell's core are the framework underneath both sides: windows,
layer shell and the other Wayland surfaces (`Quickshell.Wayland`, including
`WlSessionLock` and `ScreencopyView`), `FileView`, `JsonAdapter` and
`IpcHandler`. They are not integrations, and replacing them is a rewrite, not a
swap. Quickshell's *integration* modules (`Quickshell.Services.*`,
`.Networking`, `.Bluetooth`, `.Hyprland`, `.DBusMenu`) are not the framework:
c7shell does not use them, because they limit what the shell can do and
c7shell cannot wait for them to grow.

## The rule

[ACE LOGIC]
Every integration has a contract.
An integration is external if c7shell does not control the program, the
service, the protocol or the library behind it.
Every contract is a C++ class in the C7 plugin.
Every backend is a C++ subclass of exactly one contract.
Every contract has exactly one C7 singleton, and the singleton is the selected
backend.
A QML file reads an integration only through its C7 singleton.
No QML file imports a Quickshell integration module.
No QML file starts a process.
A capability talks to the system if it calls D-Bus, reads sysfs or /proc,
parses the output of a program, writes a file that another program reads, or
serves a socket.
If a capability talks to the system, then a C7 backend owns the capability.
If a capability is pure logic and the logic does not decide how something
looks or how something responds to input, then the C7 plugin owns the logic.
If a capability decides how something looks or how something responds to
input, then QML or JavaScript owns the capability.
[/ACE LOGIC]

The contract holds even with one backend. PipeWire stays the audio backend,
and it still sits behind `AudioBackend`, so ALSA can replace it without the
UI noticing.

A program that is itself the product -- `grim`, `wf-recorder`, `hyprsunset`,
`xdg-open`, the terminal, `c7up`, `pkexec c7power-root` -- is still an
integration: a C7 backend starts it with an async `QProcess`. A privilege
boundary always stays a separate process.

## How an integration looks: the network example

Today's `Services/NetworkService.qml` is the shape to avoid. It parses `ip` and
`nmcli` output on a 3-second timer, publishes a frozen list of SSIDs because a
JS array of network objects can crash a Repeater, and keeps the "which row is
typing a password" state in the service to hold that freeze. Every one of
those is QML working around a missing C++ layer.

The same feature, as it should be:

```
UI (WifiPopover, WifiPage, PskField, StatusPill)
   │  binds Network.*, calls Network.connect(ssid) on click
   ▼
C7 singleton  Network  ──is a──▶  NetworkBackend   (contract)
                                     ▲
                                     │ subclass
                        NmNetworkBackend   (QtDBus → org.freedesktop.NetworkManager)
```

**The contract** (`plugin/src/contracts/NetworkBackend.h`) is an abstract
`QObject`:

```cpp
class NetworkBackend : public QObject {
  Q_OBJECT
  QML_NAMED_ELEMENT(Network)
  QML_SINGLETON
  Q_PROPERTY(bool wifiEnabled READ wifiEnabled NOTIFY wifiEnabledChanged)
  Q_PROPERTY(Link primary READ primary NOTIFY primaryChanged)
  Q_PROPERTY(QString ip READ ip NOTIFY ipChanged)
  Q_PROPERTY(QString gateway READ gateway NOTIFY gatewayChanged)
  Q_PROPERTY(Metered metered READ metered NOTIFY meteredChanged)
  Q_PROPERTY(QAbstractItemModel *networks READ networks CONSTANT)
public:
  enum class Link { None, Wifi, Ethernet };  Q_ENUM(Link)
  enum class ConnectResult { Started, NeedsKey };  Q_ENUM(ConnectResult)
  enum class Metered { Unknown, Yes, No };  Q_ENUM(Metered)

  Q_INVOKABLE virtual void setWifiEnabled(bool on) = 0;
  Q_INVOKABLE virtual void requestScan(bool on) = 0;
  Q_INVOKABLE virtual ConnectResult connect(const QString &ssid) = 0;
  Q_INVOKABLE virtual void connectWithPsk(const QString &ssid, const QString &psk) = 0;
  Q_INVOKABLE virtual void forget(const QString &ssid) = 0;
  Q_INVOKABLE virtual void setMetered(Metered choice) = 0;

  // The singleton factory picks the backend. A configurable choice comes only
  // when a second backend exists.
  static NetworkBackend *create(QQmlEngine *, QJSEngine *);
  // ...
};
```

**The backend** (`plugin/src/backends/network/NmNetworkBackend.cpp`) talks to
NetworkManager over D-Bus and nothing else. Devices, access points, IPv4
config and `Metered` all arrive as `PropertiesChanged` signals, so nothing
polls and nothing spawns.

**Collections are list models with stable rows.** `networks` is a
`QAbstractListModel` keyed by SSID, with roles such as `ssid`, `strength`,
`security`, `known`, `connected` and `needsKey`. A model updates rows in place,
so a list view never rebuilds the row someone is typing a password into. That
deletes `otherNames`, `byName()` and `pskTarget` instead of porting them.

**The UI** keeps only interaction and presentation:

```qml
// WifiPopover.qml
onOpenChanged: Network.requestScan(open)

ListView {
  model: Network.networks
  delegate: ListRow {
    title: ssid
    subtitle: securityLabel(security)          // display formatting stays in JS
    onClicked: if (Network.connect(ssid) === Network.NeedsKey) psk.ask()
  }
}
```

## The contracts

| Contract (C7 singleton) | C++ backend talks to |
|---|---|
| `AudioBackend` (`Audio`) | PipeWire (`libpipewire`) |
| `BatteryBackend` (`Battery`) | UPower over D-Bus |
| `MediaBackend` (`Media`) | MPRIS over D-Bus |
| `BluetoothBackend` (`Bluetooth`) | BlueZ over D-Bus |
| `NetworkBackend` (`Network`) | NetworkManager over D-Bus |
| `TailscaleBackend` (`Tailscale`) | tailscaled's local API socket |
| `RadioBackend` (`Radio`) | `/dev/rfkill` (airplane mode) |
| `CompositorBackend` (`Compositor`) | Hyprland's request and event sockets |
| `NotificationsBackend` (`Notifications`) | owns `org.freedesktop.Notifications` |
| `TrayBackend` (`Tray`) | StatusNotifierWatcher/Item + dbusmenu |
| `AppMenuBackend` (`AppMenu`) | owns `com.canonical.AppMenu.Registrar` + dbusmenu |
| `AuthBackend` (`Auth`) | `libpolkit-agent-1` + the askpass socket |
| `PowerProfileBackend` (`PowerProfile`) | tuned over D-Bus |
| `BrightnessBackend` (`Brightness`) | sysfs backlight, logind, `libddcutil` |
| `FingerprintBackend` (`Fingerprint`) | fprintd over D-Bus |
| `SessionBackend` (`Session`) | logind and systemd over D-Bus |
| `NightLightBackend` (`NightLight`) | hyprsunset |
| `CaptureBackend`, `RecordingBackend` | the capture surface, wf-recorder |
| `UpdatesBackend` (`Updates`) | `c7up` |
| `IdleBackend`, `WallpaperBackend` | hypridle, hyprpaper |
| `AppsBackend` (`Apps`) | desktop entries |
| `TerminalBackend`, `ClipboardBackend` | kitty, wl-clipboard |

## Why

- **Swappable integrations.** The UI depends on a contract c7shell owns, never
  on a program or library it does not. Replacing a backend touches one
  directory in `plugin/src/backends/`.
- **Not limited by upstream.** Quickshell's integration modules expose what
  they expose; NetworkManager's gateway and metered flag, tuned's profiles and
  a polkit agent with fingerprint and password at once are all out of reach
  through them. Owning the C++ removes the ceiling.
- **One runtime.** Every helper process is another interpreter, another event
  loop and another protocol to keep in sync. The plugin runs on the Qt event
  loop `qs` already has.
- **Typed state.** `Q_PROPERTY`s with change signals and list models with
  stable rows, instead of state re-derived from command output and JS arrays.

## Rules for the C7 plugin

- **C++ with Qt 6, and nothing else.** No Rust, no Python, no second runtime.
  Qt is a C++ framework, the contracts are QObjects QML binds to directly, and
  the Wayland and polkit pieces need C++ regardless.
- **Two layers.** A library in `plugin/lib/<name>/` is plain C++ (Qt Core,
  Qt Network, Qt DBus) that talks to one external thing: Hyprland's sockets,
  NetworkManager, PipeWire. It includes no QML header and no Quickshell
  header, and it has its own tests. A contract in `plugin/src/contracts/` and
  its backend in `plugin/src/backends/<area>/` adapt a library to the QML
  singleton the UI binds to. A library can be tested and reused without QML.
- **The plugin never depends on Quickshell**, so the same plugin loads under
  `qs` today and under our own host later.
- **Quickshell is read, never copied.** Quickshell is LGPL-3.0-only and
  c7shell is MIT. You may read Quickshell to see how it solves a problem. You
  never copy, translate or paraphrase its code, and every PR that touches
  `plugin/` states "No Quickshell code copied or adapted."
- One QML module, URI `C7`, built from `plugin/` with CMake and
  `qt_add_qml_module`. It installs to `/usr/lib/qt6/qml/C7/`.
- A contract is an abstract class: state as read-only `Q_PROPERTY`s with
  `NOTIFY`, actions as pure-virtual `Q_INVOKABLE` methods, collections as
  `QAbstractListModel`s with stable rows. It is registered as a
  `QML_SINGLETON` whose `create()` returns the selected backend.
- Never block the GUI thread: async D-Bus (`QDBusPendingCallWatcher`), async
  `QProcess`, no `waitFor*`. Prefer signals to polling.
- Use only public Qt API, so an Arch Qt update needs a rebuild, not a port.
- **Test first.** Every PR adds the failing test before the code that passes
  it, and the commit order shows that.
- **Tests run against fakes of the outside world, never of our own code.**
  `plugin/lib/testing/` starts a private `dbus-daemon`, a fake Unix socket
  server or a fake process per test. Tests use the library's public API only,
  never sleep, never read the wall clock and never touch the host's buses,
  sockets or `$XDG_RUNTIME_DIR`. A refactor that keeps the behaviour keeps the
  tests green.
- **Every contract ships a fake backend** for QML-side tests. It is built into
  tests only, never into the installed module.
- **Gates.** 90% line and 80% branch coverage on libraries and backends, at
  least 70% of mutants killed, and every new or changed test passes 50
  consecutive runs. The gates run in GitHub Actions and locally.
- **Review.** Three review agents (code reviewer, test analyzer, silent-failure
  hunter) approve every PR before it is merged.
- Errors surface as properties or signals the UI can show.
- Secrets (polkit, askpass, PSKs) are never logged, never put in argv, and
  dropped after use.

## Rules for QML and JavaScript

- QML binds to C7 singletons and calls their actions. It does not import a
  Quickshell integration module and does not start a process.
- Every `.js` file starts with `.pragma library`, is stateless, and holds only
  presentation logic (formatting, geometry, colour maths).
- `Services/*.qml` keeps only shell-internal state that no integration owns:
  which popover is open, the OSD queue, the shell's own preferences.

## Where things live

```
plugin/                     C++ QML module "C7"
  lib/<name>/               one plain C++ library per external thing, + tests/
  lib/testing/              per-test fakes: private D-Bus, sockets, processes
  src/contracts/            one abstract contract per integration
  src/backends/<area>/      the backends that implement them
  src/                      other C7 types (files, generated configs, logic)
  tests/                    QtTest for contracts and backends
quickshell/c7shell/         the shell config, copied to ~/.config by c7shell-setup
  Common/                   shared components and .pragma library JS
  Services/                 shell-internal state only
  Modules/                  the UI, one directory per surface
bin/                        install and maintenance tools (not shell runtime)
tests/                      test-*.sh, run by PKGBUILD check()
```

`docs/diagrams/current.png` and `target.png` draw today's integrations and the
target, with their Graphviz sources next to them.

Code that predates this rule is listed in the `debt` tables of
`tests/test-native-boundary.sh`, and `tests/test-native-boundary-selftest.sh`
proves the check catches each kind of violation. Each entry leaves its table when its
migration lands, and the test fails on an entry that no longer matches, so the
tables only shrink.
