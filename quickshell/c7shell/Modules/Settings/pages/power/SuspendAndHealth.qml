pragma ComponentBehavior: Bound
import QtQuick
import qs.Theme
import qs.Common
import qs.Services
import qs.Modules.Settings

// The right-hand half of settings -> system -> power: what the machine does
// when it is left alone, and what it does to the battery while charging.
// None of it goes through tuned, which is why it stays up when the profile
// section above it is replaced by the tuned-missing card.
Row {
  spacing: 14

  Column {
    width: (parent.width - 14) - 290
    spacing: 8

    SectionHeading { width: parent.width; text: "suspend & screen" }

    SettingsCard {
      width: parent.width
      padV: 0
      padH: 0
      spacing: 0

      // hypridle reads its config once at startup, so every change here
      // rewrites ~/.config/hypr/hypridle.conf and restarts it. The page is
      // the single editor for these and for the lid below, which is the only
      // way the two cannot end up disagreeing.
      TimingRow {
        width: parent.width
        divider: false
        title: "blank screen"
        seconds: PowerStore.blankScreen
        options: [0, 60, 120, 300, 600, 900, 1800]
        onPicked: v => PowerStore.values.blankScreen = v
      }

      TimingRow {
        width: parent.width
        enabled: PowerStore.blankScreen > 0
        title: "lock after blank"
        seconds: PowerStore.lockAfterBlank
        options: [0, 30, 60, 300, 600]
        neverLabel: "immediately"
        onPicked: v => PowerStore.values.lockAfterBlank = v
      }

      TimingRow {
        width: parent.width
        title: "suspend on battery"
        seconds: PowerStore.suspendOnBattery
        options: [0, 600, 1200, 1800, 3600]
        onPicked: v => PowerStore.values.suspendOnBattery = v
      }

      SettingsListRow {
        width: parent.width
        title: "lid close"
        // logind, not hypridle -- and it is system state, so this one asks.
        subtitle: "written to logind, which needs an admin password"

        Dropdown {
          anchors.verticalCenter: parent.verticalCenter
          implicitWidth: 104
          options: ["suspend", "lock", "ignore", "poweroff"]
          current: PowerStore.lidClose
          onPicked: v => PowerService.setLidClose(v)
        }
      }
    }
  }

  Column {
    width: 290
    spacing: 8

    SectionHeading { width: parent.width; text: "battery health" }

    SettingsCard {
      width: parent.width
      spacing: 9

      Text {
        width: parent.width
        visible: !BatteryService.present
        text: "no battery detected on this machine"
        font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
        color: Theme.alpha(Theme.text, 0.35)
      }

      Column {
        width: parent.width
        visible: BatteryService.present
        spacing: 4

        HealthRow {
          width: parent.width
          key: "capacity"
          // Health, then what it means in Wh. A pack that does not report
          // health drops the ratio rather than printing "0% of 0 Wh".
          value: BatteryService.health >= 0
            ? `${BatteryService.health}% · ${BatteryService.energyFullWh.toFixed(1)} of ${BatteryService.energyDesignWh.toFixed(1)} Wh`
            : `${BatteryService.energyFullWh.toFixed(1)} Wh`
        }
        HealthRow {
          width: parent.width
          visible: BatteryService.cycles > 0
          key: "cycles"
          value: `${BatteryService.cycles}`
        }
        HealthRow {
          width: parent.width
          key: "charge"
          value: `${BatteryService.percent}% · ${BatteryService.energyWh.toFixed(1)} Wh`
        }
      }

      ChargeLimitRow {
        width: parent.width
        visible: BatteryService.present
      }
    }
  }

  component HealthRow: Item {
    id: hrow

    required property string key
    required property string value

    implicitHeight: hrow.visible ? 14 : 0

    Text {
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      text: hrow.key
      font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
      color: Theme.alpha(Theme.text, 0.42)
    }
    Text {
      anchors { right: parent.right; verticalCenter: parent.verticalCenter }
      text: hrow.value
      font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
      color: Theme.text
    }
  }

  // A SettingsListRow whose control is a duration. Seconds in, seconds out --
  // the minutes are a presentation detail and never reach PowerStore.
  component TimingRow: SettingsListRow {
    id: trow

    required property int seconds
    required property var options
    property string neverLabel: "never"

    signal picked(int value)

    function label(s) {
      if (s <= 0) return trow.neverLabel
      if (s < 60) return `${s} s`
      return `${s / 60} min`
    }

    Dropdown {
      anchors.verticalCenter: parent.verticalCenter
      implicitWidth: 92
      options: trow.options.map(s => trow.label(s))
      current: trow.label(trow.seconds)
      onPicked: v => {
        const i = trow.options.map(s => trow.label(s)).indexOf(v)
        if (i >= 0) trow.picked(trow.options[i])
      }
    }
  }
}
