import QtQuick
import QtQuick.Window
import qs.Services
import qs.Modules.Settings.pages.power

// Self-check for Modules/Settings/pages/power/ChargeLimitRow (run by
// tests/test-charge-limit.sh).
Window {
  id: win
  visible: true
  width: 400; height: 100

  function check(cond, msg) {
    if (!cond) throw new Error(msg)
  }

  function find(item, name) {
    if (item.objectName === name) return item
    for (let i = 0; i < item.children.length; i++) {
      const hit = find(item.children[i], name)
      if (hit) return hit
    }
    return null
  }

  ChargeLimitRow { id: row; width: 360 }

  Component.onCompleted: {
    const label = find(row, "limitLabel")
    const pick = find(row, "limitPick")
    const grid = "60%,70%,80%,85%,90%,95%,off"

    // On the grid: the list is the grid, the picker marks the value.
    PowerService.chargeLimit = 80
    check(pick.current === "80%", `80 picks "${pick.current}"`)
    check(pick.options.join() === grid, `80 lists ${pick.options}`)
    check(label.text === "stops at 80% to slow wear", `80 reads "${label.text}"`)

    // 0 and 100 are both "off" in the picker and "charges to full" in the label.
    for (const v of [0, 100]) {
      PowerService.chargeLimit = v
      check(pick.current === "off", `${v} picks "${pick.current}"`)
      check(pick.options.join() === grid, `${v} lists ${pick.options}`)
      check(label.text === "charges to full", `${v} reads "${label.text}"`)
    }

    // Off the grid: the read value joins the list in order, so it gets the
    // marker and the picker opens on it rather than on row 0.
    PowerService.chargeLimit = 64
    check(pick.current === "64%", `64 picks "${pick.current}"`)
    check(pick.options.join() === "60%,64%,70%,80%,85%,90%,95%,off", `64 lists ${pick.options}`)
    check(label.text === "stops at 64% to slow wear", `64 reads "${label.text}"`)
    check(pick.options.indexOf(pick.current) === 1, "the picker would open on row 0, not on 64%")

    PowerService.chargeLimit = 55
    check(pick.current === "55%", `55 picks "${pick.current}"`)
    check(pick.options[0] === "55%", `55 lists ${pick.options}`)
    check(label.text === "stops at 55% to slow wear", `55 reads "${label.text}"`)

    // Picking still writes what it did: a percentage, or 100 for "off".
    pick.picked("70%")
    pick.picked("off")
    check(PowerService.written.join() === "70,100", `picks wrote ${PowerService.written}`)

    // What the real service reports for a 0 read: no threshold, picker off
    // and disabled (PowerService.limitSupported requires chargeLimit > 0).
    PowerService.chargeLimit = 0
    PowerService.limitSupported = false
    check(label.text === "this pack exposes no charge threshold", `unsupported reads "${label.text}"`)
    check(pick.current === "off" && !pick.enabled, `unsupported picks "${pick.current}", enabled ${pick.enabled}`)

    console.log("CHARGE-LIMIT-TEST-PASS")
    Qt.quit()
  }
}
