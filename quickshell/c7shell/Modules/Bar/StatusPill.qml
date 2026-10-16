import QtQuick
import Quickshell.Networking
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import C7
import qs.Theme
import qs.Common
import qs.Services

Rectangle {
  id: root

  readonly property var wifi: Networking.devices.values.find(d => d.type === DeviceType.Wifi) ?? null
  readonly property var btAdapter: Bluetooth.defaultAdapter
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property bool muted: sink?.audio?.muted ?? false

  PwObjectTracker { objects: root.sink ? [root.sink] : [] }

  implicitWidth: content.implicitWidth + 12   // slots carry their own padding now
  implicitHeight: Theme.pillHeight
  radius: Theme.pillRadius
  color: Theme.surface05

  Row {
    id: content
    anchors.centerIn: parent
    spacing: 2   // slots carry their own padding now

    QuickSlot {
      anchors.verticalCenter: parent.verticalCenter
      visible: ScreenshareService.active
      slotColor: Theme.alpha(Theme.accent, 0.18)
      hoverColor: Theme.powerHover
      onClicked: ScreenshareService.stop()
      Icon { name: "screen-share"; tint: Theme.accentSoft }
    }
    // The badge is a door now, not a re-check: the dry run behind it already
    // knows whether one click is enough, so opening it is the whole point.
    // While a run is going it becomes the thin progress ring the design gives
    // a dropdown that has been closed over a running update.
    QuickSlot {
      id: updateSlot
      anchors.verticalCenter: parent.verticalCenter
      visible: UpdatesService.total > 0 || UpdatesService.running
               || UpdatesService.pacnews.length > 0
      active: PopoverManager.current === "updates"
      slotColor: UpdatesService.kernelPending ? Theme.accentFill : "transparent"
      onClicked: PopoverManager.toggle("updates", updateSlot)

      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: 13; height: 13

        Icon {
          anchors.fill: parent
          visible: !UpdatesService.running
          name: "package"; size: 13
          tint: UpdatesService.kernelPending ? Theme.accentSoft : Theme.text3
        }
        ProgressRing {
          anchors.fill: parent
          visible: UpdatesService.running
          fraction: UpdatesService.runTotal > 0
            ? UpdatesService.doneCount / UpdatesService.runTotal : 0
        }

        // Housekeeping parked by a "later": amber, and it outlives the run
        // that produced it. Overlaid on the icon rather than placed beside it,
        // so it does not push the count along.
        Rectangle {
          anchors { right: parent.right; top: parent.top; margins: -1 }
          visible: UpdatesService.pacnews.length > 0 && !UpdatesService.running
          width: 4; height: 4; radius: 2
          color: Theme.warning
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // The count only, never a "0": the slot also stands for a parked
        // pacnew and for the seconds after a run when nothing has been
        // counted yet, and in both the icon alone is the honest badge.
        visible: !UpdatesService.running && UpdatesService.total > 0
        text: `${UpdatesService.total}`
        font { family: Theme.fontMono; pixelSize: 10; weight: 600 }
        color: UpdatesService.kernelPending ? Theme.accentSoft : Theme.text3
      }
    }
    QuickSlot {
      anchors.verticalCenter: parent.verticalCenter
      active: CaptureService.overlayOpen
      onClicked: CaptureService.toggle()
      Icon { name: "scan"; tint: CaptureService.overlayOpen ? Theme.accentSoft : Theme.text }
    }
    // Airplane mode has no popover of its own: the slot only exists while every
    // radio is off, and the one thing to do from there is come back out. It
    // sits ahead of the radio slots because it is the reason they look the way
    // they do -- and it appears however the radios went down, the Fn key
    // included, since the service derives the mode rather than storing it.
    QuickSlot {
      anchors.verticalCenter: parent.verticalCenter
      visible: AirplaneService.enabled
      slotColor: Theme.accentFill
      onClicked: AirplaneService.setEnabled(false)
      Icon { name: "plane"; tint: Theme.accentSoft }
    }
    // Ahead of the radios: egress outranks which radio carries it.
    //
    // NoState means two different things and the slot answers them
    // differently. On a machine with no tailscaled there is no tailnet to
    // report on and never was, so there is no slot -- a globe on a machine
    // that does not run Tailscale is chrome. Once tailscaled HAS answered,
    // NoState means it stopped answering, and then the slot stays: the whole
    // reason TailscaleBackend.h keeps the last snapshot when the daemon dies
    // is that exitNodeBlocked must not fall quiet exactly when the thing
    // dropping the traffic goes unreachable, and hiding the slot would drop
    // it just as thoroughly as blanking the snapshot would. An absent icon
    // cannot tell "the tailnet is fine" from "tailscaled is gone"; a dimmed
    // one can, and the icon below dims on anything short of Running.
    //
    // What IS gated on state is the panel behind the slot: a last-known
    // device list and a last-known identity would read as live (see
    // TailscalePopover). The badges here are the exception the contract asks
    // for, not a hole in that rule.
    QuickSlot {
      id: tsSlot
      // The one handle a compositor-less test has on this slot: a QuickSlot in
      // a row of eight differs from its neighbours only by what it is bound to.
      objectName: "tailscale"
      anchors.verticalCenter: parent.verticalCenter

      // "Has tailscaled ever answered since the bar started?" -- latched, not
      // a binding, because its whole job is to outlive the state that set it.
      property bool everAnswered: false
      readonly property bool answering: Tailscale.state !== Tailscale.NoState
      onAnsweringChanged: if (tsSlot.answering) tsSlot.everAnswered = true
      // The binding above does not fire for a value that was already true
      // when this was built, which is the ordinary case for a bar restarted
      // under a running tailscaled.
      Component.onCompleted: if (tsSlot.answering) tsSlot.everAnswered = true

      visible: tsSlot.everAnswered
      active: PopoverManager.current === "tailscale"
      slotColor: Tailscale.exitNodeActive ? Theme.accentFill : "transparent"
      // The outline as well, only here: the battery's warn threshold is the
      // other state allowed to shout, and this is the Tailscale equivalent --
      // traffic is being dropped, not merely routed somewhere unusual.
      slotBorder: Tailscale.exitNodeBlocked ? Theme.accentBorder : "transparent"
      onClicked: PopoverManager.toggle("tailscale", tsSlot)

      Item {
        width: 15; height: 15
        anchors.verticalCenter: parent.verticalCenter

        Icon {
          anchors.fill: parent
          name: "globe"
          // Dimmed rather than hidden whenever the daemon is not actually
          // carrying traffic; accent-tinted while an exit node is.
          tint: Tailscale.state !== Tailscale.Running ? Theme.textDisabled
            : Tailscale.exitNodeActive ? Theme.accentSoft : Theme.text
        }
        // tailscaled's own health warnings: amber, not crimson, because
        // nothing is broken. Both badges own the same corner, so this one
        // stands down for the blocked one rather than stacking on it.
        Rectangle {
          anchors { right: parent.right; bottom: parent.bottom; margins: -1 }
          visible: Tailscale.issueCount > 0 && !Tailscale.exitNodeBlocked
          width: 4; height: 4; radius: 2
          color: Theme.warning
        }
        Text {   // ✕ badge, bottom-right, as the wifi slot wears it when offline
          // The selected exit node cannot be reached, so tailscaled is
          // dropping all egress rather than leaking it onto the local network.
          // The machine looks connected and nothing works; this is the only
          // thing on screen that says why.
          visible: Tailscale.exitNodeBlocked
          anchors { right: parent.right; bottom: parent.bottom; rightMargin: -2; bottomMargin: -2 }
          text: "✕"
          font { family: Theme.fontMono; pixelSize: 7; weight: 700 }
          color: Theme.accentSoft
        }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // Named, not just tinted: clearing the block means knowing which node
        // to clear, and the name is the only identity the panel will offer.
        visible: Tailscale.exitNodeActive
        text: Tailscale.exitNodeName
        // A MagicDNS label, or -- for a peer with no DNSName -- the raw
        // HostName tailscaled was handed when that machine enrolled. Either
        // way it is text off the network, and Common/ListRow.qml:97-105
        // writes out what the default Text.AutoText does with it: it renders
        // <b> AND fetches a remote <img src>, which is a markup injection and
        // a beacon in the shell's own bar.
        textFormat: Text.PlainText
        // Capped, unlike the update slot's label beside it: that one is a
        // count, this is a MagicDNS hostname off the network and nothing
        // bounds its length. QuickSlot grows with its content and the pill
        // grows with the slot, so an uncapped name would shove every slot to
        // its right -- and the clock with them -- each time an exit node came
        // or went.
        width: Math.min(implicitWidth, 90)
        elide: Text.ElideRight
        font { family: Theme.fontMono; pixelSize: 10; weight: 600 }
        color: Theme.accentSoft
      }
    }
    QuickSlot {
      id: netSlot
      anchors.verticalCenter: parent.verticalCenter
      visible: root.wifi !== null || NetworkService.ethDevice !== null
      active: PopoverManager.current === "wifi"
      slotColor: NetworkService.primary === "none" ? Theme.accentFill : "transparent"
      onClicked: PopoverManager.toggle("wifi", netSlot)

      Item {
        width: 15; height: 15
        anchors.verticalCenter: parent.verticalCenter
        Icon {
          anchors.fill: parent
          name: NetworkService.primary === "ethernet" ? "ethernet" : "wifi"
          tint: NetworkService.primary === "none" ? Theme.accentSoft : Theme.text
        }
        Text {   // ✕ badge, bottom-right, only when offline
          visible: NetworkService.primary === "none"
          anchors { right: parent.right; bottom: parent.bottom; rightMargin: -2; bottomMargin: -2 }
          text: "✕"
          font { family: Theme.fontMono; pixelSize: 7; weight: 700 }
          color: Theme.accentSoft
        }
      }
    }
    QuickSlot {
      id: btSlot
      anchors.verticalCenter: parent.verticalCenter
      visible: root.btAdapter !== null && root.btAdapter.enabled
      active: PopoverManager.current === "bluetooth"
      onClicked: PopoverManager.toggle("bluetooth", btSlot)
      Icon { name: "bluetooth"; tint: Theme.text }
    }
    QuickSlot {
      id: volSlot
      anchors.verticalCenter: parent.verticalCenter
      visible: root.sink !== null
      active: PopoverManager.current === "audio"
      onClicked: PopoverManager.toggle("audio", volSlot)
      Icon { name: root.muted ? "volume-x" : "volume-2"; tint: root.muted ? Theme.accentSoft : Theme.text }
    }
    // Below the warn threshold the whole slot goes crimson-tinted, which is
    // the one state the battery widget is allowed to shout in.
    QuickSlot {
      id: batterySlot
      anchors.verticalCenter: parent.verticalCenter
      visible: BatteryService.present
      active: PopoverManager.current === "battery"
      slotColor: battery.warn ? Theme.accentFill : "transparent"
      slotBorder: battery.warn ? Theme.accentBorder : "transparent"
      onClicked: PopoverManager.toggle("battery", batterySlot)

      BatteryIndicator {
        id: battery
        anchors.verticalCenter: parent.verticalCenter
        // The tooltip stands down while the popover is up: it says a subset of
        // what the panel says, and two surfaces over one pill is one too many.
        hovered: batterySlot.hovered && PopoverManager.current !== "battery"
      }
    }
  }
}
