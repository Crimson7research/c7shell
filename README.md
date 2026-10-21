# c7shell

A Hyprland desktop: the compositor configured in Lua, plus **c7shell** — a
[Quickshell](https://quickshell.org) shell providing the bar, launcher, global
menu, notifications, OSDs, media controls, capture/recording, power menu and
settings app.

```
hypr/                 hyprland.lua + conf/*.lua   (Hyprland 0.56+, Lua config)
quickshell/c7shell/   shell.qml, Modules, Services, Theme, Assets, bin, scripts
bin/                  c7shell-setup (copies the configs into ~/.config),
                      c7shell-doctor (checks the runtime requirements),
                      c7shell-bootstrap (sets up a bare Arch install),
                      c7shell-upgrade (updates an existing install)
PKGBUILD              the package
```

## Install

From a bare Arch install — a CLI, `sudo` and a network connection is enough:

```bash
git clone https://github.com/Jonohas/c7shell.git
cd c7shell
./install.sh         # bootstrap the system, then build and install c7shell
c7shell-setup        # copies the configs into ~/.config (run as your user)
```

`./install.sh` runs four steps, and shows you the plan before it changes
anything:

1. **build tools** — `base-devel`, because `makepkg` will not start without
   them (see below).
2. **`c7shell-bootstrap`** — what a fresh Arch box is missing underneath the
   session: GPU driver, greetd, the pipewire daemons, fonts, an icon theme,
   `xdg-utils`, and the enabled system services. It prints the whole plan and
   waits for a `y` first. `./install.sh --dry-run` shows that plan and stops.
3. **`makepkg -sif`** — builds and installs the package itself. The `-f`
   forces a rebuild even if a package for the same version is already in the
   build directory, so an interrupted build's half-written tarball cannot
   masquerade as the current one.
4. **`c7shell-doctor`** — checks the result and offers the optional programs.

What the bootstrap decides for you, and how to override it:

| Area | What it does |
| --- | --- |
| GPU | `lspci` detection → `mesa` plus `vulkan-intel` / `vulkan-radeon`, or `nvidia-open-dkms` + `nvidia-utils` + the headers of every installed kernel, and `/etc/modprobe.d/c7shell-nvidia.conf` setting `nvidia_drm modeset=1`. A pre-Turing card (GTX 10xx and older) is reported, not guessed at — `nvidia-open-dkms` does not support it. `--no-drivers` opts out. |
| Greeter | `greetd` and `cage`, greetd enabled but not started, so it takes over at the next boot. If gdm/lightdm/sddm/lxdm is already enabled it says so and enables nothing — two display managers fight over the seat and neither comes up. `--no-greeter` opts out. |
| Greeter config | `/etc/greetd/config.toml` running `c7shell-greeter` inside `cage` as the `greeter` user (and letting the greeter read `/proc` for its kernel and battery readout), plus the greeter's log and state paths owned by `greeter`. The greeter ships with the package; only the config is a write to `/etc`, which is why it lives here. `--no-greeter-theme` leaves an existing greetd config alone. |
| Audio | `pipewire`, `pipewire-pulse`, `pipewire-alsa`, `wireplumber` + the user units. `wireplumber` is a session manager, not a sound server: without the daemons under it the volume keys do nothing. |
| Network | `NetworkManager` and `bluetooth` enabled — unless `systemd-networkd` or `iwd` is already driving the network, in which case it warns instead of stacking two managers on one link. |
| Fonts, icons | `ttf-jetbrains-mono` (`Theme.fontMono`), `noto-fonts`, `noto-fonts-emoji`, `hicolor`/`adwaita`/`breeze` icon themes for the launcher's real app icons. |
| Qt app theming | `plasma-integration` + `breeze` + `breeze-icons`, but **only** alongside `dolphin` — installed with it, added if the machine already has it, skipped otherwise. Nothing in the shell needs them; only QWidget-based Qt/KDE apps do. |
| AUR | `paru` (the source package, so it links the libalpm actually installed -- `paru-bin` ships a binary built against one specific `libalpm.so` while declaring `libalpm.so>=14`, so pacman lets it outlive the soname it needs) if no *working* AUR helper is present, for `ttf-space-grotesk` (`Theme.fontDisplay`, not in the official repos; fontconfig falls back without it). `--no-aur` opts out. |
| Extras | `kitty`, `dolphin` (the SUPER+Q / SUPER+E binds), `ddcutil`, `brightnessctl`, `playerctl`, plus `i2c-dev` and the `i2c` group so `ddcutil` can reach external monitors. `--no-extras` opts out. |

It also runs a full `pacman -Syu` first: a partial upgrade is unsupported on
Arch, and a DKMS driver built against the headers of a kernel you are not
running is the same as no driver at all. `--no-upgrade` skips it.

`c7shell-bootstrap` is installed as a command too, so it can be re-run later
(`c7shell-bootstrap --dry-run` to see what it would change).

`install.sh` is a thin wrapper around `makepkg -sif`. On a fresh machine
`makepkg` aborts before it reads the PKGBUILD if the Arch build tools are not
there ("Cannot find the fakeroot binary", "Cannot find the debugedit binary"),
so the wrapper installs `base-devel` first and then hands every argument you
gave it to `makepkg`. If you already have `base-devel`, `makepkg -sif` on its
own still works exactly as before (the `-f` is what keeps a stale tarball from
an interrupted build being installed instead of the current one).

After the build it runs `c7shell-doctor`, which checks everything `pacman`
cannot: that Hyprland is 0.56 or newer (older versions do not read
`hyprland.lua` at all), that quickshell was built with every QML module the
shell imports, that the appmenu daemon's python modules import, that there is
a DRM device to open, and that the configs have reached `~/.config`. Anything
missing is reported with the package that provides it, and
`c7shell-doctor --fix` installs those packages. Run it any time:

```bash
c7shell-doctor            # required + optional checks, exits 1 if something required is missing
c7shell-doctor --quiet    # problems only
c7shell-doctor --fix      # pacman -S --needed the packages behind the failures
c7shell-doctor --optional # pick which of the optional packages to install
```

`install.sh` ends with the `--optional` picker: it lists the optional packages
you do not have — terminal, file manager, `ddcutil`/`brightnessctl`, `upower`,
`playerctl`, `solaar`, `jq`, `kwallet` — with what each one is for, and installs
only the ones you choose (numbers, ranges, `a` for all, enter for none).
Nothing is installed without a selection, and with no terminal to ask on it
says so and moves on. `C7SHELL_SKIP_OPTIONAL=1 ./install.sh` skips the
question entirely.

A session that shows a black screen and drops straight back to the greeter is
almost always one of the things it checks — most often that `c7shell-setup`
was never run, since the package installs to `/usr/share/c7shell` and neither
hyprland nor quickshell reads config from there.

The PKGBUILD is a git source: `makepkg` clones the branch named in it and
builds *that*, not the working tree you run `./install.sh` from. Local commits
and pulled feature branches therefore do nothing until they are pushed and
named — to build one, `C7SHELL_BRANCH=my-branch ./install.sh`.

Then log out and pick the **c7shell** session, or run `start-hyprland` from a
TTY. `start-hyprland` rather than `Hyprland`: since 0.53 it is the launcher
Hyprland expects, it exports the session and portal environment, and it gives
you crash recovery and safe mode. Launching the binary directly makes Hyprland
warn that it "was started without start-hyprland".

The shell installs as a [named Quickshell
config](https://quickshell.org/docs/master/guide/distribution/) at
`~/.config/quickshell/c7shell`, so it never collides with a Quickshell config
you already have. It runs as `qs -c c7shell`, and every `qs ipc call` in
`hypr/conf/binds.lua` carries the same `-c c7shell`.

Everything comes from the Arch `extra` repository — no AUR helper needed.

## Qt and KDE app colours

The shell's palette lives in `~/.config/hypr/appearance.json`; Qt and KDE apps
read `~/.config/kdeglobals`. `quickshell/c7shell/scripts/c7shell-theme-export.py`
writes the second from the first, writes the lock screen's palette
(`hyprlock-palette.conf`, see [Lock screen](#lock-screen)) beside it, and emits
the signal that repaints running apps — the settings app runs it whenever the
accent or variant changes, and `c7shell-setup` seeds it once at install time so
a fresh session is not a themed shell beside a stock-looking dolphin.

The accent is either one of `palette.json`'s five `accentChoices` or any
six-digit hex. The last swatch in the settings app's accent row is the way to
the second: it opens a saturation/value square, a hue strip and a hex field
(`Modules/Settings/AccentPicker.qml`), and writes the same
`appearance.json` key the presets do. Everything downstream reads that value
and not the shortlist — the exporter above, hyprland's active border, the lock
screen palette and the greeter — so a custom colour reaches all of them.

This only applies if you actually run a QWidget-based Qt/KDE app. The shell
itself is QML — the bar, launcher and settings window take none of this — so
the packages below are `optdepends`, the bootstrap installs them only together
with `dolphin`, and `c7shell-doctor` skips the whole section on a machine with
no such app rather than warning about something it has no use for. Picking
`dolphin` in `c7shell-doctor --optional` brings them along, since dolphin
without them is dolphin that ignores the palette.

When one is installed, three things have to be in place, and `c7shell-doctor`
checks all three:

- `QT_QPA_PLATFORMTHEME=kde` — set in `hypr/conf/environment.lua`. Not `qt6ct`:
  KDE apps ignore qt6ct's palette and come up stock light while their
  KColorScheme parts stay dark, which is the mixed look.
- **`plasma-integration`** — provides the `kde` platform theme plugin
  (`/usr/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.so`). Without
  it the variable above does nothing at all.
- **`breeze`** — the Qt6 widget style that platform theme draws with.

## The theme apps detect

Separate from all of the above: GTK, Electron, Chromium and libadwaita apps do
not read kdeglobals — they ask `xdg-desktop-portal` for
`org.freedesktop.appearance color-scheme`, and a desktop that never answers is
read as "no preference", which every one of them renders as light. That is why a
dark shell used to sit next to a light browser.

There is no separate setting for it: the **Appearance** theme implies it. A
light theme tells apps to prefer light; dark and oled tell them to prefer dark.
The export script derives it from `theme` in `~/.config/hypr/appearance.json`
and publishes it where the answer is looked up:

- the GSettings key `org.gnome.desktop.interface color-scheme`
  (`prefer-dark` / `prefer-light`), which the portal reports over the bus;
- `gtk-application-prefer-dark-theme` in `~/.config/gtk-{3,4}.0/settings.ini`,
  for GTK apps that never ask the portal. `gtk-theme-name` is left alone — the
  preference says which face an app should wear, not which theme you run.

Two packages carry it, and `c7shell-doctor` checks both: **`xdg-desktop-portal-gtk`**,
because `xdg-desktop-portal-hyprland` implements screencast and not `Settings`
(the `hyprland-portals.conf` that c7shell-setup puts in
`~/.config/xdg-desktop-portal` names `gtk` as the fallback, so installing it is
the whole fix), and `gsettings-desktop-schemas`, which it depends on.

## The file picker

The "open file" dialog most apps show is not theirs: they ask
`xdg-desktop-portal` for a `FileChooser`, and whichever backend answers draws
it. Left to the `gtk` fallback above, that is the GTK picker — which looks
nothing like dolphin (`SUPER+E`). The shipped
`~/.config/xdg-desktop-portal/hyprland-portals.conf` routes `FileChooser` to
the `kde` backend instead: the KDE file dialog, with the same KIO places
sidebar and the same kdeglobals palette as dolphin. That backend is
**`xdg-desktop-portal-kde`**, a package dependency; without it the portal
falls back to the gtk picker on its own, and `c7shell-doctor` warns.

The portal reads that file once, when it starts, so a fresh install or an
upgrade that writes it does not change anything until the portal is restarted —
until then every picker is still the gtk one, with nothing on screen to say so.
`c7shell-doctor` warns when the running portal is older than the config:

```bash
systemctl --user restart xdg-desktop-portal
```

The settings app asks for the same dialog: **Appearance → wallpaper →
"browse →"** opens the portal's `FileChooser`, filtered to the image formats
hyprpaper can actually load — `png`, `jpg`, `jpeg`, `bmp`, `webp`, `jxl`, `svg`,
the ones `libhyprgraphics` links a decoder for. It opens in the folder the
current wallpaper came from, and cancelling it leaves that wallpaper alone. The
path field beside the button still takes a typed or pasted path.

Quickshell 0.3.1 has no generic DBus client, so the call is made by
`quickshell/c7shell/scripts/c7shell-filechooser.py`, which prints the chosen
path. It is usable on its own:

```bash
python3 ~/.config/quickshell/c7shell/scripts/c7shell-filechooser.py \
  --title 'Choose a wallpaper' --images --current-folder ~/Pictures
```

To export by hand at any time — kdeglobals, the lock screen palette and the
preference, all three:

```bash
python3 ~/.config/quickshell/c7shell/scripts/c7shell-theme-export.py
```

### Where the wallpaper comes from

hyprpaper draws it, except on a virtual GPU, where it cannot: hyprpaper renders
through hyprtoolkit, which has no software path and commits a dmabuf for every
wallpaper. `aquamarine` cannot build a DRM renderer to import that buffer —

```
CDRMRenderer(drm): Can't create renderer, no matching devices found
drm: initMgpu: no renderer
```

— the compositor drops the connection, and hyprtoolkit aborts on the way out
rather than exiting. So hyprpaper is not merely wallpaper-less on those
machines: it **SIGABRTs on the first wallpaper request of the session** and is
gone, which looks exactly like a setting that saves and does nothing.
`LIBGL_ALWAYS_SOFTWARE` does not help — the buffer is allocated on the device
the compositor advertises, not by GL.

`hypr/conf/gpu.lua` decides which it is (the same `vmwgfx` / `vboxvideo` /
`virtio_gpu` test that picks llvmpipe for clients). On a virtual GPU
`conf/autostart.lua` leaves hyprpaper out, `conf/environment.lua` exports
`C7SHELL_WALLPAPER=shell`, and the shell paints the wallpaper itself on the
background layer — it renders with llvmpipe and the compositor imports its
buffers happily, which the bar has been proof of all along. Everywhere else
nothing changes and the shell maps no window at all. `c7shell-doctor` reports
which one is in force.

## Global menu

Apps that export a menu bar over dbusmenu — dolphin and other Qt/KDE apps —
show it in the top bar next to the workspaces, and hide their own. That is a
choice, not a fixture: **settings → topbar → global menu** turns it off, and
the setting persists in `~/.config/hypr/shell.json`.

The switch is the `com.canonical.AppMenu.Registrar` bus name itself, not just
the chips in the bar. An app hands its menu bar over precisely because it finds
that name owned, so a shell that only stopped drawing the export would leave
dolphin with no menus anywhere. Off tells `c7shell-appmenud` to release the
name; on tells it to take it back.

A toolkit asks for the registrar once, when a window's menu bar is created, and
caches the answer — so windows that are already open keep the menu bar they
started with. Reopen them to see the change.

## Lock screen

`SUPER+L`, the power menu's lock row and hypridle's 5-minute idle timeout all
run `hyprlock`, configured by `hypr/hyprlock.conf` — near-black, one centered
field, the desktop blurred behind it, so it reads as the same surface as the
greeter.

Its accent is the one picked in the settings app. hyprlang does no variable
expansion and cannot read JSON, so hyprlock cannot follow `appearance.json` on
its own; what it can do is `source` a file, and the export script above writes
`~/.config/hypr/hyprlock-palette.conf` from the same accent and variant it
writes kdeglobals from. `hyprlock.conf` keeps the default crimson palette as a
fallback — hyprlang takes the last definition of a variable, so the sourced file
wins, and a machine that has never exported gets one `ERR` in the log rather
than a lock screen with no colours in it. The glow behind it follows the accent
too: `c7shell-lock` renders that PNG at lock time (see below) and reads
`appearance.json` for the tint.

That file is **not optional**. hyprlock refuses to start without a config
(`Config path error: Could not find config`) and searches only
`XDG_CONFIG_HOME`, `HOME`, `XDG_CONFIG_DIRS` and `/etc/xdg` — the copy the
hyprlock package leaves in `/usr/share/hypr` is never found. Without it `SUPER+L`
appears to do nothing, and less visibly, hypridle's `lock_cmd` and
`before_sleep_cmd` fail too, so the machine idles and suspends **unlocked**.
`c7shell-doctor` fails on that, naming the consequence, and
`tests/test-lockscreen.sh` has hyprlock itself validate the file (against a
Wayland display that does not exist, so it parses the config and dies on the
connection instead of locking your screen) — which is what catches a key being
renamed under it on a hyprlock upgrade.

If a lock screen ever does come up wrong, `Ctrl+Alt+F2` to a TTY and
`pkill hyprlock` is the way out.

## Greeter

The login screen is `c7shell-greeter`, a Qt/QML greetd greeter running inside
the `cage` kiosk compositor. Its QML lives in `sddm/themes/c7shell`, drawn from
the same tokens as the shell: near-black ground with two crimson glows and a
56px grid, one glass card with the avatar, the password field and a caps-lock
line, a user list and a session picker as side panels, and the shell's pill bar
along the bottom (session · layout · network · battery · sleep / reboot /
shutdown).
Reboot and shutdown are hold-to-confirm, the same 600 ms as the shell's power
menu. `Up`/`Down` moves through the users, `F1` cycles the session, `F2` the
keyboard layout, `Esc` clears the field. Three failed attempts add a 30-second
cooldown.

The network pill needs a hand: the greeter is QML with no D-Bus binding,
running as the `greeter` user before any session exists, so it cannot ask
NetworkManager what it is connected to. The package installs
`/usr/lib/NetworkManager/dispatcher.d/50-c7shell-greeter`, which NetworkManager
runs as root on every connection change — including before login — to publish
the connection name to `/run/c7shell/network` (mode 644). The greeter polls that
file. Delete the script and the pill simply never appears; nothing else changes,
and nothing is exposed that `nmcli dev` would not already tell any local user.
The name is NetworkManager's profile name, which for a wifi network added the
usual way is its SSID.

The binary is `/usr/bin/c7shell-greeter` and its QML is installed to
`/usr/share/c7shell/greeter` by the package — not copied into `~/.config`,
because the greeter runs as the `greeter` user before any session exists and
cannot read your home directory. Pointing greetd at it is a write to
`/etc/greetd/config.toml`, done by `c7shell-bootstrap` on a fresh machine and by
`c7shell-upgrade` on an existing one; `c7shell-doctor` reports which display
manager the machine uses and whether greetd runs the c7shell greeter.

The greeter writes its stderr to `/var/log/c7greeter.log`, and remembers the
last account in `/var/lib/c7shell-greeter`. Set `C7_GREETER_DEBUG=1` in the
greetd command to add a trace of the greetd conversation (message types only,
never a secret). Keyboard layout switching does not work under cage: the layout
pill shows the `KEYMAP` from `/etc/vconsole.conf`, for display only.

Per-machine settings live in `/usr/share/c7shell/greeter/theme.conf`:

| Key | Default | What it does |
| --- | --- | --- |
| `background` | *(empty)* | Wallpaper behind the card. Empty means the generated backdrop. Point it at the file hyprpaper uses for a continuous boot → desktop image — it has to be readable by the `greeter` user, so under `/usr/share`, not in `$HOME`. |
| `grid` | `true` | The 56px grid. Ignored when a wallpaper is set. |
| `userList` | `auto` | `auto` shows the user panel on a multi-account machine, `always` always, `never` only when you click "switch user". |
| `allowManualLogin` | `true` | An "other…" row for an account the greeter does not list — the only way in for a directory user who has not signed in on this machine before. |
| `maxAttempts`, `cooldownSeconds` | `3`, `30` | The greeter's own lockout, separate from and looser than `pam_faillock`'s. |

To see it without logging out:

```bash
qml6 tests/greeter-preview.qml                       # the resting state
qml6 tests/greeter-preview.qml -- --failed --sessions # failed auth, picker open
qml6 tests/greeter-preview.qml -- --typed 7            # the dot row and caret
```

The greeter keeps the display manager's objects out of everything but
`Main.qml` (`greetd-greeter/Main.qml`), so `Greeter.qml` takes plain properties
and the preview can feed it mock models. `tests/test-greeter.sh` renders every
state offscreen and fails on any QML warning — the greeter's own log is easy to
miss, so a broken binding there is invisible until someone tries to log in.

## Updating

```bash
c7shell-upgrade              # rebuild the package from git, then refresh ~/.config
c7shell-upgrade --dry-run    # show what both halves would change
```

`pacman -Syu` cannot do this: `c7shell` is built locally, so there is no
repository to upgrade it from. `c7shell-upgrade` keeps a build clone under
`~/.cache/c7shell`, rebuilds when the installed commit is behind (the commit is
baked into `pkgver`), and then refreshes the configs.

The config half is pacnew-style, because `~/.config` is yours to edit:

| Your file | What happens |
| --- | --- |
| untouched since it was installed | updated in place |
| edited by you, and changed upstream | **kept**, new version written beside it as `<file>.new`, listed at the end (exit 4) |
| edited by you, unchanged upstream | left alone |
| new upstream | added |
| dropped upstream, untouched by you | removed |
| dropped upstream, edited by you | kept, reported |

Which case a file falls into comes from a manifest of the hashes last
installed (`~/.local/state/c7shell/manifest`, written by `c7shell-setup` and
`c7shell-upgrade`). An install predating that manifest has nothing to compare
against, so every difference is treated as your edit and kept — the safe
direction, at the cost of more `.new` files on the first run.

`--package-only` and `--config-only` run one half. To replace your copies
outright instead, `c7shell-setup --force` still backs them up to
`.bak-<stamp>` first; without `--force` it leaves every existing part alone,
so it can never eat local edits by accident. It exits 3 when it copied nothing
and 4 when it copied only some parts.

To switch to another setup, `c7shell-setup --uninstall` takes c7shell's config
out of the way. It reads the same manifest. Each shipped file you have not
edited is removed, with any `<file>.new` beside it. The run0 `sudo` line setup
added to `~/.bashrc` or `~/.zshrc` is removed too. Edited files, files you
added, and `.bak-<stamp>` backups stay, and it lists the edited ones. It leaves
the run0 lines in your arch-update and paru configs, because it cannot tell
them from your own choice. Add `--dry-run` to see the list first.

## What is where

| Path | Purpose |
| --- | --- |
| `hypr/hyprland.lua` | entry point; requires each `conf/*.lua` module |
| `hypr/conf/binds.lua` | keybinds — media keys and brightness route through the shell's IPC |
| `hypr/conf/autostart.lua` | starts the appmenu daemon, `qs`, hyprpaper, hypridle, solaar |
| `hypr/hyprlock.conf` | the lock screen; mandatory, hyprlock will not start without it |
| `hypr/xdph.conf` | points xdph's screencopy picker at the shell's own picker |
| `quickshell/c7shell/shell.qml` | shell entry point |
| `quickshell/c7shell/preview.qml` | preview harness; must sit here to resolve `qs.*`, not shipped |
| `plugin/` | the `C7` QML module in C++; installed to `/usr/lib/qt6/qml/C7` |
| `tools/qml-imports` | builds the module tree editors resolve `qs.*` against |
| `tools/qml-preview` | runs one component in a window of its own |
| `quickshell/c7shell/Services/` | brightness, network, bluetooth, audio, notifications, capture |
| `quickshell/c7shell/bin/screenshare-picker.sh` | xdph `custom_picker_binary` wrapper |
| `quickshell/c7shell/scripts/c7shell-appmenud.py` | `com.canonical.AppMenu.Registrar` for the global menu |
| `~/.config/hypr/shell.json` | shell preferences the settings app writes (global menu) |
| `~/.config/hypr/hyprlock-palette.conf` | generated: the lock screen's colours, from `appearance.json` |
| `greetd-greeter/` | `c7shell-greeter`: the greetd client, models and the `Main.qml` that wires them into `Greeter.qml` |
| `sddm/themes/c7shell/` | the greeter's shared QML (`Greeter.qml` and its components) |
| `sddm/themes/c7shell/theme.conf` | greeter settings (wallpaper, user list, lockout) |
| `share/c7shell-network-dispatcher` | NetworkManager dispatcher script; publishes the connection for the greeter's network pill |
| `bin/c7-authd` | the password prompt's backend: polkit agent + the `sudo -A` askpass socket |
| `bin/c7-askpass` | what `SUDO_ASKPASS` points at, so sudo asks through the shell |
| `quickshell/c7shell/Modules/Auth/` | the 280px prompt panel and the window it lives in |
| `bin/c7up` | the system-update backend: dry run, transaction, pacnew review, orphan cleanup — NDJSON, unprivileged |
| `bin/c7up-root` | the only part of it that runs as root; takes a fixed verb, never a command line |
| `share/polkit-1/actions/io.crimson7.c7shell.policy` | the polkit action that authorises it |
| `quickshell/c7shell/Modules/Updates/` | the update dropdown's run view, the wizard, the toast, the pacnew and orphan cards |
| `/etc/greetd/config.toml` | runs the c7shell greeter; written by bootstrap/upgrade, not by the package |

## Password prompts

Everything that needs your password uses one panel: polkit (pkexec, systemctl,
GNOME Disks, the update flow's own root helper) and `sudo -A`. It names what is
being asked for in plain language, keeps the polkit action id visible
underneath, and says which user is authenticating.

The shell is the session's polkit authentication agent — `bin/c7-authd`
registers as one at startup, which is why `hypr/conf/autostart.lua` no longer
launches hyprpolkitagent. hyprpolkitagent stays installed as a fallback: if
c7-authd will not start, the shell launches it after three failed attempts, on
the grounds that an unstyled dialog beats a desktop where `pkexec` silently
does nothing.

Only one prompt is on screen at a time. A second request queues behind the
first and says so; the queued one is not started, so there is never more than
one live PAM conversation.

For sudo, `hypr/conf/environment.lua` sets `SUDO_ASKPASS=/usr/bin/c7-askpass`.
sudo consults that for `sudo -A`, and when there is no terminal to read from —
so a GUI program that shells out to sudo gets the prompt instead of failing.
Plain `sudo` in a terminal is left alone: it has a terminal, so it reads from
it. To route those through the shell too:

```
echo "Path askpass /usr/bin/c7-askpass" | sudo tee -a /etc/sudo.conf
```

That is a line in a file the sudo package owns, so neither the package nor
`c7shell-bootstrap` writes it for you; `c7shell-doctor` prints it and stops
there.

### Upgrading an existing install

`c7shell-upgrade` covers both halves: it rebuilds the package from git (which
brings `c7-authd` and `c7-askpass`) and refreshes `~/.config`. Then log out and
back in — until you do, hyprpolkitagent is still running from the old session
and holds the registration.

The one thing to watch is a half-upgraded config. The refresh deliberately does
not overwrite a file you have edited: it parks the new version as `<file>.new`
and leaves yours alone. If that happens to `shell.qml`, the package brings the
prompt's backend while your config has no `AuthWindow` to draw it — the shell
becomes the polkit agent and then shows nothing, so `pkexec` waits on a window
that does not exist. `c7shell-doctor` reports exactly that, and the fix is to
merge the parked file:

```
diff -u ~/.config/quickshell/c7shell/shell.qml{,.new}
```

`c7shell-upgrade --take-shipped` resolves every such conflict in favour of the
shipped version, which is what you want for configs you did not deliberately
edit.

## System updates

The package badge in the bar is the whole flow. Behind it a dry run has
already happened, so by the time you open it, it knows which of two things it
is:

- **nothing needs a decision** — the dropdown does the update itself, in
  place. One click, no window, no step counter. Close it and the run keeps
  going; the badge becomes a progress ring.
- **something does** — the same button opens a review window instead, holding
  only the steps that apply. A kernel or driver, a package replacement, a new
  signing key, a changed AUR `PKGBUILD`, a `.pacnew`, an unsatisfiable
  dependency: any of those escalates, and nothing else does.

The run never stops to ask a question. Everything answerable is answered
before it starts, and anything left over — configs to review, a pending
reboot, services wanting a restart, packages nothing depends on any more — is
collected at the end. "Later" parks it in **settings → system** with an amber
dot on the badge rather than dropping it.

Orphans are the one item that is offered rather than escalated: `arch-update`
asks about them after every terminal run, and they are the same list
(`pacman -Qtdq`), but an orphan costs disk and nothing else. Making one a
decision would put a question in front of the one-click path on every machine
that has ever removed a package, so they are offered rather than escalated:
one card — total size, names spelled out, `remove them` / `keep them` — at
three widths. In the dropdown "clean up" unfolds it in place rather than
opening a window, the same way the update itself runs in place; the wizard's
cleanup step and **settings → system** show the same card. Removal is
`pacman -Rns` on the set, and root re-derives the orphan list before it
removes anything.

`arch-update` is underneath: c7up reads its config (which AUR helper, which
elevation command) and writes its state files, so the bar and a terminal run
of `arch-update` never disagree about what is pending. What `arch-update`
cannot provide is a parseable interface — every stage of it is a `read -rp`
against a TTY, and its output is localised, coloured and column-aligned — so
`bin/c7up` is the machine-readable half. Its header documents the split.
`arch-update` itself is still one click away: the failure state's "open in
terminal" runs it.

`c7shell-bootstrap` installs everything this needs; nothing here is a manual
step.

Elevation goes through one polkit action (`io.crimson7.c7shell.update`), and a
run asks for your password exactly once however long it takes. It needs root
three times — the repo sync, the AUR helper's install of what it built, and the
post-run service check — and those can be an hour apart, so what `pkexec`
authorises is not a verb but `c7up-root session`: one root process that stays
alive for the run and takes verbs down a pipe. (Three separate `pkexec` calls
leaned on `auth_admin_keep` instead, which polkit keeps for five minutes, so
any update longer than that asked again halfway through.) `bin/c7up-root` is
still the trust boundary and still takes a fixed verb, one per line, through
the same checks — the AUR helper's install step included, via
`--sudo bin/c7up-sudo`, rather than a password prompt on a TTY the shell does
not have.

## Optional pieces

`kitty` (`SUPER+Q`), `dolphin` (`SUPER+E`), `ddcutil` (external-monitor
backlight over DDC/CI), `brightnessctl` (internal panel), `playerctl` (media
keys), `upower` (battery), `solaar` (Logitech gestures — needs your own
`~/.config/solaar/rules.yaml`). All are `optdepends`; the shell degrades
without them.

The update flow's dependencies are not in this list — `c7shell-bootstrap`
installs them, because the badge is not something the shell degrades
gracefully without: `pacman-contrib` (`checkupdates` for the rootless dry run,
`pacdiff` for the pacnew list) from the repos, and `arch-update` (the shared
config and state) plus `checkservices` (the post-update restart check) from
the AUR. `--no-aur` drops the last two and the flow still works — what is lost
is agreement with a terminal `arch-update` about what is pending, and the
service-restart step.

`flatpak` stays genuinely optional: install it and its updates join the same
flow, skip it and that source does not appear.

## Working on the QML

Two tools, neither of them shipped. Both exist because quickshell invents the
`qs.` import prefix at runtime and nothing outside quickshell knows about it.

`tools/qml-imports` builds a throwaway module tree in `~/.cache/c7shell/` that
qmllint, qmlls and any editor driven by them can resolve `qs.*` against. Without
it a single failed import turns every `Theme.text` in a file into "unqualified
access" and every component into an unknown type. Re-run it after adding,
renaming or deleting a `.qml` file, and point the editor's QML import path at
what it prints.

```bash
tools/qml-imports
```

`tools/qml-preview` runs one component in a window of its own, without starting
the shell. Use it for anything you would otherwise have to restart the whole bar
to look at.

```bash
tools/qml-preview --list
tools/qml-preview qs.Common/BatteryGlyph --zoom 8
tools/qml-preview qs.Modules.Settings/SettingsWindow --show appearance
```

`--list` names every previewable component as `<module>/<Type>`. Bar glyphs are
around 20px, so `--zoom` is usually the difference between seeing the change and
not. `--show` is for a component that opens itself rather than being drawn into
a frame: `SettingsWindow`, the popovers and the launcher build nothing until
something calls `show()`, and its argument goes straight through — for the
settings window that is a sidebar key (`wifi`, `bluetooth`, `audio`,
`appearance`, `system`, `displays`, `power`, `notifications`, `topbar`,
`keybinds`).

You do not need to say which kind you are looking at. The harness builds the
component and checks it for `anchors`: a visual `Item` is reparented into a
`FloatingWindow` sized to it, and a `Scope` that owns its own window is left
alone as the top level it already is.

Under Hyprland the window is tiled like any other, so a glyph at `--zoom 8`
gets a whole tile with a screen of empty space around it. `preview.qml` asks for
a size that fits the component, but that is a hint a tiling compositor is free
to ignore. Every preview window titles itself `preview: <target>`, which is
enough to float them with a rule in `hypr/conf/rules.lua` shaped like the
`float-c7shell-settings` one already there — quickshell cannot set a per-window
class, so a title match is the only identity available.

Editing a previewed file reloads it in place, the same as the running shell.

### When the preview will not build

`unknown target` after adding a component means nothing more than a typo — the
registry is regenerated on every run, so a name that is spelled right is there.

Singletons are absent by design. `Theme` and everything under `Services/` is
reached as `Theme.accent`, never instantiated, and `Theme {}` is a hard error.

`Created graphical object was not placed in the graphics scene` is expected on
every visual component and is not a fault. The component exists for one tick
under the root `Scope` before it is reparented, and there is no way to know
which kind it is until it exists.

`Could not register notification server` is also expected: your running shell
already owns that D-Bus name, and `NotifServer` is pulled in transitively by the
service graph.

What will not work is reaching a component by path. A `Loader` pointed at
`Common/BatteryGlyph.qml` loads the file but its sibling `Icon` stops resolving,
and `Qt.createQmlObject("import qs.Common; ...")` fails outright with `module
"qs.Common" is not installed`. Quickshell generates a directory's qmldir only
for directories the entry file references *statically*, so anything named by a
string at runtime reaches a module that was never built. That is the whole
reason `PreviewRegistry.qml` is generated rather than resolved on the fly, and
why `preview.qml` sits beside `shell.qml` instead of in a subdirectory of its
own — `qs` is whatever directory quickshell registers under the file `-p` points
at.

## Working on the C7 plugin

`plugin/` is the shell's C++ side: the `C7` QML module, built with CMake
against Qt 6 (`docs/architecture.md` says what belongs there). The package
installs it to `/usr/lib/qt6/qml/C7`. To run the shell against your build
instead, build into `build/` and put its module directory first on the import
path:

```bash
cmake -S plugin -B build -G Ninja && cmake --build build && ctest --test-dir build
qs kill -c c7shell
QML_IMPORT_PATH=$PWD/build/qml qs -c c7shell
```

Qt searches `QML_IMPORT_PATH` before its own directory, so the built `C7`
wins over the installed one. Rebuild and restart `qs` after each C++ change:
unlike the QML, a loaded plugin does not reload in place. `build/` is ignored
by git.

## Tests

```bash
tests/test-setup.sh
tests/test-doctor.sh
tests/test-bootstrap.sh
tests/test-upgrade.sh
tests/test-greeter.sh
tests/test-lockscreen.sh
tests/test-packaging.sh
tests/test-c7-plugin.sh
tests/test-filechooser.sh
tests/test-wallpaper.sh
tests/test-c7up.sh
tests/test-updates.sh
tests/test-authd.sh
tests/test-auth.sh
tests/test-wifi.sh
```

The two lua suites run from `hypr/`, since the config resolves its own
`require("conf/...")` relative to the working directory:

```bash
cd hypr && lua ../tests/test-monitors.lua && lua ../tests/test-gpu.lua
```
