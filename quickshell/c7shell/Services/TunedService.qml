pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick
import qs.Services

// tuned owns the state. This service reads the active profile and asks for
// changes; it never writes a governor, an EPP value or a platform profile
// itself. A profile changed from outside the shell (`tuned-adm profile …`, or
// another desktop) shows up here within a second, because the list is driven by
// tuned's own profile_changed signal rather than by what the shell last set.
//
// -- why gdbus and not a QML DBus object --
// quickshell 0.3.1 ships no generic D-Bus client (Quickshell.Io has none, and
// the only D-Bus surfaces it exposes are the tray's DBusMenu and UPower). So
// the bus calls go through gdbus, which is glib's own client and is on every
// machine that has GTK anywhere near it. This is still D-Bus and NOT the
// `tuned-adm` shell-out the handoff rules out: the reads are method calls on
// com.redhat.tuned, and the live updates are the real signal off the bus, not
// a poll of a CLI.
Singleton {
  id: root

  readonly property string busName: "com.redhat.tuned"
  readonly property string busPath: "/Tuned"
  readonly property string busIface: "com.redhat.tuned.control"

  // -- state -----------------------------------------------------------------

  // The bus name answered. Everything the profile UI offers hangs off this;
  // when it is false the profile list is HIDDEN rather than faked, and the
  // battery readout carries on regardless.
  property bool available: false
  // Installed but not answering is a different sentence from not installed at
  // all -- one of them has an "enable tuned.service" button that will work.
  property bool installed: false
  property string version: ""

  // The tuned profile name, exactly as tuned spells it.
  property string activeProfile: ""
  // Which of our three that is, or "" for a profile outside the three -- a
  // state the UI says out loud instead of lighting up the nearest card.
  readonly property string activeKey: PowerStore.keyForTuned(root.activeProfile)

  // Every profile tuned knows, for the "see all N tuned profiles" link.
  property var allProfiles: []

  // "manual" | "auto". tuned's own, read back rather than remembered.
  property string mode: ""

  // The UI key of a switch in flight, "" when idle. The picked row goes crimson
  // and spins immediately; the others dim rather than lock, so a mis-click
  // costs one more click.
  property string applying: ""
  // Set alongside a switch and cleared once two fresh draw samples have landed.
  // Until then every runtime estimate is arithmetic on the OLD profile's draw,
  // so the header says "recalculating…" rather than printing a number it is
  // about to contradict.
  property bool recalculating: false

  property string lastError: ""

  // -- runtime estimates -----------------------------------------------------
  // Remaining Wh divided by the draw the profile actually pulls ON THIS
  // MACHINE. The learned median is preferred; a profile with no history yet
  // falls back to the live draw, which is right for the active one and a
  // reasonable guess for the other two.
  function drawFor(key) {
    const learned = PowerStore.learnedDraw(key)
    if (learned > 0) return learned
    return BatteryService.watts > 0.5 ? BatteryService.watts : 0
  }

  function estimateSeconds(key) {
    const w = root.drawFor(key)
    if (w <= 0 || BatteryService.energyWh <= 0) return 0
    return BatteryService.energyWh / w * 3600
  }

  // "≈ 5 h 20 m", or "" when the machine has told us nothing to divide by. The
  // handoff is explicit: show the ≈, and never a seconds field.
  function estimateText(key) {
    const s = root.estimateSeconds(key)
    return s > 0 ? `≈ ${BatteryService.duration(s)}` : ""
  }

  // Idle draw as the settings cards print it. Whole watts: the second decimal
  // of a learned median is noise dressed as precision.
  function idleDrawText(key) {
    const w = root.drawFor(key)
    return w > 0 ? `≈ ${Math.round(w)} W` : "not measured yet"
  }

  // -- switching -------------------------------------------------------------

  // `announce` is what separates a click in the popover (its own feedback, no
  // toast) from an automatic switch or one made from a keybind (which happened
  // somewhere the user was not looking, and gets one).
  function apply(key, announce) {
    const profile = PowerStore.profileFor(key)
    if (!profile || !root.available) return
    if (root.applying !== "") return

    root.lastError = ""
    root.applying = key
    root.recalculating = true
    // The old estimate has to be captured BEFORE the draw window is thrown
    // away, or the toast compares the new profile against itself.
    switcher.wasEstimate = root.estimateSeconds(root.activeKey)
    switcher.announce = announce === true
    switcher.targetKey = key

    // A change of profile invalidates the draw window for the same reason a
    // change of direction does: averaging the tail of one profile into the head
    // of the next shows a figure that was never true.
    BatteryService.resetSamples()

    switcher.exec(root.call("switch_profile", [profile.tuned]))
  }

  // A tuned profile by name, for the "see all N tuned profiles" list. It goes
  // through the same in-flight guard and the same draw-window reset as the
  // three buttons; what it cannot do is announce, because a profile outside the
  // three has no card for a toast to be about.
  function applyProfile(name) {
    if (!root.available || root.applying !== "" || name === root.activeProfile) return
    root.lastError = ""
    // The spinner is keyed on a UI key, which this may not have. Marking it
    // with the tuned name is enough for the guard, and no row spins -- which is
    // honest: the list is names, not cards.
    root.applying = PowerStore.keyForTuned(name)
    root.recalculating = true
    switcher.wasEstimate = 0
    switcher.announce = false
    switcher.targetKey = root.applying
    BatteryService.resetSamples()
    switcher.exec(root.call("switch_profile", [name]))
  }

  // Both directions of the toggle are tuned's own state, read back from
  // profile_mode rather than remembered here.
  function setAutoMode(auto) {
    if (!root.available) return
    if (auto) modeSwitch.exec(root.call("auto_profile"))
    else if (root.activeProfile !== "") modeSwitch.exec(root.call("switch_profile", [root.activeProfile]))
  }

  signal switched(string key, real seconds, real wasSeconds)

  // -- gdbus plumbing --------------------------------------------------------

  function call(method, args) {
    const argv = ["gdbus", "call", "--system",
                  "--dest", root.busName,
                  "--object-path", root.busPath,
                  "--method", `${root.busIface}.${method}`]
    // gdbus takes each argument as its own GVariant literal; a plain string is
    // valid GVariant syntax for `s` only when it is quoted, and the quoting has
    // to be inside the argument rather than around it because there is no shell
    // in the middle to strip it.
    for (const a of (args ?? [])) argv.push(JSON.stringify(a))
    return argv
  }

  // gdbus prints a GVariant tuple: ('balanced',) / (['a', 'b'],) / (true, 'OK').
  // Only the strings and the leading boolean are ever wanted, so the parsing
  // stays at the level of "pull the quoted runs out", which is robust against
  // the tuple shape changing under us.
  function strings(text) {
    const out = []
    const re = /'((?:[^'\\]|\\.)*)'/g
    let m
    while ((m = re.exec(text)) !== null) out.push(m[1].replace(/\\(.)/g, "$1"))
    return out
  }

  function probe() {
    activeRead.exec(root.call("active_profile"))
    profilesRead.exec(root.call("profiles"))
    modeRead.exec(root.call("profile_mode"))
  }

  Process {
    id: activeRead
    stdout: StdioCollector {
      onStreamFinished: {
        const s = root.strings(text)
        if (s.length === 0) return
        root.available = true
        root.activeProfile = s[0]
      }
    }
    // A dead bus name is the "tuned is not running" state, not a fault to log.
    stderr: StdioCollector {}
    onExited: code => { if (code !== 0) { root.available = false; root.activeProfile = "" } }
  }

  Process {
    id: profilesRead
    stdout: StdioCollector { onStreamFinished: root.allProfiles = root.strings(text) }
    stderr: StdioCollector {}
  }

  Process {
    id: modeRead
    stdout: StdioCollector {
      onStreamFinished: {
        const s = root.strings(text)
        // profile_mode returns (mode, error); the mode is the first string.
        root.mode = s.length > 0 ? s[0] : ""
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: switcher

    property string targetKey: ""
    property real wasEstimate: 0
    property bool announce: false

    stdout: StdioCollector {
      onStreamFinished: {
        // (true, 'OK') on success; (false, 'reason') when tuned refuses.
        if (!text.trim().startsWith("(true")) {
          const s = root.strings(text)
          root.lastError = s.length > 0 ? s[s.length - 1] : "tuned refused the switch"
        }
      }
    }
    stderr: StdioCollector {
      onStreamFinished: if (text.trim() !== "") root.lastError = text.trim()
    }
    onExited: code => {
      root.applying = ""
      if (code !== 0 && root.lastError === "") root.lastError = "could not reach tuned"
      if (code !== 0) { root.recalculating = false; return }
      // profile_changed normally beats this, but reading back is what makes the
      // UI's idea of the active profile tuned's rather than ours.
      root.probe()
      if (switcher.announce)
        root.switched(switcher.targetKey, root.estimateSeconds(switcher.targetKey), switcher.wasEstimate)
    }
  }

  Process {
    id: modeSwitch
    stdout: StdioCollector { onStreamFinished: root.probe() }
    stderr: StdioCollector {}
  }

  // The live half. `gdbus monitor` is a signal subscription, so an external
  // `tuned-adm profile powersave` lands here in the time it takes the bus to
  // deliver -- and the name-owner lines it prints either side of that are how
  // the shell notices tuned starting or stopping without polling for it.
  Process {
    id: monitor

    // setpriv --pdeathsig: ask the kernel to kill this when the shell dies.
    // quickshell reaps its Processes on a clean exit, but the shell does not
    // always get one -- when the compositor goes, it loses its wayland
    // connection and can be torn down before it reaps anything. A surviving
    // gdbus keeps the logind session scope alive, which leaves the session
    // `closing` on its VT and strands the next login on the same VT.
    command: ["setpriv", "--pdeathsig", "SIGTERM",
              "gdbus", "monitor", "--system", "--dest", root.busName]
    stdout: SplitParser {
      onRead: line => {
        if (line.includes("does not have an owner")) {
          root.available = false
          root.activeProfile = ""
          return
        }
        if (line.includes("is owned by") || line.includes("profile_changed")) {
          root.probe()
          return
        }
      }
    }
    stderr: StdioCollector {}
    // gdbus exits if the bus goes away entirely; without this the shell would
    // silently stop noticing profile changes for the rest of the session.
    onExited: monitorRetry.restart()
  }

  Timer {
    id: monitorRetry
    interval: 5000
    onTriggered: monitor.running = true
  }

  // Whether tuned is installed at all, which is the difference between an
  // "enable tuned.service" button that will work and one that cannot. The
  // version is read from pacman rather than invented: this is an Arch desktop
  // (the whole update flow is pacman), and tuned exposes no version on the bus.
  Process {
    id: pkgQuery
    running: true
    command: ["pacman", "-Q", "tuned"]
    stdout: StdioCollector {
      onStreamFinished: {
        const m = text.trim().match(/^tuned\s+(\S+?)(-\d+)?$/)
        if (!m) return
        root.installed = true
        root.version = m[1]
      }
    }
    stderr: StdioCollector {}
  }

  Component.onCompleted: {
    monitor.running = true
    root.probe()
  }

  // A slow re-read of the active profile alone, purely as a backstop:
  // everything above is event-driven, and this only exists so a missed signal
  // costs half a minute rather than the rest of the session. Deliberately not
  // the full probe -- the profile list and the mode do not change on their own.
  Timer {
    running: true
    interval: 30000
    repeat: true
    onTriggered: activeRead.exec(root.call("active_profile"))
  }

  // -- recalculating latch ---------------------------------------------------
  // Two fresh samples is the handoff's own bar, and it is the right one: the
  // first sample after a switch is usually still the old profile's draw.
  Connections {
    target: BatteryService
    function onSampleCountChanged() {
      if (root.recalculating && BatteryService.sampleCount >= 2)
        root.recalculating = false
    }
  }

  // -- learning the per-profile draw ----------------------------------------
  // Median, not mean: one compile or one video call would drag a mean up for
  // the rest of the machine's life, and the figure is meant to describe the
  // profile rather than the last thing that happened on it.
  property var learnWindow: []

  Timer {
    running: BatteryService.present && BatteryService.discharging
      && root.activeKey !== "" && !root.recalculating
    interval: 20000
    repeat: true
    onTriggered: {
      const w = BatteryService.watts
      if (w <= 0.5) return
      root.learnWindow = root.learnWindow.concat([w]).slice(-15)
      if (root.learnWindow.length < 5) return
      const sorted = root.learnWindow.slice().sort((a, b) => a - b)
      const mid = Math.floor(sorted.length / 2)
      const median = sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
      PowerStore.setLearnedDraw(root.activeKey, parseFloat(median.toFixed(2)))
    }
  }

  // A different profile is a different population; keeping the old samples
  // would blend the two.
  onActiveKeyChanged: root.learnWindow = []

  // -- automatic switching ---------------------------------------------------
  // The handoff asks for tuned's own AC/battery rules rather than shell logic.
  // tuned has no such rule set reachable over D-Bus -- `auto_profile` selects
  // by HARDWARE recommendation, not by whether the cable is in -- and the only
  // other way to configure one is writing /etc/tuned as root on every toggle.
  // So the trigger stays here, and it is an EVENT rather than the timer the
  // handoff rules out: exactly the unplug and plug transitions, nothing polled.
  // The consequence the handoff cares about still holds -- a manual pick wins
  // until the next unplug -- because nothing but these two transitions and the
  // threshold below ever switches on its own.
  Connections {
    target: BatteryService
    enabled: PowerStore.autoSwitch && root.available && BatteryService.present

    function onOnAcChanged() {
      const key = BatteryService.onAc
        ? PowerStore.onPowerProfile : PowerStore.onBatteryProfile
      if (key === root.activeKey) return
      root.apply(key, true)
    }
  }

  // One switch per crossing, latched the same way the low-battery toast is, so
  // plugging in and out arms it again. And never silent: the handoff asks for
  // one toast, which `announce` gives it.
  property bool dropped: false

  readonly property bool belowDrop: BatteryService.discharging
    && BatteryService.percent < PowerStore.dropBelow

  onBelowDropChanged: {
    if (!root.belowDrop) { root.dropped = false; return }
    if (root.dropped || !PowerStore.autoSwitch || !root.available) return
    root.dropped = true
    if (root.activeKey === "powersave") return
    root.apply("powersave", true)
  }

  // -- keyboard route --------------------------------------------------------
  // The other half of "a switch made from the keyboard": bind these in
  // hyprland.lua and the toast is what tells you it took.
  IpcHandler {
    target: "power"

    function profile(name: string): void {
      root.apply(name, true)
    }

    function cycle(): void {
      const keys = PowerStore.profiles.map(p => p.key)
      const i = keys.indexOf(root.activeKey)
      root.apply(keys[(i + 1) % keys.length], true)
    }
  }
}
