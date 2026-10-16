import QtQuick
import QtQuick.Window
import Quickshell
import C7
import qs.Theme
import qs.Modules.Bar
import qs.Modules.Popovers
import qs.Services

// Self-check for the bar's Tailscale slot (run by tests/test-tailscale.sh).
//
// The slot is the only thing in the shell that says "every packet you send is
// being dropped on purpose". That verdict is assembled entirely out of
// bindings -- a tint, a badge, a label -- so there is no function to call and
// nothing throws when one of them is wrong; the slot simply looks calm. This
// drives the six states the design names and reads back what the slot wears.
//
// It also pins the gating rule from TailscaleBackend.h: when tailscaled dies
// the backend publishes NoState and deliberately KEEPS the last snapshot, so
// a slot that does not gate on state renders a healthy tailnet served by a
// daemon that is gone.
//
// The second half of the file drives the panel behind the slot. Same problem,
// one layer up: a popover is bindings too, so a wrong one draws a calm panel
// rather than throwing. The last section of all is the one this module has
// owed since Task 3 -- a REAL ListView over the peer model, with local state
// on one delegate, driven through the signals PeerModel is proven to emit.
Window {
  id: root
  visible: true
  // Big enough that the panel is laid out at its real size rather than
  // against a 100px window; nothing here reads the window's own geometry.
  width: 480; height: 900

  // Throws rather than calling Qt.exit(): Qt.exit() only schedules the exit,
  // so the rest of the block would run on and print the PASS line anyway.
  function check(cond, msg) {
    if (!cond) throw new Error(msg)
  }

  StatusPill { id: pill }
  TailscalePopover { id: pop }

  // Every action the panel has asked of the contract, in order. An action is a
  // REQUEST and moves nothing on the singleton -- so a control that is merely
  // enabled proves nothing about what it does, and the recorded call is the
  // only evidence there is that a row asked for the node it is drawn as.
  property var calls: []

  Connections {
    target: Tailscale
    function onCalled(call) { root.calls.push(call) }
  }

  // Read and cleared together: every assertion below is about what ONE press
  // asked for, so a leftover from the press before it would pass the next
  // check for the wrong reason.
  function tookCalls() {
    const taken = root.calls
    root.calls = []
    return taken.join(" ")
  }

  // Every visual descendant, flattened. The slot has no id reachable from
  // out here, and giving each badge its own hook would mean writing the
  // design into the test twice -- so the test looks for what the design
  // actually specifies: a glyph of a given colour, a label of a given text.
  //
  // contentItem is walked as well as children, because a ListView's delegates
  // live under it and not under the view -- without that the panel's device
  // rows are simply not in this list, and every assertion about them would
  // report "not there" rather than failing on what it meant to check.
  // `seen` keeps the two from double-counting a contentItem that is also a
  // child.
  function collect(item, seen) {
    if (!item) return seen
    for (const c of (item.children ?? [])) {
      if (seen.indexOf(c) >= 0) continue
      seen.push(c)
      root.collect(c, seen)
    }
    const inner = item.contentItem ?? null
    if (inner && inner !== item && seen.indexOf(inner) < 0) {
      seen.push(inner)
      root.collect(inner, seen)
    }
    return seen
  }

  function descendants(item) {
    return root.collect(item, [])
  }

  // objectName, because a QuickSlot in a Row of eight otherwise differs from
  // its neighbours only by what it happens to be bound to.
  function slot() {
    return root.descendants(pill).find(o => o.objectName === "tailscale") ?? null
  }

  function slotParts() {
    return root.descendants(root.slot())
  }

  // `color` is undefined on the plain Items in the tree (and on Icon, which
  // carries a `tint`), so the guard is load-bearing, not defensive.
  //
  // Compared as strings rather than with Qt.colorEqual: colorEqual answered
  // false for a crimson badge whose colour and Theme.accentSoft stringify to
  // the same value. accentSoft is the one token built with Qt.hsla instead of
  // read from the palette, and the rgb tokens it sits beside -- warning, text,
  // textDisabled -- compare fine, so the spec is what differs. Both sides
  // stringify through the same conversion, which is what is actually painted.
  function visibleOfColour(c) {
    return root.slotParts().filter(o => o.visible && o.color !== undefined
                                        && `${o.color}` === `${c}`)
  }

  function visibleText(s) {
    return root.slotParts().some(o => o.visible && o.text === s)
  }

  // A badge assertion that fails says only "not there", which reads the same
  // whether the element is missing, hidden or the wrong colour. The message
  // carries what the slot is actually holding instead.
  function dump() {
    return root.slotParts().map(o =>
      `[${o.visible ? "shown" : "hidden"}${o.text !== undefined ? ` "${o.text}"` : ""}`
      + `${o.color !== undefined ? ` ${o.color}` : ""}`
      + `${o.tint !== undefined ? ` tint ${o.tint}` : ""}]`).join(" ")
  }

  // A Row lays out on polish, not on the binding change that provoked it, so
  // implicitWidth read in the same block is the previous frame's. The shell
  // gets a frame along in a millisecond and never notices; this has none.
  function slotWidth() {
    for (const o of root.slotParts())
      if (o.forceLayout !== undefined) o.forceLayout()
    return root.slot().implicitWidth
  }

  // The exit-node label. Both Texts in the slot carry `truncated`, so it is
  // told apart from the badge by the one thing that never varies about the
  // badge: its glyph.
  function label() {
    const labels = root.slotParts().filter(o => o.truncated !== undefined && o.text !== "\u2715")
    root.check(labels.length === 1, `expected one label in the slot, found ${labels.length}`)
    return labels[0]
  }

  // The icon's tint is the dimming, and Icon is the only thing in the slot
  // that has one.
  function iconTint() {
    const icons = root.slotParts().filter(o => o.tint !== undefined)
    root.check(icons.length === 1, `expected one Icon in the slot, found ${icons.length}`)
    return icons[0].tint
  }

  // The resting tailnet: up, no exit node, nothing to report.
  function connected() {
    Tailscale.state = Tailscale.Running
    Tailscale.issues = []
    Tailscale.exitNodeActive = false
    Tailscale.exitNodeOnline = false
    Tailscale.exitNodeName = ""
  }

  Component.onCompleted: {
    try {
      root.run()
    } catch (e) {
      console.log(`TAILSCALE-TEST-FAIL: ${e.message}`)
      Qt.exit(1)
      return
    }
    console.log("TAILSCALE-TEST-PASS")
    Qt.exit(0)
  }

  function run() {
    root.check(root.slot() !== null,
      "the bar has no Tailscale slot: nothing in StatusPill answers to objectName \"tailscale\"")

    // 1 -- NO TAILSCALE ON THIS MACHINE. Nothing has answered since this bar
    // started AND there is nothing at the socket path to answer -- which the
    // contract publishes as NoState with an EMPTY readError, and which is what
    // a machine without tailscaled looks like forever. A globe there is chrome
    // for a thing that is not installed.
    //
    // The empty readError is the half this case used to leave out, and leaving
    // it out is what made the check agree with the bug: `visible:
    // everAnswered` alone, asserted against never-answered NoState, pins the
    // conflation of "no tailscaled" with "tailscaled is there and I cannot
    // read it" as correct. 1b below is the second reading, and the two differ
    // only by this property.
    //
    // This runs FIRST deliberately: it is the only point in the file at which
    // the slot has never seen a daemon, and 5b below is the third reading of
    // the same NoState -- one that HAS answered, and must keep its badges. The
    // values set underneath are a healthy tailnet with a live exit node, so a
    // slot that showed anything here would be showing it from nowhere.
    Tailscale.state = Tailscale.NoState
    Tailscale.readError = ""
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = true
    Tailscale.exitNodeName = "pentest-exit-node"
    root.check(root.slot().visible === false,
      "the bar drew a Tailscale slot on a machine that has no tailscaled at all")
    root.check(!root.visibleText("pentest-exit-node"),
      "an exit-node label was drawn before any daemon had reported one")

    // 1b -- TAILSCALED IS THERE AND CANNOT BE READ. The same NoState, and the
    // opposite thing to show: the daemon is present, something is wrong with
    // it, and the panel carries the only sentence that says so. Every read
    // failure lands here when it happens at boot -- a 403 on the read path, a
    // TS_SOCKET naming another listener, a wedged daemon, a body that will not
    // parse -- and at boot is when it usually happens, so nothing has ever
    // answered and the latch is still false.
    //
    // With the slot hidden, the popover is unreachable: it opens by clicking
    // the slot (StatusPill.onClicked), so "tailscaled is not responding" could
    // never be shown in the one scenario it exists for.
    Tailscale.readError = "/localapi/v0/status answered HTTP/1.1 403 Forbidden"
    root.check(root.slot().visible === true,
      "tailscaled is present and unreadable and the bar drew nothing at all, which leaves"
      + " the panel that would explain it unreachable")
    root.check(Qt.colorEqual(root.iconTint(), Theme.textDisabled),
      "an unreadable tailscaled is drawn as brightly as a running one")
    // The panel says why, in the words of whatever failed the read. The row
    // above it is the same sentence for all three readings of NoState; this is
    // the only thing that tells them apart on screen.
    root.check(root.panelOne("ts-read-error").visible,
      "the panel drew no diagnosis for a daemon it could not read")
    root.check(root.panelOne("ts-read-error").text === Tailscale.readError,
      `the panel published something other than the read failure's own words:`
      + ` "${root.panelOne("ts-read-error").text}"`)
    // And it goes when there is nothing to say: on a machine with no tailscaled
    // the row above stands alone rather than over an empty line.
    Tailscale.readError = ""
    root.check(!root.panelOne("ts-read-error").visible,
      "the diagnosis line was drawn with no diagnosis in it")
    root.check(root.slot().visible === false,
      "the slot stayed on the bar after the read failure cleared, with nothing having answered")

    // 2 -- connected, healthy: present, plain, undimmed, no label.
    root.connected()
    root.check(root.slot().visible === true, "the slot is not visible while Running")
    root.check(Qt.colorEqual(root.slot().slotColor, "transparent"),
      "a healthy tailnet with no exit node tinted the slot")
    root.check(Qt.colorEqual(root.iconTint(), Theme.text),
      "the icon is not drawn at full strength while Running")
    root.check(root.slotParts().every(o => !o.visible || o.text === undefined || o.text === ""),
      "the slot carries a label with no exit node behind it")

    // 3 -- health has something to say. Amber, not crimson: nothing is broken.
    Tailscale.issues = ["is-using-unstable-version"]
    root.check(root.visibleOfColour(Theme.warning).length === 1,
      `issueCount ${Tailscale.issueCount} did not raise the amber badge: ${root.dump()}`)
    root.check(root.visibleOfColour(Theme.accentSoft).length === 0,
      "a health warning was drawn in crimson, which is reserved for blocked egress")

    // 3b -- down. Dimmed, still present: an absent icon could not tell this
    // apart from a tailnet that is fine.
    Tailscale.state = Tailscale.Stopped
    root.check(root.slot().visible === true, "the slot disappeared when Tailscale stopped")
    root.check(Qt.colorEqual(root.iconTint(), Theme.textDisabled),
      "a stopped Tailscale is drawn as brightly as a running one")
    root.check(root.visibleOfColour(Theme.warning).length === 1,
      "the amber badge went away when the daemon stopped, though the issue did not")

    // 4 -- egress is routed through an exit node that answers.
    root.connected()
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = true
    Tailscale.exitNodeName = "pentest-exit-node"
    root.check(Qt.colorEqual(root.slot().slotColor, Theme.accentFill),
      "an active exit node did not tint the slot")
    root.check(Qt.colorEqual(root.iconTint(), Theme.accentSoft),
      "an active exit node did not tint the icon")
    root.check(root.visibleText("pentest-exit-node"),
      "the active exit node is not named beside the icon")
    root.check(!root.visibleOfColour(Theme.accentSoft).some(o => o.text === "✕"),
      "a reachable exit node drew the crimson badge, which means blocked")

    // 5 -- the state the module exists for. The node is unreachable, so
    // tailscaled is dropping all egress rather than leaking it.
    Tailscale.exitNodeOnline = false
    root.check(Tailscale.exitNodeBlocked, "the stub's own derived flag is wrong")
    root.check(root.visibleOfColour(Theme.accentSoft).some(o => o.text === "✕"),
      `a blocked exit node did not raise the crimson badge -- nothing else says traffic is being dropped: ${root.dump()}`)
    root.check(Qt.colorEqual(root.slot().slotColor, Theme.accentFill),
      "the slot stopped being tinted once the exit node went unreachable")
    root.check(root.visibleText("pentest-exit-node"),
      "the blocked exit node is not named, so there is no way to tell which one to clear")

    // The two badges share one corner, so the louder one wins: being cut off
    // outranks a version warning.
    Tailscale.issues = ["is-using-unstable-version"]
    root.check(root.visibleOfColour(Theme.warning).length === 0,
      "the amber badge drew on top of the crimson one")

    // 5b -- the daemon dies while that is true. NoState now means something
    // else than it did in 1: tailscaled HAS answered on this machine, so the
    // slot is the stale reading of a tailnet whose daemon is gone, not the
    // absence of Tailscale. Hiding it here would drop exitNodeBlocked exactly
    // when the thing dropping the traffic went unreachable -- which is the
    // whole reason TailscaleBackend.h keeps the last snapshot rather than
    // blanking it.
    Tailscale.state = Tailscale.NoState
    root.check(root.slot().visible === true,
      "the slot vanished when tailscaled died, taking the only thing on screen that says"
      + " egress is being dropped with it")
    root.check(Qt.colorEqual(root.iconTint(), Theme.textDisabled),
      "a tailnet with no daemon behind it is drawn as brightly as a live one")
    root.check(root.visibleOfColour(Theme.accentSoft).some(o => o.text === "\u2715"),
      `the blocked badge went quiet when the daemon did: ${root.dump()}`)
    root.check(root.visibleText("pentest-exit-node"),
      "the slot stopped naming the node to clear once the daemon went")
    Tailscale.state = Tailscale.Running

    // 6 -- the label is bounded. A MagicDNS hostname is arbitrary text off the
    // network, QuickSlot grows with its content and the pill grows with the
    // slot: an uncapped name moves every slot to its right, and the clock with
    // them, every time an exit node comes or goes. Nothing about that is
    // visible in a screenshot of one state, which is why it is pinned here.
    const house = "yankee-with-a-long-magicdns-name.example-tailnet.ts.net"
    Tailscale.exitNodeName = "sierra"
    const narrow = root.slotWidth()
    Tailscale.exitNodeName = house
    const capped = root.slotWidth()
    root.check(capped > narrow,
      `the label contributes no width at all: "sierra" and "${house}" both give ${capped}`)
    root.check(root.label().truncated,
      `a ${house.length}-character node name was drawn in full rather than elided`)
    Tailscale.exitNodeName = house + house
    root.check(root.slotWidth() === capped,
      `doubling the node name widened the slot from ${capped} to ${root.slotWidth()}`)

    // The cap is a ceiling, not a fixed width: a short name must still shrink
    // the slot back, or the bar simply carries a 90px hole instead.
    Tailscale.exitNodeName = "sierra"
    root.check(root.slotWidth() === narrow,
      "the slot kept the width of the long name after a short one replaced it")
    root.check(!root.label().truncated, "a short node name was elided")

    // 6b -- the name is DRAWN, never interpreted. Common/ListRow.qml:97-105
    // writes the prohibition out in full and seven other sites on this branch
    // set Text.PlainText; this label is the eighth, and it is the one in the
    // bar. The default is Text.AutoText, which renders <b> AND fetches a
    // remote <img src> -- a markup injection, and a beacon, in the shell's own
    // chrome. The trigger is ordinary: a peer with no DNSName, whose raw
    // HostName is whatever that machine was called when it enrolled, selected
    // as the exit node.
    //
    // Read as WIDTH rather than as the textFormat property, because width is
    // what the person sees: eight literal characters are several times the
    // single glyph the markup would decorate, and nothing about an
    // interpreted label looks wrong in a screenshot.
    Tailscale.exitNodeName = "a"
    root.slotWidth()
    const bare = root.label().implicitWidth
    Tailscale.exitNodeName = "<b>a</b>"
    root.slotWidth()
    const literal = root.label().implicitWidth
    root.check(literal > bare * 2,
      `the slot interpreted the markup in an exit-node name instead of drawing it:`
      + ` "<b>a</b>" took ${literal}px where the one glyph it decorates takes ${bare}px`)
    Tailscale.exitNodeName = "sierra"

    // -- the panel behind the slot ------------------------------------------
    root.panelChecks()
    root.foldOutChecks()
    root.exitNodeControlChecks()
    root.settingsChecks()
    root.connectToggleChecks()
    root.delegateIdentityChecks()
  }

  // ==========================================================================
  // The popover
  // ==========================================================================

  // Everything under the panel, by the objectName the design hangs on it. The
  // panel's rows have no ids reachable from out here either, and the mock
  // names its elements rather than numbering them.
  function panelAll(name) {
    return root.descendants(pop).filter(o => o.objectName === name)
  }

  // `visible` is effective visibility in QML -- it is false for an item inside
  // a hidden parent -- which is exactly what the view switching and the
  // NoState gate are asserted through.
  function panelShown(name) {
    return root.panelAll(name).filter(o => o.visible)
  }

  function panelOne(name) {
    const hits = root.panelAll(name)
    root.check(hits.length === 1, `expected one "${name}" in the panel, found ${hits.length}`)
    return hits[0]
  }

  // A Column, a Row and a ListView all lay out on polish rather than on the
  // binding change that provoked it, so a geometry or a delegate read in the
  // same block is the previous frame's. The shell gets a frame along in a
  // millisecond; this has none.
  //
  // Once per level of nesting, because a child positioner settling changes the
  // implicitHeight its parent is about to lay out against, and these are
  // walked parents first. Two passes was enough until the sub-cards: the exit
  // nodes are now a Column inside a Flickable inside a card's Column inside
  // the panel's Column inside the popover's, and at two passes the panel's
  // height read back as the previous shape's -- which is the trap this helper
  // exists for, arriving one level deeper.
  function layout() {
    for (let pass = 0; pass < 5; ++pass)
      for (const o of root.descendants(pop))
        if (o.forceLayout !== undefined) o.forceLayout()
  }

  // A tailnet trimmed to four devices -- one per group, plus an offline one
  // that carries no IPv6. Already in the order PeerModel sorts them: Mine,
  // Tagged, Others.
  //
  // `workstation` carries the gap this module shipped with: its OS hostname is
  // `localhost` and its DNS label is `workstation`, which is the shape of six
  // of the twenty devices on the tailnet this was measured against. A row
  // bound to hostName names it `localhost` -- a name every second phone on a
  // tailnet also answers to.
  readonly property var tailnetPeers: [
    { hostName: "tango", displayName: "tango",
      ip4: "100.119.215.89", ip6: "fd7a:115c:a1e0::3016:83db",
      dnsName: "tango.example-tailnet.ts.net", online: true, group: 0,
      ownerName: "owner@example.com", nodeId: "nAAA1CNTRL", exitNodeOption: false },
    // No IPv6 at all: the copy menu has to draw that entry dead.
    { hostName: "yankee", displayName: "yankee",
      ip4: "100.81.62.41", ip6: "",
      dnsName: "yankee-with-a-long-magicdns-name.example-tailnet.ts.net", online: false, group: 0,
      ownerName: "owner@example.com", nodeId: "nBBB1CNTRL", exitNodeOption: false },
    { hostName: "pentest-exit-node", displayName: "pentest-exit-node",
      ip4: "100.124.183.145", ip6: "fd7a:115c:a1e0::bff4:b239",
      dnsName: "pentest-exit-node.example-tailnet.ts.net", online: true, group: 1,
      ownerName: "Tagged Devices", nodeId: "nCCC1CNTRL", exitNodeOption: true },
    { hostName: "localhost", displayName: "workstation",
      ip4: "100.70.33.83", ip6: "fd7a:115c:a1e0::9ca4:f8a4",
      dnsName: "workstation.example-tailnet.ts.net", online: true, group: 2,
      ownerName: "Third Example", nodeId: "nDDD1CNTRL", exitNodeOption: false }
  ]

  // clear() + append() is a model RESET, which is the one thing PeerModel
  // never does. It is the right thing for setting a test up, and it is the
  // negative control at the end of the file -- never the way an update is
  // delivered in between.
  function seedPeers(list) {
    Tailscale.peers.clear()
    for (const p of list) Tailscale.peers.append(p)
  }

  // Every Text in a row, not just the ones the panel declares itself. The
  // panel's own bindings carry textFormat where it matters, but a row's TITLE
  // and SUBTITLE are ListRow's Texts, and a check written against the
  // panel's files alone sails straight past them -- which is exactly how
  // daemon-supplied hostnames and other people's display names reached a
  // Text.AutoText that renders <b> and fetches a remote <img src>.
  function everyTextIsPlain(item, what) {
    const texts = root.descendants(item)
      .filter(o => o.text !== undefined && o.textFormat !== undefined)
    root.check(texts.length > 0, `${what} has no Text in it at all`)
    const bad = texts.filter(o => o.textFormat !== Text.PlainText)
    root.check(bad.length === 0,
      `${what} renders ${bad.length} of its ${texts.length} strings through a markup-parsing`
      + ` element: ${bad.map(o => `"${o.text}"`).join(", ")}`)
    return texts.length
  }

  // By displayName, which is what the row is for: a lookup on the OS hostname
  // would find `workstation` under `localhost` and so would pass against a
  // panel that names every device wrong.
  function peerRow(displayName) {
    const hit = root.panelAll("ts-peer").find(o => o.displayName === displayName)
    root.check(hit !== undefined, `no peer row for ${displayName}: the panel has `
      + root.panelAll("ts-peer").map(o => o.displayName).join(", "))
    return hit
  }

  // The row holding a given device, found the way a view has to find it --
  // through the view, by what the model says, not by remembering an index.
  function rowOfNodeId(list, nodeId) {
    for (let i = 0; i < list.count; ++i) {
      const item = list.itemAtIndex(i)
      if (item && item.nodeId === nodeId) return item
    }
    return null
  }

  // Right-click, as far as a test without a compositor can drive it: the
  // signal the row's right-button MouseArea emits, with scene coordinates it
  // maps the same way. The MouseArea itself is asserted separately, so the
  // half this cannot press is still pinned.
  function rightClick(row) {
    const p = row.mapToItem(null, 10, 10)
    row.menuRequested(p.x, p.y)
    root.layout()
  }

  // The resting tailnet, with this machine's identity on it.
  function connectedWithPeers() {
    root.connected()
    Tailscale.selfName = "omega"
    Tailscale.selfIp4 = "100.115.228.122"
    Tailscale.selfIp6 = "fd7a:115c:a1e0::fd27:82d8"
    Tailscale.selfDnsName = "omega.example-tailnet.ts.net"
    Tailscale.tailnet = "example-tailnet.ts.net"
    root.seedPeers(root.tailnetPeers)
    root.layout()
  }

  function panelChecks() {
    root.connectedWithPeers()
    PopoverManager.toggle("tailscale", null)
    root.layout()
    root.check(pop.open === true,
      "the panel did not open when PopoverManager named it, so nothing below is being drawn")

    // -- the gate -----------------------------------------------------------
    // Exactly the rule from TailscaleBackend.h, one layer up from the slot:
    // the snapshot underneath is a healthy tailnet with a blocked exit node
    // and twenty devices, and it is all last-known.
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = false
    Tailscale.exitNodeName = "pentest-exit-node"
    Tailscale.state = Tailscale.NoState
    root.layout()
    root.check(root.panelShown("ts-self-ip4").length === 0,
      "the panel showed this machine's tailnet address with no daemon behind it")
    root.check(root.panelShown("ts-peer").length === 0,
      "the panel listed peers read from a daemon that is gone")
    root.check(root.panelShown("ts-blocked-alert").length === 0,
      "the panel kept alerting about an exit node it can no longer see the state of")
    root.check(root.panelOne("ts-state").text === "no daemon",
      `NoState reads as "${root.panelOne("ts-state").text}"`)

    // -- key expiry ---------------------------------------------------------
    root.connectedWithPeers()
    Tailscale.keyExpiry = null
    root.layout()
    root.check(root.panelShown("ts-expiry").length === 0,
      "a node with no key expiry -- a tagged node, or one with expiry disabled -- still grew an expiry line")

    // 548 days is eighteen average months (18 x 30.436875 = 547.86), which is
    // what the panel measures. Written in days rather than walked across the
    // calendar so the assertion does not depend on which day of the month the
    // test runs.
    Tailscale.keyExpiry = new Date(Date.now() + 548 * 86400000)
    root.layout()
    const expiry = root.panelOne("ts-expiry")
    root.check(expiry.visible && expiry.text === "expires in 18 months",
      `the expiry line reads "${expiry.text}"`)
    // Strings, not Qt.colorEqual: colorEqual answers false against
    // Theme.accentSoft, the one token built with Qt.hsla rather than read from
    // palette.json, and the comparison has to be the same one everywhere.
    root.check(`${expiry.color}` === `${Theme.textDisabled}`,
      "the expiry line is not drawn as disabled text, so it reads as something to act on")

    // -- health -------------------------------------------------------------
    const warning = "Some peers are advertising routes but --accept-routes is false."
    Tailscale.issues = [warning]
    root.layout()
    const issue = root.panelOne("ts-issue")
    root.check(issue.visible && issue.text === warning,
      `the health warning is not on the panel: "${issue.text}"`)
    // tailscaled's own strings about the user's own tailnet. Not a
    // disclosure -- but daemon-supplied text in a StyledText or a RichText is
    // markup injection into our own bar.
    root.check(issue.textFormat === Text.PlainText,
      "a tailscaled health string is bound to a StyledText/RichText element")
    root.check(root.panelOne("ts-issue-count").title === "1 issue detected…",
      `the counted row reads "${root.panelOne("ts-issue-count").title}"`)
    Tailscale.issues = []

    // -- the blocked alert --------------------------------------------------
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = false
    Tailscale.exitNodeName = "pentest-exit-node"
    root.layout()
    const alert = root.panelOne("ts-blocked-alert")
    root.check(alert.visible, "a blocked exit node raised no alert on the panel")
    const alertText = root.panelOne("ts-blocked-text")
    root.check(alertText.text.indexOf("pentest-exit-node") >= 0,
      `the alert does not name the node to clear: "${alertText.text}"`)
    root.check(alertText.textFormat === Text.PlainText,
      "the exit node's name is daemon-supplied and is bound to a markup-parsing element")
    // Above the rows, not somewhere down the panel: it is the reason the
    // person opened it.
    const alertY = alert.mapToItem(pop.panel, 0, 0).y
    const firstRowY = root.panelOne("ts-self-name").mapToItem(pop.panel, 0, 0).y
    root.check(alertY < firstRowY,
      `the alert is drawn at ${alertY}, below the first row at ${firstRowY}`)

    Tailscale.exitNodeActive = false
    Tailscale.exitNodeOnline = false
    Tailscale.exitNodeName = ""
    root.layout()

    // -- the device list ----------------------------------------------------
    root.check(root.panelShown("ts-peer").length === 0,
      "the device list is on the root card; it belongs in a sub-card folded out of it")
    // The `‹` is v1's navigation and is gone with it: a card that keeps its
    // root rows has nothing to go back from, and a chevron that says otherwise
    // is an offer to leave a panel nobody left.
    root.check(root.panelAll("ts-back").length === 0,
      "the panel still carries a back chevron, so it navigates by replacing itself")
    root.panelOne("ts-devices-row").clicked()
    root.layout()

    const rows = root.panelShown("ts-peer")
    root.check(rows.length === 4, `the device list drew ${rows.length} of 4 peers`)

    // The name on a row is the DNS label -- what the admin console, the macOS
    // app and MagicDNS all call the device -- and never the OS hostname under
    // it. `workstation` answers to `localhost`, so a panel bound to hostName
    // draws a row naming no device in particular.
    root.check(rows.every(o => o.title !== "localhost"),
      `a device row is titled by its OS hostname: ${rows.map(o => o.title).join(", ")}`)
    root.check(root.peerRow("workstation").title === "workstation",
      "the device whose DNS label and OS hostname differ is not titled by its label")

    // Sorted by where they actually land, not by the order the view happened
    // to build them in: Mine, Tagged, Others is a visual claim.
    const headings = root.panelShown("ts-section")
      .slice().sort((a, b) => a.mapToItem(pop.panel, 0, 0).y - b.mapToItem(pop.panel, 0, 0).y)
      .map(o => o.text)
    root.check(headings.join(" | ") === "my devices | tagged devices | other users",
      `the device list's sections read: ${headings.join(" | ")}`)

    // Only Other Users needs an owner line; in the other two the owner is the
    // heading.
    root.check(root.peerRow("workstation").subtitle === "Third Example",
      "a peer belonging to another user does not say whose it is")
    root.check(root.peerRow("tango").subtitle === "",
      "a device of your own repeats your own name under it")

    // A group with nobody in it draws no heading at all. Removed through the
    // model, which is how a peer actually leaves.
    Tailscale.peers.remove(3)
    root.layout()
    root.check(root.panelShown("ts-section").length === 2,
      `removing the only Other Users peer left ${root.panelShown("ts-section").length} headings`)
    root.check(!root.panelShown("ts-section").some(o => o.text === "other users"),
      "an empty group kept its heading")
    Tailscale.peers.append(root.tailnetPeers[3])
    root.layout()

    // -- copy ---------------------------------------------------------------
    // Quickshell's clipboard, read straight back. A panel that shelled out to
    // wl-copy would leave this empty -- and would be a new spawn_debt entry in
    // tests/test-native-boundary.sh.
    const arch = root.peerRow("tango")
    Quickshell.clipboardText = ""
    arch.clicked()
    root.check(Quickshell.clipboardText === "100.119.215.89",
      `clicking a peer row put "${Quickshell.clipboardText}" on the clipboard`)
    root.check(arch.copied === true,
      "the row gave no feedback for the copy, and a popover has nowhere else to put it")

    // The markup route the panel does not own. A peer row puts tailscaled's
    // hostname into ListRow's title and another user's free-form display name
    // into its subtitle, and ListRow is shared -- WifiPopover feeds the same
    // two Texts scanned SSIDs, which are whatever the access point next door
    // says they are.
    root.check(root.everyTextIsPlain(arch, "a peer row") >= 3,
      "a peer row draws fewer than three strings, so this check is not reaching ListRow's own")
    root.check(root.peerRow("workstation").subtitle === "Third Example",
      "the owner line is not where this check thinks it is")
    root.everyTextIsPlain(root.peerRow("workstation"), "a peer row with an owner line")
    root.everyTextIsPlain(root.panelOne("ts-self-name"), "the this-device row")

    // The half of the right-click this test cannot press: a RightButton-only
    // MouseArea stacked over the row's own, which is what leaves the left
    // click to the copy above.
    const rightButtons = root.descendants(arch)
      .filter(o => o.acceptedButtons !== undefined && o.acceptedButtons === Qt.RightButton)
    root.check(rightButtons.length === 1,
      `the row carries ${rightButtons.length} right-button hit areas, not 1`)

    const wanted = [["ts-copy-ip4", "100.119.215.89"],
                    ["ts-copy-ip6", "fd7a:115c:a1e0::3016:83db"],
                    ["ts-copy-dns", "tango.example-tailnet.ts.net"]]
    for (const [entryName, value] of wanted) {
      root.rightClick(arch)
      const menu = root.panelOne("ts-copy-menu")
      root.check(menu.visible, "a right-click on a peer row raised no copy menu")
      root.check(menu.displayName === "tango",
        `the menu is headed "${menu.displayName}", which is not the row that was right-clicked`)
      Quickshell.clipboardText = ""
      const entry = root.panelOne(entryName)
      root.check(entry.entryEnabled, `${entryName} is dead on a peer that has that value`)
      entry.activate()
      root.check(Quickshell.clipboardText === value,
        `${entryName} copied "${Quickshell.clipboardText}" instead of "${value}"`)
      root.check(!root.panelOne("ts-copy-menu").visible,
        "the menu stayed up after an entry was taken")
    }

    // The head of the menu names the row too, and it is the DNS label for the
    // same reason the row is: it is what tells two devices sharing an OS
    // hostname apart, which is the whole reason the head is there.
    root.rightClick(root.peerRow("workstation"))
    root.check(root.panelOne("ts-copy-menu").displayName === "workstation",
      `the copy menu is headed "${root.panelOne("ts-copy-menu").displayName}" over a device`
      + ` whose OS hostname is localhost`)
    root.panelOne("ts-copy-menu").close()

    // A peer with no IPv6 -- the offline laptop. The entry stays in place so
    // the other two do not move under the pointer, and it does nothing.
    root.rightClick(root.peerRow("yankee"))
    const dead = root.panelOne("ts-copy-ip6")
    root.check(dead.visible, "the IPv6 entry was hidden rather than disabled, moving the two below it")
    root.check(dead.entryEnabled === false, "a peer with no IPv6 offers a live Copy IPv6 entry")
    const deadLabel = root.descendants(dead).find(o => o.text !== undefined)
    root.check(`${deadLabel.color}` === `${Theme.textDisabled}`,
      "the disabled entry is drawn at full strength, so it reads as something that works")
    Quickshell.clipboardText = "untouched"
    dead.activate()
    root.check(Quickshell.clipboardText === "untouched",
      `a disabled entry copied "${Quickshell.clipboardText}"`)
    root.panelOne("ts-copy-menu").close()

    // -- exit nodes ---------------------------------------------------------
    // Back to the root by hand: the back chevron is a glyph with a MouseArea
    // on it and there is no press to send it here. That it is there, and only
    // on a sub-panel, is asserted above.
    pop.expanded = ""
    root.layout()
    Tailscale.exitNodes.clear()
    // The first one is the cloud instance whose OS hostname is its private
    // address: the exit-node list is named by the DNS label too, and an exit
    // node is the row where naming the wrong machine routes every packet
    // somewhere the person did not pick.
    Tailscale.exitNodes.append({ hostName: "ip-172-31-0-10", displayName: "host-5",
                                 nodeId: "nEEE1CNTRL" })
    Tailscale.exitNodes.append({ hostName: "pentest-exit-node", displayName: "pentest-exit-node",
                                 nodeId: "nCCC1CNTRL" })
    Tailscale.recommendedExitNodeId = "nCCC1CNTRL"
    root.panelOne("ts-exit-row-entry").clicked()
    root.layout()

    const none = root.panelOne("ts-exit-none")
    root.check(none.visible && none.active,
      "`none` is not the checked row, so the panel does not say egress is unrouted")
    const noneCheck = root.descendants(none).find(o => o.tint !== undefined)
    root.check(noneCheck !== undefined && noneCheck.visible,
      "the `none` row carries no check glyph -- radio semantics, not a toggle")

    const recommended = root.panelShown("ts-exit-recommended")
    root.check(recommended.length === 1,
      `${recommended.length} rows under RECOMMENDED; suggest-exit-node names exactly one`)
    root.check(recommended[0].title === "pentest-exit-node",
      `the recommended row is "${recommended[0].title}", not the peer recommendedExitNodeId names`)

    const all = root.panelShown("ts-exit-row")
    root.check(all.length === 2, `the tailnet exit nodes list drew ${all.length} of 2`)
    root.check(all.some(o => o.title === "host-5") && all.every(o => o.title !== "ip-172-31-0-10"),
      `the exit-node list is titled by OS hostname: ${all.map(o => o.title).join(", ")}`)

    // Which row is the one carrying the traffic, joined on the ID. Nothing
    // stops two machines enrolling under one hostname, so the list is given a
    // second row with the SAME hostName as the selected node and a different
    // nodeId: a check mark joined on exitNodeName lights both, which reads as
    // egress leaving by two doors at once.
    Tailscale.exitNodes.append({ hostName: "pentest-exit-node", displayName: "pentest-exit-node",
                                 nodeId: "nFFF1CNTRL" })
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = true
    Tailscale.exitNodeName = "pentest-exit-node"
    Tailscale.exitNodeId = "nCCC1CNTRL"
    root.layout()
    const checkedRows = root.panelShown("ts-exit-row").filter(o => {
      const glyph = root.descendants(o).find(c => c.tint !== undefined)
      return glyph !== undefined && glyph.visible
    })
    root.check(checkedRows.length === 1,
      `${checkedRows.length} of the exit-node rows are checked; one node carries the traffic`)
    root.check(checkedRows[0].nodeId === "nCCC1CNTRL",
      `the check mark is on ${checkedRows[0].nodeId}, not on the node exitNodeId names`)

    // And it goes when egress does, rather than staying on the last node used.
    Tailscale.exitNodeActive = false
    Tailscale.exitNodeId = ""
    Tailscale.exitNodeName = ""
    root.layout()
    root.check(root.panelShown("ts-exit-row").every(o => {
      const glyph = root.descendants(o).find(c => c.tint !== undefined)
      return glyph === undefined || !glyph.visible
    }), "an exit-node row stayed checked with no exit node selected")
    Tailscale.exitNodes.remove(2)
    root.layout()
    // The contract can write, and nothing has been refused, so a row is an
    // offer and is drawn as one. v1 dimmed every row here; the list that
    // explains itself as read-only is the one below, after a refusal.
    root.check(all.every(o => `${o.titleColor}` !== `${Theme.textDisabled}`),
      "an exit node row is drawn dead although no write has been refused")
    root.check(root.panelOne("ts-exit-all-label").text.indexOf("read-only") < 0,
      `the heading calls a writable list read-only: "${root.panelOne("ts-exit-all-label").text}"`)
    root.everyTextIsPlain(all[0], "an exit node row")

    // `none` is the reading of current state, not an offer, so it is the one
    // row here deliberately NOT drawn at Theme.textDisabled.
    root.check(`${none.titleColor}` !== `${Theme.textDisabled}`,
      "the `none` row is dimmed like the unselectable ones, so the panel does not say where egress goes")

    // A recommendation naming a node that is not in the list -- a peer
    // dropped between the status and the suggestion -- must take the heading
    // with it rather than leave a bare one.
    Tailscale.recommendedExitNodeId = "nZZZ1CNTRL"
    root.layout()
    root.check(root.panelShown("ts-exit-recommended").length === 0,
      "a recommendation naming a node outside exitNodes still drew a row")
    root.check(root.panelShown("ts-exit-recommended-label").length === 0,
      "the RECOMMENDED heading stayed up with nothing under it")
    Tailscale.recommendedExitNodeId = "nCCC1CNTRL"
    root.layout()
    root.check(root.panelShown("ts-exit-recommended-label").length === 1,
      "the RECOMMENDED heading did not come back when the recommendation did")
  }

  // ==========================================================================
  // The sub-card folds OUT of the card
  // ==========================================================================
  //
  // v1 replaced the panel's contents and offered a `‹` back. The macOS app
  // grows the sub-panel out of the card instead, and nothing in the earlier
  // section can tell the two apart: a replaced panel draws the same rows, in
  // the same order, with the same objectNames. So every check here is about
  // what stays on screen, what the card's HEIGHT does, and whether a row that
  // was folded away is the same row when it comes back.
  //
  // The height half is not cosmetic. The fold-out is where the popover's
  // height is decided, and the spec names a hundred-device tailnet: 3000px of
  // rows under a 38px bar. The two lists are capped and scroll, which is
  // asserted by growing the tailnet past the cap and reading that the card
  // stopped growing with it.
  function foldOutChecks() {
    root.connectedWithPeers()
    PopoverManager.toggle("tailscale", null)
    pop.expanded = ""
    root.panelOne("ts-peer-search-input").text = ""
    root.layout()

    // The card with nothing folded out of it. Every height assertion below is
    // a comparison against this one reading.
    const shut = pop.panel.height
    const rootRows = ["ts-self-name", "ts-self-ip4", "ts-devices-row", "ts-exit-row-entry"]
    for (const n of rootRows)
      root.check(root.panelOne(n).visible, `${n} is not on the card to begin with`)
    const chevron = root.panelOne("ts-devices-chevron")
    const shutRotation = chevron.rotation

    // -- opening GROWS the card, it does not replace it ---------------------
    root.panelOne("ts-devices-row").clicked()
    root.layout()
    for (const n of rootRows)
      root.check(root.panelOne(n).visible,
        `${n} left the card when the device list opened, so the sub-card replaced it`)
    root.check(root.panelShown("ts-peer").length === 4,
      `the folded-out device list drew ${root.panelShown("ts-peer").length} of 4 peers`)
    root.check(pop.panel.height > shut,
      `the card is ${pop.panel.height}px with the sub-card out and was ${shut}px without it`)
    root.check(chevron.rotation !== shutRotation,
      "the chevron on the row points the same way open as shut, so the row does not say what it does")

    // Folded out of ITS OWN row: between the row that opened it and the next
    // one, not appended to the bottom of the panel.
    const cardY = root.panelOne("ts-devices-card").mapToItem(pop.panel, 0, 0).y
    const devicesRowY = root.panelOne("ts-devices-row").mapToItem(pop.panel, 0, 0).y
    const exitRowY = root.panelOne("ts-exit-row-entry").mapToItem(pop.panel, 0, 0).y
    root.check(cardY > devicesRowY && cardY < exitRowY,
      `the device sub-card is at ${cardY}, outside the ${devicesRowY}..${exitRowY} gap under its own row`)

    // -- the field the keyboard has to reach --------------------------------
    // As far as a test with no compositor reaches: the item the window reports
    // as focused is exactly what PopupSurface hands the bar's keys to
    // (`innerFocus` -> Keys.forwardTo, off PopoverManager.keySink). A field
    // that is not this item cannot receive a keystroke however the Hyprland
    // grab behaves, so this is the half that CAN be pinned.
    const search = root.panelOne("ts-peer-search-input")
    root.check(search.activeFocus,
      "the device search did not take focus as its card folded out, so there is nothing to type into")
    root.check(root.activeFocusItem === search,
      "the device search holds focus but is not what the window reports as focused,"
      + " which is the item the bar forwards keys to")

    // -- closing comes back, and does not reload ----------------------------
    const tango = root.peerRow("tango")
    Quickshell.clipboardText = ""
    tango.clicked()
    root.check(tango.copied, "the row under test never took the local state this check is about")
    root.panelOne("ts-devices-row").clicked()
    root.layout()
    root.check(root.panelShown("ts-peer").length === 0,
      "the device rows stayed on screen after their card was folded away")
    root.check(Math.abs(pop.panel.height - shut) < 1,
      `the card is ${pop.panel.height}px with the sub-card folded away and was ${shut}px before it opened`)
    root.check(chevron.rotation === shutRotation, "the chevron did not turn back")
    root.panelOne("ts-devices-row").clicked()
    root.layout()
    root.check(root.peerRow("tango") === tango,
      "folding the sub-card away and back rebuilt the device rows -- same bug as #124,"
      + " one level out: whatever a row was holding is gone")
    root.check(root.peerRow("tango").copied,
      "the row survived the fold but its own state did not")

    // -- the device search --------------------------------------------------
    // The number on the row is a claim about the list under it. Task 6 left it
    // as the tailnet's own total, which reads as 50 over a list showing one
    // the moment a query is running -- and the row is the only thing on screen
    // that says how many devices the search left standing.
    const deviceCount = root.panelOne("ts-devices-count")
    root.check(deviceCount.text === "4",
      `the device row says "${deviceCount.text}" over an unfiltered list of 4`)

    search.text = "TANGO"
    root.layout()
    const hits = root.panelShown("ts-peer")
    root.check(hits.length === 1 && hits[0].title === "tango",
      `searching "TANGO" left ${hits.length} rows: ${hits.map(o => o.title).join(", ")}`)
    root.check(root.panelShown("ts-peer-no-match").length === 0,
      "a device search that DID match said it matched nothing")
    root.check(deviceCount.text === "1",
      `the device row says "${deviceCount.text}" over a list the query left showing 1 device`)

    // A section whose every row the query hid may not keep its heading -- a
    // heading over nothing reads as a group the search emptied of devices
    // rather than one it filtered out.
    const mine = root.panelShown("ts-section").map(o => o.text)
    root.check(mine.length === 1 && mine[0] === "my devices",
      `a query answered only by one of your own devices left these headings: ${mine.join(" | ")}`)

    // The same from the other end of the list: the heading that has to SURVIVE
    // is the one two emptied sections above it.
    search.text = "workstation"
    root.layout()
    const others = root.panelShown("ts-section").map(o => o.text)
    root.check(others.length === 1 && others[0] === "other users",
      `a query answered only by another user's device left these headings: ${others.join(" | ")}`)

    // The two empty lists a device list has to tell apart, exactly as the
    // exit-node panel tells them apart.
    search.text = "no-device-answers-to-this"
    root.layout()
    root.check(root.panelShown("ts-peer").length === 0, "a query matching no device still drew rows")
    root.check(root.panelShown("ts-section").length === 0,
      "every heading stayed up over a device list the query left empty")
    root.check(root.panelShown("ts-peer-no-match").length === 1,
      "a device query matching nothing said nothing at all")
    root.check(root.panelShown("ts-peer-empty").length === 0,
      "a device query that matched nothing reads as a tailnet with no devices on it")

    search.text = ""
    root.seedPeers([])
    root.layout()
    root.check(root.panelShown("ts-peer-empty").length === 1,
      "a tailnet with no devices on it says nothing about why the list is empty")
    root.check(root.panelShown("ts-peer-no-match").length === 0,
      "an empty tailnet reads as a failed search")
    root.seedPeers(root.tailnetPeers)
    root.layout()
    root.check(root.panelShown("ts-peer").length === 4, "the device list did not come back")
    root.check(deviceCount.text === "4",
      `the device row says "${deviceCount.text}" after the query was cleared over 4 devices`)

    // -- the height the fold-out decides ------------------------------------
    // Twenty-five devices is an ordinary tailnet. The card has to stop growing
    // somewhere, and the list scrolls past that point instead: without it the
    // popover is taller than the screen and there is nothing to scroll.
    root.seedPeers(root.manyPeers(25))
    root.layout()
    const list = root.panelOne("ts-peer-list")
    const at25 = pop.panel.height
    root.check(list.contentHeight > list.height,
      "twenty-five devices did not fill the capped list, so the cap is not being exercised")
    root.check(list.clip, "the capped list does not clip, so its rows draw outside the card")
    root.seedPeers(root.manyPeers(50))
    root.layout()
    root.check(Math.abs(pop.panel.height - at25) < 1,
      `the card grew from ${at25}px to ${pop.panel.height}px when the tailnet went from 25 devices to 50`)

    // A heading is hidden off a count of the delegates the VIEW built, and a
    // view builds only what is near its viewport. The case that would break
    // that is a single match in the LAST group of a long list -- which is this
    // one: filtered rows collapse to zero height, so the whole model lands
    // inside the viewport and every row is counted.
    search.text = "node-49"
    root.layout()
    const far = root.panelShown("ts-peer")
    root.check(far.length === 1 && far[0].title === "node-49",
      `a query answered by the last device of fifty left ${far.length} rows`)
    const farSections = root.panelShown("ts-section").map(o => o.text)
    root.check(farSections.length === 1 && farSections[0] === "other users",
      `the last group of a long filtered list left these headings: ${farSections.join(" | ")}`)

    search.text = ""
    root.seedPeers(root.tailnetPeers)
    root.layout()

    // -- the exit sub-card ---------------------------------------------------
    root.panelOne("ts-exit-row-entry").clicked()
    root.layout()
    root.check(root.panelOne("ts-self-name").visible,
      "the exit sub-card replaced the card instead of folding out of it")
    root.check(root.panelShown("ts-peer").length === 0,
      "opening the exit nodes left the device sub-card folded out as well")
    const exitSearch = root.panelOne("ts-exit-search-input")
    root.check(exitSearch.activeFocus && root.activeFocusItem === exitSearch,
      "the exit-node search did not take focus as its card folded out")

    // Same cap, same reason: a tailnet can offer more exit nodes than a
    // popover has room for, and Task 5 shipped this list uncapped.
    Tailscale.exitNodes.clear()
    Tailscale.recommendedExitNodeId = ""
    for (let i = 0; i < 20; ++i)
      Tailscale.exitNodes.append({ hostName: `exit-${i}`, displayName: `exit-${i}`,
                                   nodeId: `nE${i}CNTRL` })
    root.layout()
    const scroll = root.panelOne("ts-exit-scroll")
    const exitAt20 = pop.panel.height
    root.check(scroll.contentHeight > scroll.height,
      "twenty exit nodes did not fill the capped list, so the cap is not being exercised")
    root.check(scroll.clip, "the capped exit list does not clip, so its rows draw outside the card")
    for (let i = 20; i < 40; ++i)
      Tailscale.exitNodes.append({ hostName: `exit-${i}`, displayName: `exit-${i}`,
                                   nodeId: `nE${i}CNTRL` })
    root.layout()
    root.check(Math.abs(pop.panel.height - exitAt20) < 1,
      `the card grew from ${exitAt20}px to ${pop.panel.height}px when the tailnet went`
      + ` from 20 exit nodes to 40`)

    // The search field stays put while the nodes under it scroll: a filter you
    // have to scroll back up to reach is not a filter.
    const searchY = root.panelOne("ts-exit-search").mapToItem(pop.panel, 0, 0).y
    root.check(searchY < scroll.mapToItem(pop.panel, 0, 0).y,
      "the exit-node search scrolls away with the list it filters")

    Tailscale.exitNodes.clear()
    pop.expanded = ""
    root.layout()
  }

  // A tailnet of `n` devices, all but the last of them your own: the last one
  // is in Other Users, which is the group a long filtered list is most likely
  // to lose the heading of.
  function manyPeers(n) {
    const out = []
    for (let i = 0; i < n; ++i)
      out.push({ hostName: `node-${i}`, displayName: `node-${i}`,
                 ip4: `100.64.1.${i}`, ip6: "",
                 dnsName: `node-${i}.example-tailnet.ts.net`, online: true,
                 group: i === n - 1 ? 2 : 0, ownerName: "Third Example",
                 nodeId: `n${i}0CNTRL`, exitNodeOption: false })
    return out
  }

  // ==========================================================================
  // The exit-node view as a CONTROL
  // ==========================================================================
  //
  // v1 drew this list and could not act on it. The contract can write now, so
  // every row here is an offer -- and the one thing that cannot be read off a
  // screenshot is whether pressing it asks tailscaled for the node that row
  // names. The stub reports each action through `called`, so every check below
  // is on the recorded request and never on the control looking alive.
  //
  // The gate is `writable`, read the way TailscaleBackend.h spells it out: it
  // starts TRUE and goes false only once a write has been refused. So the
  // panel opens live, and "disabled when !writable" means disabled AFTER a
  // refusal -- the opposite reading would open every control dead on a machine
  // where writing works perfectly, with no way left to make the first write.
  function exitNodeControlChecks() {
    root.connected()
    Tailscale.writable = true
    Tailscale.writeError = ""
    Tailscale.exitNodeActive = false
    Tailscale.exitNodeId = ""
    Tailscale.exitNodeName = ""
    root.seedExitNodes()
    pop.expanded = "exit"
    root.layout()

    // -- live before the first write ----------------------------------------
    const rows = root.panelShown("ts-exit-row")
    root.check(rows.length === 3, `the exit list drew ${rows.length} of 3 rows`)
    root.check(rows.every(o => `${o.titleColor}` !== `${Theme.textDisabled}`),
      "the exit-node rows opened disabled with nothing refused yet: `writable` is a claim"
      + " about the last attempt, not permission to make the first")
    root.check(rows.every(o => o.hoverable),
      "a selectable row does not light up under the pointer, so it reads as dead")
    root.check(root.panelShown("ts-exit-write-error").length === 0,
      "the panel explained a refusal that has not happened")

    // -- a row asks for ITS OWN node, by id ---------------------------------
    // The list carries two rows under one display name, as a tailnet may:
    // nothing stops two machines enrolling under the same hostname. A click
    // joined on the name would send either one of them.
    root.tookCalls()
    const twin = rows.find(o => o.nodeId === "nFFF1CNTRL")
    root.check(twin !== undefined,
      "no row for the second node sharing a hostname, so the id check below proves nothing")
    twin.clicked()
    root.check(root.tookCalls() === "setExitNode(nFFF1CNTRL)",
      "clicking an exit-node row did not ask for that row's own node id")

    // The click is a REQUEST: nothing moves on the contract until the daemon
    // says so, and the panel must not draw it as selected on its own.
    root.layout()
    root.check(root.panelShown("ts-exit-row").every(o => {
      const glyph = root.descendants(o).find(c => c.tint !== undefined)
      return glyph === undefined || !glyph.visible
    }), "a row checked itself on the click rather than on what the daemon then reported")

    // -- `none` clears it ---------------------------------------------------
    root.panelOne("ts-exit-none").clicked()
    root.check(root.tookCalls() === "setExitNode()",
      "the `none` row does not ask for an empty node id, which is how egress is unrouted")

    // -- the recommended row is a control too -------------------------------
    const suggested = root.panelShown("ts-exit-recommended")
    root.check(suggested.length === 1, `${suggested.length} rows under RECOMMENDED`)
    suggested[0].clicked()
    root.check(root.tookCalls() === "setExitNode(nCCC1CNTRL)",
      "the recommended row does not ask for the node suggest-exit-node named")

    // -- allow local network access -----------------------------------------
    // The control that matters when an exit node is blackholing the LAN: with
    // it off, a node that stops answering takes the printer and the router's
    // own web UI with it.
    //
    // IT READS ITSELF BACK OFF THE CONTRACT, which it could not until the
    // three read-back properties existed. With only the action under it the
    // switch drew what was last clicked on it IN THIS SESSION: it opened off
    // on a machine where LAN access was already on, a change made with
    // `tailscale set` elsewhere never reached it, and a refused write could
    // not spring it back because there was nothing for it to spring back to.
    Tailscale.exitNodeAllowLANAccess = true
    root.layout()
    const lan = root.panelOne("ts-exit-lan")
    const lanSwitch = root.panelOne("ts-exit-lan-switch")
    root.check(lanSwitch.checked,
      "the panel opened on a machine where LAN access is already on and drew the switch off:"
      + " it is showing what was last clicked here, not what tailscaled holds")

    root.tookCalls()
    lan.clicked()
    root.check(root.tookCalls() === "setExitNodeAllowLANAccess(false)",
      "the LAN row does not ask for the opposite of the value tailscaled currently holds")

    // The click ASKED. An action moves nothing on the contract, so a switch
    // that moved here is drawing its own click as a fact -- and a refused
    // write looks exactly like an accepted one from then on.
    root.layout()
    root.check(lanSwitch.checked,
      "the switch moved on the click rather than on what the daemon then reported,"
      + " so a write tailscaled refuses leaves it showing the wrong value")

    // The daemon answering is what moves it. tailscaled took this one.
    Tailscale.exitNodeAllowLANAccess = false
    root.layout()
    root.check(!lanSwitch.checked, "the switch did not follow the daemon's own notification")

    // And the other direction, which is the refusal: the panel asks for `true`
    // and tailscaled keeps it off. The switch has to stay off.
    lan.clicked()
    root.check(root.tookCalls() === "setExitNodeAllowLANAccess(true)",
      "the LAN control asks for the same value twice, so it is not a switch")
    root.layout()
    root.check(!lanSwitch.checked,
      "a write the daemon never confirmed left the switch showing the value it asked for")

    // -- use this device as an exit node… -----------------------------------
    // The contract has no action for advertising this machine as an exit node
    // -- the five it publishes are WantRunning, ExitNodeID,
    // ExitNodeAllowLANAccess, RouteAll and CorpDNS. The row the mock drew is
    // kept, drawn dead and saying why, rather than wired to nothing.
    const advertise = root.panelOne("ts-exit-advertise")
    root.check(advertise.visible, "the row the mock drew for this is simply gone")
    root.check(`${advertise.titleColor}` === `${Theme.textDisabled}`,
      "the row offers an action the contract has none for")
    root.check(advertise.subtitle !== "", "a dead row with no reason on it")
    advertise.clicked()
    root.check(root.tookCalls() === "",
      "the advertise row asked the contract for something")

    // -- search -------------------------------------------------------------
    const search = root.panelOne("ts-exit-search-input")
    search.text = "HOST"
    root.layout()
    const hits = root.panelShown("ts-exit-row")
    root.check(hits.length === 1 && hits[0].title === "host-5",
      `searching "HOST" left ${hits.length} rows: ${hits.map(o => o.title).join(", ")}`)
    root.check(root.panelShown("ts-exit-recommended").length === 0,
      "the recommended row ignored the search, so a filtered list still shows a node twice")
    root.check(root.panelShown("ts-exit-no-match").length === 0,
      "a search that DID match said it matched nothing")
    root.check(root.panelOne("ts-exit-none").visible,
      "`none` was filtered away: it is the reading of current state, not a search result")

    // A query nobody answers to. The distinction this makes is the whole
    // point: an empty list that reads as an empty tailnet is a panel that
    // looks broken.
    search.text = "no-node-answers-to-this"
    root.layout()
    root.check(root.panelShown("ts-exit-row").length === 0,
      "a query matching nothing still drew rows")
    const noMatch = root.panelShown("ts-exit-no-match")
    root.check(noMatch.length === 1, "a query matching nothing said nothing at all")
    root.check(noMatch[0].title === "no matches",
      `an unmatched query reads "${noMatch[0].title}"`)
    root.check(root.panelShown("ts-exit-empty").length === 0,
      "a query that matched nothing reads as a tailnet with no exit nodes on it")

    search.text = ""
    root.layout()
    root.check(root.panelShown("ts-exit-row").length === 3,
      "clearing the search did not bring the list back")
    root.check(root.panelShown("ts-exit-no-match").length === 0,
      "the no-match row stayed up over a list with rows in it")

    // The other half of the same distinction: a tailnet with no exit nodes
    // offers none, and says THAT rather than "no matches".
    Tailscale.exitNodes.clear()
    root.layout()
    root.check(root.panelShown("ts-exit-empty").length === 1,
      "a tailnet with no exit nodes on it says nothing about why the list is empty")
    root.check(root.panelShown("ts-exit-no-match").length === 0,
      "an empty tailnet reads as a failed search")
    root.seedExitNodes()
    root.layout()
    root.check(root.panelShown("ts-exit-row").length === 3,
      "the list did not come back when the exit nodes did")

    // -- after a refusal, and only after one --------------------------------
    // 403 "prefs write access denied" is what an un-bootstrapped machine
    // answers every write with. The panel may not pretend that took.
    const refusal = "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden"
    Tailscale.writable = false
    Tailscale.writeError = refusal
    root.layout()

    const why = root.panelShown("ts-exit-write-error")
    root.check(why.length === 1, "a refused write left the panel silent")
    root.check(why[0].text.indexOf(refusal) >= 0,
      `the explanation does not carry what refused it: "${why[0].text}"`)
    root.check(why[0].textFormat === Text.PlainText,
      "the refusal is daemon-supplied text in a markup-parsing element")
    root.check(root.panelOne("ts-exit-all-label").text.indexOf("read-only") >= 0,
      `a list that cannot be written reads "${root.panelOne("ts-exit-all-label").text}"`)

    const dead = root.panelShown("ts-exit-row")
    root.check(dead.length === 3, `${dead.length} rows after a refusal`)
    root.check(dead.every(o => `${o.titleColor}` === `${Theme.textDisabled}`),
      "a row kept its live colour after tailscaled refused to change anything")
    root.check(dead.every(o => !o.hoverable),
      "a dead row still lights up under the pointer, which is a promise")
    root.check(root.panelOne("ts-exit-lan-switch").enabled === false,
      "the LAN switch is still live after a refusal")

    root.tookCalls()
    dead[0].clicked()
    root.panelOne("ts-exit-none").clicked()
    root.panelOne("ts-exit-lan").clicked()
    root.check(root.tookCalls() === "",
      "a control disabled after a refusal still asked tailscaled to change something")

    // And back. `writable` follows the LAST attempt rather than latching, so
    // an operator named while the panel is open brings the controls back.
    Tailscale.writable = true
    Tailscale.writeError = ""
    root.layout()
    root.check(root.panelShown("ts-exit-write-error").length === 0,
      "the refusal is still explained after a write was accepted")
    root.panelShown("ts-exit-row")[0].clicked()
    root.check(root.tookCalls() !== "",
      "the controls stayed dead after `writable` came back, so the flag latched")

    // Every row the controls added, not only the node rows the earlier section
    // covers: all of them put their strings through ListRow's two Texts, which
    // default to Text.AutoText and would fetch a remote <img src>.
    root.everyTextIsPlain(root.panelOne("ts-exit-lan"), "the LAN access row")
    root.everyTextIsPlain(root.panelOne("ts-exit-advertise"), "the advertise row")
    root.everyTextIsPlain(root.panelOne("ts-exit-no-match"), "the no-match row")
  }

  // ==========================================================================
  // The settings sub-card
  // ==========================================================================
  //
  // Two more prefs of the same shape as the LAN switch -- an action to ask
  // with, a property to read back from -- and `accept routes` closes a loop
  // this module has carried since v1.
  //
  // RouteAll: false is the pref behind the one health warning the backend
  // SUPPRESSES (LocalApiTailscaleBackend::suppressedHealth: "advertising
  // routes but --accept-routes is false"). Surfaced naively it is an issue
  // that never clears on a machine that deliberately does not accept routes,
  // so the panel would warn forever about a setting someone chose; dropped
  // with nothing said, it is a hidden special case and the issue list is
  // quietly not the whole of what tailscaled reported. Said beside the switch
  // that changes it, it is an explanation -- which is the only reading of the
  // suppression that is honest, and is why the explanation is asserted here
  // rather than treated as decoration.
  function settingsChecks() {
    root.connectedWithPeers()
    PopoverManager.toggle("tailscale", null)
    Tailscale.writable = true
    Tailscale.writeError = ""
    Tailscale.acceptRoutes = false
    Tailscale.acceptDns = false
    pop.expanded = ""
    root.layout()

    root.check(root.panelShown("ts-settings-routes").length === 0,
      "the settings rows are on the root card; they belong in a sub-card folded out of it")

    const shut = pop.panel.height
    const settingsRow = root.panelOne("ts-settings-row")
    const chevron = root.panelOne("ts-settings-chevron")
    const shutRotation = chevron.rotation
    settingsRow.clicked()
    root.layout()

    // Folded out of its own row, like the other two: the root rows stay, the
    // card grows, and the card lands under the row that opened it.
    root.check(root.panelOne("ts-self-name").visible,
      "the settings sub-card replaced the card instead of folding out of it")
    root.check(root.panelShown("ts-peer").length === 0,
      "opening settings left the device sub-card folded out as well")
    root.check(pop.panel.height > shut,
      `the card is ${pop.panel.height}px with the settings card out and was ${shut}px without it`)
    root.check(chevron.rotation !== shutRotation,
      "the chevron on the settings row points the same way open as shut")
    const cardY = root.panelOne("ts-settings-card").mapToItem(pop.panel, 0, 0).y
    root.check(cardY > settingsRow.mapToItem(pop.panel, 0, 0).y,
      `the settings sub-card is at ${cardY}, above the row that opens it`)

    // -- accept routes ------------------------------------------------------
    const routesRow = root.panelOne("ts-settings-routes")
    const routesSwitch = root.panelOne("ts-settings-routes-switch")
    root.check(routesSwitch.enabled && routesRow.hoverable,
      "the settings switches opened disabled with nothing refused yet: `writable` is a claim"
      + " about the last attempt, not permission to make the first")
    root.check(!routesSwitch.checked,
      "the accept-routes switch does not read itself back off the contract")

    root.tookCalls()
    routesRow.clicked()
    root.check(root.tookCalls() === "setAcceptRoutes(true)",
      "the accept-routes row does not ask for the opposite of what tailscaled holds")
    root.layout()
    root.check(!routesSwitch.checked,
      "the accept-routes switch drew its own click as a fact, so a refused write would leave it"
      + " showing a setting the machine does not have")
    Tailscale.acceptRoutes = true
    root.layout()
    root.check(routesSwitch.checked,
      "the accept-routes switch did not follow the daemon's own notification")
    routesRow.clicked()
    root.check(root.tookCalls() === "setAcceptRoutes(false)",
      "the accept-routes control asks for the same value twice, so it is not a switch")

    // -- why the route warning is not in the issue list ---------------------
    // With RouteAll off, tailscaled raises its standing --accept-routes
    // warning and this module drops it. Both halves are asserted: the issue
    // list is empty, and the panel still says what is being hidden.
    Tailscale.acceptRoutes = false
    Tailscale.issues = []
    root.layout()
    root.check(root.panelShown("ts-issue").length === 0,
      "this check needs an empty issue list to mean anything and the list is not empty")
    const why = root.panelShown("ts-settings-routes-why")
    root.check(why.length === 1,
      "the warning this module suppresses is suppressed with nothing said about it, so the"
      + " issue list is quietly not the whole of what tailscaled reported")
    root.check(why[0].text.toLowerCase().indexOf("route") >= 0,
      `the explanation beside accept routes does not mention routes: "${why[0].text}"`)
    root.check(why[0].textFormat === Text.PlainText,
      "the suppression explanation is in a markup-parsing element")
    root.check(why[0].mapToItem(pop.panel, 0, 0).y > routesRow.mapToItem(pop.panel, 0, 0).y,
      "the explanation is not beside the control it explains")

    // On a machine that DOES accept routes tailscaled raises no such warning,
    // so there is nothing suppressed and nothing to explain.
    Tailscale.acceptRoutes = true
    root.layout()
    root.check(root.panelShown("ts-settings-routes-why").length === 0,
      "the panel explains a suppressed warning on a machine where tailscaled raises none")
    Tailscale.acceptRoutes = false
    root.layout()

    // -- accept dns ---------------------------------------------------------
    const dnsRow = root.panelOne("ts-settings-dns")
    const dnsSwitch = root.panelOne("ts-settings-dns-switch")
    Tailscale.acceptDns = true
    root.layout()
    root.check(dnsSwitch.checked,
      "the accept-dns switch does not read itself back off the contract: it opened off on a"
      + " machine using the tailnet's DNS")
    root.tookCalls()
    dnsRow.clicked()
    root.check(root.tookCalls() === "setAcceptDns(false)",
      "the accept-dns row does not ask for the opposite of what tailscaled holds")
    root.layout()
    root.check(dnsSwitch.checked, "the accept-dns switch moved on the click rather than on the bus")
    Tailscale.acceptDns = false
    root.layout()
    root.check(!dnsSwitch.checked, "the accept-dns switch did not follow the daemon")

    // -- after a refusal, and only after one --------------------------------
    const refusal = "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden"
    Tailscale.writable = false
    Tailscale.writeError = refusal
    root.layout()
    const explained = root.panelShown("ts-settings-write-error")
    root.check(explained.length === 1, "a refused write left the settings card silent")
    root.check(explained[0].text.indexOf(refusal) >= 0,
      `the explanation does not carry what refused it: "${explained[0].text}"`)
    root.check(explained[0].textFormat === Text.PlainText,
      "the refusal is daemon-supplied text in a markup-parsing element")
    root.check(!routesSwitch.enabled && !dnsSwitch.enabled,
      "a settings switch is still live after tailscaled refused to change anything")
    root.check(`${routesRow.titleColor}` === `${Theme.textDisabled}`
      && `${dnsRow.titleColor}` === `${Theme.textDisabled}`,
      "a settings row kept its live colour after a refusal")
    root.check(!routesRow.hoverable && !dnsRow.hoverable,
      "a dead settings row still lights up under the pointer, which is a promise")

    root.tookCalls()
    routesRow.clicked()
    dnsRow.clicked()
    root.check(root.tookCalls() === "",
      "a settings control disabled after a refusal still asked tailscaled to change something")

    // The suppressed-warning explanation is not an offer and does not go with
    // the controls: it says why the issue list is short, which is true however
    // dead the switch above it is.
    root.check(root.panelShown("ts-settings-routes-why").length === 1,
      "the explanation of the suppressed warning went away with the controls")

    // And back: `writable` follows the LAST attempt rather than latching.
    Tailscale.writable = true
    Tailscale.writeError = ""
    root.layout()
    root.check(root.panelShown("ts-settings-write-error").length === 0,
      "the refusal is still explained after a write was accepted")
    routesRow.clicked()
    root.check(root.tookCalls() !== "",
      "the settings controls stayed dead after `writable` came back, so the flag latched")

    root.everyTextIsPlain(routesRow, "the accept routes row")
    root.everyTextIsPlain(dnsRow, "the accept dns row")

    // The row that opened the card closes it, as the other two do.
    settingsRow.clicked()
    root.layout()
    root.check(root.panelShown("ts-settings-routes").length === 0,
      "the settings rows stayed on screen after their card was folded away")
    root.check(chevron.rotation === shutRotation, "the settings chevron did not turn back")
    root.check(Math.abs(pop.panel.height - shut) < 1,
      `the card is ${pop.panel.height}px with the settings card folded away and was ${shut}px`
      + ` before it opened`)
  }

  // The tailnet's exit nodes, twice over the same display name: `host-5` is
  // the cloud instance whose OS hostname is its own private address, and the
  // two `pentest-exit-node` rows are the pair nothing on a tailnet prevents.
  function seedExitNodes() {
    Tailscale.exitNodes.clear()
    Tailscale.exitNodes.append({ hostName: "ip-172-31-0-10", displayName: "host-5",
                                 nodeId: "nEEE1CNTRL" })
    Tailscale.exitNodes.append({ hostName: "pentest-exit-node", displayName: "pentest-exit-node",
                                 nodeId: "nCCC1CNTRL" })
    Tailscale.exitNodes.append({ hostName: "pentest-exit-node", displayName: "pentest-exit-node",
                                 nodeId: "nFFF1CNTRL" })
    Tailscale.recommendedExitNodeId = "nCCC1CNTRL"
  }

  // ==========================================================================
  // The connect toggle
  // ==========================================================================
  //
  // prefs.WantRunning, and the one control the v2 spec's table promised that
  // no task in the plan ever claimed. It shipped `enabled: false` under a
  // tooltip saying the panel could not write -- true in v1, and untrue from
  // the moment the contract grew actions. A control that is permanently dead
  // is indistinguishable from one whose write is being refused, which is the
  // distinction this whole module is built around.
  //
  // Same shape as the other three switches: bound to what tailscaled holds,
  // asking for the opposite, settled by the bus. The toggle is driven through
  // `toggled()` directly, which bypasses TogglePill's own `enabled` gate and
  // reaches the handler -- so a handler relying on `enabled` alone fails here,
  // exactly as the ListRow checks drive `clicked()` past `hoverable`.
  function connectToggleChecks() {
    root.connected()
    Tailscale.writable = true
    Tailscale.writeError = ""
    Tailscale.wantRunning = true
    PopoverManager.toggle("tailscale", null)
    root.layout()

    const toggle = root.panelOne("ts-connect-toggle")
    root.check(toggle.enabled,
      "the connect toggle opened disabled with nothing refused yet -- which is how it shipped,"
      + " and is indistinguishable from a control whose write tailscaled is refusing")
    root.check(toggle.checked,
      "the connect toggle does not read WantRunning back off the contract")

    // WantRunning, NOT `state`. They are different questions, and the panel
    // has `state` on screen already as the header's subtitle. A machine that
    // is Starting, or NeedsLogin with WantRunning true, is one tailscale is
    // MEANT to be up on -- a toggle drawn off `state` there says the daemon
    // was told to stop, which it was not, and clicking it would then ask for
    // the value it already holds.
    Tailscale.state = Tailscale.Starting
    root.layout()
    root.check(toggle.checked,
      "the toggle went off while tailscaled was still coming up, so it is drawing what the"
      + " daemon is DOING rather than what it was told to do")
    Tailscale.state = Tailscale.NeedsLogin
    root.layout()
    root.check(toggle.checked,
      "the toggle went off on a logged-out machine that is meant to be on the tailnet")
    root.connected()
    root.layout()

    // -- the request, and the bus settling it -------------------------------
    root.tookCalls()
    toggle.toggled()
    root.check(root.tookCalls() === "setWantRunning(false)",
      "the connect toggle does not ask for the opposite of what tailscaled holds")
    root.layout()
    root.check(toggle.checked,
      "the toggle moved on its own click rather than on what the daemon then reported, so a"
      + " refused `tailscale down` would leave the panel saying the tailnet is off")
    Tailscale.wantRunning = false
    root.layout()
    root.check(!toggle.checked, "the toggle did not follow the daemon's own notification")
    toggle.toggled()
    root.check(root.tookCalls() === "setWantRunning(true)",
      "the connect toggle asks for the same value twice, so it is not a toggle")

    // -- no daemon, nothing to ask ------------------------------------------
    // TailscaleBackend.h: NoState KEEPS the last snapshot, so WantRunning is
    // then a value from a daemon that is not there. Every other row on this
    // panel is gated on that and this one has to be too -- it would otherwise
    // be offering to write to nothing, over a header that says "no daemon".
    Tailscale.wantRunning = true
    Tailscale.state = Tailscale.NoState
    root.layout()
    root.check(!toggle.enabled,
      "the toggle still offers to connect a machine whose tailscaled is not answering")
    root.tookCalls()
    toggle.toggled()
    root.check(root.tookCalls() === "",
      "a toggle over a daemon that is gone still asked tailscaled to change something")
    root.connected()
    Tailscale.wantRunning = true
    root.layout()
    root.check(toggle.enabled && toggle.checked,
      "the toggle did not come back when the daemon did")

    // -- after a refusal, and only after one --------------------------------
    const refusal = "/localapi/v0/prefs answered HTTP/1.1 403 Forbidden"
    Tailscale.writable = false
    Tailscale.writeError = refusal
    root.layout()
    root.check(!toggle.enabled, "the connect toggle is still live after a refusal")
    root.tookCalls()
    toggle.toggled()
    root.check(root.tookCalls() === "",
      "a toggle disabled after a refusal still asked tailscaled to change something")

    // The reason, where this control has always put its explanation: under
    // the pointer. The root card carries no inline refusal line -- the two
    // sub-cards each carry their own, and a third would mean two of them on
    // screen at once whenever a card is folded out.
    const tip = root.panelOne("ts-connect-tip")
    root.check(tip.text.indexOf(refusal) >= 0,
      `a refused connect toggle does not say what refused it: "${tip.text}"`)
    root.check(tip.textFormat === Text.PlainText,
      "the refusal is daemon-supplied text in a markup-parsing element")

    // And back: `writable` follows the LAST attempt rather than latching.
    Tailscale.writable = true
    Tailscale.writeError = ""
    root.layout()
    root.check(toggle.enabled,
      "the toggle stayed dead after `writable` came back, so the flag latched")
    root.check(tip.text.indexOf(refusal) < 0,
      "the toggle still explains a refusal after a write was accepted")

    // A live toggle says what it DOES, and on this one that is worth a
    // sentence: WantRunning: false is `tailscale down`, which on a machine
    // reached over the tailnet ends the session doing the clicking. A
    // confirmation dialog was considered and rejected -- see TailscalePopover
    // -- so this sentence is the whole of the warning and may not be empty.
    root.check(tip.text !== "",
      "a live connect toggle says nothing about what it does, and what it does is drop the"
      + " tailnet this machine may be reached over")
    root.tookCalls()
    toggle.toggled()
    root.check(root.tookCalls() !== "",
      "the toggle recorded no request once `writable` came back")
  }

  // ==========================================================================
  // What PeerModel is for, against a real ListView
  // ==========================================================================
  //
  // Six tasks have proved at the C++ signal level that PeerModel updates rows
  // in place -- dataChanged and rowsMoved, never a reset, never a remove and
  // re-insert (plugin/lib/tailscale/tests/tst_peermodel.cpp). Nothing has ever
  // shown a QML delegate SURVIVING those signals, which is the half the claim
  // is actually about: #124 was a row rebuilt under a half-typed password.
  //
  // So: a real ListView, a real delegate with state that exists only on that
  // one instance, the update driven through the model, and the same delegate
  // object asked for afterwards. The model here is a ListModel rather than a
  // PeerModel -- the stub cannot be a QAbstractListModel written in C++ -- but
  // both are QAbstractListModels and setProperty/move emit exactly the
  // dataChanged/rowsMoved the C++ tests pin PeerModel to. What the ListModel
  // adds is that this test can send them deliberately, and can send the reset
  // PeerModel never sends, which is the control at the bottom.
  function delegateIdentityChecks() {
    // Three devices, one group: every row on screen, no heading moving under
    // the assertions, nothing scrolled out and freed for reasons unrelated to
    // the model.
    const three = [
      { hostName: "alpha", displayName: "alpha", ip4: "100.64.0.1", ip6: "fd7a:115c:a1e0::1",
        dnsName: "alpha.example-tailnet.ts.net", online: true, group: 0,
        ownerName: "owner@example.com", nodeId: "nAAA1CNTRL", exitNodeOption: false },
      { hostName: "bravo", displayName: "bravo", ip4: "100.64.0.2", ip6: "fd7a:115c:a1e0::2",
        dnsName: "bravo.example-tailnet.ts.net", online: true, group: 0,
        ownerName: "owner@example.com", nodeId: "nBBB1CNTRL", exitNodeOption: false },
      { hostName: "gamma", displayName: "gamma", ip4: "100.64.0.3", ip6: "fd7a:115c:a1e0::3",
        dnsName: "gamma.example-tailnet.ts.net", online: true, group: 0,
        ownerName: "owner@example.com", nodeId: "nCCC1CNTRL", exitNodeOption: false }
    ]
    root.connected()
    root.seedPeers(three)
    pop.expanded = "devices"
    root.layout()

    const list = root.panelOne("ts-peer-list")
    root.check(list.count === 3, `the view has ${list.count} rows, not 3`)
    root.check(list.itemAtIndex(0) !== null,
      "the ListView built no delegates at all, so nothing below could fail")

    const target = root.rowOfNodeId(list, "nBBB1CNTRL")
    root.check(target !== null, "no delegate for bravo")

    // State that lives on this delegate and nowhere else: the model does not
    // know about it, so a rebuilt row cannot get it back. In #124 this was
    // the password being typed into the row.
    Quickshell.clipboardText = ""
    target.clicked()
    root.check(target.copied === true, "the delegate did not take the local state")
    root.check(Quickshell.clipboardText === "100.64.0.2",
      "the row that was clicked is not the row that copied")

    // The update tailscaled delivers when alpha goes offline: its data changes
    // and it sorts below the devices still up. A dataChanged and a rowsMoved
    // -- which is what PeerModel emits, asserted in
    // plugin/lib/tailscale/tests/tst_peermodel.cpp -- plus a second row's
    // address changing underneath, so the surviving row is not simply the only
    // thing that happened.
    Tailscale.peers.setProperty(0, "online", false)
    Tailscale.peers.move(0, 2, 1)
    // The rows are now bravo, gamma, alpha -- so this changes GAMMA, a row
    // neither moved nor under test, which is what makes the update more than
    // the one row being watched.
    Tailscale.peers.setProperty(1, "ip4", "100.64.0.9")
    root.layout()

    root.check(list.count === 3, `the update changed the row count to ${list.count}`)
    const after = root.rowOfNodeId(list, "nBBB1CNTRL")
    root.check(after !== null, "bravo is gone from the view entirely after an in-place update")
    root.check(after === target,
      "the ListView handed back a DIFFERENT delegate for a row the model only moved around it"
      + " -- which is #124: whatever that row was holding is gone")
    root.check(after.copied === true,
      "the delegate object survived but its local state did not, which is the same bug one level in")
    // The update did land -- otherwise "nothing changed" would pass the check
    // above for the wrong reason.
    root.check(root.rowOfNodeId(list, "nAAA1CNTRL").online === false,
      "the moved row did not carry its update with it, so the model never actually changed")
    root.check(list.itemAtIndex(2).nodeId === "nAAA1CNTRL" && list.itemAtIndex(0).nodeId === "nBBB1CNTRL",
      "the rows did not reorder, so nothing was asked of the view")
    root.check(root.rowOfNodeId(list, "nCCC1CNTRL").ip4 === "100.64.0.9" && after.ip4 === "100.64.0.2",
      "a row that was NOT the one under test did not take its own update")

    // The other two verbs PeerModel has. peermodel.cpp inserts and removes
    // rows rather than resetting (tst_peermodel's insertsANewPeerInPlace and
    // insertsAndRemovesRatherThanResetting), and a peer joining or leaving the
    // tailnet while someone is reading a row is the ordinary case, not a
    // corner: a device waking up is one rowsInserted on a list the panel is
    // already showing.
    Tailscale.peers.insert(0, { hostName: "delta", displayName: "delta", ip4: "100.64.0.4",
      ip6: "fd7a:115c:a1e0::4", dnsName: "delta.example-tailnet.ts.net", online: true,
      group: 0, ownerName: "owner@example.com", nodeId: "nDDD1CNTRL",
      exitNodeOption: false })
    root.layout()
    root.check(list.count === 4, `the insert left ${list.count} rows`)
    root.check(root.rowOfNodeId(list, "nBBB1CNTRL") === target,
      "a peer joining the tailnet rebuilt the row someone was already reading")
    root.check(target.copied === true, "the inserted sibling took the neighbouring row's local state")

    Tailscale.peers.remove(0)
    root.layout()
    root.check(list.count === 3, `the remove left ${list.count} rows`)
    root.check(root.rowOfNodeId(list, "nBBB1CNTRL") === target,
      "a peer leaving the tailnet rebuilt the row someone was already reading")
    root.check(target.copied === true, "the removed sibling took the neighbouring row's local state")

    // The control. Everything above is the same ListView, the same delegate
    // and the same local state; the only difference here is that the model
    // RESETS instead of updating. If this passes as well, the assertions above
    // were never capable of failing.
    root.seedPeers(three)
    root.layout()
    const rebuilt = root.rowOfNodeId(list, "nBBB1CNTRL")
    root.check(rebuilt !== null, "the control lost the row entirely")
    root.check(rebuilt !== target,
      "a model reset handed back the SAME delegate, so the survival checks above prove nothing"
      + " -- this test cannot tell an in-place update from a rebuild")
    root.check(rebuilt.copied === false,
      "the control kept the local state across a reset, so the state is not local to the delegate"
      + " and proves nothing about the delegate surviving")
  }
}
