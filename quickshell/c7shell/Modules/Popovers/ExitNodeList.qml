import QtQuick
import C7
import qs.Theme
import qs.Common

// The exit-node panel of the mock: a search field, a checked `none` row, the
// node /localapi/v0/suggest-exit-node recommends promoted under its own
// heading, every exit node the tailnet offers, and the two preference rows
// the mock drew underneath them.
//
// The rows are CONTROLS. v1 drew them dead because `tailscale set` refuses for
// a non-root, non-operator user; the contract can write now, and
// c7shell-bootstrap names the desktop user as tailscaled's operator, so a row
// here asks for the node it names.
Column {
  id: root

  objectName: "ts-exit-list"
  spacing: 6

  // `writable` is a claim about the LAST write, never permission for the next
  // one: TailscaleBackend.h says so in as many words, because the name invites
  // the opposite reading. It starts TRUE and goes false only once tailscaled
  // has refused something, so these controls are live until a refusal and dead
  // afterwards -- with the refusal's own words above them. Gated the other way
  // round, a correctly bootstrapped machine would open this panel with every
  // control disabled and no way left to make the first write.
  readonly property bool refused: !Tailscale.writable

  // How tall the scrolling part of this list may get. The owner decides it --
  // this panel is folded out of a card that has a header, an alert and the
  // root rows above it, and only the owner knows what is left.
  property int maxListHeight: 180

  // Focused by whatever grew this panel, never by this panel itself: see
  // Common/SearchField.
  function focusSearch() { searchField.focusInput() }

  // Folded once here rather than per row per keystroke.
  readonly property string query: searchField.text.trim().toLowerCase()

  function matches(displayName) {
    return root.query === "" || displayName.toLowerCase().indexOf(root.query) >= 0
  }

  // How many node rows the query leaves standing. Counted rather than derived
  // from the children, because Item.visibleChildren does not re-announce
  // itself when a child's own `visible` flips -- measured on this tree, not
  // assumed. Every delegate calls this when its own `matched` moves, so the
  // last call always lands after the last binding has settled; the Repeater
  // calls it when the model gains or loses a row.
  property int matchCount: 0

  function recount() {
    let found = 0
    for (let i = 0; i < nodes.count; ++i) {
      const row = nodes.itemAt(i)
      if (row && row.matched) ++found
    }
    root.matchCount = found
  }

  // An action is a REQUEST: this asks, and the daemon's next notification is
  // what moves the check mark. Nothing is drawn as selected here.
  function choose(nodeId) {
    if (root.refused) return
    Tailscale.setExitNode(nodeId)
  }

  // WHAT TAILSCALED HOLDS, not what was last clicked here. Task 5 shipped this
  // as a local bool because the contract had the action and no property to
  // read back from, and that switch lied in three ways: it opened off on a
  // machine where LAN access was already on, it never heard a change made with
  // `tailscale set` elsewhere, and a refused write could not spring it back.
  //
  // A plain binding, with no optimistic latch over it. tailscaled puts a Prefs
  // notification on the bus for an accepted write -- measured at t+3.0s on a
  // first write and in milliseconds thereafter -- and the backend re-reads
  // /prefs on it, so the round trip is already faster than the eye and the
  // value on screen is the daemon's. A latch would buy nothing and would make
  // a refused write indistinguishable from an accepted one, which is the one
  // outcome TailscaleBackend.h says this module may not produce.
  readonly property bool lanAccess: Tailscale.exitNodeAllowLANAccess

  // -- why everything below is dead -------------------------------------------
  // Only after a refusal, which is the one moment the flag is for. The wording
  // is presentation and so lives here: the contract publishes what refused it
  // and deliberately does not phrase it.
  Text {
    objectName: "ts-exit-write-error"
    width: root.width
    visible: root.refused
    leftPadding: 8
    rightPadding: 8
    text: qsTr("tailscaled refused the change: it takes orders only from root or its operator. Run c7shell-bootstrap to name this user. (%1)").arg(Tailscale.writeError)
    // The daemon's own answer, verbatim, which makes it daemon-supplied text.
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    font { family: Theme.fontMono; pixelSize: 10; weight: 400 }
    color: Theme.accentSoft
  }

  // -- search ------------------------------------------------------------------
  // The list below scrolls now, so this is no longer the only thing standing
  // between a hundred-node tailnet and an unusable panel -- but scrolling for
  // a node you can name is still worse than typing it. The filter is on the
  // display name because that is what the row shows.
  SearchField {
    id: searchField

    objectName: "ts-exit-search"
    // The FIELD, not the pill: the focus check and the filter both want the
    // item holding the text.
    fieldName: "ts-exit-search-input"
    width: root.width
  }

  // `none` is a checked row rather than an absence: you pick egress, you do
  // not toggle a feature. It is never filtered -- it is the reading of where
  // traffic goes now, not a search result.
  ListRow {
    objectName: "ts-exit-none"
    width: root.width
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    leadingSize: 12
    titleSize: 11
    titleWeight: 500
    hoverable: !root.refused
    active: !Tailscale.exitNodeActive
    title: qsTr("none")

    // An empty id is how the contract spells "no exit node" -- the same string
    // exitNodeId publishes when egress is unrouted.
    onClicked: root.choose("")

    // Deliberately NOT drawn at Theme.textDisabled with the rest after a
    // refusal: the others are offers that cannot be taken, this one is the
    // reading -- egress is unrouted right now -- and a reading of current
    // state has to stay legible however dead the panel is.
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

      required property string displayName
      required property string nodeId

      width: root.width
      spacing: 6
      // Filtered with the list: the suggested node is one of the rows below
      // too, so a query it does not answer to would otherwise leave it on
      // screen as the only hit, under a heading, twice.
      visible: recommended.nodeId !== ""
        && recommended.nodeId === Tailscale.recommendedExitNodeId
        && root.matches(recommended.displayName)

      SectionLabel {
        objectName: "ts-exit-recommended-label"
        text: qsTr("recommended")
      }

      ExitRow {
        objectName: "ts-exit-recommended"
        width: recommended.width
        displayName: recommended.displayName
        nodeId: recommended.nodeId
      }
    }
  }

  SectionLabel {
    objectName: "ts-exit-all-label"
    // The list says what it is. "(read-only)" is the state after a refusal
    // now, not the permanent condition it was in v1.
    text: root.refused ? qsTr("tailnet exit nodes (read-only)") : qsTr("tailnet exit nodes")
  }

  // The one part of this panel that is allowed to be longer than the card.
  // v1 and Task 5 both left it as a plain Column, which made a twenty-node
  // tailnet a 700px popover and the hundred-node one the spec names
  // unopenable. Everything else here -- the search, the `none` row, the
  // recommendation, the preference rows -- stays pinned: a filter you have to
  // scroll back up to reach is not a filter, and the preferences are not part
  // of the list they sit under.
  Flickable {
    objectName: "ts-exit-scroll"
    width: root.width
    height: Math.min(nodeColumn.implicitHeight, root.maxListHeight)
    contentHeight: nodeColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: nodeColumn
      // Explicit: a Flickable's contentItem has no width of its own to
      // inherit, so `parent.width` here is zero and every row in it collapses.
      width: root.width
      spacing: 6

      Repeater {
        id: nodes

        model: Tailscale.exitNodes

        onItemAdded: root.recount()
        onItemRemoved: root.recount()

        ExitRow {
          objectName: "ts-exit-row"
          width: root.width
        }
      }
    }
  }

  // The two empty lists a view has to tell apart. A query that found nothing
  // is not a tailnet with no exit nodes on it, and a panel that says the wrong
  // one of those looks broken rather than filtered.
  ListRow {
    objectName: "ts-exit-no-match"
    width: root.width
    visible: root.query !== "" && root.matchCount === 0 && nodes.count > 0
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: false
    titleColor: Theme.textDisabled
    title: qsTr("no matches")
  }

  ListRow {
    objectName: "ts-exit-empty"
    width: root.width
    visible: nodes.count === 0
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: false
    titleColor: Theme.textDisabled
    title: qsTr("no exit nodes on this tailnet")
  }

  SectionLabel {
    objectName: "ts-exit-prefs-label"
    text: qsTr("preferences")
  }

  // Scoped to the exit-node view and not to global settings, because it is
  // meaningless without one: it is the control that matters when an exit node
  // is blackholing the LAN, which is the failure this project hit on its own
  // test VM -- without it, a node that stops answering takes the printer, the
  // router's web UI and the NAS with it.
  ListRow {
    id: lanRow

    objectName: "ts-exit-lan"
    width: root.width
    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: !root.refused
    titleColor: root.refused ? Theme.textDisabled : Theme.alpha(Theme.text, 0.85)
    title: qsTr("allow local network access")

    // The OPPOSITE of what tailscaled holds, which is what a switch asks for.
    // Nothing is assigned here: the request goes out and the bus settles what
    // the pill draws.
    onClicked: {
      if (root.refused) return
      Tailscale.setExitNodeAllowLANAccess(!root.lanAccess)
    }

    TogglePill {
      objectName: "ts-exit-lan-switch"
      anchors.verticalCenter: parent.verticalCenter
      checked: root.lanAccess
      enabled: !root.refused
      // The pill sits in the trailing slot, above the row's own MouseArea, so
      // it takes its own press -- both paths end in the one handler.
      onToggled: lanRow.clicked()
    }
  }

  // THE CONTRACT HAS NO ACTION FOR THIS. Advertising this machine as an exit
  // node is `AdvertiseRoutes: ["0.0.0.0/0", "::/0"]`, and the five actions the
  // contract publishes are WantRunning, ExitNodeID, ExitNodeAllowLANAccess,
  // RouteAll and CorpDNS -- the v2 spec puts advertising routes out of scope.
  // The mock drew this row disabled and so does this: a row wired to nothing
  // would be indistinguishable from one whose write is being refused.
  ListRow {
    objectName: "ts-exit-advertise"
    width: root.width
    implicitHeight: 38
    radius: Theme.radiusMenuRow
    inset: 8
    titleSize: 11
    titleWeight: 500
    hoverable: false
    titleColor: Theme.textDisabled
    title: qsTr("use this device as an exit node…")
    subtitle: qsTr("not in this release")
    subtitleColor: Theme.textDisabled
  }

  component ExitRow: ListRow {
    id: exitRow

    // The DNS label, as on a device row: a cloud instance's OS hostname is
    // its own private address, and the console names it by the label.
    required property string displayName
    required property string nodeId

    // Reported rather than read off `visible`, so the count above does not
    // depend on a positioner having laid out yet.
    readonly property bool matched: root.matches(exitRow.displayName)

    implicitHeight: 30
    radius: Theme.radiusMenuRow
    inset: 8
    leadingSize: 12
    titleSize: 11
    titleWeight: 500
    visible: exitRow.matched
    // Dead only after a refusal, and then it does not light up under the
    // pointer either: a hover tint on a row that cannot be chosen is a promise.
    hoverable: !root.refused
    titleColor: root.refused ? Theme.textDisabled : Theme.alpha(Theme.text, 0.85)
    title: exitRow.displayName

    // Its own id, never its name: the row next to it may carry the same one.
    onClicked: root.choose(exitRow.nodeId)

    onMatchedChanged: root.recount()

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
