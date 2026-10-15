import QtQuick
import C7
import qs.Theme
import qs.Common

// The exit-node panel of the mock: a checked `none` row, the node
// /localapi/v0/suggest-exit-node recommends promoted under its own heading,
// then every exit node the tailnet offers.
//
// v1 is read-only. `tailscale set` refuses for a non-root, non-operator user,
// so picking a node here would be a row that looks like a radio button and
// does nothing. The rows are therefore drawn at Theme.textDisabled and the
// heading says so, rather than being left out -- which node you are on, and
// which one the tailnet suggests, is worth reading even when it cannot be
// changed from here.
Column {
  id: root

  spacing: 6

  // `none` is a checked row rather than an absence: you pick egress, you do
  // not toggle a feature.
  ListRow {
    objectName: "ts-exit-none"
    width: parent.width
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    leadingSize: 12
    titleSize: 11
    titleWeight: 500
    hoverable: false
    active: !Tailscale.exitNodeActive
    title: qsTr("none")

    leading: Icon {
      name: "check"
      size: 12
      tint: Theme.accentSoft
      visible: !Tailscale.exitNodeActive
    }
  }

  // Shown off recommendedExitNodeId alone: the contract says it matches a row
  // in exitNodes, and the model has no random access from QML to confirm it
  // against -- the Repeater below is what actually finds the row.
  SectionLabel {
    objectName: "ts-exit-recommended-label"
    visible: Tailscale.recommendedExitNodeId !== ""
    text: qsTr("recommended")
  }

  // One Repeater over the whole model with a single visible row, because a
  // QAbstractItemModel offers QML no way to look a row up by id. A Column
  // lays out only its visible children, so the hidden ones cost nothing here.
  Repeater {
    model: Tailscale.exitNodes

    ExitRow {
      objectName: "ts-exit-recommended"
      width: root.width
      visible: nodeId !== "" && nodeId === Tailscale.recommendedExitNodeId
    }
  }

  SectionLabel {
    objectName: "ts-exit-all-label"
    text: qsTr("tailnet exit nodes (read-only)")
  }

  Repeater {
    model: Tailscale.exitNodes

    ExitRow {
      objectName: "ts-exit-row"
      width: root.width
    }
  }

  component ExitRow: ListRow {
    id: exitRow

    required property string hostName
    required property string nodeId

    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    leadingSize: 12
    titleSize: 11
    titleWeight: 500
    // Not selectable in v1, so it does not light up under the pointer either:
    // a hover tint on a row that cannot be chosen is a promise.
    hoverable: false
    titleColor: Theme.textDisabled
    title: exitRow.hostName

    // ExitNodeStatus carries no hostname, so the backend joins the name back
    // off the peer list; the name is the only identity both ends share here.
    leading: Icon {
      name: "check"
      size: 12
      tint: Theme.accentSoft
      visible: Tailscale.exitNodeActive && Tailscale.exitNodeName === exitRow.hostName
    }
  }
}
