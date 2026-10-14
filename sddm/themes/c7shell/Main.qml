import QtQuick

// The entry point sddm loads, once per screen. Everything it does is wire the
// greeter's context objects -- sddm, userModel, sessionModel, keyboard, config,
// primaryScreen -- into Greeter.qml, which knows nothing about them. That split
// is what lets tests/greeter-preview.qml render the same UI with mock models.
Item {
  id: container

  // sddm sizes the view to the screen; these are only the fallback for a
  // window with no geometry yet.
  width: 1120
  height: 630

  LayoutMirroring.enabled: Qt.locale().textDirection === Qt.RightToLeft
  LayoutMirroring.childrenInherit: true

  // theme.conf, overridable per machine in /etc/sddm.conf.d. config values
  // arrive as strings, so anything non-string is converted here rather than at
  // every use.
  readonly property bool cfgGrid: config.stringValue("grid") !== "false"
  readonly property bool cfgManual: config.stringValue("allowManualLogin") === "true"
  readonly property string cfgUserList: {
    const v = config.stringValue("userList")
    return v === "always" || v === "never" ? v : "auto"
  }
  readonly property int cfgAttempts: {
    const v = parseInt(config.stringValue("maxAttempts"), 10)
    return isNaN(v) || v < 1 ? 3 : v
  }
  // Draw the card, panels and bars on every screen rather than the primary one.
  readonly property bool cfgAllScreens: config.stringValue("loginOnAllScreens") === "true"
  readonly property int cfgCooldown: {
    const v = parseInt(config.stringValue("cooldownSeconds"), 10)
    return isNaN(v) || v < 0 ? 30 : v
  }

  Greeter {
    id: greeter
    anchors.fill: parent
    focus: true

    hostName: sddm.hostName
    users: userModel
    sessions: sessionModel
    layouts: keyboard.layouts
    currentLayout: keyboard.currentLayout
    capsLock: keyboard.capsLock
    canSuspend: sddm.canSuspend
    canReboot: sddm.canReboot
    canPowerOff: sddm.canPowerOff

    // An empty background= leaves the generated backdrop in place, which is
    // the mockup's look; point it at a file the sddm user can read to make
    // boot -> desktop one continuous image. stringValue() rather than
    // config.background: a key that is in neither theme.conf nor sddm.conf
    // reads as undefined that way, and url properties reject undefined.
    wallpaper: config.stringValue("background")
    showGrid: container.cfgGrid
    allowManualLogin: container.cfgManual
    userList: container.cfgUserList
    maxAttempts: container.cfgAttempts
    cooldownSeconds: container.cfgCooldown
    // Each screen's instance keeps its own field, selected user and cooldown;
    // sddm gives the keyboard to one window, so only the focused card fills in.
    primary: primaryScreen || container.cfgAllScreens
    scaleAuthority: primaryScreen

    // Both models remember what was used last, which is the whole reason the
    // greeter opens on the right account with the right session preselected.
    userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    onLoginRequested: function (user, password, sessionIndex) {
      sddm.login(user, password, sessionIndex)
    }
    onLayoutRequested: function (index) { keyboard.currentLayout = index }
    onSuspendRequested: sddm.suspend()
    onRebootRequested: sddm.reboot()
    onPowerOffRequested: sddm.powerOff()
  }

  Connections {
    target: sddm

    function onLoginSucceeded() { greeter.loginSucceeded() }
    // sddm sends no reason with this one -- the greeter supplies the wording.
    function onLoginFailed() { greeter.loginFailed("") }
    // Informational, not a failure: PAM sends these during a *successful*
    // authentication as well. A real failure arrives on onLoginFailed above.
    function onInformationMessage(message) { greeter.showMessage(message) }
  }
}
