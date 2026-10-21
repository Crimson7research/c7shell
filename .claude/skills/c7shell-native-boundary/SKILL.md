---
name: c7shell-native-boundary
description: Use in the c7shell repo before writing or changing code that decides where logic lives or touches anything external — adding or editing a Services/*.qml singleton, a contract in plugin/src/contracts, a backend in plugin/src/backends, an import of Quickshell.Services.*, Quickshell.Hyprland, Quickshell.Bluetooth or Quickshell.Networking, a Process {} block, Quickshell.execDetached, exec([...]), a Timer that polls, D-Bus access (gdbus, busctl, dbus-send), nmcli/ip/systemctl/rfkill/hyprctl calls, sh -c, reading sysfs or /proc, parsing command output, writing a config file another program reads, a python helper, a JS array of objects used as a model, or a large function in a .js file. Also on casual asks — "add a service for X", "read the battery/brightness/network from…", "call this D-Bus method", "shell out to…", "poll every N seconds", "move this to C++", "move this to Rust", "add a type to the plugin", "support ALSA / another backend", "swap X for Y", "wrap pipewire/hyprland", "add a backend", "why does test-native-boundary fail". Decides QML/JS vs the C7 Rust plugin, puts every integration behind a cxx-qt contract and a Rust backend, and says how to add both. NOT for pure layout, styling, animation or copy changes in Modules/, and NOT for bin/ install tooling.
---

# c7shell native boundary

Announce first: **Using c7shell-native-boundary to place this code.**

## 1. Read the rule

Read `docs/architecture.md` with the Read tool now, including the network
example. Do not decide from memory: the rule and the contract shape live there
and only there.

## 2. Classify, and write the verdict down

For each piece of the change, state one line in your reply:
`<what> → <C7 contract/backend | C7 other type | QML/JS> because <rule from architecture.md>`.

For anything that touches a program, service, protocol or library c7shell does
not control, also name its contract from the table in `docs/architecture.md`,
or the new contract you are adding. "Quickshell already has a module for it"
is not a reason to use that module: integration modules are off limits in
QML, and the backend is Rust against the system API itself.

## 3. Act on the verdict

- **Integration:** the system client is a plain Rust crate in
  `plugin/lib/<name>/` (no Qt, no cxx-qt, no QML or Quickshell crate),
  written test first against fakes from `plugin/lib/testing/`. Read
  Quickshell for ideas if useful; never copy, translate or paraphrase it.
  Then add or extend the cxx-qt contract in `plugin/src/contracts/`
  (read-only `#[qproperty]`s with `NOTIFY`, `#[qinvokable]` actions,
  `#[base = QAbstractListModel]` models with stable rows for collections,
  a `#[qml_singleton]` that delegates to the backend behind the contract's
  trait). Implement the trait in `plugin/src/backends/<area>/` with async
  I/O on the plugin's tokio runtime only, and add a Rust-driven headless QML
  test. Ship a fake backend for the contract, built into tests only and
  never into the installed module. Never write a `.cpp`, `.h` or `.hpp`
  file. Until epic #287 lands the cxx-qt plugin crate, a new contract
  waits for it. QML binds to the singleton and calls its
  actions; it never imports the integration module or starts the process.
- **Other C7 type** (file operations, generated configs, pure logic): add it
  under `plugin/src/` in Rust, with a Rust test.
- **QML/JS:** interaction and presentation only. A new `.js` file starts with
  `.pragma library`.

Never add an entry to any `debt` table in `tests/test-native-boundary.sh`. If
your change removes a debt use, delete its line in the same change.

## 4. Prove it

Run `tests/test-native-boundary.sh` and paste its three `PASS` lines. If you
touched `plugin/`, also paste the plugin test run's summary line. Done means
both are in your reply.
