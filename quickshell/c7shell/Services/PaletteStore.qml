pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Named for the collision it would otherwise walk into: QtQuick has a Palette
// type, and `import QtQuick` shadows a singleton called Palette -- every read
// off it comes back undefined with nothing in the log.
//
// Reads ../palette.json, which is the single source for every colour in the
// shell and for the appearance defaults. Theme.qml takes the palette half and
// AppearanceStore the defaults half; the exporter, hypr/conf/appearance.lua and
// the login greeter read the same file in their own languages.
//
// Resolved off this file, not off $HOME: the packaged shell lives in
// /usr/share/c7shell, and a hardcoded ~/.config path would silently read
// nothing there -- the same reason AppearanceStore resolves the exporter this
// way (see its `exporter` property).
//
// This is in Services/ rather than Theme/ because AppearanceStore needs it too,
// and nothing under Services/ may import qs.Theme.
Singleton {
  id: root

  readonly property var palette: root.doc.palette ?? ({})
  readonly property var defaults: root.doc.defaults ?? ({})

  readonly property var doc: {
    // A colour that arrives one frame late is not a default, it is black: every
    // binding below feeds a first paint, so the read blocks.
    const text = file.text()
    if (!text) {
      console.warn("Palette: cannot read", file.path,
                   "-- the shell will come up with no colours in it")
      return {}
    }
    try {
      return JSON.parse(text)
    } catch (e) {
      console.warn("Palette:", file.path, "is not valid JSON --", e)
      return {}
    }
  }

  FileView {
    id: file

    path: Qt.resolvedUrl("../palette.json").toString().replace(/^file:\/\//, "")
    blockLoading: true
    // The warning above says it better, and says it once.
    printErrors: false
  }
}
