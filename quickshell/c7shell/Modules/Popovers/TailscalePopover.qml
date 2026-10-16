import QtQuick
import Quickshell
import C7
import qs.Theme
import qs.Common

// The panel behind the bar's Tailscale slot: who this machine is on the
// tailnet, what tailscaled says about it, and the chevrons the mock puts the
// device list, the exit nodes and the tailnet settings behind.
//
// Those open as SUB-CARDS folded out of this one, the way the macOS menu
// grows its submenus -- the root rows stay where they were and the card gets
// taller. v1 swapped the panel's contents for them and offered a `‹` back,
// which loses the state the person opened the panel to read (what this machine
// is, whether egress is blocked) at the moment they go looking for a device.
//
// Nothing in Common/GlassPopover had to change for it, and nothing in it was
// changed: the panel already sizes itself off its content Column, so a card
// that appears in that Column grows the popover on its own. GlassPopover is
// also the base for the bluetooth, wifi and power panels, and a sizing or
// anchoring change there reaches all three for no gain here.
//
// Everything that describes the tailnet is gated on `live`. TailscaleBackend.h
// is explicit about why: losing tailscaled publishes NoState and deliberately
// KEEPS the last snapshot, so the fail-closed exitNodeBlocked flag does not go
// quiet exactly when the daemon behind it dies. Drawing that snapshot anyway
// would render a healthy tailnet served by nothing.
//
GlassPopover {
  id: root

  name: "tailscale"
  panelWidth: 320
  gap: 10

  // "" | "devices" | "exit" | "settings" -- which sub-card is folded out, and
  // only ever one: two open at once is a popover taller than the screen, and
  // the macOS menu does not do it either.
  property string expanded: ""

  // Where this popover's height is decided. A sub-card's list is capped at
  // this and scrolls past it; everything around the list -- a search field, a
  // section heading, the preference rows -- stays pinned. The spec names a
  // hundred-device tailnet, which is 3000px of rows hanging off a 38px bar.
  readonly property int subListCap: 180

  readonly property bool live: Tailscale.state !== Tailscale.NoState

  // `writable` is a claim about the LAST write and never permission for the
  // next one -- TailscaleBackend.h spells that out, because the name invites
  // the opposite reading. The header's toggle is live until tailscaled has
  // refused something and dead afterwards, which is the same rule the
  // exit-node rows and the settings switches follow. The two sub-cards read
  // this off their own files; the header is the root card's one control.
  readonly property bool refused: !Tailscale.writable

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

  // The panel always reopens folded shut, and never over a menu left up from
  // last time.
  onOpenChanged: if (!root.open) {
    root.expanded = ""
    copyMenu.close()
  }

  // The row that opened a sub-card is the row that closes it -- there is no
  // back chevron any more, so the chevron on the row has to work both ways.
  function fold(which) {
    root.expanded = root.expanded === which ? "" : which
    // Focused as it grows, which is the order Common/PskField.ask() uses and
    // the only one in this shell proven to take keystrokes under the popover's
    // Hyprland focus grab. See Common/SearchField for what the keys travel
    // through to get here.
    if (root.expanded === "devices") deviceSearch.focusInput()
    else if (root.expanded === "exit") exitList.focusSearch()
    // Nothing on the settings card takes the keyboard, and nothing is on
    // screen at all once a card folds shut -- so focus goes back to the panel,
    // or esc stops closing the popup, the field that held it having just been
    // folded away. Common/PskField.collapse() does the same, for the same
    // reason.
    else root.panel.forceActiveFocus()
  }

  // -- filtering the device list ---------------------------------------------
  // Folded once rather than per row per keystroke.
  readonly property string deviceQuery: deviceSearch.text.trim().toLowerCase()

  function deviceMatches(displayName) {
    return root.deviceQuery === ""
      || displayName.toLowerCase().indexOf(root.deviceQuery) >= 0
  }

  // How many rows of each group the query leaves standing, and how many in
  // all. Counted off the delegates and not off the model, because the model is
  // a QAbstractItemModel and QML has no way to walk one.
  //
  // The rows PUSH this rather than the panel walking the view for it, which
  // ExitNodeList's Repeater can do and a ListView cannot: a delegate the view
  // has just built is not yet reachable through itemAtIndex(), so a walk
  // triggered from its own creation misses it and nothing ever triggers
  // another. Measured, on fifty devices filtered to the last one: the only
  // match in the list reported no group at all and its heading went with it.
  // A row adding and removing itself is a statement no walk can be too early
  // for.
  property var groupTally: ({})
  property int deviceMatchCount: 0
  // `groupTally` is mutated in place and a `var` property does not announce
  // that, so this is the dependency the headings actually bind to.
  property int tallyRevision: 0

  function tallyDevice(group, delta) {
    root.groupTally[group] = (root.groupTally[group] ?? 0) + delta
    root.deviceMatchCount += delta
    ++root.tallyRevision
  }

  function groupMatched(group) {
    // tallyRevision is read for the dependency, never for the value.
    return root.tallyRevision >= 0 && (root.groupTally[group] ?? 0) > 0
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

    // v1 swapped this glyph for a `‹` on the two sub-panels. There are no
    // sub-panels any more -- the card keeps its own identity while a sub-card
    // is out of it, so the header never changes and there is nowhere to go
    // back to.
    Icon {
      id: headIcon
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      name: "globe"
      size: 15
      tint: Tailscale.state !== Tailscale.Running ? Theme.textDisabled
        : Tailscale.exitNodeActive ? Theme.accentSoft : Theme.text
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
        text: qsTr("tailscale")
        font { family: Theme.fontMono; pixelSize: 12; weight: 600 }
        color: Theme.text
        elide: Text.ElideRight
      }
      Text {
        objectName: "ts-state"
        width: parent.width
        text: root.stateText
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Tailscale.exitNodeBlocked ? Theme.accentSoft : Theme.text3
        elide: Text.ElideRight
      }
    }

    // prefs.WantRunning: connect and disconnect this machine from the tailnet.
    //
    // It shipped `enabled: false` under a tooltip saying the panel could not
    // write, which was true in v1 and stopped being true the moment the
    // contract grew actions. A control that is permanently dead cannot be
    // told apart from one whose write tailscaled is refusing -- which is the
    // distinction this whole module is built around.
    //
    // NO CONFIRMATION, DELIBERATELY, and this is the one control on the panel
    // where that was a decision rather than a default. WantRunning: false is
    // `tailscale down`: it drops the tailnet, and on a machine reached OVER
    // tailscale it ends the session doing the clicking -- the one action here
    // that cannot be undone from where it was taken. Three reasons it is
    // still a plain toggle: the macOS menu offers it as one; a confirmation
    // on a quick-settings switch is dismissed rather than read, so it trains
    // the habit it is meant to interrupt; and a popover has nowhere to put a
    // modal that does not also cover the state the person opened it to read.
    // What it gets instead is a sentence under the pointer saying what it
    // does, which is the thing the mock's bare pill never said.
    Item {
      id: toggleHit
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      width: connectToggle.width
      height: connectToggle.height

      TogglePill {
        id: connectToggle

        objectName: "ts-connect-toggle"
        // WantRunning, NOT `state` -- what tailscaled was TOLD, never what it
        // is doing. The two disagree for as long as a machine is Starting and
        // indefinitely on a logged-out one that wants to be up, and on both
        // of those a toggle drawn off `state` says the daemon was told to
        // stop when it was not. `state` is on screen already, as the header's
        // subtitle, which is where "is the tailnet actually up" belongs.
        //
        // Gated on `live` all the same: NoState keeps the last snapshot, so
        // WantRunning then describes a daemon that is not there, and every
        // other row on this panel is gated the same way.
        checked: root.live && Tailscale.wantRunning
        // Live by default. Dead after a refusal -- and dead with no daemon to
        // ask, which is not a judgement about permission but the absence of
        // anything to write to.
        enabled: root.live && !root.refused

        // The request, never an assignment: the next Prefs notification is
        // what moves the pill, as it is for the other three switches.
        onToggled: {
          if (!root.live || root.refused) return
          Tailscale.setWantRunning(!Tailscale.wantRunning)
        }
      }

      MouseArea {
        id: toggleHover
        anchors.fill: parent
        hoverEnabled: true
        // Hover only: the press belongs to the pill underneath.
        acceptedButtons: Qt.NoButton
      }

      Tooltip {
        open: toggleHover.containsMouse
        anchorItem: toggleHit
        panelWidth: tipLabel.width + 16
        panelHeight: tipLabel.implicitHeight + 10
        panelRadius: Theme.radiusChip

        Text {
          id: tipLabel

          objectName: "ts-connect-tip"
          anchors.centerIn: parent
          // CAPPED, because this label stopped being one short phrase: the
          // refusal branch is three sentences and tailscaled's own words, and
          // an uncapped implicitWidth would hang a 1000px tooltip off a 320px
          // panel. Text.implicitWidth is the unwrapped width and does not
          // depend on `width`, so this is a cap and not a loop.
          width: Math.min(tipLabel.implicitWidth, 220)
          // After a refusal it carries tailscaled's own words plus the advice
          // the contract deliberately does not phrase. The root card has no
          // inline refusal line of its own -- the two sub-cards each carry
          // one, and a third here would put two explanations on screen at
          // once whenever a card is folded out.
          text: root.refused
            ? qsTr("tailscaled refused the change: it takes orders only from root or its operator. Run c7shell-bootstrap to name this user. (%1)").arg(Tailscale.writeError)
            : !root.live ? qsTr("tailscaled is not answering, so there is nothing to ask")
            : Tailscale.wantRunning
              ? qsTr("disconnect from the tailnet — a session reached over tailscale ends with it")
              : qsTr("connect to the tailnet")
          // Carries the daemon's own refusal verbatim on one of its branches.
          textFormat: Text.PlainText
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
  Column {
    width: parent.width
    visible: !root.live
    spacing: 4

    ListRow {
      objectName: "ts-no-daemon"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      hoverable: false
      titleColor: Theme.textDisabled
      title: qsTr("tailscaled is not responding")
    }

    // WHY, when this module can say why. NoState is three different things --
    // nothing has answered yet, there is no tailscaled here, and tailscaled is
    // there and cannot be read -- and the row above is the same sentence for
    // all three. readError is the third one's own words: a 403, a socket
    // closed mid-body, a non-hex chunk length, a timeout, a reply that is not
    // a status. It is empty for the other two, so this line appears exactly
    // when there is something to add.
    //
    // Not the row's subtitle: a diagnosis is a sentence and that row elides to
    // one line, and the one thing a person can act on here is the whole of it.
    Text {
      objectName: "ts-read-error"
      width: parent.width
      visible: Tailscale.readError !== ""
      leftPadding: 8
      rightPadding: 8
      text: Tailscale.readError
      // Whatever failed the read, in its own words, which makes it
      // daemon-supplied text.
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
      color: Theme.textDisabled
    }
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

  // -- the card -------------------------------------------------------------
  // No longer gated on a view: these rows are what the panel IS, and they stay
  // on screen while a sub-card is folded out from between them.
  Column {
    width: parent.width
    spacing: 2
    visible: root.live

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

      onClicked: root.fold("devices")

      // WHAT THE LIST IS SHOWING, which is the tailnet's own total only while
      // nothing is filtering it. The search lives inside the card this row
      // opens, so with a query running the tailnet count sits above a list of
      // one and reads as a lie -- and this number is the only thing on screen
      // that says how many devices the query left standing.
      Text {
        objectName: "ts-devices-count"
        anchors.verticalCenter: parent.verticalCenter
        text: root.deviceQuery === "" ? peerList.count : root.deviceMatchCount
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.text3
      }
      FoldChevron {
        objectName: "ts-devices-chevron"
        anchors.verticalCenter: parent.verticalCenter
        open: root.expanded === "devices"
      }
    }

    // -- network devices ----------------------------------------------------
    SubCard {
      objectName: "ts-devices-card"
      width: parent.width
      visible: root.live && root.expanded === "devices"

      SearchField {
        id: deviceSearch
        objectName: "ts-peer-search"
        fieldName: "ts-peer-search-input"
        width: parent.width
      }

      // Instantiated whether or not the card is out, because the row above
      // reads its `count` for the device tally. An invisible view costs its
      // delegates and nothing else -- and keeping it alive is also what makes
      // folding the card away and back NOT a reload: a Loader here would
      // destroy every row and whatever it was holding.
      ListView {
        id: peerList

        objectName: "ts-peer-list"
        width: parent.width
        height: Math.min(contentHeight, root.subListCap)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: Tailscale.peers

        // Rows arrive already sorted Mine / Tagged / Others, and PeerModel
        // moves a row rather than removing and re-inserting it, so a section
        // heading falls out of the data with no special casing -- and a group
        // with no peers in it produces no heading at all.
        section.property: "group"
        section.criteria: ViewSection.FullString
        // The label sits in a slot rather than being the section delegate
        // itself, and that is load-bearing: a ListView OWNS `visible` on a
        // section item and writes its own value over any binding put there --
        // measured, the heading stayed on screen at zero height. The slot is
        // the view's to show and hide; the label inside it is this panel's.
        section.delegate: Item {
          id: sectionSlot

          required property string section

          // A heading over a group the QUERY emptied has to go as well, or a
          // filtered list reads as a group the search removed the devices
          // from. Never consulted without a query: see tallyDevice().
          readonly property bool shown: root.deviceQuery === ""
            || root.groupMatched(sectionSlot.section)

          width: peerList.width
          // Collapsed as well as hidden: a section item keeps its slot in the
          // view, so a heading that is merely invisible leaves a 20px hole
          // where the group used to be.
          height: sectionSlot.shown ? 20 : 0

          SectionLabel {
            objectName: "ts-section"
            anchors.fill: parent
            visible: sectionSlot.shown
            verticalAlignment: Text.AlignBottom
            text: sectionSlot.section === "0" ? qsTr("my devices")
              : sectionSlot.section === "1" ? qsTr("tagged devices")
              : qsTr("other users")
          }
        }

        // The cache keeps a row that scrolls just out of sight alive, so the
        // model is not the only thing standing between a delegate and its
        // local state.
        cacheBuffer: 400

        delegate: PeerRow {
          id: peerDelegate

          // Reported rather than read off `visible`, so the counts above do
          // not depend on the view having laid out yet.
          readonly property bool matched: root.deviceMatches(peerDelegate.displayName)

          width: peerList.width
          visible: peerDelegate.matched
          // Collapsed rather than merely hidden, for the same reason the
          // heading is: a hidden row of its own height leaves a gap in the
          // list exactly where it was filtered out.
          height: peerDelegate.matched ? peerDelegate.implicitHeight : 0

          // Which group this row is currently counted under, or -1 for not
          // counted. Remembered rather than recomputed, because the group a
          // row has to be taken OUT of is the one it was put into: PeerModel
          // moves a device between groups in place, and a row that gave its
          // match back to the group it had just moved to would leave the
          // heading it came from standing over nothing.
          property int countedGroup: -1

          function syncTally() {
            const want = peerDelegate.matched ? peerDelegate.group : -1
            if (want === peerDelegate.countedGroup) return
            if (peerDelegate.countedGroup >= 0) root.tallyDevice(peerDelegate.countedGroup, -1)
            peerDelegate.countedGroup = want
            if (want >= 0) root.tallyDevice(want, 1)
          }

          onMatchedChanged: peerDelegate.syncTally()
          onGroupChanged: peerDelegate.syncTally()
          Component.onCompleted: peerDelegate.syncTally()
          // A row the view frees is a row that is no longer standing. Without
          // this the tally only ever grows and every heading stays up.
          Component.onDestruction: {
            if (peerDelegate.countedGroup >= 0) root.tallyDevice(peerDelegate.countedGroup, -1)
            peerDelegate.countedGroup = -1
          }

          onMenuRequested: (sceneX, sceneY) =>
            root.openCopyMenu(peerDelegate.displayName, peerDelegate.ip4, peerDelegate.ip6,
                              peerDelegate.dnsName, sceneX, sceneY)
        }
      }

      // The two empty lists a device list has to tell apart, as the exit-node
      // panel tells them apart: a query nobody answers to is not a tailnet
      // with nothing on it, and a panel that says the wrong one of those looks
      // broken rather than filtered.
      ListRow {
        objectName: "ts-peer-no-match"
        width: parent.width
        visible: root.deviceQuery !== "" && root.deviceMatchCount === 0 && peerList.count > 0
        implicitHeight: 30
        radius: Theme.radiusMenuRow
        inset: 8
        titleSize: 11
        titleWeight: 500
        hoverable: false
        titleColor: Theme.textDisabled
        title: qsTr("no matches")
      }

      ListRow {
        objectName: "ts-peer-empty"
        width: parent.width
        visible: peerList.count === 0
        implicitHeight: 30
        radius: Theme.radiusMenuRow
        inset: 8
        titleSize: 11
        titleWeight: 500
        hoverable: false
        titleColor: Theme.textDisabled
        title: qsTr("no other devices on this tailnet")
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

      onClicked: root.fold("exit")

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: Tailscale.exitNodeActive ? Tailscale.exitNodeName : qsTr("none")
        textFormat: Text.PlainText
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Tailscale.exitNodeActive ? Theme.accentSoft : Theme.text3
      }
      FoldChevron {
        objectName: "ts-exit-chevron"
        anchors.verticalCenter: parent.verticalCenter
        open: root.expanded === "exit"
      }
    }

    // -- exit nodes ---------------------------------------------------------
    SubCard {
      objectName: "ts-exit-card"
      width: parent.width
      visible: root.live && root.expanded === "exit"

      ExitNodeList {
        id: exitList
        width: parent.width
        maxListHeight: root.subListCap
      }
    }

    ListRow {
      objectName: "ts-settings-row"
      width: parent.width
      implicitHeight: 30
      radius: Theme.radiusMenuRow
      inset: 8
      titleSize: 11
      titleWeight: 500
      title: qsTr("settings")

      onClicked: root.fold("settings")

      FoldChevron {
        objectName: "ts-settings-chevron"
        anchors.verticalCenter: parent.verticalCenter
        open: root.expanded === "settings"
      }
    }

    // -- settings -----------------------------------------------------------
    // Last, and deliberately: the rows above are this machine on the tailnet
    // and what its traffic is doing, which is what the panel is opened for.
    // These two are the tailnet's own settings and are changed once.
    //
    // No cap and no Flickable, unlike the other two: this card holds two rows
    // and a paragraph, and all three are known at build time rather than
    // coming from a tailnet that may have a hundred of anything.
    SubCard {
      objectName: "ts-settings-card"
      width: parent.width
      visible: root.live && root.expanded === "settings"

      TailscaleSettings {
        width: parent.width
      }
    }
  }

  // The card inside the card. Its own surface and hairline, because a list
  // that simply appeared between two rows would read as more rows rather than
  // as something folded out of one of them.
  component SubCard: Rectangle {
    default property alias body: cardColumn.data

    implicitHeight: cardColumn.implicitHeight + 16
    radius: Theme.radiusChip
    color: Theme.surface04
    border.width: 1
    border.color: Theme.hairline
    clip: true

    Column {
      id: cardColumn
      anchors { top: parent.top; left: parent.left; right: parent.right; margins: 8 }
      spacing: 6
    }
  }

  // The `›` the mock puts on a row that opens something, turned a quarter when
  // what it opens is open. Deliberately NOT animated: the popup window itself
  // resizes in one step when the card grows, so a chevron easing round over
  // 120ms next to a panel that snapped reads as a dropped frame rather than as
  // motion.
  component FoldChevron: Text {
    property bool open: false

    text: "›"
    rotation: open ? 90 : 0
    font { family: Theme.fontMono; pixelSize: 11; weight: 500 }
    color: Theme.text3
  }
}
