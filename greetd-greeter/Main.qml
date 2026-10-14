import QtQuick
import QtQuick.Window

// The adapter. Greeter.qml and the components beside it know nothing about
// greetd; only this file does.
//
// greetd never answers a prompt on the greeter's behalf. The secret typed into
// the card is spent on exactly one auth_message and then cleared, so a mistyped
// PIN costs one attempt rather than being replayed until the directory deletes
// the credential. A further question -- enrol a PIN, change a password --
// reaches the user, which is what makes enrolment possible here at all.
//
// sddm loaded its Main.qml once per screen and handed each copy a primaryScreen
// flag. greetd has no such notion, so the windows are made here: one per
// screen, with the card on the primary one and the backdrop on the rest.
// The root is a real Window rather than a QtObject holding Instantiators:
// under wayland Qt.application.screens can still be empty when Main.qml loads,
// and a greeter that fails to draw is worse than one that misses a screen.
// This window is the primary; any further screens are added beside it.
Window {
  id: root

  visible: true
  visibility: Window.FullScreen
  color: "black"
  title: "c7shell"

  // Put the card on the internal panel. Qt's screen 0 is whichever output the
  // compositor enumerated first, which on a docked laptop is usually the
  // external monitor -- so the login card appeared in front of nobody.
  readonly property var internalScreen: {
    const want = keyboardState.internalOutput
    if (want === "") return null
    const all = Qt.application.screens
    for (let i = 0; i < all.length; i++)
      if (all[i].name === want) return all[i]
    return null
  }
  screen: root.internalScreen !== null ? root.internalScreen : Qt.application.screens[0]

  // Conversation state, shared across every screen -- only one login is ever
  // in flight, whichever screen it was typed on.
  property string pendingSecret: ""
  property string pendingUser: ""
  property bool awaitingResponse: false
  // The Greeter drawing the card; the one that receives messages and failures.
  property var cardGreeter: null

  function resetConversation() {
    root.pendingSecret = ""
    root.pendingUser = ""
    root.awaitingResponse = false
  }

  function beginLogin(user, password) {
    if (root.awaitingResponse) {
      root.awaitingResponse = false
      greetd.respond(password)
      return
    }
    // greetd refuses a second create_session while one is still waiting for a
    // response ("a session is already being configured"), so clear any
    // conversation left half-finished by an earlier attempt.
    greetd.cancelSession()
    root.pendingSecret = password
    root.pendingUser = user
    greetd.createSession(user)
  }

  // cage makes a fullscreen client cover the whole extended surface -- here
  // 5360x1440 across a 1920x1200 panel and a 3440x1440 monitor -- while
  // advertising only one output. So the window cannot be used as the card's
  // frame: anchors.fill centres it across the join, which put the login card
  // on the external monitor.
  //
  // Backdrop across everything, card on the internal panel.
  Greeter {
    anchors.fill: parent
    primary: false
    scaleAuthority: false
    wallpaper: themeConfig.wallpaper
    showGrid: themeConfig.showGrid
  }

  Greeter {
    id: greeter
    focus: true

    // The internal panel's rectangle within the extended surface.
    x: root.screen ? root.screen.virtualX : 0
    y: root.screen ? root.screen.virtualY : 0
    width: root.screen ? root.screen.width : root.width
    height: root.screen ? root.screen.height : root.height

    primary: true
    scaleAuthority: true

    hostName: machineHostName
    users: userModel
    sessions: sessionModel
    canSuspend: power.canSuspend
    canReboot: power.canReboot
    canPowerOff: power.canPowerOff

    wallpaper: themeConfig.wallpaper
    showGrid: themeConfig.showGrid
    allowManualLogin: themeConfig.allowManualLogin
    userList: themeConfig.userList
    maxAttempts: themeConfig.maxAttempts
    cooldownSeconds: themeConfig.cooldownSeconds
    lastUser: lastUserStore.lastUser

    capsLock: keyboardState.capsLock
    layouts: keyboardState.layouts

    onLoginRequested: function (user, password, sessionIndex) {
      root.beginLogin(user, password)
    }
    onSuspendRequested: power.suspend()
    onRebootRequested: power.reboot()
    onPowerOffRequested: power.powerOff()

    Component.onCompleted: root.cardGreeter = greeter
  }

  property Connections conversation: Connections {
    target: greetd

    function onAuthMessage(text, type) {
      const g = root.cardGreeter
      if (type === "secret" || type === "visible") {
        if (root.pendingSecret !== "") {
          // Spend it once. Clearing first is what stops a rejected secret
          // being handed straight back to the next prompt.
          const secret = root.pendingSecret
          root.pendingSecret = ""
          greetd.respond(secret)
          return
        }
        root.awaitingResponse = true
        if (g) g.promptAgain(text)
        return
      }
      // info and error are not questions, but they still have to be answered:
      // greetd waits for a post_auth_message_response before carrying on, and
      // a Hello PIN login opens with an info message.
      if (g) {
        if (type === "error") g.loginFailed(text)
        else g.showMessage(text)
      }
      greetd.acknowledge()
    }

    function onAuthSuccess() {
      lastUserStore.remember(root.pendingUser)
      const g = root.cardGreeter
      root.resetConversation()
      if (g) g.loginSucceeded()
      const exec = sessionModel.execAt(g ? g.sessionIndex : 0)
      const cmd = exec !== "" ? exec : "start-hyprland"
      // Hyprland prints its banner and early debug lines to stdout before it
      // reads debug.enable_stdout_logs and switches to its own log file. Those
      // would land on the VT the greeter just vacated.
      greetd.startSession(["/bin/sh", "-lc", cmd + " >/dev/null 2>&1"])
    }

    function onSessionStarted() {
      // greetd starts the session once we are gone. Lingering here is dead
      // time the user spends looking at a greeter that has already finished.
      Qt.quit()
    }

    function onAuthError(description) {
      const g = root.cardGreeter
      root.resetConversation()
      if (g) g.loginFailed(description)
    }
  }
}
