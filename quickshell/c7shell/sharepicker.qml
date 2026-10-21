//@ pragma UseQApplication
// The screenshare picker's entry point, launched by bin/screenshare-picker.sh
// for xdph. It lives beside shell.qml for the reason preview.qml gives: `qs -p`
// roots the `qs` module at this file's directory, so from
// Modules/SharePicker/ neither qs.Theme nor qs.Common resolves.
import Quickshell
import qs.Modules.SharePicker

ShellRoot {
  PickerApp {}
}
