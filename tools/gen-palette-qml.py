#!/usr/bin/env python3
"""Compile quickshell/c7shell/palette.json into a QML singleton.

The shell itself does not need this: Quickshell has FileView, so
Services/PaletteStore.qml reads the JSON directly and a change takes effect on the
next start. Two consumers cannot.

  - The login greeter is plain QtQuick. It has no FileView, and QML's
    XMLHttpRequest refuses to read a local file unless QML_XHR_ALLOW_FILE_READ
    is set in the environment -- which only the greetd config sets, and a file
    read that depends on a line in /etc is one more way for the login screen to
    come up wrong. Its PaletteStore.qml is
    therefore generated and committed, and tests/test-greeter.sh fails if it has
    gone stale. A login screen is the last place to put a file read that can
    fail.
  - The qml6 component tests, whose Theme stand-in has the same problem and no
    reason to solve it differently. tests/fixtures/theme-stub.sh generates one
    into the temporary import path on every run, so it is never stale.

JSON is valid JavaScript, so the values go in verbatim as an object literal;
the `_`-prefixed keys palette.json documents itself with are dropped.

  tools/gen-palette-qml.py <palette.json> <output.qml>
"""

import json
import sys


def strip_prose(node):
    """The `_comment` / `_thing` keys are for whoever edits palette.json."""
    if isinstance(node, dict):
        return {k: strip_prose(v) for k, v in node.items() if not k.startswith("_")}
    if isinstance(node, list):
        return [strip_prose(v) for v in node]
    return node


def render(doc, source):
    body = {k: strip_prose(v) for k, v in doc.items() if not k.startswith("_")}
    parts = [
        "pragma Singleton\n",
        "import QtQuick\n",
        "\n",
        f"// GENERATED from {source} by tools/gen-palette-qml.py -- do not edit.\n",
        "// Regenerate after changing the palette; tests/test-greeter.sh fails on a\n",
        "// copy that has fallen behind.\n",
        "QtObject {\n",
    ]
    for name in ("palette", "defaults"):
        # Parenthesised: a bare { in a QML binding is a block, not an object.
        value = json.dumps(body.get(name, {}), indent=2, ensure_ascii=False)
        value = "\n".join(
            ("    " + line if i else line) for i, line in enumerate(value.splitlines()))
        parts.append(f"  readonly property var {name}: ({value})\n")
    parts.append("}\n")
    return "".join(parts)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip().splitlines()[-1].strip())
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        doc = json.load(f)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(render(doc, "quickshell/c7shell/palette.json"))


if __name__ == "__main__":
    main()
