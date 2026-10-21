#!/usr/bin/env bash
# The screenshare picker contract. Run it directly: tests/test-screenshare.sh
#
# xdph's Screencopy custom_picker_binary path does `data.output.pop_back()` on
# the "screen:<name>" selection, expecting the reference hyprland-share-picker's
# trailing std::endl. c7shell's PickerApp.qml writes the selection itself, so it
# MUST emit that newline -- without it xdph strips a real character ("DP-3" ->
# "DP-"), finds no such output, and the screencast never starts (Discord shows
# a crash). Windows survive it (handle parse tolerates a short string); screens
# do not. This is invisible without a compositor and a portal on the bus, so
# the newline is asserted here where a future edit that drops it fails loudly.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
picker=$repo/quickshell/c7shell/Modules/SharePicker/PickerApp.qml
wrapper=$repo/quickshell/c7shell/bin/screenshare-picker.sh

entry=$repo/quickshell/c7shell/sharepicker.qml

[[ -f $picker ]]  || fail 'PickerApp.qml is missing'
[[ -f $wrapper ]] || fail 'screenshare-picker.sh is missing'

# The entry point sits at the config root so qs.Theme resolves; sharepicker.qml
# says why (#95).
[[ -f $entry ]] || fail 'sharepicker.qml, the picker entry point at the config root, is missing'
grep -qE '^[[:space:]]*PickerApp[[:space:]]*\{' "$entry" \
  || fail 'sharepicker.qml does not instantiate PickerApp'
grep -qF 'quickshell/c7shell/sharepicker.qml' "$wrapper" \
  || fail 'the wrapper does not launch sharepicker.qml, so qs.Theme does not resolve in the picker'
grep -q 'ShellRoot' "$picker" \
  && fail 'PickerApp.qml is still a ShellRoot: it is a component, and sharepicker.qml is the root'
grep -q '^import qs.Theme$' "$picker" || fail 'PickerApp.qml does not import qs.Theme'
# Theme pulls in AppearanceStore; the flag keeps it from re-applying the desktop
# on every share (tests/test-appearance-readonly.sh tests the store itself).
grep -qF 'C7SHELL_APPEARANCE_READONLY=1 qs -p' "$wrapper" \
  || fail 'the wrapper starts the picker without C7SHELL_APPEARANCE_READONLY=1, so every share re-applies the appearance'

# The selection writer must terminate the line, or xdph eats the last char.
grep -qF 'printf "%s\\n"' "$picker" \
  || fail 'PickerApp.qml writes the selection without a trailing newline (xdph pop_back() will truncate the screen name)'

# xdph parses "[SELECTION]/<flags>/<kind>:...". The kind tokens must be exactly
# what Screencopy.cpp compares with find(...) == 0.
grep -q 'screen:' "$picker" || fail 'PickerApp.qml no longer emits the "screen:" token'
grep -q 'window:' "$picker" || fail 'PickerApp.qml no longer emits the "window:" token'
grep -qF '[SELECTION]' "$picker" || fail 'PickerApp.qml no longer emits the [SELECTION] marker'

# The wrapper relays $XDPH_OUT verbatim; if it stops, xdph reads nothing.
grep -q 'XDPH_OUT' "$wrapper" || fail 'the wrapper no longer relays $XDPH_OUT'

printf '%s: all checks passed\n' "$(basename "$0")"
