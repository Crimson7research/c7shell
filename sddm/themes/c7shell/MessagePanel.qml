import QtQuick

// The panel under the card that carries what PAM is telling the user.
//
// PAM talks during a *successful* authentication, not only a failed one: a
// directory backend will ask for an MFA number to type into a phone, say which
// credential it wants, or report enrolment progress. sddm hands all of it to
// the theme on one channel (informationMessage), and none of it is a rejection.
//
// They are collected rather than replaced, because a single sign-in can
// produce several in sequence and the earlier ones stay relevant -- the MFA
// number in particular has to remain readable while the user picks up a phone.
GlassPanel {
  id: root

  property var messages: []
  // Set by the greeter when PAM keeps asking the same thing: the conversation
  // needs an answer sddm's one-secret protocol cannot send.
  property bool stuck: false

  radius: Theme.radiusPanel
  implicitWidth: Theme.cardWidth
  implicitHeight: column.implicitHeight + Theme.px(28)
  visible: root.messages.length > 0

  Column {
    id: column
    anchors.fill: parent
    anchors.margins: Theme.px(12)
    anchors.topMargin: Theme.px(14)
    anchors.bottomMargin: Theme.px(14)
    spacing: Theme.px(6)

    Text {
      leftPadding: Theme.px(8)
      topPadding: Theme.px(3)
      bottomPadding: Theme.px(4)
      text: qsTr("sign-in")
      color: Theme.ink(0.3)
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(9)
      font.letterSpacing: 0.08 * Theme.fs(9)
    }

    Repeater {
      model: root.messages
      delegate: Text {
        required property string modelData
        required property int index

        width: column.width
        leftPadding: Theme.px(8)
        rightPadding: Theme.px(8)
        text: modelData
        wrapMode: Text.WordWrap
        // The newest line is the one being acted on; older ones stay for
        // context but step back so the eye lands in the right place.
        color: index === root.messages.length - 1 ? Theme.ink(0.9) : Theme.ink(0.45)
        font.family: Theme.fontMono
        font.pixelSize: Theme.fs(10.5)
        font.weight: index === root.messages.length - 1 ? 500 : 400
      }
    }

    // The way out, when there isn't one here.
    Item { width: 1; height: Theme.px(4); visible: root.stuck }

    Text {
      visible: root.stuck
      width: column.width
      leftPadding: Theme.px(8)
      rightPadding: Theme.px(8)
      text: qsTr("This step needs a text console. Press Ctrl+Alt+F3 and sign in there, then return with Ctrl+Alt+F1.")
      wrapMode: Text.WordWrap
      color: Theme.accentSoft
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(10)
      font.weight: 500
    }
  }
}
