pragma ComponentBehavior: Bound
import QtQuick
import qs.Theme
import qs.Common
import qs.Services

// The battery charge-limit row on settings -> system -> power: a label saying
// what the limit does, and a picker to change it. Both read one mapping of
// PowerService.chargeLimit, so they cannot describe the same value two ways.
Item {
  id: root

  // 0 and anything at or above 100 both mean "no threshold": the picker shows
  // "off", and picking "off" writes 100.
  readonly property bool limitOff: PowerService.chargeLimit === 0 || PowerService.chargeLimit >= 100
  readonly property string currentOption: root.limitOff ? "off" : `${PowerService.chargeLimit}%`
  readonly property var grid: [60, 70, 80, 85, 90, 95]

  // A vendor clamp can leave sysfs on a value the grid does not offer, such as
  // 55. That value joins the list in order, so the picker marks it and opens
  // on it instead of parking on the first row.
  readonly property var options: {
    const limits = root.limitOff || root.grid.includes(PowerService.chargeLimit)
      ? root.grid
      : root.grid.concat([PowerService.chargeLimit]).sort((a, b) => a - b)
    return limits.map(l => `${l}%`).concat(["off"])
  }

  implicitHeight: limitBody.implicitHeight + 9

  Rectangle {
    anchors { left: parent.left; right: parent.right; top: parent.top }
    height: 1
    color: Theme.alpha(Theme.text, 0.06)
  }

  Item {
    id: limitBody

    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
    implicitHeight: Math.max(limitText.implicitHeight, limitPick.implicitHeight)

    Column {
      id: limitText

      anchors {
        left: parent.left; right: limitPick.left; rightMargin: 12
        verticalCenter: parent.verticalCenter
      }
      spacing: 2

      Text {
        width: parent.width
        text: "charge limit"
        font { family: Theme.fontMono; pixelSize: 10; weight: 500 }
        color: Theme.alpha(Theme.text, 0.75)
      }
      Text {
        objectName: "limitLabel"
        width: parent.width
        // The value shown is the one sysfs reports back, never the one
        // that was asked for: several vendors clamp the write, and a
        // limit that did not take must not read as though it did.
        text: !PowerService.limitSupported
          ? "this pack exposes no charge threshold"
          : root.limitOff
            ? "charges to full"
            : `stops at ${PowerService.chargeLimit}% to slow wear`
        font { family: Theme.fontMono; pixelSize: 9; weight: 400 }
        color: Theme.alpha(Theme.text, 0.35)
        wrapMode: Text.WordWrap
      }
    }

    Dropdown {
      id: limitPick

      objectName: "limitPick"
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      implicitWidth: 76
      enabled: PowerService.limitSupported
      opacity: PowerService.limitSupported ? 1 : 0.4
      options: root.options
      current: root.currentOption
      onPicked: v => PowerService.setChargeLimit(v === "off" ? 100 : parseInt(v))
    }
  }
}
