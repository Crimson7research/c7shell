import QtQuick
import Quickshell
import C7
import qs.Theme
import qs.Common

// The panel behind the bar's Tailscale slot: who this machine is on the
// tailnet, what tailscaled says about it, and the two chevrons the mock puts
// the device list and the exit nodes behind.
//
// Everything that describes the tailnet is gated on `live`. TailscaleBackend.h
// is explicit about why: losing tailscaled publishes NoState and deliberately
// KEEPS the last snapshot, so the fail-closed exitNodeBlocked flag does not go
// quiet exactly when the daemon behind it dies. Drawing that snapshot anyway
// would render a healthy tailnet served by nothing.
//
// v1 is read-only. `tailscale set` refuses for a non-root, non-operator user,
// so the connect toggle and the exit-node rows render disabled rather than
// offering an action that would fail.
GlassPopover {
  id: root

  name: "tailscale"
  panelWidth: 320
  gap: 10

  // "root" | "devices" | "exit" -- the mock's three panels, which are one
  // panel here because they share a header and a width.
  property string view: "root"

  readonly property bool live: Tailscale.state !== Tailscale.NoState

  // The eight-state vocabulary renders as the header's subtitle, never as its
  // own element.
  readonly property string stateText: {
    switch (Tailscale.state) {
    case Tailscale.NoState: return qsTr("no daemon")
    case Tailscale.NeedsMachineAuth: return qsTr("waiting for machine approval")
    case Tailscale.NeedsLogin: return qsTr("logged out")
    case Tailscale.Stopped: return qsTr("not connected")
    case Tailscale.Starting: return qsTr("starting…")
    }
    return Tailscale.exitNodeBlocked ? qsTr("exit node unreachable") : qsTr("connected")
  }

  // An invalid QDateTime reaches QML as an Invalid Date, and a backend that
  // has never heard a key expiry hands over nothing at all -- a tagged node
  // and a node with key expiry disabled both report no expiry, and neither
  // should grow a line about it.
  readonly property bool keyExpires: {
    const d = Tailscale.keyExpiry
    return d instanceof Date && !isNaN(d.getTime())
  }

  // Measured in days and divided by the average month, not walked across the
  // calendar: a month-end expiry that lands in a shorter month would otherwise
  // read one month short of what the tailnet admin set.
  //
  // `new Date()` is not a binding dependency, so this re-reads only when the
  // expiry itself moves. A key that expires in eighteen months does not need
  // the line to tick over while the panel is open.
  readonly property string expiryText: {
    if (!root.keyExpires) return ""
    const ms = Tailscale.keyExpiry.getTime() - Date.now()
    if (ms <= 0) return qsTr("session expired")
    const days = Math.floor(ms / 86400000)
    const months = Math.round(days / 30.436875)
    if (months > 1) return qsTr("expires in %1 months").arg(months)
    if (months === 1) return qsTr("expires in 1 month")
    if (days > 1) return qsTr("expires in %1 days").arg(days)
    // `days` is floored, so one whole day left is anything from 24 to 48
    // hours out -- which is a day, not "under a day".
    if (days === 1) return qsTr("expires in 1 day")
    return qsTr("expires in under a day")
  }

  // The panel always reopens on the root view, and never over a menu left up
  // from last time.
  onOpenChanged: if (!root.open) {
    root.view = "root"
    copyMenu.close()
  }

  // GlassPopover's default property appends into its content Column, and that
  // append happens AFTER an element's own property assignments -- so a
  // `parent:` written in the declaration below would be overwritten by it.
  // Moved here instead, where the Column has already let go: the menu is an
  // overlay over the whole panel, not a row in it.
  Component.onCompleted: copyMenu.parent = root.panel

  function openCopyMenu(displayName, ip4, ip6, dnsName, sceneX, sceneY) {
    copyMenu.displayName = displayName
    copyMenu.ip4 = ip4
    copyMenu.ip6 = ip6
    copyMenu.dnsName = dnsName
    const p = root.panel.mapFromItem(null, sceneX, sceneY)
    copyMenu.showAt(p.x, p.y)
  }

  CopyMenu {
    id: copyMenu
    // Sized rather than anchored: it spends the first moment of its life as a
    // child of the content Column, and a Column warns about anchored children.
    width: root.panel.width
    height: root.panel.height
  }

  // -- header ---------------------------------------------------------------
  Item {
    width: parent.width
    implicitHeight: 28

    // The back chevron takes the place of the glyph on the two sub-panels,
    // exactly as the mock draws them.
    Icon {
      id: headIcon
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      visible: root.view === "root"
      name: "globe"
      size: 15
      tint: Tailscale.state !== Tailscale.Running ? Theme.textDisabled
        : Tailscale.exitNodeActive ? Theme.accentSoft : Theme.text
    }
    Text {
      id: backChevron
      objectName: "ts-back"
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      visible: root.view !== "root"
      width: 15
      horizontalAlignment: Text.AlignHCenter
      text: "‹"
      font { family: Theme.fontMono; pixelSize: 14; weight: 500 }
      color: Theme.text3

      MouseArea {
        anchors { fill: parent; margins: -6 }
        onClicked: root.view = "root"
      }
    }

    Column {
      anchors {
        left: headIcon.right; leftMargin: 10
        right: toggleHit.left; rightMargin: 10
        verticalCenter: parent.verticalCenter
      }
      spacing: 1

      Text {
        width: parent.width
        text: root.view === "devices" ? qsTr("network devices")
          : root.view === "exit" ? qsTr("exit nodes")
          : qsTr("tailscale")
        font { family: Theme.fontMono; pixelSize: 12; weight: 600 }
        color: Theme.text
        elide: Text.ElideRight
      }
      Text {
        objectName: "ts-state"
        width: parent.width
        visible: root.view === "root"
        text: root.stateText
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Tailscale.exitNodeBlocked ? Theme.accentSoft : Theme.text3
        elide: Text.ElideRight
      }
    }

    // The toggle is prefs.WantRunning, which is a write, which v1 does not
    // have. Shown anyway, dead, with the reason under the pointer: leaving it
    // out would make the panel look like it had never been designed to have
    // one.
    Item {
      id: toggleHit
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      width: connectToggle.width
      height: connectToggle.height

      TogglePill {
        id: connectToggle
        checked: Tailscale.state === Tailscale.Running
        enabled: false
      }

      MouseArea {
        id: toggleHover
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
      }

      Tooltip {
        open: toggleHover.containsMouse
        anchorItem: toggleHit
        panelWidth: tipLabel.implicitWidth + 16
        panelHeight: tipLabel.implicitHeight + 10
        panelRadius: Theme.radiusChip

        Text {
          id: tipLabel
          anchors.centerIn: parent
          text: qsTr("read-only: tailscale set needs root or the operator")
          font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
          color: Theme.text2
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // -- the daemon is gone ---------------------------------------------------
  // The one thing drawn when state is NoState. Everything below this is the
  // last snapshot and would be a lie.
  ListRow {
    width: parent.width
    visible: !root.live
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: false
    titleColor: Theme.textDisabled
    title: qsTr("tailscaled is not responding")
  }

  // -- the state the module exists for --------------------------------------
  // Under the header and above every row, on whichever view is up: egress is
  // being dropped on purpose and nothing else on screen says so.
  Rectangle {
    objectName: "ts-blocked-alert"
    width: parent.width
    visible: root.live && Tailscale.exitNodeBlocked
    implicitHeight: blockedText.implicitHeight + 20
    radius: Theme.radiusChip
    color: Theme.accentFill
    border.width: 1
    border.color: Theme.accentBorder

    Icon {
      id: blockedIcon
      anchors { left: parent.left; leftMargin: 11; top: parent.top; topMargin: 11 }
      name: "alert-triangle"
      size: 12
      tint: Theme.accentSoft
    }
    Text {
      id: blockedText
      objectName: "ts-blocked-text"
      anchors {
        left: blockedIcon.right; leftMargin: 9
        right: parent.right; rightMargin: 11
        verticalCenter: parent.verticalCenter
      }
      // Tailscale's own exitNodeOfflineExplainer: blocked, not degraded. The
      // node name is joined back off the peer list by the backend and is
      // tailscaled's string, so PlainText.
      text: qsTr("Cannot reach exit node %1. Internet traffic is blocked until you disable the exit node or choose another.")
        .arg(Tailscale.exitNodeName)
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
      color: Theme.accentSoft
    }
  }

  // -- health ---------------------------------------------------------------
  Column {
    width: parent.width
    spacing: 6
    visible: root.live && Tailscale.issueCount > 0

    ListRow {
      objectName: "ts-issue-count"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      hoverable: false
      titleColor: Theme.warning
      title: Tailscale.issueCount === 1 ? qsTr("1 issue detected…")
        : qsTr("%1 issues detected…").arg(Tailscale.issueCount)
    }

    SectionLabel { text: qsTr("current issues") }

    Repeater {
      model: Tailscale.issues

      Text {
        required property string modelData

        objectName: "ts-issue"
        width: parent.width
        leftPadding: 8
        rightPadding: 8
        // tailscaled's own health warnings, verbatim. They are the user's own
        // tailnet talking about itself, not a disclosure -- but they are
        // daemon-supplied text, and StyledText or RichText here would be
        // markup injection into our own bar.
        text: modelData
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.warning
      }
    }
  }

  // -- root view ------------------------------------------------------------
  Column {
    width: parent.width
    spacing: 2
    visible: root.live && root.view === "root"

    ListRow {
      objectName: "ts-self-name"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      hoverable: false
      title: qsTr("this device")

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Tailscale.selfName
        textFormat: Text.PlainText
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.text3
      }
    }

    // Tailscale ships three copy actions; one row covers the common case and
    // the other two fit the right-click menu.
    ListRow {
      id: selfIp

      property bool copied: false

      objectName: "ts-self-ip4"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 400
      titleColor: selfIp.copied ? Theme.accentSoft : Theme.alpha(Theme.text, 0.85)
      title: Tailscale.selfIp4

      onClicked: {
        if (Tailscale.selfIp4 === "") return
        Quickshell.clipboardText = Tailscale.selfIp4
        selfIp.copied = true
        selfCopyReset.restart()
      }

      underlay: MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        onClicked: mouse => {
          const p = selfIp.mapToItem(null, mouse.x, mouse.y)
          root.openCopyMenu(Tailscale.selfName, Tailscale.selfIp4, Tailscale.selfIp6,
                            Tailscale.selfDnsName, p.x, p.y)
        }
      }

      Timer {
        id: selfCopyReset
        interval: 1100
        onTriggered: selfIp.copied = false
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // Feedback stays in the row: a popover has nowhere else to put it, and
        // a toast for a copy would outlive the panel that raised it.
        text: selfIp.copied ? "✓" : (selfIp.hovered ? qsTr("copy") : "")
        font { family: Theme.fontMono; pixelSize: 10; weight: 500 }
        color: selfIp.copied ? Theme.accentSoft : Theme.text3
      }
    }

    // Always shown, never gated on a threshold: hidden until it is nearly due
    // means invisible for its whole development life.
    Text {
      objectName: "ts-expiry"
      width: parent.width
      visible: root.keyExpires
      leftPadding: 8
      topPadding: 5
      bottomPadding: 5
      text: root.expiryText
      font { family: Theme.fontMono; pixelSize: 11; weight: 400 }
      color: Theme.textDisabled
    }

    ListRow {
      objectName: "ts-devices-row"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      title: qsTr("network devices")

      onClicked: root.view = "devices"

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: peerList.count
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.text3
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "›"
        font { family: Theme.fontMono; pixelSize: 11; weight: 500 }
        color: Theme.text3
      }
    }

    ListRow {
      objectName: "ts-exit-row-entry"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      title: qsTr("exit nodes")

      onClicked: root.view = "exit"

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Tailscale.exitNodeActive ? Tailscale.exitNodeName : qsTr("none")
        textFormat: Text.PlainText
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Tailscale.exitNodeActive ? Theme.accentSoft : Theme.text3
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "›"
        font { family: Theme.fontMono; pixelSize: 11; weight: 500 }
        color: Theme.text3
      }
    }
  }

  // -- network devices ------------------------------------------------------
  // The ListView is instantiated on whichever view is up, because the root
  // view reads its `count` for the chevron row. An invisible view costs its
  // delegates and nothing else.
  ListView {
    id: peerList

    objectName: "ts-peer-list"
    width: parent.width
    height: Math.min(contentHeight, 196)
    visible: root.live && root.view === "devices"
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: Tailscale.peers

    // Rows arrive already sorted Mine / Tagged / Others, and PeerModel moves a
    // row rather than removing and re-inserting it, so a section heading falls
    // out of the data with no special casing -- and a group with no peers in
    // it produces no heading at all.
    section.property: "group"
    section.criteria: ViewSection.FullString
    section.delegate: SectionLabel {
      required property string section

      objectName: "ts-section"
      width: peerList.width
      height: 20
      verticalAlignment: Text.AlignBottom
      text: section === "0" ? qsTr("my devices")
        : section === "1" ? qsTr("tagged devices")
        : qsTr("other users")
    }

    // The cache keeps a row that scrolls just out of sight alive, so the model
    // is not the only thing standing between a delegate and its local state.
    cacheBuffer: 400

    delegate: PeerRow {
      id: peerDelegate

      width: peerList.width
      onMenuRequested: (sceneX, sceneY) =>
        root.openCopyMenu(peerDelegate.displayName, peerDelegate.ip4, peerDelegate.ip6,
                          peerDelegate.dnsName, sceneX, sceneY)
    }
  }

  // -- exit nodes -----------------------------------------------------------
  ExitNodeList {
    width: parent.width
    visible: root.live && root.view === "exit"
  }
}
