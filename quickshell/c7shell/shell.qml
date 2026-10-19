//@ pragma UseQApplication
// Required for the tray's dbus menus: SystemTrayItem.display() renders a
// platform menu, which only exists under QApplication.

import Quickshell
import qs.Modules.Auth
import qs.Modules.Bar
import qs.Modules.Launcher
import qs.Modules.Capture
import qs.Modules.Popovers
import qs.Modules.Osd
import qs.Modules.Power
import qs.Modules.Settings
import qs.Modules.Updates
import qs.Modules.Wallpaper
import qs.Services

Scope {
  // First, and on the background layer: on most machines this is nothing at
  // all -- hyprpaper owns the wallpaper and Wallpaper.qml maps no windows.
  Wallpaper {}

  Bar {}
  CommandWindow {}
  CaptureOverlay {}
  // The "3s" chip's seconds. Its own surface because the overlay is unmapped
  // for the whole countdown -- see CountdownPill.qml.
  CountdownPill {}

  // One instance each, not per-screen: a popover anchors itself to whichever
  // bar item opened it.
  AudioPopover {}
  WifiPopover {}
  TailscalePopover {}
  BluetoothPopover {}
  CalendarPopover {}
  MediaPopover {}
  UpdatesDropdown {}
  PowerPopover {}

  // One instance, like every other popover: it anchors to whichever bar's
  // power button opened it.
  PowerDropdown {}

  // The escalated path's window. Like SettingsWindow it is a Scope around a
  // Loader, so killing the toplevel does not stop it reopening.
  UpdateWizard {}

  // The password prompt, for polkit and for `sudo -A`. One window, always
  // mapped on the overlay layer while a request is live and nowhere at all
  // otherwise -- and it is the shell that owns it now, not hyprpolkitagent
  // (hypr/conf/autostart.lua no longer starts one).
  AuthWindow {}

  // The one top-right toast host: capture card and notification stack.
  NotificationToasts {}

  OsdPill {}
  OsdSources {}   // event sources; without this nothing ever raises a pill

  // One window; SettingsService.openRequested and the "settings" IPC target
  // both route into it. Killing the toplevel does not destroy this object, so
  // reopening works without re-instantiating anything.
  SettingsWindow {}
}
