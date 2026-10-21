pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick
// For Terminal: the three things in this flow that belong in a terminal --
// "merge…", "view diff" and "view log" -- route through it.
import qs.Services

// The merged update flow, service side. Everything the bar, the dropdown, the
// wizard and the toast bind to lives here; none of them touch a process.
//
// The shape of this file follows the one decision the design makes: a dry run
// happens in the background *before* the dropdown is ever opened, so by the
// time it opens it already knows whether one click is enough. `verdict` is
// that answer and `clean` is the branch.
//
// arch-update is still underneath: its config, its state directory, its idea
// of which AUR helper to use and what counts as a post-update task. What it
// cannot provide is a parseable interface -- every stage of it is a `read -rp`
// against a TTY -- so bin/c7up is the machine-readable half and this talks to
// that. See bin/c7up's header for the division.
Singleton {
  id: root

  // -- the standing verdict --------------------------------------------------
  // Null until the first dry run lands, so the dropdown can show "checking"
  // rather than a count it cannot yet act on.
  property var verdict: null

  readonly property var sources: root.verdict?.sources ?? []
  readonly property var decisions: root.verdict?.decisions ?? []
  readonly property int total: root.sources.reduce((n, s) => n + s.items.length, 0)
  readonly property real size: root.verdict?.size ?? 0
  readonly property bool clean: root.verdict?.clean ?? true
  // Whether there is a verdict at all. Not the same as "nothing pending": at
  // startup, and in the seconds after a run, the counts above are zero because
  // nothing has been counted yet, and a view that reads them as "up to date"
  // states something it does not know.
  readonly property bool hasVerdict: root.verdict !== null
  readonly property bool rebootPredicted: root.verdict?.reboot ?? false
  readonly property double checkedAt: root.verdict?.checked ?? 0
  property bool checking: false
  property string checkError: ""

  // The bar's crimson tint: a kernel or driver in the set is the one thing
  // worth colouring a 14px icon over.
  readonly property bool kernelPending:
    root.decisions.some(d => d.kind === "kernel" || d.kind === "driver")

  // -- the run ---------------------------------------------------------------
  property bool running: false
  property bool awaitingAuth: false
  property int doneCount: 0
  property int runTotal: 0
  // Per-source state, keyed as c7up emits it: running / done / failed.
  property var phases: ({})
  // The collapsed log. Capped: a full -Syu is thousands of lines and the view
  // only ever shows the last handful.
  property var lines: []
  property string logPath: ""

  // -- what the run left behind ----------------------------------------------
  property var result: null              // the last {"ev":"done"} payload
  property var pacnews: []               // configs still to review
  property var services: []              // units wanting a restart
  property bool rebootRequired: false

  // Packages nothing depends on any more -- arch-update's own post-update
  // question, which this shell used to compute and never show. They are not a
  // decision and they never block a run: an orphan costs disk and nothing
  // else, and putting it in front of the clean path would mean no machine
  // that has ever removed a package gets one click again.
  property var orphans: []
  // A removal goes through pkexec, so there is a dialog between the click and
  // anything happening. The card says "removing…" rather than looking dead.
  property bool removingOrphans: false
  readonly property real orphanSize:
    root.orphans.reduce((n, p) => n + (p.size ?? 0), 0)

  // A clean run that turned out to need a decision anyway. The toast escalates
  // on this rather than the run having stopped mid-way to ask.
  readonly property bool needsReview: root.pacnews.length > 0 || root.rebootRequired

  signal finished(bool ok)
  // The wizard's only entry point. `entry` is which of the three reduced forms
  // it opens as: "approve" (step 1, the escalated path), "review" (step 3
  // alone, what the toast's "review now" opens) or "failure".
  signal wizardRequested(string entry)

  function openWizard(entry) { root.wizardRequested(entry) }

  // What the user unticked in step 1, as c7up decision ids.
  property var skipped: []

  function toggleSkip(id) {
    root.skipped = root.skipped.includes(id)
      ? root.skipped.filter(s => s !== id)
      : root.skipped.concat([id])
  }

  // Human "412 MB" for the button. Decimal units, because that is what pacman
  // and every mirror quote.
  function humanSize(bytes) {
    if (!bytes) return ""
    const u = ["B", "KB", "MB", "GB"]
    let i = 0, n = bytes
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++ }
    return `${n < 10 && i > 0 ? n.toFixed(1) : Math.round(n)} ${u[i]}`
  }

  function agoText() {
    if (!root.checkedAt) return "never checked"
    const s = Math.max(0, Math.floor(Date.now() / 1000 - root.checkedAt))
    if (s < 60) return "checked just now"
    if (s < 3600) return `checked ${Math.floor(s / 60)}m ago`
    if (s < 86400) return `checked ${Math.floor(s / 3600)}h ago`
    return `checked ${Math.floor(s / 86400)}d ago`
  }

  // Seconds as the design writes them: "3m 12s".
  function duration(secs) {
    if (secs === undefined || secs === null) return ""
    const m = Math.floor(secs / 60)
    return m > 0 ? `${m}m ${secs % 60}s` : `${secs}s`
  }

  // ---------------------------------------------------------------- refresh --
  function refresh() {
    // Guarded on the process, not on `checking`: the end of a run sets
    // `checking` itself, before the dry run it is announcing has started.
    if (verdictProc.running || root.running) return
    refreshAfterRun.stop()
    root.checking = true
    root.checkError = ""
    verdictProc.running = true
  }

  function apply() {
    if (root.running) return
    root.running = true
    root.awaitingAuth = false
    root.doneCount = 0
    root.runTotal = root.total
    root.phases = ({})
    root.lines = []
    root.result = null
    const args = ["c7up", "run"]
    for (const id of root.skipped) args.push("--skip", id)
    runProc.command = args
    runProc.running = true
  }

  function abort() {
    if (!root.running) return
    // SIGINT, not SIGKILL: pacman traps it and rolls the transaction back,
    // which is the whole promise of the abort button. A kill would leave the
    // lock behind and the transaction half-prepared.
    runProc.signal(2)
  }

  // The result of a run that exited without its `done` event. An empty stderr
  // still has to say something: the failure view is otherwise an empty box
  // (#144), and the exit code is the only fact left to show.
  function fallbackResult(code, stderr, done, total) {
    const err = (stderr ?? "").trim()
    return {
      ok: false,
      aborted: code === 130 || code === 2,
      error: err !== "" ? err : `c7up run exited with status ${code} before it reported a result`,
      done: done,
      total: total
    }
  }

  function reloadPacnews() { pacnewProc.running = true }
  function reloadOrphans() { orphanProc.running = true }

  // -Rns takes the whole set at once, the way arch-update asks it. Removing
  // one can orphan the next, so the list is reloaded rather than assumed
  // empty afterwards.
  function removeOrphans(names) {
    if (!names || names.length === 0 || root.removingOrphans) return
    root.removingOrphans = true
    removeOrphanProc.exec(["c7up", "remove-orphans"].concat(names))
  }
  function orphanNames() { return root.orphans.map(p => p.name) }

  function resolvePacnew(action, path) { resolveProc.exec(["c7up", "resolve", action, path]) }

  // "merge…" is a three-pane editor, which is the one part of this flow that
  // genuinely belongs in a terminal. c7up execs $DIFFPROG there.
  function mergePacnew(path) { Terminal.run(["c7up", "resolve", "merge", path]) }

  // The failure state's "open in terminal": arch-update's own interactive run,
  // which is exactly the escape hatch a GUI should always leave open.
  function openInTerminal() { Terminal.run(["arch-update"]) }

  // Step 1's "view diff" on an AUR package whose PKGBUILD moved. A PKGBUILD is
  // a shell script and its diff is read in a pager, not a panel.
  //
  // WHICH pager, and whether this machine has one at all, is c7up's business
  // and not this file's. Naming `less` here is how the log button came to open
  // a terminal that printed "Failed to launch child: less" and closed again:
  // `less` is not part of base, and a shell must not assume the tools it hands
  // work off to.
  function showDiff(pkg) { Terminal.run(["c7up", "aurdiff", pkg]) }

  // No argument: c7up falls back to the most recent log, so the button still
  // works in a shell session that has not run an update itself.
  function openLog() {
    Terminal.run(root.logPath !== "" ? ["c7up", "log", root.logPath] : ["c7up", "log"])
  }
  function restartServices(units) { restartProc.exec(["c7up", "restart"].concat(units)) }
  function reboot() { rebootProc.exec(["c7up", "reboot"]) }

  // ------------------------------------------------------------- processes --
  Process {
    id: verdictProc
    command: ["c7up", "verdict"]
    stdout: SplitParser {
      onRead: line => {
        if (line.trim() === "") return
        try {
          const ev = JSON.parse(line)
          if (ev.ev !== "verdict") return
          if (ev.error) { root.checkError = ev.error; return }
          root.verdict = ev
          // A verdict is also the moment to notice work parked by an earlier
          // run: pacnews and orphans outlive the process that made them. The
          // orphans ride along on the verdict itself; the pacnews need a
          // second call because resolving one does not produce a new verdict.
          root.orphans = ev.orphans ?? []
          root.reloadPacnews()
        } catch (e) {
          console.warn("updates: unparseable verdict line:", line)
        }
      }
    }
    stderr: StdioCollector { id: verdictErr }
    onExited: code => {
      root.checking = false
      if (code !== 0 && root.checkError === "")
        root.checkError = verdictErr.text.trim() || `c7up verdict exited ${code}`
    }
  }

  Process {
    id: runProc
    stdout: SplitParser {
      onRead: line => {
        if (line.trim() === "") return
        let ev
        try { ev = JSON.parse(line) } catch (e) { return }
        switch (ev.ev) {
        case "start":
          root.runTotal = ev.total
          root.logPath = ev.log ?? ""
          break
        case "auth":
          root.awaitingAuth = ev.state === "waiting"
          break
        case "phase": {
          // Reassigned rather than mutated: QML does not see a property change
          // when the object it already points at is edited in place.
          const p = Object.assign({}, root.phases)
          p[ev.source] = ev
          root.phases = p
          break
        }
        case "progress":
          root.doneCount = ev.done
          if (ev.total) root.runTotal = ev.total
          break
        case "line": {
          const l = root.lines.concat([ev.text])
          root.lines = l.length > 400 ? l.slice(l.length - 400) : l
          break
        }
        case "done":
          root.result = ev
          root.pacnews = ev.pacnew ?? []
          root.services = ev.services ?? []
          root.orphans = ev.orphans ?? []
          root.rebootRequired = ev.reboot ?? false
          break
        }
      }
    }
    stderr: StdioCollector { id: runErr }
    onExited: code => {
      root.running = false
      root.awaitingAuth = false
      // Aborted, or c7up died before it could say anything. Which phases
      // finished is unknown, and the view says that rather than guessing.
      if (root.result === null)
        root.result = root.fallbackResult(code, runErr.text, root.doneCount, root.runTotal)
      root.finished(root.result.ok === true)
      // A failure is the one place the wizard opens itself: it proposes
      // actions rather than asking a question, and there is nowhere else to
      // put them. A clean run that produced configs to review does NOT open
      // anything -- it escalates the toast, and the toast offers the wizard.
      if (root.result.ok !== true && !root.result.aborted) root.openWizard("failure")
      // The verdict describes the machine as it was *before* this run: every
      // package in it has just been installed. Left standing until the next dry
      // run lands, the bar keeps its count and the dropdown re-opens on the
      // list it just finished applying. Dropped here, and `checking` raised
      // now rather than when the process starts, so the seconds in between
      // read as "checking…" instead of as a pending update.
      root.verdict = null
      root.checking = true
      root.checkError = ""
      refreshAfterRun.restart()
    }
  }

  Timer {
    id: refreshAfterRun
    interval: 2000
    onTriggered: root.refresh()
  }

  Process {
    id: pacnewProc
    command: ["c7up", "pacnew"]
    stdout: SplitParser {
      onRead: line => {
        if (line.trim() === "") return
        try {
          const ev = JSON.parse(line)
          if (ev.ev === "pacnew") root.pacnews = ev.files ?? []
        } catch (e) {}
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: orphanProc
    command: ["c7up", "orphans"]
    stdout: SplitParser {
      onRead: line => {
        if (line.trim() === "") return
        try {
          const ev = JSON.parse(line)
          if (ev.ev === "orphans") root.orphans = ev.packages ?? []
        } catch (e) {}
      }
    }
    stderr: StdioCollector {}
  }

  Process {
    id: removeOrphanProc
    stderr: StdioCollector {}
    onExited: {
      root.removingOrphans = false
      root.reloadOrphans()
    }
  }

  Process {
    id: resolveProc
    stderr: StdioCollector {}
    onExited: root.reloadPacnews()
  }
  Process {
    id: restartProc
    stderr: StdioCollector {}
    onExited: root.services = []
  }
  Process {
    id: rebootProc
    stderr: StdioCollector {}
  }

  // The dry run rides the same cadence as the plain check it replaces.
  // arch-update's own timer keeps running alongside and writes the same state
  // files; the two agree because c7up writes them in arch-update's format.
  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }
  // The first one waits for the network rather than racing login.
  Timer {
    interval: 60 * 1000
    running: true
    onTriggered: root.refresh()
  }
}
