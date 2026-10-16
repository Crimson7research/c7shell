import QtQuick
import qs.Theme

// The search pill the Settings sidebar wears, in a popover: a glass pill, a
// glyph, and a field the whole pill focuses.
//
// One component rather than a copy per list, because the part that is easy to
// get subtly wrong is not the pill -- it is the focus. A popover holds a
// Hyprland focus grab, Hyprland then keeps the keyboard on the BAR surface,
// and the bar forwards what it receives to PopoverManager.keySink, which
// PopupSurface points at the panel, which forwards on to whatever inside it
// holds the window's focus. A field that does not hold that focus cannot be
// typed into at all, and nothing about it looks different. So `focusInput()`
// is the whole contract: the owner calls it from the thing that grew the
// field -- the same order Common/PskField.ask() uses, which is the one path
// in this shell proven to take keystrokes live.
Rectangle {
  id: root

  property alias text: input.text
  property string placeholder: qsTr("search…")
  // The panel names the FIELD, not the pill: a test and a focus check both
  // want the item that holds the text, and an alias cannot carry an
  // objectName onto it.
  property string fieldName: ""

  function focusInput() {
    input.forceActiveFocus()
  }

  implicitHeight: 26
  radius: Theme.radiusChip
  color: Theme.surface05

  Icon {
    id: glass
    anchors { left: parent.left; leftMargin: 9; verticalCenter: parent.verticalCenter }
    name: "search"
    size: 11
    tint: Theme.alpha(Theme.text, 0.4)
  }

  TextInput {
    id: input

    objectName: root.fieldName
    anchors {
      left: glass.right; leftMargin: 8
      right: parent.right; rightMargin: 9
      verticalCenter: parent.verticalCenter
    }
    font { family: Theme.fontMono; pixelSize: 11; weight: 400 }
    color: Theme.text
    clip: true
    // Accepted, so esc clears the query rather than closing the popover out
    // from under someone who is still reading the list.
    Keys.onEscapePressed: event => {
      input.text = ""
      event.accepted = true
    }

    Text {
      anchors.fill: parent
      verticalAlignment: Text.AlignVCenter
      visible: input.text === ""
      text: root.placeholder
      textFormat: Text.PlainText
      font { family: Theme.fontMono; pixelSize: 11; weight: 400 }
      color: Theme.alpha(Theme.text, 0.35)
    }
  }

  MouseArea {
    anchors.fill: parent
    // 26px of field: the whole pill should take the press.
    onClicked: root.focusInput()
  }
}
