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

    // 1 -- no daemon. The snapshot underneath is deliberately still a healthy
    // tailnet with a live exit node, which is exactly what must NOT show.
    Tailscale.state = Tailscale.NoState
    Tailscale.exitNodeActive = true
    Tailscale.exitNodeOnline = true
    Tailscale.exitNodeName = "pentest-exit-node"
    root.check(root.slot().visible === false,
      "the slot stayed up at NoState, showing the last snapshot of a tailnet whose daemon is gone")
    root.check(!root.visibleText("pentest-exit-node"),
      "the exit-node label survived the daemon it was read from")

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

    // 6 -- the label is bounded. A MagicDNS hostname is arbitrary text off the
    // network, QuickSlot grows with its content and the pill grows with the
    // slot: an uncapped name moves every slot to its right, and the clock with
    // them, every time an exit node comes or goes. Nothing about that is
    // visible in a screenshot of one state, which is why it is pinned here.
    const house = "c7-lap-g1157c6m.cama-major.ts.net"
    Tailscale.exitNodeName = "pve1"
    const narrow = root.slotWidth()
    Tailscale.exitNodeName = house
    const capped = root.slotWidth()
    root.check(capped > narrow,
      `the label contributes no width at all: "pve1" and "${house}" both give ${capped}`)
    root.check(root.label().truncated,
      `a ${house.length}-character node name was drawn in full rather than elided`)
    Tailscale.exitNodeName = house + house
    root.check(root.slotWidth() === capped,
      `doubling the node name widened the slot from ${capped} to ${root.slotWidth()}`)

    // The cap is a ceiling, not a fixed width: a short name must still shrink
    // the slot back, or the bar simply carries a 90px hole instead.
    Tailscale.exitNodeName = "pve1"
    root.check(root.slotWidth() === narrow,
      "the slot kept the width of the long name after a short one replaced it")
    root.check(!root.label().truncated, "a short node name was elided")

    // -- the panel behind the slot ------------------------------------------
    root.panelChecks()
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
  // millisecond; this has none. Twice, because a child positioner settling
  // changes the implicitHeight its parent is about to lay out against.
  function layout() {
    for (let pass = 0; pass < 2; ++pass)
      for (const o of root.descendants(pop))
        if (o.forceLayout !== undefined) o.forceLayout()
  }

  // c7-test-2's own tailnet, trimmed to four devices -- one per group, plus
  // the offline duplicate-hostname device that carries no IPv6. Already in
  // the order PeerModel sorts them: Mine, Tagged, Others.
  readonly property var tailnetPeers: [
    { hostName: "arch-dev01", ip4: "100.116.79.110", ip6: "fd7a:115c:a1e0::9a3b:4f6f",
      dnsName: "arch-dev01.cama-major.ts.net", online: true, group: 0,
      ownerName: "adriaan@crimson7.io", nodeId: "nAAA1CNTRL", exitNodeOption: false },
    // No IPv6 at all: the copy menu has to draw that entry dead.
    { hostName: "C7-LAP-G1157C6M", ip4: "100.81.116.117", ip6: "",
      dnsName: "c7-lap-g1157c6m.cama-major.ts.net", online: false, group: 0,
      ownerName: "adriaan@crimson7.io", nodeId: "nBBB1CNTRL", exitNodeOption: false },
    { hostName: "pentest-exit-node", ip4: "100.111.18.72", ip6: "fd7a:115c:a1e0::5101:1248",
      dnsName: "pentest-exit-node.cama-major.ts.net", online: true, group: 1,
      ownerName: "Tagged Devices", nodeId: "nCCC1CNTRL", exitNodeOption: true },
    { hostName: "workstation", ip4: "100.89.152.30", ip6: "fd7a:115c:a1e0::143b:981e",
      dnsName: "workstation.cama-major.ts.net", online: true, group: 2,
      ownerName: "Atilla Balin", nodeId: "nDDD1CNTRL", exitNodeOption: false }
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

  function peerRow(hostName) {
    const hit = root.panelAll("ts-peer").find(o => o.hostName === hostName)
    root.check(hit !== undefined, `no peer row for ${hostName}: the panel has `
      + root.panelAll("ts-peer").map(o => o.hostName).join(", "))
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
    Tailscale.selfName = "c7-test-2"
    Tailscale.selfIp4 = "100.73.10.20"
    Tailscale.selfIp6 = "fd7a:115c:a1e0::5e3b:a15"
    Tailscale.selfDnsName = "c7-test-2.cama-major.ts.net"
    Tailscale.tailnet = "cama-major.ts.net"
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
      "the device list is on the root panel; the mock puts it behind a chevron")
    root.check(root.panelOne("ts-back").visible === false,
      "the root panel offers a back chevron with nothing to go back to")
    root.panelOne("ts-devices-row").clicked()
    root.layout()
    root.check(root.panelOne("ts-back").visible === true,
      "a sub-panel with no way back to the root")

    const rows = root.panelShown("ts-peer")
    root.check(rows.length === 4, `the device list drew ${rows.length} of 4 peers`)

    // Sorted by where they actually land, not by the order the view happened
    // to build them in: Mine, Tagged, Others is a visual claim.
    const headings = root.panelShown("ts-section")
      .slice().sort((a, b) => a.mapToItem(pop.panel, 0, 0).y - b.mapToItem(pop.panel, 0, 0).y)
      .map(o => o.text)
    root.check(headings.join(" | ") === "my devices | tagged devices | other users",
      `the device list's sections read: ${headings.join(" | ")}`)

    // Only Other Users needs an owner line; in the other two the owner is the
    // heading.
    root.check(root.peerRow("workstation").subtitle === "Atilla Balin",
      "a peer belonging to another user does not say whose it is")
    root.check(root.peerRow("arch-dev01").subtitle === "",
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
    const arch = root.peerRow("arch-dev01")
    Quickshell.clipboardText = ""
    arch.clicked()
    root.check(Quickshell.clipboardText === "100.116.79.110",
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
    root.check(root.peerRow("workstation").subtitle === "Atilla Balin",
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

    const wanted = [["ts-copy-ip4", "100.116.79.110"],
                    ["ts-copy-ip6", "fd7a:115c:a1e0::9a3b:4f6f"],
                    ["ts-copy-dns", "arch-dev01.cama-major.ts.net"]]
    for (const [entryName, value] of wanted) {
      root.rightClick(arch)
      const menu = root.panelOne("ts-copy-menu")
      root.check(menu.visible, "a right-click on a peer row raised no copy menu")
      root.check(menu.hostName === "arch-dev01",
        `the menu is headed "${menu.hostName}" -- two devices on this tailnet answer to one name`)
      Quickshell.clipboardText = ""
      const entry = root.panelOne(entryName)
      root.check(entry.entryEnabled, `${entryName} is dead on a peer that has that value`)
      entry.activate()
      root.check(Quickshell.clipboardText === value,
        `${entryName} copied "${Quickshell.clipboardText}" instead of "${value}"`)
      root.check(!root.panelOne("ts-copy-menu").visible,
        "the menu stayed up after an entry was taken")
    }

    // A peer with no IPv6 -- the offline laptop. The entry stays in place so
    // the other two do not move under the pointer, and it does nothing.
    root.rightClick(root.peerRow("C7-LAP-G1157C6M"))
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
    pop.view = "root"
    root.layout()
    Tailscale.exitNodes.clear()
    Tailscale.exitNodes.append({ hostName: "ip-10-20-9-170", nodeId: "nEEE1CNTRL" })
    Tailscale.exitNodes.append({ hostName: "pentest-exit-node", nodeId: "nCCC1CNTRL" })
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
    // v1 cannot write prefs, so a row that looked choosable would be a lie.
    root.check(all.every(o => `${o.titleColor}` === `${Theme.textDisabled}`),
      "an exit node row is drawn as selectable, and selecting it is a write v1 does not have")
    root.check(root.panelOne("ts-exit-all-label").text.indexOf("(read-only)") >= 0,
      `the heading does not say the list is read-only: "${root.panelOne("ts-exit-all-label").text}"`)
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
      { hostName: "alpha", ip4: "100.64.0.1", ip6: "fd7a:115c:a1e0::1",
        dnsName: "alpha.cama-major.ts.net", online: true, group: 0,
        ownerName: "adriaan@crimson7.io", nodeId: "nAAA1CNTRL", exitNodeOption: false },
      { hostName: "bravo", ip4: "100.64.0.2", ip6: "fd7a:115c:a1e0::2",
        dnsName: "bravo.cama-major.ts.net", online: true, group: 0,
        ownerName: "adriaan@crimson7.io", nodeId: "nBBB1CNTRL", exitNodeOption: false },
      { hostName: "gamma", ip4: "100.64.0.3", ip6: "fd7a:115c:a1e0::3",
        dnsName: "gamma.cama-major.ts.net", online: true, group: 0,
        ownerName: "adriaan@crimson7.io", nodeId: "nCCC1CNTRL", exitNodeOption: false }
    ]
    root.connected()
    root.seedPeers(three)
    pop.view = "devices"
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
    Tailscale.peers.insert(0, { hostName: "delta", ip4: "100.64.0.4",
      ip6: "fd7a:115c:a1e0::4", dnsName: "delta.cama-major.ts.net", online: true,
      group: 0, ownerName: "adriaan@crimson7.io", nodeId: "nDDD1CNTRL",
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
