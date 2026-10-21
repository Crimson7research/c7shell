import QtQuick
import QtQuick.Window
import qs.Common
import qs.Services

// Self-check for the two pieces of the update flow that are pure computation
// and therefore silently wrong rather than visibly broken (run by
// tests/test-updates.sh):
//
//   VersionDelta   which part of "25.1.2 → 25.1.4" gets highlighted. Getting
//                  this wrong still renders a version, just the wrong half of
//                  it, and no screenshot review catches that reliably.
//   UpdatesService the numbers on the button and in the headline.
Window {
  id: root
  visible: true
  width: 100; height: 100

  // Throws rather than calling Qt.exit(): Qt.exit() only *schedules* the exit,
  // so the enclosing function runs on and prints the PASS line anyway. A
  // harness that cannot fail is worse than no harness.
  function check(cond, msg) {
    if (!cond) throw new Error(msg)
  }

  // The four worked examples from the design's own notes. In each, the WHOLE
  // changed number is picked out -- never the differing digit, never the tail
  // after it.
  Repeater {
    id: deltas
    model: [
      { old: "8.15.0",  now: "8.16.0",  prefix: "8.",   lead: "",  changed: "16",  suffix: ".0" },
      { old: "r812",    now: "r819",    prefix: "",     lead: "r", changed: "819", suffix: ""   },
      { old: "1.104",   now: "1.105",   prefix: "1.",   lead: "",  changed: "105", suffix: ""   },
      { old: "2.0-24",  now: "2.0-25",  prefix: "2.0-", lead: "",  changed: "25",  suffix: ""   },
      // A pkgrel-only bump: everything up to the release is unchanged.
      { old: "0.3.113-4", now: "0.3.113-5", prefix: "0.3.113-", lead: "", changed: "5", suffix: "" },
      // Identical versions cannot highlight anything.
      { old: "1.0.0",   now: "1.0.0",   prefix: "1.0.0", lead: "", changed: "",   suffix: ""   },
      // Flatpak has no old version at all; the whole thing is the change.
      { old: "",        now: "3.2.1",   prefix: "",     lead: "",  changed: "3",   suffix: ".2.1" }
    ]
    VersionDelta {
      required property var modelData
      oldVersion: modelData.old
      newVersion: modelData.now
    }
  }

  Component.onCompleted: {
    try {
    root.check(deltas.count === deltas.model.length,
      `the delta repeater built ${deltas.count} of ${deltas.model.length} cases`)
    for (let i = 0; i < deltas.count; i++) {
      const d = deltas.itemAt(i)
      const e = deltas.model[i]
      const where = `${e.old} → ${e.now}`
      root.check(d.prefix === e.prefix,
        `${where}: dim prefix is "${d.prefix}", expected "${e.prefix}"`)
      root.check(d.lead === e.lead,
        `${where}: dim lead is "${d.lead}", expected "${e.lead}"`)
      root.check(d.changed === e.changed,
        `${where}: highlighted "${d.changed}", expected "${e.changed}"`)
      root.check(d.suffix === e.suffix,
        `${where}: dim suffix is "${d.suffix}", expected "${e.suffix}"`)
      // Whatever the split, it has to reassemble into the version verbatim --
      // otherwise the row renders a version that does not exist.
      root.check(d.prefix + d.lead + d.changed + d.suffix === e.now,
        `${where}: the pieces do not rejoin into "${e.now}"`)
    }

    // -- the numbers on the button ------------------------------------------
    // Decimal units, because that is what pacman and every mirror quote: a
    // 412 MB download shown as 393 MB is a number nothing else on the machine
    // agrees with.
    root.check(UpdatesService.humanSize(412000000) === "412 MB",
      `humanSize(412000000) = "${UpdatesService.humanSize(412000000)}"`)
    root.check(UpdatesService.humanSize(0) === "",
      "humanSize(0) must render nothing rather than '0 B'")
    root.check(UpdatesService.humanSize(1500) === "1.5 KB",
      `humanSize(1500) = "${UpdatesService.humanSize(1500)}"`)

    root.check(UpdatesService.duration(192) === "3m 12s",
      `duration(192) = "${UpdatesService.duration(192)}"`)
    root.check(UpdatesService.duration(45) === "45s",
      `duration(45) = "${UpdatesService.duration(45)}"`)
    root.check(UpdatesService.duration(undefined) === "",
      "duration(undefined) must render nothing, not 'NaNs'")

    // -- step 1's ticks -------------------------------------------------------
    root.check(UpdatesService.skipped.length === 0, "skipped did not start empty")
    UpdatesService.toggleSkip("kernel:linux")
    root.check(UpdatesService.skipped.length === 1, "toggleSkip did not add")
    UpdatesService.toggleSkip("kernel:linux")
    root.check(UpdatesService.skipped.length === 0, "toggleSkip did not remove")

    // -- the verdict is the branch --------------------------------------------
    // With no verdict yet the flow must read as clean, or an empty dropdown
    // would offer "review & update →" over nothing to review.
    root.check(UpdatesService.clean, "the flow is not clean before the first dry run")
    root.check(UpdatesService.total === 0, "total is not zero before the first dry run")
    // ...but "no verdict yet" and "nothing pending" are different answers, and
    // the views tell them apart with this. Without it, the seconds after a run
    // -- when the verdict is deliberately dropped -- read as "up to date".
    root.check(!UpdatesService.hasVerdict, "hasVerdict was true before the first dry run")

    UpdatesService.verdict = {
      clean: false,
      checked: 0,
      size: 412000000,
      reboot: true,
      sources: [
        { key: "pacman", label: "pacman", items: [{ name: "linux", old: "6.15.4", new: "6.16.1" }] },
        { key: "aur", label: "aur", items: [{ name: "hyprpicker", old: "0.4.3", new: "0.4.4" }] },
        { key: "flatpak", label: "flatpak", items: [] }
      ],
      decisions: [{ id: "kernel:linux", kind: "kernel", title: "linux", detail: "", note: "" }]
    }
    root.check(UpdatesService.hasVerdict, "a verdict landed and hasVerdict stayed false")
    root.check(UpdatesService.total === 2, `total across sources = ${UpdatesService.total}`)
    root.check(!UpdatesService.clean, "an escalated verdict still read as clean")
    root.check(UpdatesService.kernelPending, "a kernel decision did not tint the bar")
    root.check(UpdatesService.rebootPredicted, "the predicted reboot was dropped")

    // -- the cleanup nobody was shown ----------------------------------------
    // Orphans ride along on the verdict, and the card is built from the size
    // sum and the name list. A verdict without them must leave the card off
    // rather than render "0 packages · NaN".
    root.check(UpdatesService.orphans.length === 0,
      "a verdict with no orphan list still produced orphans")
    root.check(UpdatesService.orphanSize === 0,
      `orphanSize with no orphans = ${UpdatesService.orphanSize}`)

    // Assigned directly rather than through `verdict`: the property is written
    // by three different events (a verdict, a run's done, the standalone
    // orphans verb) and cleared by "keep them", so it is a property and not a
    // binding. What is under test here is the arithmetic the card is built
    // from, which is the part that is silently wrong rather than absent.
    UpdatesService.orphans =
      [{ name: "oldlib", size: 12582912 }, { name: "stale-thing", size: 524288 }]
    root.check(UpdatesService.orphanSize === 13107200,
      `orphanSize summed to ${UpdatesService.orphanSize}`)
    root.check(UpdatesService.orphanNames().join(" · ") === "oldlib · stale-thing",
      `the orphan card would list "${UpdatesService.orphanNames().join(" · ")}"`)
    // Orphans are cleanup, not a decision: they must not tint the bar or take
    // the one-click path away.
    root.check(!UpdatesService.kernelPending || UpdatesService.decisions.length === 1,
      "the orphan list changed what counts as a decision")
    // An empty removal is a no-op rather than a c7up invocation with no
    // arguments, which would exit 2 and pop a polkit dialog for nothing --
    // and it must not arm the card's "removing…" state, which only a real
    // process exiting clears again.
    root.check(!UpdatesService.removingOrphans, "the removing state did not start off")
    UpdatesService.removeOrphans([])
    root.check(!UpdatesService.removingOrphans,
      "an empty removal armed the card's removing state with nothing running")

    // These three route into the Terminal singleton, and an unresolved name
    // there would not surface until the first click on "merge…" in a shipped
    // build. Calling them here is the only place that gets caught.
    UpdatesService.mergePacnew("/etc/pacman.conf")
    UpdatesService.showDiff("quickshell-git")
    UpdatesService.openInTerminal()
    UpdatesService.openLog()

    // -- a run that ended without a result ----------------------------------
    // c7up exiting before its `done` event with nothing on stderr used to
    // leave the failure view an empty red box (#144). The exit code is the one
    // fact left, so the error carries it.
    const silent = UpdatesService.fallbackResult(1, "  \n", 0, 3)
    root.check(silent.ok === false, "a run with no result read as a success")
    root.check(!silent.aborted, "exit 1 read as an abort")
    root.check(silent.error === "c7up run exited with status 1 before it reported a result",
      `a silent exit's error is "${silent.error}"`)
    const loud = UpdatesService.fallbackResult(1, "c7up: boom\n", 2, 3)
    root.check(loud.error === "c7up: boom", `stderr was not the error: "${loud.error}"`)
    root.check(loud.done === 2 && loud.total === 3, "the counts were not carried")
    root.check(UpdatesService.fallbackResult(130, "", 0, 0).aborted, "exit 130 was not an abort")
    root.check(UpdatesService.fallbackResult(2, "", 0, 0).aborted, "exit 2 was not an abort")

    console.log("UPDATES-TEST-PASS")
    Qt.exit(0)
    } catch (e) {
      console.error("ASSERT-FAILED: " + e.message)
      Qt.exit(1)
    }
  }
}
