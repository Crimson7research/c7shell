import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Effects
import qs.Theme
import qs.Common
import qs.Modules.Launcher.providers

// Command window (spec 1c): 600px centered glass window driven entirely from
// the keyboard. `qs -c c7shell ipc call launcher toggle` opens and closes it.
Scope {
  id: root

  property bool open: false
  property int activeIndex: 0
  property int selected: 0

  // The one list of providers. The chip row and calcIndex both derive from it
  // through each provider's own name, so adding one is a single edit here.
  readonly property var providers: [apps, actions, windows, calc, files]
  readonly property int calcIndex: root.providers.findIndex(p => p.name === "calc")
  readonly property var current: root.providers[root.activeIndex]

  onActiveIndexChanged: root.refresh()

  IpcHandler {
    target: "launcher"
    function toggle(): void { root.open = !root.open }
  }

  // A leading "=" hands the query to calc and takes it back again, so the mode
  // switch needs no separate key.
  function refresh() {
    if (!root.current) return
    const text = input.text
    const want = text.startsWith("=") ? root.calcIndex
      : (root.activeIndex === root.calcIndex ? 0 : root.activeIndex)
    // Changing the index re-enters refresh() via onActiveIndexChanged.
    if (want !== root.activeIndex) { root.activeIndex = want; return }

    root.current.search(root.activeIndex === root.calcIndex ? text.slice(1) : text)
    root.selected = 0
  }

  function move(step) {
    const count = root.current?.results.length ?? 0
    if (count === 0) return
    root.selected = (root.selected + step + count) % count
    list.positionViewAtIndex(root.selected, ListView.Contain)
  }

  function cycle(step) {
    const count = root.providers.length
    root.activeIndex = (root.activeIndex + step + count) % count
  }

  function activate(mode) {
    const rows = root.current?.results ?? []
    if (root.selected < 0 || root.selected >= rows.length) return
    root.current.activate(rows[root.selected], mode)
    root.open = false
  }

  function handleKey(event) {
    switch (event.key) {
    case Qt.Key_Escape: root.open = false; break
    case Qt.Key_Down: root.move(1); break
    case Qt.Key_Up: root.move(-1); break
    case Qt.Key_Tab: root.cycle(1); break
    case Qt.Key_Backtab: root.cycle(-1); break
    case Qt.Key_Return:
    case Qt.Key_Enter:
      root.activate(event.modifiers & Qt.ControlModifier ? "terminal" : "open")
      break
    case Qt.Key_L:
      // The lock row advertises ctrl+l, so honour it from anywhere in the list.
      if (!(event.modifiers & Qt.ControlModifier)) return
      actions.lock()
      root.open = false
      break
    default:
      return
    }
    event.accepted = true
  }

  PanelWindow {
    id: win

    visible: root.open
    // Follow the focused monitor so super+space opens where the user is
    // looking, from any workspace. Falling back to the first screen rather than
    // to null for the reason CaptureOverlay.qml spells out: after a hotplug the
    // name match can fail, and a null screen is a window that cannot map while
    // `open` still goes true -- super+space then does nothing at all. Opening on
    // the wrong output is recoverable; opening on none is not.
    screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)
      ?? Quickshell.screens[0]
      ?? null

    // Full-screen: it costs nothing while hidden and gives outside-click
    // dismissal for free. Nothing is reserved from the layout.
    //
    // Ignore, not a zero zone: a zero zone reserves nothing but still RESPECTS
    // the bar's reservation, so this window came up Theme.barMarginTop +
    // Theme.barHeight shorter than the screen, starting that far down it, and
    // the panel's `centerIn: parent` landed HALF that below true centre. See
    // CaptureOverlay for the same fix.
    //
    // Half of a configurable number, not of 48: barMarginTop is a slider on the
    // topbar settings page (0..32 over a 38px bar), so the panel sat 19-35px
    // low depending on it -- and slid while the slider moved, which is a
    // topbar setting quietly repositioning the launcher.
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    exclusiveZone: 0
    color: "transparent"

    WlrLayershell.namespace: "c7shell-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    onVisibleChanged: {
      if (!win.visible) return
      input.text = ""
      root.activeIndex = 0
      root.refresh()
      // Keyboard focus only exists once the layer surface has mapped.
      Qt.callLater(() => input.forceActiveFocus())
    }

    AppsProvider { id: apps }
    ActionsProvider { id: actions }
    WindowsProvider { id: windows }
    CalcProvider { id: calc }
    FilesProvider { id: files }

    MouseArea {
      anchors.fill: parent
      onClicked: root.open = false
    }

    GlassPanel {
      id: panel

      anchors.centerIn: parent
      width: 600
      height: layout.height
      radius: Theme.radiusWindow
      border.color: Theme.hairlineStrong
      clip: true

      // Declared before the content so the rows' own handlers stay on top;
      // this one only stops panel clicks from reaching the dismiss area.
      MouseArea { anchors.fill: parent }

      Column {
        id: layout
        width: parent.width

        Item {
          id: headerRow
          width: parent.width
          height: 49

          Text {
            id: prompt
            anchors { left: parent.left; leftMargin: 18; verticalCenter: parent.verticalCenter }
            text: ">_"
            font { family: Theme.fontMono; pixelSize: 12; weight: 600 }
            color: Theme.accentSoft
          }

          TextInput {
            id: input
            anchors {
              left: prompt.right; leftMargin: 11
              right: escChip.left; rightMargin: 11
              verticalCenter: parent.verticalCenter
            }
            font { family: Theme.fontMono; pixelSize: 14; weight: 500 }
            color: Theme.text
            selectionColor: Theme.accentFill
            selectedTextColor: Theme.text
            focus: true
            onTextChanged: root.refresh()
            Keys.onPressed: event => root.handleKey(event)

            // Solid crimson block, not a blinking line.
            cursorDelegate: Rectangle {
              width: 8
              height: 16
              color: Theme.accent
            }
          }

          KbdChip {
            id: escChip
            anchors { right: parent.right; rightMargin: 18; verticalCenter: parent.verticalCenter }
            text: "esc"
          }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.hairline }

        Item {
          width: parent.width
          height: chips.height + 14

          Row {
            id: chips
            anchors { left: parent.left; leftMargin: 14; top: parent.top; topMargin: 10 }
            spacing: 6

            Repeater {
              // Names, not the provider objects: plain strings, built once from
              // a list that never changes while the window lives.
              model: root.providers.map(p => p.name)

              Rectangle {
                id: chip
                required property string modelData
                required property int index
                readonly property bool on: chip.index === root.activeIndex

                implicitWidth: chipLabel.implicitWidth + 22
                implicitHeight: chipLabel.implicitHeight + 8
                radius: Theme.radiusChip
                color: chip.on ? Theme.accent : Theme.surface05

                Text {
                  id: chipLabel
                  anchors.centerIn: parent
                  text: chip.modelData
                  font { family: Theme.fontMono; pixelSize: 11; weight: chip.on ? 600 : 500 }
                  color: chip.on ? Theme.textOnAccent : Theme.text2
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.activeIndex = chip.index
                }
              }
            }
          }

          Text {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: chips.verticalCenter }
            text: "tab ⇥ cycles"
            font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
            color: Theme.alpha(Theme.text, 0.3)
          }
        }

        Item {
          width: parent.width
          height: list.height > 0 ? list.height + 16 : 0

          ListView {
            id: list
            x: 8
            y: 8
            width: parent.width - 16
            // Five rows (50 + 2 gap) before it starts scrolling.
            height: Math.min(contentHeight, 258)
            spacing: 2
            clip: true
            model: root.current ? root.current.results : []

            delegate: ResultRow {
              required property var modelData
              required property int index

              width: ListView.view.width
              entry: modelData
              selected: index === root.selected
              onHovered: root.selected = index
              onActivated: { root.selected = index; root.activate("open") }
            }
          }
        }

        Rectangle { width: parent.width; height: 1; color: Theme.hairline }

        CommandFooter { width: parent.width }
      }
    }

    // Shadow only -- no source item to paint, so the panel above it stays
    // translucent and Hyprland's blur has something to work on.
    RectangularShadow {
      anchors.fill: panel
      radius: panel.radius
      color: Theme.panelShadowColor
      offset.y: 24
      blur: 80
      z: -1
    }
  }
}
