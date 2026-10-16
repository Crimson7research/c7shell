#!/usr/bin/env bash
# Self-check for the bar's Tailscale slot. Run it directly: tests/test-tailscale.sh
#
# Self-check for the bar's Tailscale slot AND the popover behind it.
#
# Same trick as tests/test-wifi.sh: both are plain QtQuick bindings over one
# singleton's properties, so the Quickshell types they reach for are shimmed,
# C7.Tailscale is stood in by a QML singleton the test writes to, and the rules
# under test -- what the slot wears in each of the six states the design names,
# and what the panel draws over each shape of tailnet -- are real. No
# compositor, no tailscaled.
#
# What it defends: the slot is the only surface that says egress is being
# dropped, and it says it with a tint and a badge. Every way of getting that
# wrong leaves a slot that renders perfectly and lies. The panel adds a second
# class of that: a list view that silently rebuilds its rows throws away
# whatever local state a row was holding (#124), and nothing about a rebuilt
# row looks different in a screenshot.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
mktmp

need_qml6

mkdir -p "$tmp/qs/Modules/Bar" "$tmp/qs/Modules/Popovers" "$tmp/qs/Common" \
  "$tmp/qs/Services" "$tmp/qs/Theme" \
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
# The panel is built out of these three, and all three carry rules the panel
# depends on -- ListRow's underlay stacking above its own MouseArea is how a
# peer row gets a right-click at all.
# SearchField is the fourth: both sub-cards filter their list through it, and
# the one thing it owns -- which item holds the window's focus -- is exactly
# what the panel is asserted on.
cp "$src/Common/ListRow.qml" "$src/Common/SectionLabel.qml" "$src/Common/TogglePill.qml" \
  "$src/Common/GlassPanel.qml" "$src/Common/SearchField.qml" "$tmp/qs/Common/"

# GlassPopover stands in: the real one is a PopupSurface, which is a
# PopupWindow with a Hyprland focus grab on it, and none of that is the
# subject. What IS the subject is the shape it hands a popover -- `name`,
# `panelWidth`, a content Column with the panel's gap, `open` off
# PopoverManager, and the `panel` the overlay menu parents itself to -- so the
# stub keeps exactly those and nothing else.
cat > "$tmp/qs/Common/GlassPopover.qml" <<'QML'
import QtQuick
import qs.Services
Item {
  id: root
  required property string name
  property int padding: 14
  property int gap: 11
  property int panelWidth: 320
  property bool pinRight: false
  default property alias content: column.data
  readonly property alias panel: panel

  property bool open: PopoverManager.current === root.name
  width: panel.width
  height: panel.height

  Item {
    id: panel
    width: root.panelWidth
    height: column.implicitHeight + root.padding * 2

    Column {
      id: column
      anchors {
        top: parent.top; left: parent.left; right: parent.right
        margins: root.padding
      }
      spacing: root.gap
    }
  }
}
QML

# The tooltip on the disabled connect toggle. A PopupWindow in the shell, and
# hover chrome here -- the panel never reads it back.
cat > "$tmp/qs/Common/Tooltip.qml" <<'QML'
import QtQuick
Item {
  id: root
  property bool open: false
  property Item anchorItem: null
  property int panelWidth: 200
  property real panelHeight: 0
  property int panelRadius: 9
  default property alias content: card.data
  visible: false
  Item { id: card; width: root.panelWidth; height: root.panelHeight }
}
QML

printf 'module qs.Common\nIcon 1.0 Icon.qml\nProgressRing 1.0 ProgressRing.qml\nListRow 1.0 ListRow.qml\nSectionLabel 1.0 SectionLabel.qml\nTogglePill 1.0 TogglePill.qml\nGlassPanel 1.0 GlassPanel.qml\nGlassPopover 1.0 GlassPopover.qml\nTooltip 1.0 Tooltip.qml\nSearchField 1.0 SearchField.qml\n' \
  > "$tmp/qs/Common/qmldir"

# -- the popover, all of it real ---------------------------------------------
cp "$src/Modules/Popovers/TailscalePopover.qml" "$src/Modules/Popovers/PeerRow.qml" \
  "$src/Modules/Popovers/ExitNodeList.qml" "$src/Modules/Popovers/CopyMenu.qml" \
  "$tmp/qs/Modules/Popovers/"
printf 'module qs.Modules.Popovers\nTailscalePopover 1.0 TailscalePopover.qml\nPeerRow 1.0 PeerRow.qml\nExitNodeList 1.0 ExitNodeList.qml\nCopyMenu 1.0 CopyMenu.qml\n' \
  > "$tmp/qs/Modules/Popovers/qmldir"

