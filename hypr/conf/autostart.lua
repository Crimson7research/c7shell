-------------------
---- AUTOSTART ----
-------------------

-- See https://wiki.hypr.land/Configuring/Basics/Autostart/

local programs = require("conf/programs")
local gpu = require("conf/gpu")

-- Autostart necessary processes (like notifications daemons, status bars, etc.)
-- Or execute your favorite apps at launch like this:
--
hl.on("hyprland.start", function ()
  -- QT_WAYLAND_DISABLE_WINDOWDECORATION: the settings window is chromeless by
  -- design; hyprland draws no server-side titlebar, this stops Qt drawing CSD.
  --
  -- c7shell-appmenud goes first and deliberately: it owns
  -- com.canonical.AppMenu.Registrar, and Qt only exports an app's menu bar if
  -- that name is already on the bus -- a decision each app makes once, at its
  -- first menu bar, and caches. Anything started before the daemon shows no
  -- menus until it is relaunched. Order against qs does not matter; the shell
  -- retries the daemon's socket with backoff.
  --
  -- The shell runs under c7shell-session, which relaunches it after a crash
  -- (and with it c7-authd, the polkit agent) and gives up on a crash loop.
  --
  -- hyprpaper is left out on a virtual GPU, where it does not merely fail to
  -- draw but SIGABRTs on the first wallpaper request (conf/gpu.lua has the
  -- whole trace). The shell draws the wallpaper instead, and knows to because
  -- conf/environment.lua sets C7SHELL_WALLPAPER=shell.
  local paper = gpu.wallpaper_backend() == "hyprpaper" and "hyprpaper & " or ""
  hl.exec_cmd("python3 $HOME/.config/quickshell/c7shell/scripts/c7shell-appmenud.py & c7shell-session & " .. paper .. "hypridle")
end)

-- pam_kwallet_init drains the socket pam_kwallet5 opened at login
-- (/run/user/$UID/kwallet5.socket) and starts kwalletd6 with the login
-- password, so the wallet is already open before anything asks for a secret.
-- Plasma runs this from plasma-kwallet-pam.service; that unit is
-- WantedBy=graphical-session.target, and nothing activates that target here,
-- so without this line kwalletd6 only ever starts via dbus activation with no
-- key -- which is what makes it prompt.
--
-- hyprpolkitagent is NOT started here any more. The shell registers as the
-- session's polkit authentication agent itself (bin/c7-authd, owned by
-- Services/AuthService.qml), so that pkexec, systemctl and c7up's own root
-- helper all prompt with the c7shell panel rather than a second, differently
-- styled dialog. Only one agent may hold the registration, so starting both
-- would mean whichever won the race drew the prompt.
--
-- It stays a depends= of the package: AuthService falls back to launching it
-- if c7-authd will not start, on the grounds that an unstyled dialog beats a
-- desktop where pkexec silently does nothing.
hl.on("hyprland.start", function ()
  hl.exec_cmd("/usr/lib/pam_kwallet_init")
end)

-- Logitech MX Master 3S: thumb-button workspace gestures (rules in ~/.config/solaar/rules.yaml)
hl.on("hyprland.start", function ()
  hl.exec_cmd("solaar --window=hide")
end)
