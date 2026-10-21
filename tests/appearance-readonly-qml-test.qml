import QtQuick
import Quickshell
import qs.Services

// Driven by tests/test-appearance-readonly.sh. Touches the store only after the
// arguments are in place, then makes the changes a settings page would and
// waits out every coalescing timer before printing what was asked for.
QtObject {
  id: root

  property Timer settle: Timer {
    interval: 900
    onTriggered: {
      for (const c of Recorder.calls) console.log(`CALL: ${c}`)
      console.log("APPEARANCE-TEST-DONE")
      Qt.quit()
    }
  }

  Component.onCompleted: {
    // Reading anything off the store creates it, as Theme does in the picker.
    const before = AppearanceStore.accent
    AppearanceStore.values.accent = "#00a149"    // palette-literal-ok: a test value, not a token
    AppearanceStore.values.wallpaper = "/tmp/c7-test.png"
    Recorder.file.adapterUpdated()
    Recorder.file.loadFailed(1)
    root.settle.start()
  }
}