# Quickshell's own singleton, for the one thing the panel asks of it: the
# clipboard. Writing it is the whole copy action, and the test reads it back --
# which is also what proves the panel is not shelling out to wl-copy, because
# a Process here would have nothing to write to.
cat > "$tmp/Quickshell/Quickshell.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property string clipboardText: ""
}
QML
printf 'module Quickshell\nsingleton Quickshell 1.0 Quickshell.qml\n' > "$tmp/Quickshell/qmldir"

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
  // The exit node's string ID. The check mark in the exit-node list joins on
  // this and not on the name, because hostnames repeat on a tailnet.
  property string exitNodeId: ""
  property string exitNodeName: ""
  readonly property bool exitNodeBlocked: root.exitNodeActive && !root.exitNodeOnline
  property var issues: []
  readonly property int issueCount: root.issues.length

  // This machine on the tailnet. All last-known values -- see State -- which
  // is why the panel gates every one of them on state.
  property string selfName: ""
  property string selfIp4: ""
  property string selfIp6: ""
  // Already normalised: the header's getter is non-virtual and strips the root
  // dot, so QML never sees the trailing one.
  property string selfDnsName: ""
  property string tailnet: ""
  // An invalid QDateTime reaches QML as an Invalid Date; null is the same
  // absence written the way a QML test can write it.
  property var keyExpiry: null
  property string recommendedExitNodeId: ""

  // PeerModel stands in as a ListModel, and that is the point rather than a
  // shortcut: both are QAbstractListModels, so a ListView sees the same
  // dataChanged / rowsMoved / rowsInserted that PeerModel is proven to emit
  // (plugin/lib/tailscale/tests/tst_peermodel.cpp pins that it emits those and
  // never a reset). What a ListModel adds is that a TEST can drive those
  // signals by hand -- setProperty is a dataChanged, move is a rowsMoved,
  // clear+append is the reset PeerModel exists to avoid -- which is what lets
  // the delegate-identity check below run a real ListView over them.
  //
  // Rows are appended already sorted Mine / Tagged / Others, as PeerModel
  // sorts them.
  //
  // dynamicRoles stays FALSE, and that is the load-bearing half: a static
  // ListModel is driven through QQmlAdaptorModel's
  // VDMAbstractItemModelDataType accessor -- the same path a C++
  // QAbstractItemModel takes -- so the delegate lifecycle under test is the
  // same code and not a lookalike. Turning dynamic roles on would quietly
  // move it onto VDMListModelInterface and invalidate the comparison without
  // failing anything. Written out rather than left to the default for that
  // reason.
  readonly property ListModel peers: ListModel { dynamicRoles: false }
  readonly property ListModel exitNodes: ListModel { dynamicRoles: false }

  // The outcome of a write, which a test states because this stub never
  // attempts one. writable is TRUE until a write is refused: it says the last
  // attempt was not refused, never that the next one will be taken, so a
  // control that goes dead on it is "disabled after a refusal" and not
  // disabled until proven.
  property bool writable: true
  property string writeError: ""

  // The actions. An action is a REQUEST: it reports what was asked for and
  // moves nothing here, exactly as the contract specifies and as
  // src/backends/tailscale/FakeTailscaleBackend.h behaves. A stub that
  // applied its own writes would stand in for a tailscaled that never refuses
  // anything.
  //
  // Reported through a signal rather than collected into a property, so the
  // property comparison below stays exactly the contract's set: a test
  // connects to `called` and keeps the list itself.
  signal called(string call)
  function setWantRunning(on) { root.called("setWantRunning(" + on + ")") }
  function setExitNode(nodeId) { root.called("setExitNode(" + nodeId + ")") }
  function setExitNodeAllowLANAccess(on) { root.called("setExitNodeAllowLANAccess(" + on + ")") }
  function setAcceptRoutes(on) { root.called("setAcceptRoutes(" + on + ")") }
  function setAcceptDns(on) { root.called("setAcceptDns(" + on + ")") }
}
QML
printf 'module C7\nsingleton Tailscale 1.0 Tailscale.qml\n' > "$tmp/C7/qmldir"

# The stub above is hand-written, and nothing in the QML suites would notice it
# drifting from the contract: rename a Q_PROPERTY in TailscaleBackend.h and
# every check in tailscale-qml-test.qml still passes against the old spelling
# while the real shell reads `undefined` off the real singleton. So both sides
# are read mechanically and compared as sets -- the header's Q_PROPERTY names
# against the stub's declared properties. plugin/tests/tst_module.cpp asserts
# the other end, that the BUILT module exposes the same set.
contract_properties() {
  # The name is the token before READ; `QAbstractItemModel *peers` puts a star
  # on it, and recommendedExitNodeId wraps its NOTIFY onto the next line, which
  # is why this matches on READ rather than on the closing bracket.
  sed -n 's/.*Q_PROPERTY(.*[ *]\([A-Za-z0-9_]\{1,\}\) READ .*/\1/p' \
    "$repo/plugin/src/contracts/TailscaleBackend.h" | sort
}
stub_properties() {
  sed -n 's/^[[:space:]]*\(readonly \)\{0,1\}property [A-Za-z0-9_]\{1,\} \([A-Za-z0-9_]\{1,\}\):.*/\2/p' \
    "$tmp/C7/Tailscale.qml" | sort
}
[ "$(contract_properties | wc -l)" -ge 15 ] \
  || fail "the contract scan found $(contract_properties | wc -l) properties in TailscaleBackend.h, so it is not reading the header"
if ! diff -u <(contract_properties) <(stub_properties) > "$tmp/props.diff"; then
  fail "the C7.Tailscale stub in this script no longer matches\nplugin/src/contracts/TailscaleBackend.h -- every QML check here would pass\nagainst a property the shell does not have:\n$(cat "$tmp/props.diff")"
fi

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
