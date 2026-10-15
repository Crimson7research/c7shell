import QtQuick
import QtQuick.Window
import C7
import qs.Theme
import qs.Modules.Bar

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
Window {
  id: root
  visible: true
  width: 400; height: 100

  // Throws rather than calling Qt.exit(): Qt.exit() only schedules the exit,
  // so the rest of the block would run on and print the PASS line anyway.
  function check(cond, msg) {
    if (!cond) throw new Error(msg)
  }

  StatusPill { id: pill }

  // Every visual descendant, flattened. The slot has no id reachable from
  // out here, and giving each badge its own hook would mean writing the
  // design into the test twice -- so the test looks for what the design
  // actually specifies: a glyph of a given colour, a label of a given text.
  function descendants(item) {
    let out = []
    for (const c of item.children) {
      out.push(c)
      out = out.concat(root.descendants(c))
    }
    return out
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
  }
}
