import QtQuick
import Quickshell
import qs.Theme
import qs.Common

// One device of the tailnet, as the mock's device list draws it: a reachability
// dot, the hostname, the owner where the section heading does not already imply
// it, and the device's IPv4 on the right.
//
// Click copies the IPv4; right-click asks the owner for the full copy menu.
// Feedback for the copy stays inside this row -- a popover has nowhere else to
// put it, and a toast would outlive the panel that raised it.
//
// That feedback is also the reason this is a delegate with LOCAL STATE rather
// than a pure function of its model row: `copied` is set on one instance and
// lives nowhere else, so it is lost the moment the view rebuilds the row. Which
// is the whole point of PeerModel updating rows in place, and is what
// tests/tailscale-qml-test.qml drives a real ListView over to pin.
ListRow {
  id: root

  // Injected from the model's roles. Declared required so this row cannot be
  // instantiated anywhere it would silently read empty.
  required property string hostName
  required property string ip4
  required property string ip6
  required property string dnsName
  required property bool online
  required property string ownerName
  // 0 = Mine, 1 = Tagged, 2 = Others, per PeerModel::Group.
  required property int group
  // tailscaled's own device id, and the identity PeerModel keys a row on: not
  // the hostname, which repeats on a tailnet -- two of c7-test-2's twenty
  // devices answer to `localhost` and two more to `C7-LAP-G1157C6M`.
  required property string nodeId

  // (x, y) of the press in scene coordinates -- the owner maps them into
  // whatever it parents the menu to.
  signal menuRequested(real sceneX, real sceneY)

  objectName: "ts-peer"

  implicitHeight: 30
  radius: Theme.radiusMenuRow
  inset: 8
  leadingSize: 5
  titleSize: 11
  titleWeight: 500
  titleColor: root.online ? Theme.alpha(Theme.text, 0.85) : Theme.textDisabled
  subtitleSize: 10
  subtitleColor: Theme.text3
  title: root.hostName
  // Only Other Users needs an owner line; in the other two sections the owner
  // is the heading.
  subtitle: root.group === 2 ? root.ownerName : ""

  onClicked: root.copy(root.ip4)

  // The transient this delegate owns. Nothing in the model knows about it, so
  // a view that rebuilds the row throws it away mid-flight.
  property bool copied: false

  function copy(value) {
    if (value === "") return
    Quickshell.clipboardText = value
    root.copied = true
    copyReset.restart()
  }

  leading: Rectangle {
    width: 5
    height: 5
    radius: 2.5
    color: root.online ? Theme.success : Theme.textDisabled
  }

  // Above the row's own MouseArea (see ListRow), and right-button only, so the
  // left click still reaches the copy below it.
  underlay: MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.RightButton
    onClicked: mouse => {
      const p = root.mapToItem(null, mouse.x, mouse.y)
      root.menuRequested(p.x, p.y)
    }
  }

  Timer {
    id: copyReset
    interval: 1100
    onTriggered: root.copied = false
  }

  Text {
    anchors.verticalCenter: parent.verticalCenter
    text: root.copied ? qsTr("copied") : root.ip4
    // An address off the tailnet: tailscaled's string, never our markup.
    textFormat: Text.PlainText
    font { family: Theme.fontMono; pixelSize: 10; weight: root.copied ? 600 : 400 }
    color: root.copied ? Theme.accentSoft : Theme.text3
  }
}
