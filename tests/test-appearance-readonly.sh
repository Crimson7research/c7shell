#!/usr/bin/env bash
# AppearanceStore's read-only mode. Run it directly: tests/test-appearance-readonly.sh
#
# The screenshare picker runs as its own qs instance and reads Theme, which
# pulls in AppearanceStore (#95). Loaded normally, that store re-applies the
# look-and-feel through `hyprctl eval`, reruns the desktop exporter (kdeglobals,
# GSettings, a repaint of every KDE app), re-sends the wallpaper and writes
# appearance.json -- every time someone shares their screen. With
# C7SHELL_APPEARANCE_READONLY=1 it only reads.
#
# The real Services/AppearanceStore.qml runs here under plain qml6 against
# stand-ins for the Quickshell types it names. The stand-ins start nothing and
# write nothing: they record what the store asked for, and the test asserts on
# that record. The same store runs twice, with and without the flag, so a guard
# that also silences the shell itself fails here too.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
mktmp
need_qml6

mkdir -p "$tmp/qs/Services" "$tmp/Quickshell/Io"
cp "$src/Services/AppearanceStore.qml" "$tmp/qs/Services/"
"$src/../../tools/gen-palette-qml.py" "$src/palette.json" "$tmp/qs/Services/PaletteStore.qml"
printf 'module qs.Services\nsingleton AppearanceStore 1.0 AppearanceStore.qml\nsingleton PaletteStore 1.0 PaletteStore.qml\n' \
  > "$tmp/qs/Services/qmldir"

# -- Quickshell stand-ins ----------------------------------------------------
# Quickshell.env reads --env=KEY=VALUE from qml6's own arguments, which is how
# each run below sets the flag before the singleton exists.
printf 'import QtQuick\nItem {}\n' > "$tmp/Quickshell/Singleton.qml"
cat > "$tmp/Quickshell/Quickshell.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  function env(key) {
    const hit = Qt.application.arguments.find(a => a.startsWith(`--env=${key}=`))
    return hit === undefined ? undefined : hit.slice(`--env=${key}=`.length)
  }
}
QML
# Every side effect the store can ask for lands here.
cat > "$tmp/Quickshell/Recorder.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property var calls: []
  property var file: null
  function log(what) { calls = calls.concat([what]) }
}
QML
printf 'module Quickshell\nSingleton 1.0 Singleton.qml\nsingleton Quickshell 1.0 Quickshell.qml\nsingleton Recorder 1.0 Recorder.qml\n' \
  > "$tmp/Quickshell/qmldir"

# A file that is there: FileView reports loaded once it exists, as the real one
# does on a normal start.
cat > "$tmp/Quickshell/Io/FileView.qml" <<'QML'
import QtQuick
import Quickshell
Item {
  property string path: ""
  property bool watchChanges: false
  property bool printErrors: true
  signal fileChanged()
  signal adapterUpdated()
  signal loaded()
  signal loadFailed(int err)
  function reload() {}
  function text() { return "" }
  function writeAdapter() { Recorder.log("write appearance.json") }
  Component.onCompleted: { Recorder.file = this; loaded() }
}
QML
printf 'import QtQuick\nQtObject {}\n' > "$tmp/Quickshell/Io/JsonAdapter.qml"
printf 'import QtQuick\nQtObject { enum Error { Success, Unknown, FileNotFound, PermissionDenied, NotAFile } }\n' \
  > "$tmp/Quickshell/Io/FileViewError.qml"
cat > "$tmp/Quickshell/Io/Process.qml" <<'QML'
import QtQuick
import Quickshell
Item {
  property bool running: false
  property var stdout: null
  property var stderr: null
  signal exited(int exitCode, int exitStatus)
  function exec(argv) { Recorder.log(argv.slice(0, 3).join(" ")) }
}
QML
printf 'import QtQuick\nItem { property string text: ""\n  signal streamFinished() }\n' \
  > "$tmp/Quickshell/Io/StdioCollector.qml"
printf 'module Quickshell.Io\nFileView 1.0 FileView.qml\nJsonAdapter 1.0 JsonAdapter.qml\nFileViewError 1.0 FileViewError.qml\nProcess 1.0 Process.qml\nStdioCollector 1.0 StdioCollector.qml\n' \
  > "$tmp/Quickshell/Io/qmldir"

# run <name> [qml6 args...]: prints what the store asked for, one per line.
run() {
  local name=$1 log=$tmp/$1.log; shift
  QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 \
    timeout 30 qml6 -I "$tmp" "$here/appearance-readonly-qml-test.qml" -- "$@" >"$log" 2>&1 \
    || fail "qml6 exited non-zero ($name):\n$(cat "$log")"
  grep -q 'APPEARANCE-TEST-DONE' "$log" || fail "the $name run never reached its end:\n$(cat "$log")"
  if grep -q '\.qml:' "$log"; then fail "QML diagnostics ($name):\n$(grep '\.qml:' "$log")"; fi
  sed -n 's/^.*CALL: //p' "$log"
}

# The shell itself: it must still apply, export, push the wallpaper and persist.
# Each write is checked right after the event that asks for it -- the QML test
# logs a mark first -- so losing either write path fails on its own.
shell=$(run shell)
for want in 'hyprctl eval' 'python3 ' 'hyprctl hyprpaper wallpaper'; do
  grep -qF "$want" <<<"$shell" \
    || fail "the shell's own AppearanceStore no longer does \"$want\":\n$shell"
done
for event in adapterUpdated loadFailed; do
  grep -A1 -xF "mark: $event" <<<"$shell" | grep -qxF 'write appearance.json' \
    || fail "the shell's own AppearanceStore no longer writes appearance.json on $event:\n$shell"
done

# The picker's: it reads, and asks for nothing.
picker=$(run picker --env=C7SHELL_APPEARANCE_READONLY=1 | grep -v '^mark: ' || true)
[[ -z $picker ]] || fail "a read-only AppearanceStore still has side effects:\n$picker"

echo 'PASS: AppearanceStore read-only mode'
