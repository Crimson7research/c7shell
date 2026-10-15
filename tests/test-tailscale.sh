#!/usr/bin/env bash
# Self-check for the bar's Tailscale slot. Run it directly: tests/test-tailscale.sh
#
# Same trick as tests/test-wifi.sh: the slot is plain QtQuick bindings over one
# singleton's properties, so the Quickshell types StatusPill reaches for are
# shimmed, C7.Tailscale is stood in by a QML singleton the test writes to, and
# the rule under test -- what the slot wears in each of the six states the
# design names -- is real. No compositor, no tailscaled.
#
# What it defends: the slot is the only surface that says egress is being
# dropped, and it says it with a tint and a badge. Every way of getting that
# wrong leaves a slot that renders perfectly and lies.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
mktmp

need_qml6

mkdir -p "$tmp/qs/Modules/Bar" "$tmp/qs/Common" "$tmp/qs/Services" "$tmp/qs/Theme" \
  "$tmp/C7" "$tmp/Quickshell/Networking" "$tmp/Quickshell/Bluetooth" \
  "$tmp/Quickshell/Services/Pipewire"

# The pill itself and the hit target it hangs its slots on -- both real: the
# tint and the outline the design gives a blocked exit node are QuickSlot
# properties, so stubbing it would delete half the subject.
cp "$src/Modules/Bar/StatusPill.qml" "$src/Modules/Bar/QuickSlot.qml" "$tmp/qs/Modules/Bar/"
# The battery widget is a whole second service's worth of bindings and none of
# it is under test; the pill only reads `warn` off it.
cat > "$tmp/qs/Modules/Bar/BatteryIndicator.qml" <<'QML'
import QtQuick
Item {
  property bool hovered: false
  readonly property bool warn: false
}
QML
printf 'module qs.Modules.Bar\nStatusPill 1.0 StatusPill.qml\nQuickSlot 1.0 QuickSlot.qml\nBatteryIndicator 1.0 BatteryIndicator.qml\n' \
  > "$tmp/qs/Modules/Bar/qmldir"

# The real Icon: it is what carries the dimming, and the test reads its tint
# back. It also fetches Assets/icons/<name>.svg, so a slot naming a glyph
# nobody drew shows up here as a missing-source warning.
cp "$src/Common/Icon.qml" "$tmp/qs/Common/"
# The update slot's progress ring is QtQuick.Shapes and is not under test.
printf 'import QtQuick\nItem { property real fraction: 0 }\n' \
  > "$tmp/qs/Common/ProgressRing.qml"
printf 'module qs.Common\nIcon 1.0 Icon.qml\nProgressRing 1.0 ProgressRing.qml\n' \
  > "$tmp/qs/Common/qmldir"

# The Theme stand-in, from tests/fixtures/theme-stub.sh -- one copy, with its
# colours read from the same palette.json the real Theme reads.
write_theme_stub "$tmp/qs" "$src"

# -- C7.Tailscale ------------------------------------------------------------
# The contract from plugin/src/contracts/TailscaleBackend.h, as far as the bar
# reads it. Two things are copied deliberately rather than simplified:
#
#   * State is declared as an enum, so the slot is written against
#     `Tailscale.Running` exactly as it is against the C++ Q_ENUM. A stub with
#     plain ints would let a wrong spelling pass here and fail in the shell.
#   * exitNodeBlocked is DERIVED, never written. The header computes it
#     non-virtually so no backend can disagree about what blocked means; a
#     test that could set it directly would not be testing the same flag.
cat > "$tmp/C7/Tailscale.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  id: root
  enum State { NoState, NeedsMachineAuth, NeedsLogin, Stopped, Starting, Running }

  // The default is NoState: a backend that has not heard from tailscaled yet
  // reads as unknown, never as Stopped.
  property int state: Tailscale.State.NoState
  property bool exitNodeActive: false
  property bool exitNodeOnline: false
  property string exitNodeName: ""
  readonly property bool exitNodeBlocked: root.exitNodeActive && !root.exitNodeOnline
  property var issues: []
  readonly property int issueCount: root.issues.length
}
QML
printf 'module C7\nsingleton Tailscale 1.0 Tailscale.qml\n' > "$tmp/C7/qmldir"

