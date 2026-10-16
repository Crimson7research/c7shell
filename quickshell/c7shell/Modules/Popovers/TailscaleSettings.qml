import QtQuick
import C7
import qs.Theme
import qs.Common

// The settings sub-card: the two tailnet-wide prefs the contract can write
// that are not about one exit node -- `accept routes` (RouteAll) and
// `accept dns` (CorpDNS).
//
// Both are switches of the same shape as the exit-node panel's LAN control:
// an action to ask with, a property to read the answer back from, and nothing
// drawn from the click itself. See `routes` below for why there is no
// optimistic latch anywhere here.
//
// `accept routes` carries one thing this panel owes the user. RouteAll: false
// is the pref behind the single health warning this module SUPPRESSES --
// LocalApiTailscaleBackend::suppressedHealth, tailscaled's standing "some
// peers are advertising routes but --accept-routes is false". Suppressing it
// is right: it never clears on a machine that deliberately does not accept
// those routes, so surfaced naively the panel warns forever about a setting
// someone chose. But a warning dropped on the floor with nothing said about it
// makes the issue list quietly not the whole of what tailscaled reported --
// a special case living in a C++ policy list and nowhere a user can see. Said
// here, beside the switch that turns the warning off for real, it stops being
// hidden and becomes the explanation of a control.
Column {
  id: root

  objectName: "ts-settings"
  spacing: 6

  // `writable` is a claim about the LAST write and never permission for the
  // next one -- TailscaleBackend.h says so at length, because the name invites
  // the opposite reading. These controls are live until tailscaled has refused
  // something and dead afterwards, with the refusal's own words above them.
  readonly property bool refused: !Tailscale.writable

  // Read back off the contract, never latched from the click. An action is a
  // REQUEST: tailscaled answers an accepted write with a Prefs notification
  // within milliseconds, the backend re-reads /prefs on it, and that re-read
  // is what moves the pill. Drawing the click instead would make a refused
  // write look exactly like an accepted one.
  readonly property bool routes: Tailscale.acceptRoutes
  readonly property bool dns: Tailscale.acceptDns

  // -- what the last change did -----------------------------------------------
  // Two different things, and TailscaleWriteNote is where the difference is
  // phrased: a refusal means these controls are dead and c7shell-bootstrap is
  // the answer, while a write that merely went wrong leaves them live and the
  // answer is to click again. It says nothing after a write that was taken.
  TailscaleWriteNote { id: writeNote }

  Text {
    objectName: "ts-settings-write-error"
    width: root.width
    visible: writeNote.message !== ""
    leftPadding: 8
    rightPadding: 8
    text: writeNote.message
    // The daemon's own answer, verbatim, which makes it daemon-supplied text.
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
    color: Theme.accentSoft
  }

  SectionLabel {
    objectName: "ts-settings-label"
    text: root.refused ? qsTr("tailnet settings (read-only)") : qsTr("tailnet settings")
  }

  ListRow {
    id: routesRow

    objectName: "ts-settings-routes"
    width: root.width
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: !root.refused
    titleColor: root.refused ? Theme.textDisabled : Theme.alpha(Theme.text, 0.85)
    title: qsTr("accept routes")

    onClicked: {
      if (root.refused) return
      Tailscale.setAcceptRoutes(!root.routes)
    }

    TogglePill {
      objectName: "ts-settings-routes-switch"
      anchors.verticalCenter: parent.verticalCenter
      checked: root.routes
      enabled: !root.refused
      // The pill sits in the trailing slot, above the row's own MouseArea, so
      // it takes its own press -- both paths end in the one handler.
      onToggled: routesRow.clicked()
    }
  }

  // The suppressed warning, explained. Shown exactly when there is one to
  // explain: with RouteAll on, tailscaled raises nothing and there is nothing
  // being hidden.
  //
  // NOT gated on `refused`. It is not an offer and it does not go dead with
  // the controls -- it says why the issue list above is short, which is true
  // whether or not this machine may change it.
  Text {
    objectName: "ts-settings-routes-why"
    width: root.width
    visible: !root.routes
    leftPadding: 8
    rightPadding: 8
    bottomPadding: 2
    text: qsTr("tailscaled warns that peers advertise routes this machine does not accept. That warning never clears while this is off, so it is kept out of the issues above — and off can be deliberate: accepting the routes can take this machine's own LAN with them.")
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
    color: Theme.textDisabled
  }

  ListRow {
    id: dnsRow

    objectName: "ts-settings-dns"
    width: root.width
    implicitHeight: 38
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: !root.refused
    titleColor: root.refused ? Theme.textDisabled : Theme.alpha(Theme.text, 0.85)
    title: qsTr("accept dns")
    subtitle: qsTr("use the tailnet's DNS, MagicDNS included")
    subtitleColor: Theme.textDisabled

    onClicked: {
      if (root.refused) return
      Tailscale.setAcceptDns(!root.dns)
    }

    TogglePill {
      objectName: "ts-settings-dns-switch"
      anchors.verticalCenter: parent.verticalCenter
      checked: root.dns
      enabled: !root.refused
      onToggled: dnsRow.clicked()
    }
  }
}
