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

    // Deliberately NOT drawn at Theme.textDisabled like the rows below it.
    // Those are dimmed because they offer a choice v1 cannot make; this one
    // is not an offer, it is the reading -- egress is unrouted right now --
    // and a reading of current state has to stay legible.
    leading: Icon {
      name: "check"
      size: 12
      tint: Theme.accentSoft
      visible: !Tailscale.exitNodeActive
    }
  }

  // The heading and the row are ONE delegate, so the heading cannot outlive
  // the row it introduces: an id naming a peer that is not in exitNodes -- a
  // node dropped from the list between the status and the suggestion --
  // leaves no bare heading because there is nothing for a bare heading to be.
  //
  // It is a Repeater over the whole model rather than a lookup because a
  // QAbstractItemModel offers QML no way to find a row by id, and it is this
  // shape rather than a count of visible children because Item.visibleChildren
  // does not re-announce itself when a child's own `visible` flips -- measured,
  // not assumed: the heading stayed up.
  Repeater {
    model: Tailscale.exitNodes

    Column {
      id: recommended

      required property string hostName
      required property string nodeId

      width: root.width
      spacing: 6
      visible: recommended.nodeId !== ""
        && recommended.nodeId === Tailscale.recommendedExitNodeId

      SectionLabel {
        objectName: "ts-exit-recommended-label"
        text: qsTr("recommended")
      }

      ExitRow {
        objectName: "ts-exit-recommended"
        width: recommended.width
        hostName: recommended.hostName
        nodeId: recommended.nodeId
      }
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

    // Joined on the ID, never the name. TailscaleBackend.h says why: nothing
    // stops two machines enrolling under one hostname, and a check mark
    // joined on the name lands on every row that shares it with the node
    // actually carrying the traffic -- which reads as egress going two places
    // at once. The ID is the identity the status, exit-node and suggestion
    // endpoints all share, and is what the RECOMMENDED row joins on above.
    leading: Icon {
      name: "check"
      size: 12
      tint: Theme.accentSoft
      visible: Tailscale.exitNodeActive && exitRow.nodeId !== ""
        && Tailscale.exitNodeId === exitRow.nodeId
    }
  }
}