# -- the Quickshell types StatusPill names -----------------------------------
# All three radios read as absent, which hides their slots: the wifi, bluetooth
# and volume slots are other tests' subjects and a second QuickSlot wearing a
# crimson badge would make this one's assertions ambiguous.
cat > "$tmp/Quickshell/Networking/Networking.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  readonly property var devices: ({ values: [] })
}
QML
cat > "$tmp/Quickshell/Networking/DeviceType.js" <<'JS'
.pragma library
var Wifi = 1
var Wired = 2
JS
printf 'module Quickshell.Networking\nsingleton Networking 1.0 Networking.qml\nDeviceType 1.0 DeviceType.js\n' \
  > "$tmp/Quickshell/Networking/qmldir"

cat > "$tmp/Quickshell/Bluetooth/Bluetooth.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  readonly property var defaultAdapter: null
}
QML
printf 'module Quickshell.Bluetooth\nsingleton Bluetooth 1.0 Bluetooth.qml\n' \
  > "$tmp/Quickshell/Bluetooth/qmldir"

cat > "$tmp/Quickshell/Services/Pipewire/Pipewire.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  readonly property var defaultAudioSink: null
}
QML
printf 'import QtQuick\nItem { property var objects: [] }\n' \
  > "$tmp/Quickshell/Services/Pipewire/PwObjectTracker.qml"
printf 'module Quickshell.Services.Pipewire\nsingleton Pipewire 1.0 Pipewire.qml\nPwObjectTracker 1.0 PwObjectTracker.qml\n' \
  > "$tmp/Quickshell/Services/Pipewire/qmldir"

# -- the qs.Services singletons the other slots read -------------------------
# Every one of them at rest, for the same reason the radios are absent.
write_singleton() {
  printf 'pragma Singleton\nimport QtQuick\nQtObject {\n%s\n}\n' "$2" \
    > "$tmp/qs/Services/$1.qml"
  printf 'singleton %s 1.0 %s.qml\n' "$1" "$1" >> "$tmp/qs/Services/qmldir"
}
printf 'module qs.Services\n' > "$tmp/qs/Services/qmldir"
write_singleton ScreenshareService 'property bool active: false
  function stop() {}'
write_singleton UpdatesService 'property int total: 0
  property bool running: false
  property var pacnews: []
  property bool kernelPending: false
  property int runTotal: 0
  property int doneCount: 0'
write_singleton CaptureService 'property bool overlayOpen: false
  function toggle() {}'
write_singleton AirplaneService 'property bool enabled: false
  function setEnabled(v) {}'
write_singleton NetworkService 'property string primary: "wifi"
  property var ethDevice: null'
write_singleton BatteryService 'property bool present: false'
# The one the slot under test actually calls: it has to record the anchor, so
# the popover Task 8 adds has something to hang off.
write_singleton PopoverManager 'property string current: ""
  property Item anchorItem: null
  function toggle(name, item) { current = name; anchorItem = item }'

log=$tmp/tailscale.log
# QT_FORCE_STDERR_LOGGING: without a tty Qt sends its messages to journald,
# where this test cannot see them.
QT_QPA_PLATFORM=offscreen \
QT_FORCE_STDERR_LOGGING=1 \
timeout 30 qml6 -I "$tmp" "$here/tailscale-qml-test.qml" >"$log" 2>&1 \
  || fail "qml6 exited non-zero:\n$(cat "$log")"

# Both, in this order: a failed check names itself, and only a run that got
# all the way to the end may call itself a pass.
if grep -q 'TAILSCALE-TEST-FAIL' "$log"; then
  fail "$(grep 'TAILSCALE-TEST-FAIL' "$log")"
fi
grep -q 'TAILSCALE-TEST-PASS' "$log" || fail "the test never reached its end:\n$(cat "$log")"
# Any line naming a .qml file is a warning, an error or a type failure.
if grep -q '\.qml:' "$log"; then
  fail "QML diagnostics:\n$(grep '\.qml:' "$log")"
fi

echo 'test-tailscale.sh: all checks passed'
