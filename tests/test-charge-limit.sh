#!/usr/bin/env bash
# Self-check for the charge-limit row on settings -> system -> power.
# Run it directly: tests/test-charge-limit.sh
#
# Same trick as tests/test-tuned-notice.sh: PowerService is shimmed, the row
# and the real Dropdown are loaded. No compositor and no battery.
#
# What it defends (#275): the label and the picker read chargeLimit through two
# different mappings, so 0 read as "off" in one and "stops at 0%" in the other,
# and a vendor-clamped value off the grid left the picker with no row marked.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
mktmp
need_qml6

row=$tmp/qs/Modules/Settings/pages/power
mkdir -p "$tmp/qs/Common" "$tmp/qs/Services" "$row"

cp "$src/Modules/Settings/pages/power/ChargeLimitRow.qml" "$row/"
printf 'module qs.Modules.Settings.pages.power\nChargeLimitRow 1.0 ChargeLimitRow.qml\n' > "$row/qmldir"

cp "$src/Common/Dropdown.qml" "$tmp/qs/Common/"
printf 'module qs.Common\nDropdown 1.0 Dropdown.qml\n' > "$tmp/qs/Common/qmldir"

write_theme_stub "$tmp/qs" "$src"

# Writable here; the real one reads sysfs. Writes are recorded, not performed.
cat > "$tmp/qs/Services/PowerService.qml" <<'QML'
pragma Singleton
import QtQuick
QtObject {
  property int chargeLimit: 80
  property bool limitSupported: true
  property var written: []
  function setChargeLimit(v) { written = written.concat([v]) }
}
QML
printf 'module qs.Services\nsingleton PowerService 1.0 PowerService.qml\n' > "$tmp/qs/Services/qmldir"

log=$tmp/charge-limit.log
QT_QPA_PLATFORM=offscreen \
QT_FORCE_STDERR_LOGGING=1 \
timeout 30 qml6 -I "$tmp" "$here/charge-limit-qml-test.qml" >"$log" 2>&1 \
  || fail "qml6 exited non-zero:\n$(cat "$log")"

grep -q 'CHARGE-LIMIT-TEST-PASS' "$log" || fail "the test never reached its end:\n$(cat "$log")"
if grep -q '\.qml:' "$log"; then
  fail "QML diagnostics:\n$(grep '\.qml:' "$log")"
fi

echo 'PASS: the charge-limit row'
