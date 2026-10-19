import QtQuick
import qs.Theme

// The one list row every quick-settings surface is built from: a leading
// visual, a title over an optional subtitle, and whatever the caller wants
// right-aligned. `active` is the crimson-tinted state the mocks give the
// connected network / connected device / current output.
//
// The popovers and the settings pages use the same row at two densities --
// 12/10 type at a 12px inset on a page, 11/9 at 10px in a panel -- so the
// type scale and the inset are properties rather than a reason to fork the
// component. The defaults are the page density.
Rectangle {
  id: root

  property alias leading: leadingSlot.data
  default property alias trailing: trailingSlot.data
  // Drawn over the row's fill and under its content, for a row whose
  // background is itself a control -- the hold-to-confirm sweep on the power
  // rows. It stacks above the row's own MouseArea, so anything in here takes
  // the press.
  property alias underlay: underlaySlot.data

  property string title: ""
  property string subtitle: ""
  property bool active: false
  property bool hoverable: true
  // Width AND height reserved for the leading visual; 0 draws none. Explicit
  // rather than measured, so the title column never re-lays out as an icon
  // finishes loading.
  property int leadingSize: 0

  // A card rather than a list row: it keeps a resting surface and a hairline
  // instead of appearing on hover. Such a row does not tint on hover even when
  // it is clickable -- there is no transparent state for the tint to read
  // against.
  property bool filled: false
  // The 1g device-row accent: a softer fill for a list where several rows are
  // "current" at once (an output and an input) and full crimson on both would
  // fight.
  property bool softAccent: false

  property int inset: 12
  property int titleSize: 12
  property int titleWeight: 600
  property int subtitleSize: 10
  property color hoverFill: Theme.surface04
  property color titleColor: root.active ? Theme.text : Theme.alpha(Theme.text, 0.85)
  property color subtitleColor: Theme.alpha(Theme.text, 0.45)

  signal clicked()

  readonly property bool hovered: mouse.containsMouse

  implicitHeight: 44
  radius: Theme.radiusTile
  color: root.active ? (root.softAccent ? Theme.accentFillSoft : Theme.accentFill)
    : root.filled ? Theme.surface04
    : (root.hoverable && mouse.containsMouse ? root.hoverFill : "transparent")
  border.width: root.active || root.filled ? 1 : 0
  border.color: root.active
    ? (root.softAccent ? Theme.accentBorderSoft : Theme.accentBorder)
    : Theme.hairline

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    // Rows that only display still need the hover tint suppressed, not the
    // pointer swallowed by a disabled MouseArea.
    onClicked: if (root.hoverable) root.clicked()
  }

  Item {
    id: underlaySlot
    anchors.fill: parent
  }

  Item {
    id: leadingSlot
    anchors { left: parent.left; leftMargin: root.inset; verticalCenter: parent.verticalCenter }
    width: root.leadingSize
    height: root.leadingSize
    visible: root.leadingSize > 0
  }

  Column {
    anchors {
      left: parent.left
      leftMargin: root.leadingSize > 0 ? root.inset + root.leadingSize + 11 : root.inset
      right: trailingSlot.left
      rightMargin: 8
      verticalCenter: parent.verticalCenter
    }
    spacing: 2

    // PlainText, both of them, and not negotiable. Every caller of this row
    // puts a name that came off a network into one of these two: WifiPopover
    // feeds it scanned SSIDs, which are whatever the access point next door
    // says they are, and the Tailscale panel feeds it tailscaled's hostnames
    // and the free-form display names of other people on the tailnet. The
    // default is Text.AutoText, which renders <b> AND fetches a remote
    // <img src> -- a markup injection, and a beacon, in the shell's own bar.
    // A caller that really wants markup here sets the property on its own
    // Text; this row does not offer the choice.
    Text {
      width: parent.width
      text: root.title
      textFormat: Text.PlainText
      font { family: Theme.fontMono; pixelSize: root.titleSize; weight: root.titleWeight }
      color: root.titleColor
      elide: Text.ElideRight
    }
    Text {
      width: parent.width
      visible: root.subtitle !== ""
      text: root.subtitle
      textFormat: Text.PlainText
      font { family: Theme.fontMono; pixelSize: root.subtitleSize; weight: 400 }
      color: root.subtitleColor
      elide: Text.ElideRight
    }
  }

  // Trailing items are mixed heights — 20px chips next to 13px readouts — so
  // each one anchors its own verticalCenter. A Row permits vertical anchors on
  // its children (only left/right/horizontalCenter/fill/centerIn are refused),
  // and it has no verticalItemAlignment of its own; that belongs to Grid.
  Row {
    id: trailingSlot
    anchors { right: parent.right; rightMargin: root.inset; verticalCenter: parent.verticalCenter }
    spacing: 8
  }
}
