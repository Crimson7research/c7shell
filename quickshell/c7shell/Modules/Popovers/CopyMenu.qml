import QtQuick
import Quickshell
import qs.Theme
import qs.Common

// The right-click menu of the device list: the three copy actions Tailscale
// ships (IPv4, IPv6, MagicDNS hostname). A row can only have one primary
// action, so the click copies the IPv4 and the full set lives here.
//
// It is an overlay over the whole panel rather than a window of its own: the
// popover is already a PopupWindow with a Hyprland focus grab over it, and a
// second window inside that grab is a second grab request -- the mistake
// tests/test-qml-hygiene.sh has a whole check about. The scrim underneath the
// card is what dismisses it, exactly as the mock's document-level click
// handler does.
//
// Owners parent this to the popover's `panel` (NOT into the content Column,
// which would position it as a row) and call showAt().
Item {
  id: root

  objectName: "ts-copy-menu"

  // Whose values are on offer. The head of the menu names it by its DNS
  // label, so a tailnet with two devices whose OS hostname is `localhost`
  // still says which one is being copied.
  property string displayName: ""
  property string ip4: ""
  property string ip6: ""
  property string dnsName: ""

  property bool menuOpen: false

  visible: root.menuOpen
  z: 10

  // Opens the card with its top-left at (x, y) in this item's coordinates,
  // clamped so a right-click near the bottom-right of the panel does not put
  // the menu outside it.
  function showAt(x, y) {
    card.x = Math.max(0, Math.min(x, root.width - card.width))
    card.y = Math.max(0, Math.min(y, root.height - card.implicitHeight))
    root.menuOpen = true
  }

  function close() {
    root.menuOpen = false
  }

  // The scrim: any press outside the card closes the menu, and it swallows
  // that press so it does not also fall through to the row underneath.
  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    onPressed: root.close()
  }

  GlassPanel {
    id: card

    width: 188
    implicitHeight: entries.implicitHeight + 10
    radius: Theme.radiusChip

    // The card takes its own presses, so the scrim behind it does not close
    // the menu on the way to an entry.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.AllButtons
    }

    Column {
      id: entries
      anchors { left: parent.left; right: parent.right; top: parent.top; margins: 5 }
      spacing: 1

      Text {
        width: parent.width
        leftPadding: 4
        bottomPadding: 5
        text: root.displayName
        // Daemon-supplied text. PlainText for the same reason the issue list
        // is: a device's name is its owner's own string, not ours.
        textFormat: Text.PlainText
        elide: Text.ElideRight
        font { family: Theme.fontMono; pixelSize: 10; weight: 700 }
        color: Theme.text3
      }
      Rectangle {
        width: parent.width
        height: 1
        color: Theme.hairline
      }
      Item { width: parent.width; height: 3 }

      // onActivated rather than a call to root.close(): an inline component
      // does not share the enclosing component's scope, so `root` is not a
      // name it can see.
      Entry {
        objectName: "ts-copy-ip4"
        label: qsTr("Copy IPv4")
        value: root.ip4
        onActivated: root.close()
      }
      Entry {
        objectName: "ts-copy-ip6"
        label: qsTr("Copy IPv6")
        value: root.ip6
        onActivated: root.close()
      }
      Entry {
        objectName: "ts-copy-dns"
        label: qsTr("Copy MagicDNS hostname")
        value: root.dnsName
        onActivated: root.close()
      }
    }
  }

  // An entry with nothing behind it is drawn dead rather than hidden: the menu
  // keeps the same three rows in the same order whichever peer it is over, so
  // the one being reached for does not move.
  component Entry: Rectangle {
    id: entry

    property string label: ""
    property string value: ""

    signal activated()

    // The guard lives here, in the function the MouseArea calls, so a disabled
    // entry copies nothing by the same path whether a mouse or a test drives
    // it.
    readonly property bool entryEnabled: entry.value !== ""

    function activate() {
      if (!entry.entryEnabled) return
      Quickshell.clipboardText = entry.value
      entry.activated()
    }

    width: parent.width
    height: 26
    radius: Theme.radiusMenuRow
    color: entry.entryEnabled && hover.containsMouse ? Theme.hoverPill : "transparent"

    MouseArea {
      id: hover
      anchors.fill: parent
      hoverEnabled: entry.entryEnabled
      onClicked: entry.activate()
    }

    Text {
      anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter }
      text: entry.label
      font { family: Theme.fontMono; pixelSize: 11; weight: 500 }
      color: entry.entryEnabled ? Theme.text : Theme.textDisabled
    }
  }
}
