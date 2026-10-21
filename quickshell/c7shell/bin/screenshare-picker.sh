#!/bin/sh
# xdph screencopy:custom_picker_binary. The QML picker cannot own stdout
# (the qs launcher's own INFO banner and Qt logging pollute it), so it
# writes the selection to a temp file and this wrapper relays the single
# line xdph parses.
out=$(mktemp)
XDPH_OUT="$out" qs -p "$HOME/.config/quickshell/c7shell/sharepicker.qml" >&2
cat "$out"
rm -f "$out"
