import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Theme
import qs.Common

// 8a screenshare picker. Runs as its own qs instance, rooted at
// ../../sharepicker.qml (see bin/screenshare-picker.sh); writes
// "[SELECTION]/..." to $XDPH_OUT and quits. Cancel = quit without writing.
// ponytail: screens + windows only; region needs a drag overlay — the
// region:OUT@x,y,w,h protocol is ready whenever it is worth building.
Scope {
  id: root

  property string tab: "screens"
  property int selScreen: -1
  property string selWindow: ""
  property string selWindowLabel: ""

  // "{handle}[HC>]{class}[HT>]{title}[HE>]{addr}[HA>]" repeated.
  readonly property var windows: {
    const s = Quickshell.env("XDPH_WINDOW_SHARING_LIST") ?? ""
    const out = []
    const re = /(\d+)\[HC>\](.*?)\[HT>\](.*?)\[HE>\](.*?)\[HA>\]/g
    let m
    while ((m = re.exec(s)) !== null)
      out.push({ handle: m[1], cls: m[2], title: m[3] })
    return out
  }

  function confirm() {
    let sel = ""
    if (root.tab === "screens" && root.selScreen >= 0)
      sel = `[SELECTION]/screen:${Quickshell.screens[root.selScreen].name}`
    else if (root.tab === "windows" && root.selWindow !== "")
      sel = `[SELECTION]/window:${root.selWindow}`
    if (sel === "") return
    // argv keeps the shell out of the selection string; $XDPH_OUT is the
    // wrapper's tempfile. Trailing newline is required: xdph pop_back()s the
    // screen name, expecting the reference picker's std::endl -- without it a
    // real char is stripped ("DP-3" -> "DP-") and the screencast never starts.
    writeProc.exec(["sh", "-c", 'printf "%s\\n" "$1" > "$XDPH_OUT"', "sh", sel])
  }

  Process {
    id: writeProc
    onExited: Qt.quit()
  }

  PanelWindow {
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "c7shell-sharepicker"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    // The mockup's rgba(4,4,6,.6); Theme.bg is a shade off it, as in
    // CaptureOverlay. Below the 0.7 ignore_alpha of hypr/conf/rules.lua, so the
    // dim stays sharp: the dialog is the only thing that needs blur here.
    color: Theme.alpha(Theme.bg, 0.6)

    MouseArea { anchors.fill: parent; onClicked: Qt.quit() }   // click-away cancels

    GlassPanel {   // the dialog; blur handled by hypr layer rules (alpha ≥ .7)
      id: dialog
      anchors.centerIn: parent
      width: 560
      height: 420
      radius: Theme.radiusWindow
      MouseArea { anchors.fill: parent }   // swallow clicks inside

      Column {
        anchors { fill: parent; margins: 16 }
        spacing: 12

        Text {
          text: "share your screen"
          font { family: Theme.fontMono; pixelSize: 13; weight: 600 }
          color: Theme.text
        }

        Row {   // screens / windows segmented tabs
          spacing: 6
          Repeater {
            model: ["screens", "windows"]
            Rectangle {
              required property string modelData
              width: tabLabel.implicitWidth + 20; height: 24; radius: Theme.radiusChip
              color: root.tab === modelData ? Theme.accent : Theme.surface05
              Text {
                id: tabLabel
                anchors.centerIn: parent
                text: parent.modelData
                font { family: Theme.fontMono; pixelSize: 10; weight: 600 }
                color: root.tab === parent.modelData ? Theme.textOnAccent : Theme.text2
              }
              MouseArea { anchors.fill: parent; onClicked: root.tab = parent.modelData }
            }
          }
        }

        Flickable {
          width: parent.width
          height: 280
          contentHeight: root.tab === "screens" ? screenFlow.implicitHeight : windowCol.implicitHeight
          clip: true

          Flow {   // monitor cards with live thumbnails
            id: screenFlow
            visible: root.tab === "screens"
            width: parent.width
            spacing: 10
            Repeater {
              model: Quickshell.screens
              Rectangle {
                required property var modelData
                required property int index
                width: 254; height: 170; radius: Theme.radiusPreview
                color: Theme.surface04
                border.width: 2
                border.color: root.selScreen === index ? Theme.accent : Theme.hairline

                Column {
                  anchors { fill: parent; margins: 8 }
                  spacing: 6
                  ScreencopyView {
                    width: parent.width; height: 128
                    captureSource: parent.parent.modelData
                    live: true
                  }
                  Text {
                    text: `${parent.parent.modelData.name} · ${parent.parent.modelData.width}×${parent.parent.modelData.height}`
                    font { family: Theme.fontMono; pixelSize: 10; weight: 500 }
                    color: Theme.text2
                  }
                }
                Text {   // accent check on the selected card
                  visible: root.selScreen === parent.index
                  anchors { top: parent.top; right: parent.right; margins: 8 }
                  text: "✓"
                  font { family: Theme.fontMono; pixelSize: 12; weight: 700 }
                  color: Theme.accent
                }
                MouseArea { anchors.fill: parent; onClicked: root.selScreen = parent.index }
              }
            }
          }

          Column {   // window rows: monogram + class + title
            id: windowCol
            visible: root.tab === "windows"
            width: parent.width
            spacing: 6
            Repeater {
              model: root.windows
              Rectangle {
                required property var modelData
                width: parent.width; height: 40; radius: Theme.radiusTile
                color: root.selWindow === modelData.handle ? Theme.accentFill : Theme.surface04
                border.width: 1
                border.color: root.selWindow === modelData.handle ? Theme.accentBorder : Theme.surface07
                Column {
                  anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                  spacing: 2
                  Text {
                    text: parent.parent.modelData.cls
                    font { family: Theme.fontMono; pixelSize: 11; weight: 600 }
                    color: Theme.text
                  }
                  Text {
                    text: parent.parent.modelData.title
                    width: dialog.width - 64
                    elide: Text.ElideRight
                    font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
                    color: Theme.text2
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: {
                    root.selWindow = parent.modelData.handle
                    root.selWindowLabel = parent.modelData.cls
                  }
                }
              }
            }
          }
        }

        Row {   // footer: cancel / share →
          anchors.right: parent.right
          spacing: 8
          Rectangle {
            width: cancelLabel.implicitWidth + 24; height: 28; radius: Theme.radiusChip
            color: Theme.surface05
            Text {
              id: cancelLabel
              anchors.centerIn: parent; text: "cancel"
              font { family: Theme.fontMono; pixelSize: 10; weight: 600 }
              color: Theme.text2
            }
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
          }
          Rectangle {
            readonly property bool ready:
              (root.tab === "screens" && root.selScreen >= 0)
              || (root.tab === "windows" && root.selWindow !== "")
            width: shareLabel.implicitWidth + 24; height: 28; radius: Theme.radiusChip
            color: Theme.accent
            opacity: ready ? 1 : 0.35
            Text {
              id: shareLabel
              anchors.centerIn: parent
              text: root.tab === "screens" && root.selScreen >= 0
                ? `share ${Quickshell.screens[root.selScreen].name} →`
                : root.selWindow !== "" ? `share ${root.selWindowLabel} →` : "share →"
              font { family: Theme.fontMono; pixelSize: 10; weight: 700 }
              color: Theme.textOnAccent
            }
            MouseArea { anchors.fill: parent; enabled: parent.ready; onClicked: root.confirm() }
          }
        }
      }
    }

    Shortcut { sequence: "Escape"; onActivated: Qt.quit() }
    Shortcut { sequence: "Return"; onActivated: root.confirm() }
  }
}
