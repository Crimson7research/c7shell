---
name: c7shell-plugin-layout
description: Use in the c7shell repo whenever you create, move, rename or split a C++ file under plugin/ — a new class, header, source, library, contract, backend, data type, test or CMake file — or decide which folder, file name, namespace or include path a piece of C++ gets. Also on casual asks — "where does this go", "add a class for X", "new file for the NetworkManager client", "split this file", "move this to core", "what should I call this header", "add a backend folder", "add a types struct for the D-Bus reply", "which namespace", "fix the include path". Places code in the plugin source tree (plugin/src/core, plugin/src/shell, plugin/src/types), names the file PascalCase.hpp/.cpp roots every include at plugin/src and keeps one CMake target per area. NOT for formatting or naming inside a file (c7shell-cpp-style), NOT for deciding QML versus C++ (c7shell-native-boundary runs first), and NOT for anything under quickshell/c7shell/, bin/ or hypr/.
---

# c7shell plugin layout

Announce first: **Using c7shell-plugin-layout to place this file.**

**Legacy C++ only.** `docs/architecture.md` makes the plugin Rust with no
hand-written C++. This skill applies only to C++ already on `main` until epic
#287 ports it. Never use it to create a new `.cpp`, `.h` or `.hpp` file.

Run `c7shell-native-boundary` first if it has not run for this change. It decides
whether code is C++ at all. This skill decides where the C++ goes.

## 1. Check which tree is live

Run `ls plugin/src/core plugin/lib 2>&1` and read the output.

- If `plugin/src/core/` exists, use the target tree in step 2.
- If only `plugin/lib/` exists, the move tracked in Jonohas/c7shell#243 has not
  landed. Use today's paths with the same roles: `plugin/lib/<area>/` is
  `core/<area>/`, and `plugin/src/contracts/` plus `plugin/src/backends/<area>/`
  are `shell/`. Do not create the target tree piecemeal: half a move breaks the
  `plugin/lib` check in `tests/test-c7-plugin.sh`.

## 2. Place each file

Write one line per new or moved file in your reply, before you create it:
`<path> → core | shell | types because <rule below>`. A file with no line is
unplaced; do not write it.

| Area | Path | Holds | May include |
| --- | --- | --- | --- |
| `core` | `plugin/src/core/<area>/` | Reusable plain C++ on Qt Core, Network and DBus: one client per external system, plus logger, settings, file and process helpers. Knows nothing of c7shell. | `core/`, `types/`, Qt, std |
| `shell` | `plugin/src/shell/contracts/`, `plugin/src/shell/backends/<area>/` | c7shell-specific code QML sees: contracts and their backends. | `shell/`, `core/`, `types/`, Qt QML |
| `types` | `plugin/src/types/<system>/` | Plain data shapes of an external protocol: a D-Bus struct, a Hyprland IPC reply. No behaviour beyond construction and comparison. | `types/`, Qt Core, std |

Decide with these questions, in order:

1. Does it describe data an external program sends or expects, and nothing else? → `types`.
2. Would another Qt program reuse it unchanged, with no QML and no c7shell name in it? → `core`.
3. Otherwise → `shell`.

[ACE LOGIC]
If a file is under `core/`, then it includes no file under `shell/` and no QML, Quick or Quickshell header.
If a file is under `types/`, then it includes no file under `core/` and no file under `shell/`.
If a file is a contract or a backend, then it is under `shell/`.

## 3. Name it

- One class per file pair: `PascalCase.hpp` and `PascalCase.cpp`, named after the class (`NmClient.hpp`, `NetworkBackend.hpp`).
- Folders are lowercase single words (`network`, `audio`, `hyprland`).
- A header-only type gets only the `.hpp`.
- The namespace follows the area: `C7` for shared code, `C7::<Area>` inside an area folder (`C7::Network`).
- Every project include is rooted at `plugin/src`: `#include "core/network/NmClient.hpp"`, never `"../NmClient.hpp"` and never a bare `"NmClient.hpp"` from another folder.

## 4. Mirror the test and wire CMake

- Put the test at the mirrored path under `plugin/tests/`: `plugin/src/core/network/NmClient.cpp` gets `plugin/tests/core/network/TstNmClient.cpp`.
- Each area is its own CMake target, so the build enforces the layering: `c7_types` is an `INTERFACE` library, `c7_core` is a static library linking `c7_types`, and the `c7` QML module links both. Never link `c7_core` or `c7_types` against the QML module or a Qt QML component.
- Add the new `.hpp` and `.cpp` to the target of the area the file sits in, listed explicitly. Do not add a `GLOB`.
- Put each new third-party dependency in its own `plugin/cmake/<dep>.cmake`, included from `plugin/CMakeLists.txt`.

## 5. Prove it

Run these and paste their output in your reply:

```bash
grep -rnE '#include "(\.\./|shell/)' plugin/src/core plugin/src/types
grep -rnE '#include <(Qt(Qml|Quick)|Quickshell)' plugin/src/core plugin/src/types
```

If step 1 found only `plugin/lib/`, run both against `plugin/lib` instead.
Both must print nothing. Then build the plugin and run `tests/test-c7-plugin.sh`.
If any of these reports a hit or a link error, move the file or the include before you continue.

Then apply `c7shell-cpp-style` to the file's contents.
