import QtQuick
import QtQml

// The whole greeter, driven by explicit properties rather than by sddm's
// context objects: Main.qml wires those in, and tests/greeter-preview.qml wires
// mock ones in, so the layout can be run and looked at without a display
// manager -- which is the only way to see a greeter without logging out.
FocusScope {
  id: root

  // -- what sddm provides --------------------------------------------------
  property string hostName: ""
  property var users: null           // userModel: name, realName, icon roles
  property var sessions: null        // sessionModel: name, comment, type roles
  property var layouts: []           // keyboard.layouts, a QList<QObject*>
  // userModel.lastUser: the account sddm recorded on the last successful
  // login. A name rather than an index, which is what makes it usable here --
  // see applyLastUser().
  property string lastUser: ""
  property int currentLayout: 0
  property bool capsLock: false
  property bool canSuspend: true
  property bool canReboot: true
  property bool canPowerOff: true

  // -- theme.conf ----------------------------------------------------------
  property url wallpaper: ""
  property bool showGrid: true
  property bool allowManualLogin: false
  // "auto" shows the user panel when there is more than one account.
  property string userList: "auto"
  // Where the NetworkManager dispatcher script publishes the current
  // connection. A property so the preview can substitute a file of its own.
  property string networkFile: "/run/c7shell/network"
  property int maxAttempts: 3
  property int cooldownSeconds: 30
  // Everything but the backdrop is drawn on the primary screen only: a second
  // monitor gets the same ground, so the pair looks deliberate rather than
  // duplicated. theme.conf's loginOnAllScreens=true sets this on every screen
  // instead, which puts a card on each of them.
  property bool primary: true
  // Which instance owns the shared Theme.s. Exactly one screen may, whatever
  // `primary` says -- see applyScale().
  property bool scaleAuthority: true

  // The field's contents. Only the preview harness writes this -- sddm's
  // greeter has a keyboard.
  property alias password: field.text

  signal loginRequested(string user, string password, int sessionIndex)
  signal suspendRequested
  signal rebootRequested
  signal powerOffRequested
  signal layoutRequested(int index)

  // -- state ---------------------------------------------------------------
  property int userIndex: 0
  property int sessionIndex: 0
  // Whether the last account has been preselected yet; see applyLastUser().
  property bool lastUserApplied: false
  property bool usersHidden: false    // "hide users" on a multi-user machine
  property bool usersForced: false    // "switch user" on a single-user one
  property bool sessionsOpen: false
  property int attempt: 0
  property int cooldown: 0
  property string message: ""
  // What PAM has said during this sign-in attempt -- see showMessage() below.
  property var messages: []
  // True once PAM is plainly asking for something this greeter cannot give it;
  // see showMessage(). The panel then tells the user where they can.
  property bool conversationStuck: false
  // How many times the same message may repeat before we call it a loop. Two
  // is a legitimate retry -- mistyped PIN, wrong number -- three is not.
  readonly property int stuckAfter: 3

  readonly property int userCount: root.users ? root.users.count : 0
  readonly property int sessionCount: root.sessions ? root.sessions.count : 0
  readonly property int layoutCount: root.layouts ? root.layouts.length : 0
  // The "other..." row sits one past the last account.
  readonly property bool manual: root.allowManualLogin && root.userIndex === root.userCount
  readonly property bool userPanelVisible: !root.usersHidden
                                           && (root.usersForced
                                               || root.userList === "always"
                                               || (root.userList === "auto"
                                                   && (root.userCount > 1 || root.allowManualLogin)))

  // -- model reads ---------------------------------------------------------
  // Bumped whenever a Repeater finishes populating, so the bindings that call
  // the helpers below re-evaluate: a function call tracks no dependency of its
  // own, and the models arrive one frame after the properties do.
  property int rowsRevision: 0
  // A QAbstractItemModel offers QML no way to read row N by role name, so one
  // non-visual Instantiator per model mirrors the roles into objects that can
  // be indexed. Cheap: three plain QtObjects per row, no delegates, no views.
  function userField(index, key) {
    root.rowsRevision            // dependency, see above
    const row = index >= 0 && index < root.userCount ? userRows.itemAt(index) : null
    return row ? row[key] : ""
  }
  function sessionName(index) {
    root.rowsRevision            // dependency, see above
    const row = index >= 0 && index < root.sessionCount ? sessionRows.itemAt(index) : null
    return row ? row.name : ""
  }
  function layoutName(index) {
    const row = root.layouts && index >= 0 && index < root.layoutCount ? root.layouts[index] : null
    return row ? row.shortName : ""
  }

  // Preselect the account that logged in last.
  //
  // sddm also offers userModel.lastIndex, but that is an index into a model
  // the account need not be in. sddm builds the list from NSS and then drops
  // anything outside Users/MinimumUid..MaximumUid, which defaults to
  // 1000..60513 -- a directory backend that derives uids by hash lands far
  // above that (Himmelblau's default range is 200000..2000200000), so the
  // account enumerates perfectly well and is discarded anyway. lastIndex then
  // lands on whichever local account happens to be first, which is how
  // logging out used to hand you somebody else's name.
  //
  // Match on the name instead. Names need normalising: NSS may report a
  // directory account under a short name while sddm recorded the UPN that was
  // typed, so compare case-insensitively and treat "adriaan" and
  // "adriaan@crimson7.io" as the same account. When the name really is not in
  // the list, take the manual row and fill it in -- logging out should return
  // you to yourself either way.
  // "ADRIAAN@crimson7.io" and "adriaan" both reduce to "adriaan".
  function userKey(name) {
    const n = String(name).toLowerCase()
    const at = n.indexOf("@")
    return at > 0 ? n.substring(0, at) : n
  }

  // Where AccountsService keeps avatars, and where sddm itself looks for one
  // (it builds "/var/lib/AccountsService/icons/%1" from the login name). The
  // model's icon role already resolves this for a listed account; this is for
  // the manual row, where there is no model row to ask. Himmelblau writes the
  // file under the same short name, so userKey() lands on it.
  //
  // The name is typed, so keep it to the characters a login name can have --
  // a path built from free text has no business reaching outside this
  // directory. A miss is harmless: Image fails, hasPicture stays false and
  // the monogram shows instead.
  function accountsServiceIcon(name) {
    const key = root.userKey(name)
    if (key === "" || !/^[a-z0-9._-]+$/.test(key)) return ""
    return "file:///var/lib/AccountsService/icons/" + key
  }

  function applyLastUser() {
    if (root.lastUserApplied || root.lastUser === "") return
    const want = root.userKey(root.lastUser)
    for (let i = 0; i < root.userCount; i++) {
      if (root.userKey(root.userField(i, "name")) === want) {
        root.userIndex = i
        root.lastUserApplied = true
        lastUserFallback.stop()
        return
      }
    }
    // Not there -- but the models arrive a frame or two after the properties,
    // so let them settle before concluding the account is unlistable.
    lastUserFallback.restart()
  }

  Timer {
    id: lastUserFallback
    interval: 250
    onTriggered: {
      if (root.lastUserApplied || root.lastUser === "" || !root.allowManualLogin) return
      root.userIndex = root.userCount      // the manual row
      usernameInput.text = root.lastUser
      root.lastUserApplied = true
      // The name is already filled in, so the password is what is being asked
      // for -- focus belongs there, not back on the username.
      field.forceActiveFocus()
    }
  }

  // Repeater, not Instantiator: Instantiator's objects do not pick up model
  // roles as required properties, and a Repeater's do. The delegates are
  // sizeless and invisible -- they exist to be read by index.
  Repeater {
    id: userRows
    model: root.users
    delegate: Item {
      required property string name
      required property string realName
      required property string icon
      visible: false
      width: 0
      height: 0
    }
    onCountChanged: {
      root.rowsRevision = root.rowsRevision + 1
      root.applyLastUser()
    }
  }
  Repeater {
    id: sessionRows
    model: root.sessions
    delegate: Item {
      required property string name
      visible: false
      width: 0
      height: 0
    }
    onCountChanged: root.rowsRevision = root.rowsRevision + 1
  }

  // -- actions -------------------------------------------------------------
  function login() {
    if (root.cooldown > 0) return
    const name = root.manual ? usernameInput.text : root.userField(root.userIndex, "name")
    if (name === "") {
      if (root.manual) usernameInput.forceActiveFocus()
      return
    }
    root.message = ""
    root.messages = []
    root.conversationStuck = false
    root.loginRequested(name, field.text, root.sessionIndex)
  }

  // Called by Main.qml, from sddm's own signals.
  function loginFailed(text) {
    root.attempt = root.attempt + 1
    root.message = text && text !== "" ? text : qsTr("authentication failed")
    field.clear()
    field.shake()
    field.forceActiveFocus()
    // "third failure adds a 30 s cooldown"
    if (root.attempt >= root.maxAttempts) root.cooldown = root.cooldownSeconds
  }
  // PAM talks to us during a successful authentication too, not only a failed
  // one: an MFA number to type into a phone, "set up a PIN", "please wait".
  // Those are instructions, not rejections, so they must not consume an
  // attempt, clear what has been typed, or move the user toward the cooldown.
  // A genuine failure arrives separately, on sddm's loginFailed signal.
  // The backend asked something we have no answer for: a PIN to enrol, a new
  // password, a second factor. Put the question up and clear the field, but do
  // not touch the attempt counter -- nothing has been rejected.
  function promptAgain(text) {
    if (text && text !== "") root.showMessage(text)
    root.message = ""
    field.clear()
    field.forceActiveFocus()
  }

  function showMessage(text) {
    root.messages = root.messages.concat([text])

    // sddm's greeter protocol carries one secret per login() call, so a PAM
    // conversation that asks a second question -- enrolling a PIN, changing an
    // expired password -- cannot be answered from here. PAM re-asks, sddm sends
    // nothing, and the pair spin forever. The user sees no error and has no way
    // to know a text console would work. Spot the repetition and say so.
    var seen = 0
    for (var i = 0; i < root.messages.length; i++)
      if (root.messages[i] === text) seen++
    if (seen >= root.stuckAfter) root.conversationStuck = true
  }
  function loginSucceeded() {
    root.message = ""
    root.messages = []
    root.conversationStuck = false
    root.cooldown = 0
  }

  function cycleLayout() {
    if (root.layoutCount < 2) return
    root.layoutRequested((root.currentLayout + 1) % root.layoutCount)
  }
  function cycleSession(step) {
    if (root.sessionCount < 1) return
    root.sessionIndex = (root.sessionIndex + step + root.sessionCount) % root.sessionCount
  }
  function moveUser(step) {
    const count = root.userCount + (root.allowManualLogin ? 1 : 0)
    if (count < 2) return
    root.userIndex = (root.userIndex + step + count) % count
    root.message = ""
    root.messages = []
    root.conversationStuck = false
    field.clear()
    // Moving through a list you cannot see is disorienting, so show it.
    root.usersHidden = false
    root.usersForced = true
    if (root.manual) usernameInput.forceActiveFocus()
    else field.forceActiveFocus()
  }
  function toggleUserPanel() {
    if (root.userPanelVisible) { root.usersHidden = true; root.usersForced = false }
    else { root.usersHidden = false; root.usersForced = true }
    field.forceActiveFocus()
  }

  Timer {
    running: root.cooldown > 0
    interval: 1000
    repeat: true
    onTriggered: {
      root.cooldown = root.cooldown - 1
      // The counter resets with the lockout: the next three tries are a fresh
      // set, the way pam_faillock treats them.
      if (root.cooldown === 0) {
        root.attempt = 0
        root.message = ""
        root.messages = []
        root.conversationStuck = false
        field.forceActiveFocus()
      }
    }
  }

  Timer {
    id: clock
    property date now: new Date()
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: now = new Date()
  }

  SysInfo { id: sys; networkFile: root.networkFile }

  Backdrop {
    anchors.fill: parent
    wallpaper: root.wallpaper
    showGrid: root.showGrid
  }

  // ---------------------------------------------------------------- corners
  Column {
    visible: root.primary
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.topMargin: Theme.screenMargin
    anchors.leftMargin: Theme.screenMarginSide
    spacing: Theme.px(5)

    Text {
      text: root.hostName
      color: Theme.ink(0.62)
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(12)
      font.weight: 600
      font.letterSpacing: 0.06 * Theme.fs(12)
    }
    Text {
      // "arch linux · 6.16.4-arch1-1 · c7shell"
      text: [sys.distro, sys.kernel, root.sessionName(root.sessionIndex).toLowerCase()]
              .filter(part => part !== "").join(" · ")
      color: Theme.ink(0.28)
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(10)
    }
  }

  Column {
    visible: root.primary
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.topMargin: Theme.screenMargin
    anchors.rightMargin: Theme.screenMarginSide
    spacing: Theme.px(4)

    Text {
      anchors.right: parent.right
      text: Qt.formatTime(clock.now, "HH:mm")
      color: Theme.ink(0.8)
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(30)
      font.weight: 300
      font.letterSpacing: -0.02 * Theme.fs(30)
    }
    Text {
      anchors.right: parent.right
      text: Qt.formatDate(clock.now, "ddd d MMM yyyy").toLowerCase()
      color: Theme.ink(0.3)
      font.family: Theme.fontMono
      font.pixelSize: Theme.fs(10)
    }
  }

  // ------------------------------------------------------------------- body
  // The card is centered and stays centered: the side panels hang off it, so
  // opening the session picker or the user list does not slide the password
  // field out from under whoever is already typing in it.
  UserPanel {
    visible: root.primary && root.userPanelVisible
    anchors.right: card.left
    anchors.rightMargin: Theme.panelGap
    anchors.verticalCenter: card.verticalCenter
    users: root.users
    currentIndex: root.userIndex
    allowManualLogin: root.allowManualLogin
    onPicked: function (index) {
      root.userIndex = index
      root.message = ""
      root.messages = []
      root.conversationStuck = false
      field.clear()
      if (index === root.userCount) usernameInput.forceActiveFocus()
      else field.forceActiveFocus()
    }
  }

  // Under the card, because what PAM is asking for belongs next to the field
  // the user is typing into -- not off to one side with the account list.
  MessagePanel {
    visible: root.primary && root.messages.length > 0
    anchors.top: card.bottom
    anchors.topMargin: Theme.panelGap
    anchors.horizontalCenter: card.horizontalCenter
    messages: root.messages
    stuck: root.conversationStuck
  }

  SessionPanel {
    visible: root.primary && root.sessionsOpen
    anchors.left: card.right
    anchors.leftMargin: Theme.panelGap
    anchors.verticalCenter: card.verticalCenter
    sessions: root.sessions
    currentIndex: root.sessionIndex
    onPicked: function (index) {
      root.sessionIndex = index
      root.sessionsOpen = false
      field.forceActiveFocus()
    }
  }

  // ------------------------------------------------------------- the card
  GlassPanel {
  id: card
  visible: root.primary
  anchors.centerIn: parent
  // "centered with a 24px upward offset so it sits above the bottom bar"
  anchors.verticalCenterOffset: -Theme.px(24)
  radius: Theme.radiusCard
    implicitWidth: Theme.cardWidth
    // padding 30 top / 24 bottom, as in the mockup
    implicitHeight: cardColumn.implicitHeight + Theme.px(54)

    Column {
      id: cardColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Theme.px(30)
      anchors.leftMargin: Theme.px(30)
      anchors.rightMargin: Theme.px(30)
      spacing: 0

      Avatar {
        anchors.horizontalCenter: parent.horizontalCenter
        // On the manual row there is no model row to read, but there is a
        // name in the field -- typed, or filled in by applyLastUser() after a
        // logout. Monogram it and look for its avatar, so returning to your
        // own account looks like your own account.
        name: root.manual ? usernameInput.text : root.userField(root.userIndex, "name")
        realName: root.manual ? "" : root.userField(root.userIndex, "realName")
        picture: root.manual ? root.accountsServiceIcon(usernameInput.text)
                             : root.userField(root.userIndex, "icon")
      }

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        topPadding: Theme.px(15)
        text: root.manual ? qsTr("sign in") : root.userField(root.userIndex, "name")
        color: Theme.text
        font.family: Theme.fontMono
        font.pixelSize: Theme.fs(15)
        font.weight: 500
      }

      // The real name, then "switch user" -- the mockup's second line.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        topPadding: Theme.px(4)
        spacing: Theme.px(7)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          text: {
            if (root.manual) return qsTr("type a username and password")
            const real = root.userField(root.userIndex, "realName")
            return real !== "" && real !== root.userField(root.userIndex, "name")
                   ? real : qsTr("local account")
          }
          color: Theme.ink(0.34)
          font.family: Theme.fontMono
          font.pixelSize: Theme.fs(10)
        }
        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Theme.px(3); height: Theme.px(3)
          radius: width / 2
          color: Theme.ink(0.25)
          visible: switchUser.visible
        }
        Text {
          id: switchUser
          anchors.verticalCenter: parent.verticalCenter
          visible: root.userCount > 1 || root.allowManualLogin
          text: root.userPanelVisible ? qsTr("hide users") : qsTr("switch user")
          color: switchHover.hovered ? Theme.accentSoft : Theme.ink(0.34)
          font.family: Theme.fontMono
          font.pixelSize: Theme.fs(10)

          HoverHandler { id: switchHover; cursorShape: Qt.PointingHandCursor }
          TapHandler { onTapped: root.toggleUserPanel() }
        }
      }

      // Manual login: the username no user list can offer.
      Item {
        width: parent.width
        height: root.manual ? Theme.px(12) + Theme.fieldHeight : 0
        visible: root.manual

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Theme.fieldHeight
          radius: Theme.radiusField
          color: Theme.field
          border.width: 1
          border.color: usernameInput.activeFocus ? Theme.focusBorder : Theme.hairline

          TextInput {
            id: usernameInput
            activeFocusOnTab: true
            // Tab moves on to the secret, which is the order the card is read
            // in; without this the chain follows declaration order and lands
            // somewhere arbitrary.
            KeyNavigation.tab: field
            anchors.fill: parent
            anchors.leftMargin: Theme.px(14)
            anchors.rightMargin: Theme.px(14)
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.text
            font.family: Theme.fontMono
            font.pixelSize: Theme.fs(12)
            selectionColor: Theme.crimson(0.4)
            selectedTextColor: Theme.text
            onAccepted: field.forceActiveFocus()

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: usernameInput.text === ""
              text: qsTr("username")
              color: Theme.ink(0.28)
              font: usernameInput.font
            }
          }
        }
      }

      Item { width: 1; height: Theme.px(22) }

      PasswordField {
        id: field
        width: parent.width
        focus: true
        error: root.message
        attempt: root.attempt
        maxAttempts: root.maxAttempts
        cooldown: root.cooldown
        onAccepted: root.login()
        // Clears the failure text, but not the PAM messages: an MFA number has
        // to stay readable while the user types it into a phone.
        onEdited: if (text !== "") root.message = ""
      }

      // The footer line: caps lock on the left, and on the right whichever of
      // the attempt counter, the lockout or the session is worth saying.
      Item {
        width: parent.width
        height: Theme.px(9) + footerRow.implicitHeight

        Item {
          id: footerRow
          anchors.bottom: parent.bottom
          width: parent.width
          implicitHeight: Math.max(caps.implicitHeight, attempts.implicitHeight)

          Row {
            id: caps
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.px(6)

            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "arrow-big-up"
              size: Theme.px(11)
              color: root.capsLock ? Theme.accentSoft : Theme.ink(0.3)
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.capsLock ? qsTr("caps lock on") : qsTr("caps lock off")
              color: root.capsLock ? Theme.accentSoft : Theme.ink(0.3)
              font.family: Theme.fontMono
              font.pixelSize: Theme.fs(9.5)
            }
          }

          Text {
            id: attempts
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.cooldown > 0
                  ? qsTr("locked for %1 s").arg(root.cooldown)
                  : root.attempt > 0
                    ? qsTr("%1 of %2 attempts used").arg(root.attempt).arg(root.maxAttempts)
                    : root.sessionName(root.sessionIndex).toLowerCase()
            color: Theme.ink(0.3)
            font.family: Theme.fontMono
            font.pixelSize: Theme.fs(9.5)
          }
        }
      }
    }
  }


  // ------------------------------------------------------------- bottom bar
  BottomBar {
    visible: root.primary
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Theme.px(22)

    sessionName: root.sessionName(root.sessionIndex).toLowerCase()
    sessionPanelOpen: root.sessionsOpen
    layout: root.layoutName(root.currentLayout)
    layoutCount: root.layoutCount
    capsLock: root.capsLock
    batteryLevel: sys.batteryLevel
    batteryCharging: sys.batteryCharging
    networkName: sys.networkName
    networkWireless: sys.networkWireless
    canSuspend: root.canSuspend
    canReboot: root.canReboot
    canPowerOff: root.canPowerOff

    onSessionToggled: {
      root.sessionsOpen = !root.sessionsOpen
      field.forceActiveFocus()
    }
    onLayoutCycled: root.cycleLayout()
    onSuspendRequested: root.suspendRequested()
    onRebootRequested: root.rebootRequested()
    onPowerOffRequested: root.powerOffRequested()
  }

  // Up/Down through the user list, F1 for the session, F2 for the layout, Esc
  // clears -- the TextInput ignores all of them, so they arrive here by
  // propagation from the focused field.
  Keys.onPressed: function (event) {
    switch (event.key) {
    case Qt.Key_Up:     root.moveUser(-1); event.accepted = true; break
    case Qt.Key_Down:   root.moveUser(1);  event.accepted = true; break
    case Qt.Key_F1:     root.cycleSession(1); event.accepted = true; break
    case Qt.Key_F2:     root.cycleLayout(); event.accepted = true; break
    case Qt.Key_Escape:
      field.clear()
      root.message = ""
      root.messages = []
      root.conversationStuck = false
      root.sessionsOpen = false
      event.accepted = true
      break
    }
  }

  // Theme.s turns the mockup's 1120x630 units into screen pixels. Only the
  // primary screen sets it -- sddm instantiates the theme once per screen and
  // the singleton is shared, so a second monitor must not resize the card --
  // and it is capped: past ~1.6 the card stops reading as a login card. This
  // stays on the primary screen even with loginOnAllScreens=true: the cards
  // then match each other rather than each sizing to its own panel.
  function applyScale() {
    if (!root.scaleAuthority || root.width <= 0 || root.height <= 0) return
    const fit = Math.min(root.width / 1120, root.height / 630)
    Theme.s = Math.max(1, Math.min(1.6, fit * 0.7))
  }
  onWidthChanged: root.applyScale()
  onHeightChanged: root.applyScale()

  Component.onCompleted: {
    root.applyScale()
    root.applyLastUser()
    field.forceActiveFocus()
  }
}
