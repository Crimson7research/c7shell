pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Spec §7: ~/.config/hypr/appearance.json is the single source of truth for
// look-and-feel. The settings app writes `values`, JsonAdapter persists them,
// and this singleton pushes them at the compositor. conf/look-and-feel.lua
// reads the same file at config load, so a value survives both a hyprland
// reload and a qs restart. Hand-edits arrive through watchChanges.
//
// This is a service, so the Process calls belong here and nowhere else.
Singleton {
  id: root

  // Settings pages assign straight to this — writes persist themselves.
  readonly property alias values: adapter

  // Set by bin/screenshare-picker.sh. The picker is its own qs instance and
  // reads Theme, which reads this store; without the flag every screen share
  // would re-apply the compositor config, rerun the desktop exporter, re-send
  // the wallpaper and write appearance.json, all from a dialog that only wants
  // the accent. Read-only, the store still loads and follows the file.
  readonly property bool readOnly: Quickshell.env("C7SHELL_APPEARANCE_READONLY") === "1"

  // -- clamped reads --------------------------------------------------------
  // Everything that leaves this file goes through these, never through the
  // adapter: the JSON is hand-editable, so its contents are untrusted input
  // and a stray value must not reach a Lua eval or wedge the compositor.
  readonly property string theme: Object.keys(PaletteStore.palette.variants ?? {}).includes(root.values.theme)
    ? root.values.theme : PaletteStore.defaults.theme
  readonly property color accent: /^#[0-9a-fA-F]{6}$/.test(root.values.accent)
    ? root.values.accent : PaletteStore.defaults.accent

  readonly property int rounding: root.clamp(root.values.rounding, 0, 40)
  readonly property int gapsIn: root.clamp(root.values.gapsIn, 0, 40)
  readonly property int gapsOut: root.clamp(root.values.gapsOut, 0, 60)
  readonly property int blurSize: root.clamp(root.values.blurSize, 1, 20)
  readonly property int blurPasses: root.clamp(root.values.blurPasses, 1, 5)
  readonly property real inactiveOpacity: root.clamp(root.values.inactiveOpacity, 0.3, 1)
  readonly property int borderWidth: root.clamp(root.values.borderWidth, 0, 10)
  // Active border is the accent (spec §7); only the inactive one is a choice.
  readonly property color inactiveBorder: /^#[0-9a-fA-F]{6}$/.test(root.values.inactiveBorder)
    ? root.values.inactiveBorder : PaletteStore.defaults.inactiveBorder
  // Bar geometry is shell-side only -- no hyprctl, no lua. Top is capped below
  // the bar's own 36px shadow gutter so the island never outruns the window it
  // is drawn in; sides are capped at a quarter of a narrow 1366px screen.
  readonly property int barMarginTop: root.clamp(root.values.barMarginTop, 0, 32)
  readonly property int barMarginSide: root.clamp(root.values.barMarginSide, 0, 80)
  readonly property bool animationsEnabled: root.values.animationsEnabled
  readonly property real animationSpeed: root.clamp(root.values.animationSpeed, 0.25, 4)
  readonly property string wallpaper: root.values.wallpaper
  // The cursor name reaches a directory lookup, two config files and an argv
  // element in the exporter, so it is held to a plain theme name here too.
  readonly property string cursorTheme: /^[A-Za-z0-9._-]+$/.test(root.values.cursorTheme)
    ? root.values.cursorTheme : PaletteStore.defaults.cursorTheme
  readonly property int cursorSize: root.clamp(root.values.cursorSize, 8, 128)

  function clamp(v, lo, hi) {
    const n = Number(v)
    return isNaN(n) ? lo : Math.max(lo, Math.min(hi, n))
  }

  // Both swatch rows, and what each one is, are palette.json's business.
  readonly property var accentChoices: PaletteStore.palette.accentChoices ?? []
  readonly property var borderChoices: PaletteStore.palette.borderChoices ?? []

  // -- persistence ----------------------------------------------------------
  FileView {
    id: file

    path: `${Quickshell.env("HOME")}/.config/hypr/appearance.json`
    watchChanges: true
    // First run has no file; that is expected, not something to warn about.
    printErrors: false

    onFileChanged: file.reload()
    onAdapterUpdated: if (!root.readOnly) file.writeAdapter()
    onLoaded: { apply.restart(); desktopExport.restart() }
    // Write the defaults out so hyprland has something to read on its next
    // config load, instead of both sides silently disagreeing.
    onLoadFailed: err => {
      if (err === FileViewError.FileNotFound && !root.readOnly) file.writeAdapter()
    }

    JsonAdapter {
      id: adapter

      // Every default comes from palette.json, which hypr/conf/appearance.lua
      // and the exporter read as well -- this adapter's shape used to be
      // mirrored by hand in three languages, and the lua copy had already
      // drifted by an inactiveBorder. The bindings break on load, which is
      // correct: the file's own value wins from then on.
      property string theme: PaletteStore.defaults.theme
      property string accent: PaletteStore.defaults.accent
      property int rounding: PaletteStore.defaults.rounding
      property int gapsIn: PaletteStore.defaults.gapsIn
      property int gapsOut: PaletteStore.defaults.gapsOut
      property int blurSize: PaletteStore.defaults.blurSize
      property int blurPasses: PaletteStore.defaults.blurPasses
      property real inactiveOpacity: PaletteStore.defaults.inactiveOpacity
      property int borderWidth: PaletteStore.defaults.borderWidth
      property int barMarginTop: PaletteStore.defaults.barMarginTop
      property int barMarginSide: PaletteStore.defaults.barMarginSide
      property string inactiveBorder: PaletteStore.defaults.inactiveBorder
      property bool animationsEnabled: PaletteStore.defaults.animationsEnabled
      property real animationSpeed: PaletteStore.defaults.animationSpeed
      property string wallpaper: PaletteStore.defaults.wallpaper
      // Not exposed in the settings app yet; they live here so a hand-edit
      // survives the next write instead of being dropped from the JSON.
      property string cursorTheme: PaletteStore.defaults.cursorTheme
      property int cursorSize: PaletteStore.defaults.cursorSize
    }
  }

  // -- live apply -----------------------------------------------------------
  // A slider drag changes the value every frame; coalesce into one hyprctl.
  Timer {
    id: apply
    interval: 120
    onTriggered: root.applyNow()
  }

  onRoundingChanged: apply.restart()
  onGapsInChanged: apply.restart()
  onGapsOutChanged: apply.restart()
  onBlurSizeChanged: apply.restart()
  onBlurPassesChanged: apply.restart()
  onInactiveOpacityChanged: apply.restart()
  onBorderWidthChanged: apply.restart()
  onAnimationsEnabledChanged: apply.restart()
  onAnimationSpeedChanged: apply.restart()
  onAccentChanged: { apply.restart(); desktopExport.restart() }
  onThemeChanged: desktopExport.restart()
  // The exporter is what carries a cursor change to kcminputrc, both GTK
  // settings.ini files and `hyprctl setcursor`; the compositor's own env is
  // read by conf/environment.lua at config load.
  onCursorThemeChanged: desktopExport.restart()
  onCursorSizeChanged: desktopExport.restart()
  onWallpaperChanged: wallpaperApply.restart()

  // The rest of the desktop does not read appearance.json: Qt and KDE apps take
  // their colours from ~/.config/kdeglobals, and everything that asks "is this a
  // dark desktop?" -- GTK, Electron, browsers -- asks the settings portal, which
  // answers out of GSettings. Nothing kept either in step, so the shell went
  // green while dolphin stayed crimson, and every app that detects a scheme came
  // up light. scripts/c7shell-theme-export.py writes both from this store, then
  // emits the signal plasma-integration repaints on. Only accent and theme
  // move it -- theme also implies the colour scheme apps are told to prefer --
  // and the geometry sliders have nothing to export.
  //
  // The Qt half needs QT_QPA_PLATFORMTHEME=kde (hypr/conf/environment.lua):
  // under qt6ct KDE apps read neither kdeglobals nor qt6ct's palette and come up
  // stock light. The portal half needs an xdg-desktop-portal backend that
  // implements Settings (xdg-desktop-portal-gtk; xdph does not).
  //
  // Resolved off this file, not off $HOME: the packaged shell lives in
  // /usr/share/c7shell, and a hardcoded ~/.config path would silently export
  // nothing there.
  readonly property string exporter:
    Qt.resolvedUrl("../scripts/c7shell-theme-export.py").toString().replace(/^file:\/\//, "")

  Timer {
    id: desktopExport
    interval: 250
    onTriggered: {
      if (root.readOnly) return
      if (exportProc.running) { desktopExport.restart(); return }
      exportProc.exec(["python3", root.exporter])
    }
  }

  Process {
    id: exportProc
    // The script reads appearance.json itself rather than taking argv, so a
    // hand-edit lands the same way a settings click does.
    stderr: StdioCollector {}
  }

  // Hyprland wants rgba(rrggbbaa); `accent` is already validated hex, and
  // going through Qt.color keeps the conversion honest either way.
  function rgba(c, a) {
    const col = Qt.color(c)
    const h = x => Math.round(x * 255).toString(16).padStart(2, "0")
    return `rgba(${h(col.r)}${h(col.g)}${h(col.b)}${h(a)})`
  }

  // `hyprctl keyword` does not work on this build: the config provider is lua,
  // and Hyprland answers keyword with "can't work with non-legacy parsers, use
  // eval". So live-apply speaks the same hl.config() dialect the config files
  // do (see conf/look-and-feel.lua).
  function luaConfig() {
    return "hl.config({"
      + `general={gaps_in=${root.gapsIn},gaps_out=${root.gapsOut},border_size=${root.borderWidth},`
      + `col={active_border="${root.rgba(root.accent, 238 / 255)}",`
      + `inactive_border="${root.rgba(root.inactiveBorder, 170 / 255)}"}},`
      + `decoration={rounding=${root.rounding},inactive_opacity=${root.inactiveOpacity.toFixed(3)},`
      + `blur={size=${root.blurSize},passes=${root.blurPasses}}},`
      + `animations={enabled=${root.animationsEnabled ? "true" : "false"}}})`
  }

  // Speed is per-animation-leaf in Hyprland — there is no global multiplier
  // keyword. conf/animations.lua returns its leaf table so the multiplier can
  // be re-applied over it without this file duplicating the speeds.
  // ponytail: pcall'd because a hyprland whose animations.lua predates that
  // change simply keeps its configured speeds instead of erroring.
  function luaAnimations() {
    return ";pcall(function() for _,l in ipairs(require('conf/animations')) do"
      + ` hl.animation({leaf=l.leaf,enabled=${root.animationsEnabled ? "true" : "false"},`
      + `speed=l.speed/${root.animationSpeed.toFixed(3)},bezier=l.bezier,spring=l.spring,style=l.style}) end end)`
  }

  function applyNow() {
    if (root.readOnly) return
    if (hypr.running) { apply.restart(); return }
    hypr.exec(["hyprctl", "eval", root.luaConfig() + root.luaAnimations()])
  }

  Process {
    id: hypr
    // A compositor that is not there is not an error worth a toast: the shell
    // can run under a plain nested session while a page is being designed.
    stderr: StdioCollector {}
  }

  // Who paints the wallpaper. hypr/conf/environment.lua exports this after
  // hypr/conf/gpu.lua decides -- on a virtual GPU hyprpaper is not merely
  // unable to draw, it SIGABRTs on the first request and conf/autostart.lua
  // does not start it there, so Modules/Wallpaper draws instead. Unset means
  // hyprpaper, which keeps a shell run outside the session behaving as before.
  readonly property bool shellDrawsWallpaper: Quickshell.env("C7SHELL_WALLPAPER") === "shell"

  // This hyprpaper (0.8.4) implements exactly one request — `wallpaper`, taking
  // [mon],[path],[fit_mode]. `preload` is rejected as an invalid request, and
  // is not needed: a bare wallpaper request loads the file itself (verified —
  // hyprpaper ends up holding an open fd on it) and validates the path,
  // answering "bad path" when it does not exist. An empty monitor field means
  // every monitor. argv, so the path is never parsed by a shell.
  Timer {
    id: wallpaperApply
    interval: 200
    onTriggered: {
      if (root.readOnly || root.wallpaper === "" || paper.running) return
      // Nothing to push when the shell is the one drawing it: the window in
      // Modules/Wallpaper is bound to the same value and has already changed.
      if (root.shellDrawsWallpaper) return
      paper.exec(["hyprctl", "hyprpaper", "wallpaper", `,${root.wallpaper}`])
    }
  }

  Process {
    id: paper
    stderr: StdioCollector {}
  }

  // -- browsing for a wallpaper ---------------------------------------------
  // The dialog is the desktop's, not the shell's: hyprland-portals.conf routes
  // org.freedesktop.impl.portal.FileChooser to the kde backend, so this is the
  // same picker -- same KIO places sidebar, same kdeglobals palette -- that
  // every portal-using app on the machine shows (README, "The file picker").
  // Quickshell 0.3.1 has no generic DBus client, so scripts/c7shell-filechooser.py
  // makes the call and prints the path; only its exit status decides whether a
  // wallpaper is set, so a cancelled dialog cannot clear the one in force.
  //
  // Resolved off this file for the same reason the exporter is: the packaged
  // shell lives in /usr/share/c7shell, where a ~/.config path finds nothing.
  readonly property string filechooser:
    Qt.resolvedUrl("../scripts/c7shell-filechooser.py").toString().replace(/^file:\/\//, "")

  // True while the dialog is up, so the settings page can say so -- the portal
  // can take a moment to activate its backend the first time, and a button that
  // looks like it did nothing gets clicked again.
  readonly property bool browsing: chooser.running

  function browseWallpaper() {
    if (chooser.running) return
    const cut = root.wallpaper.lastIndexOf("/")
    const folder = cut > 0 ? root.wallpaper.slice(0, cut) : `${Quickshell.env("HOME")}/Pictures`
    chooser.exec(["python3", root.filechooser,
                  "--title", "Choose a wallpaper",
                  "--accept", "Set wallpaper",
                  "--images",
                  "--current-folder", folder])
  }

  Process {
    id: chooser

    property string picked: ""

    stdout: StdioCollector { onStreamFinished: chooser.picked = text.trim() }
    stderr: StdioCollector {}
    // Exit 1 is a cancelled dialog and 2 is a portal that could not be reached;
    // neither is a wallpaper. Only status 0 carries a path.
    onExited: exitCode => {
      if (exitCode === 0 && chooser.picked !== "") root.values.wallpaper = chooser.picked
      chooser.picked = ""
    }
  }
}
