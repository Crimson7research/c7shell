import QtQuick

// The card's one input. Two states in one item, as the mockup has it: a focused
// field with dot echo and a crimson caret, and the failed-auth state where the
// field itself carries the message and the attempt counter.
//
// The dots are drawn rather than echoed: TextInput's password character is a
// platform bullet in whatever the font offers, and the mockup's is a 5px round
// dot at 70% ink with a 1.5px crimson caret after it.
FocusScope {
  id: root

  // Qt Quick defaults activeFocusOnTab to false, which left the greeter with
  // no focus chain at all -- Tab did nothing. The field is the one thing a
  // keyboard user must always be able to reach.
  activeFocusOnTab: true

  property string error: ""          // "" = accepting input
  property int attempt: 0            // failures so far
  property int maxAttempts: 3
  property int cooldown: 0           // seconds left of the lockout, 0 = none
  // Not readonly: clear() is the normal way to empty it, but a settable alias
  // is what lets tests/greeter-preview.qml render the dot row with characters
  // in it -- the dots are drawn from text.length, so an empty field proves
  // nothing about how they sit.
  property alias text: input.text
  readonly property bool locked: root.cooldown > 0

  signal accepted
  signal edited

  function clear() { input.text = "" }
  function shake() { shakeAnim.restart() }

  implicitWidth: Theme.cardWidth
  implicitHeight: Theme.fieldHeight

  Rectangle {
    id: frame
    // Not anchors.fill: the failure shake animates x, which an anchor owns.
    width: root.width
    height: root.height
    radius: Theme.radiusField
    color: root.error !== "" ? Theme.errorFill : Theme.field
    border.width: 1
    border.color: root.error !== "" ? Theme.errorBorder
                : root.activeFocus ? Theme.focusBorder
                : Theme.hairline

    Behavior on color { ColorAnimation { duration: 120 } }
    Behavior on border.color { ColorAnimation { duration: 120 } }

    // box-shadow: 0 0 0 3px crimson .12 -- a ring, so it is a rectangle behind
    // the frame rather than a blur.
    Rectangle {
      anchors.centerIn: parent
      width: parent.width + Theme.px(6)
      height: parent.height + Theme.px(6)
      radius: parent.radius + Theme.px(3)
      color: "transparent"
      border.width: Theme.px(3)
      border.color: Theme.focusRing
      visible: root.activeFocus && root.error === ""
      z: -1
    }

    Row {
      anchors.fill: parent
      anchors.leftMargin: Theme.px(14)
      anchors.rightMargin: Theme.px(14)
      spacing: Theme.px(10)

      Icon {
        anchors.verticalCenter: parent.verticalCenter
        name: root.error !== "" ? "alert-triangle" : "lock"
        size: Theme.px(13)
        color: root.error !== "" ? Theme.accentSoft : Theme.crimson(0.85)
      }

      // -- accepting input: the dot row and the caret --------------------
      Item {
        id: echoArea
        anchors.verticalCenter: parent.verticalCenter
        width: frame.width - Theme.px(13) - Theme.px(10) * 2 - Theme.px(28) - hint.width
        height: parent.height
        visible: root.error === "" && !root.locked
        clip: true

        Row {
          id: dots
          anchors.verticalCenter: parent.verticalCenter
          spacing: Theme.px(4)

          // Capped at what fits: a 60-character passphrase must not push the
          // caret out of the field.
          Repeater {
            model: Math.min(input.text.length,
                            Math.max(1, Math.floor((echoArea.width - Theme.px(8)) / Theme.px(9))))
            Rectangle {
              // The row is as tall as the caret, so a 5px dot left to itself
              // sits at the top of it -- the mockup centers both on the
              // field's middle line (align-items:center).
              anchors.verticalCenter: parent.verticalCenter
              width: Theme.px(5); height: Theme.px(5)
              radius: width / 2
              color: Theme.ink(0.7)
            }
          }

          Rectangle {
            width: Math.max(1, Theme.px(1.5))
            height: Theme.px(15)
            anchors.verticalCenter: parent.verticalCenter
            color: Theme.accent
            visible: root.activeFocus
            opacity: blink.on ? 1 : 0
            Timer {
              id: blink
              property bool on: true
              interval: 530; running: root.activeFocus; repeat: true
              onTriggered: on = !on
            }
          }
        }
      }

      // -- failed auth: the message replaces the dots --------------------
      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: echoArea.width
        visible: root.error !== "" || root.locked
        text: root.locked
              ? qsTr("locked out · %1 s").arg(root.cooldown)
              : root.error
        elide: Text.ElideRight
        color: Theme.accentSoft
        font.family: Theme.fontMono
        font.pixelSize: Theme.fs(11)
        font.weight: 500
      }

      // The counter while failing, the enter hint while typing.
      Text {
        id: hint
        anchors.verticalCenter: parent.verticalCenter
        text: root.error !== "" || root.locked
              ? qsTr("%1 of %2").arg(root.attempt).arg(root.maxAttempts)
              : "↵"
        color: root.error !== "" || root.locked
               ? Qt.rgba(Theme.accentSoft.r, Theme.accentSoft.g, Theme.accentSoft.b, 0.6)
               : Theme.ink(0.3)
        font.family: Theme.fontMono
        font.pixelSize: Theme.fs(9.5)
        font.letterSpacing: 0.04 * Theme.fs(9.5)
      }
    }

    TextInput {
      id: input
      anchors.fill: parent
      focus: true
      enabled: !root.locked
      // Never echoed: the dots above are drawn from text.length. Also keeps the
      // password out of any accessibility or IM surface sddm might expose.
      echoMode: TextInput.NoEcho
      color: "transparent"
      selectByMouse: false
      activeFocusOnPress: true
      // A password manager paste or an autotype tool still needs the text in.
      onTextChanged: root.edited()
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          root.accepted()
          event.accepted = true
        }
      }
    }
  }

  // "shake once", 180ms, on every failure.
  SequentialAnimation {
    id: shakeAnim
    loops: 1
    NumberAnimation { target: frame; property: "x"; to: Theme.px(7); duration: 45 }
    NumberAnimation { target: frame; property: "x"; to: -Theme.px(6); duration: 60 }
    NumberAnimation { target: frame; property: "x"; to: Theme.px(3); duration: 45 }
    NumberAnimation { target: frame; property: "x"; to: 0; duration: 30 }
  }
}
