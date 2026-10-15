# Maintainer: Jonohas <https://github.com/Jonohas>
pkgname=c7shell
pkgver=0.1.0.r72.g90bf261
pkgrel=1
pkgdesc='c7shell desktop environment: Hyprland (lua config) with the c7shell Quickshell shell'
# Not any: the C7 QML plugin (plugin/) is compiled code.
arch=('x86_64')
url='https://github.com/Jonohas/c7shell'
license=('MIT')
# Hyprland 0.56+ is required: the config is hyprland.lua, not hyprland.conf.
depends=(
  'hyprland>=0.56'
  'quickshell'
  'hypridle'
  'hyprlock'
  'hyprpaper'
  'hyprpicker'
  # No longer started at login -- the shell is the polkit agent now
  # (bin/c7-authd, and hypr/conf/autostart.lua no longer launches this). It
  # stays a hard dependency because Services/AuthService.qml falls back to it
  # when c7-authd will not start: an unstyled dialog is worth having when the
  # alternative is a desktop where pkexec silently does nothing.
  'hyprpolkitagent'
  # The login screen is part of the shell, not an optional extra: this package
  # ships /usr/bin/c7shell-greeter, and that binary speaks greetd's protocol and
  # nothing else. greetd hands the greeter the PAM conversation one message at a
  # time instead of replaying a single stored secret, which is why a mistyped
  # PIN costs one attempt here and a second prompt -- enrolling a PIN, changing
  # an expired password -- reaches the user rather than looping. cage is the
  # kiosk compositor it runs the greeter inside.
  #
  # Which greeter greetd actually runs is still a write to /etc that a package
  # must not make; c7shell-bootstrap does that.
  'greetd'
  'cage'
  'qt6-declarative'
  'wireplumber'
  'networkmanager'
  'bluez'
  'bluez-utils'
  'python'
  'python-dbus'
  # The app-menu registrar needs it -- and so does c7-authd, which drives the
  # PAM conversation through libpolkit-agent rather than reimplementing the
  # setuid helper protocol by hand.
  'python-gobject'
  'grim'
  # The delayed screenshot captures the frame BEFORE the rectangle is drawn --
  # a hover menu is gone by the time you move the pointer to draw around it --
  # so scripts/c7shell-crop.py cuts the region out of that frame afterwards,
  # through gdk-pixbuf. It arrives transitively via gtk3 on most machines;
  # naming it here is what stops that being luck.
  'gdk-pixbuf2'
  'wf-recorder'
  'wl-clipboard'
  # The capture toast's "open" button launches an image viewer on the shot it
  # just took. With none installed the handler falls back to xdg-open, whose
  # image/png default on a bare Wayland session is as often the browser as a
  # viewer (issue #56) -- so name one. imv is Wayland-native and themeable
  # (~/.config/imv/config); a different viewer set in shell.json's imageViewer
  # wins over it. CaptureService auto-detects imv when imageViewer is empty.
  'imv'
  'libnotify'
  'xdg-desktop-portal-hyprland'
  # xdph implements screencast, not Settings -- and Settings is the interface an
  # app asks whether the desktop prefers dark through. Without a backend that
  # implements it, everything that detects a system theme comes up light next to
  # a dark shell (implied by appearance.json's theme, exported by
  # scripts/c7shell-theme-export.py). hyprland-portals.conf already names gtk as
  # the fallback backend, so installing it is the whole fix.
  'xdg-desktop-portal-gtk'
  # The shipped xdg-desktop-portal/hyprland-portals.conf routes FileChooser to
  # the kde backend, so file pickers are the KDE file dialog -- same KIO
  # sidebar and kdeglobals palette as dolphin (SUPER+E). Without the package
  # the portal silently falls back to the gtk picker and the config line does
  # nothing.
  'xdg-desktop-portal-kde'
)
optdepends=(
  # What settings -> system -> power drives. Without it the page and the battery
  # popover both show the "tuned is not running" card and everything else --
  # the battery readout, the idle timings, the charge limit -- carries on.
  'tuned: power profiles in settings -> system -> power'
  'kitty: terminal bound to SUPER+Q'
  'dolphin: file manager bound to SUPER+E, and the capture toast'"'"'s "folder" button (auto-detected; override with shell.json fileManager)'
  # QT_QPA_PLATFORMTHEME=kde (hypr/conf/environment.lua) only means something
  # with plasma-integration's platform theme plugin, and it only matters if a
  # QWidget-based Qt/KDE app is installed to be themed. The shell itself is
  # QML, so a machine without such apps gains nothing from these three.
  'plasma-integration: makes Qt/KDE apps (dolphin) follow the c7shell palette'
  'breeze: Qt6 widget style that platform theme draws with'
  'breeze-icons: icon theme Qt/KDE apps expect'
  'hyprlauncher: fallback launcher (the shell provides its own)'
  'ddcutil: DDC/CI backlight control for external monitors'
  # Settings -> displays -> eye saver. Without it the toggle says so and does
  # nothing; the gamma of every output is this one process's to hold.
  'hyprsunset: the eye saver (blue light filter) in settings -> displays'
  'brightnessctl: backlight control for internal panels'
  'upower: battery readout in the bar'
  # Also the lock screen's now-playing line: the bar reads MPRIS over D-Bus
  # itself, but hyprlock cannot, so c7shell-lock-info shells out to this.
  'playerctl: media keys (XF86Audio{Next,Prev,Play,Pause}) and the lock screen now-playing line'
  'solaar: Logitech device support, autostarted if present'
  'jq: helper scripting'
  # AUR-only, so it cannot be a depends= even though the update flow now leans
  # on it hard: makepkg resolves dependencies through pacman alone and an
  # unresolvable name aborts the whole build. Install it with an AUR helper:
  #   paru -S arch-update
  # Without it the bar still counts updates and c7up still applies them -- what
  # is lost is the shared config (which AUR helper, which elevation command)
  # and the state directory the two halves agree through.
  'arch-update: shared config and state for the update flow (AUR)'
  # What c7up shells out to. pacman-contrib carries checkupdates and pacdiff:
  # the rootless sync the whole dry run is built on, and the pacnew list step 3
  # is built on.
  'pacman-contrib: the rootless update check (checkupdates) and pacnew list (pacdiff)'
  'paru: AUR updates in the same flow as the repo ones'
  'flatpak: flatpak updates in the same flow'
  'checkservices: the "these services want a restart" step after an update'
  # Not required: c7up walks $PAGER, less, most, more and finally cat, so the
  # log and diff views work on a machine with none of them. less is simply the
  # nicest of those, and it is not part of base.
  'less: a scrolling pager for the update log and PKGBUILD diffs'
  # Any one of meld / kdiff3 / neovim / vim makes the wizard's "merge..." work;
  # c7up walks them in that order after $DIFFPROG. meld is named here because
  # this is a graphical desktop and a three-pane window is what the button
  # promises, but nothing needs it specifically.
  'meld: three-pane merge for the update wizard'"'"'s pacnew review'
  'kwallet: secret storage unlocked at login by conf/autostart.lua'
  # Settings -> fingerprints enrolls through its CLI, the lock screen unlocks
  # through its D-Bus API, and c7shell-bootstrap adds its PAM module to polkit.
  'fprintd: fingerprint unlock on the lock screen and the password prompt'
)
# lua: tests/test-monitors.lua loads conf/monitors.lua against a stubbed hl.
# cmake and ninja build the C7 plugin against qt6-base and qt6-declarative,
# the second of which depends= already pulls in.
makedepends=('git' 'lua' 'cmake' 'ninja' 'qt6-base')
# makepkg builds the branch cloned here, NOT the working tree you run it from:
# a local commit or a pulled feature branch has no effect until it is pushed and
# named here. Override for testing a branch before it lands:
#   C7SHELL_BRANCH=my-branch ./install.sh
_branch=${C7SHELL_BRANCH:-main}
source=("$pkgname::git+$url.git#branch=$_branch")
sha256sums=('SKIP')
install="$pkgname.install"

pkgver() {
  cd "$srcdir/$pkgname"
  printf '0.1.0.r%s.g%s' "$(git rev-list --count HEAD)" "$(git rev-parse --short HEAD)"
}

build() {
  cd "$srcdir/$pkgname"
  # The C7 QML module the shell imports. None: makepkg's CFLAGS decide the
  # optimisation, not a CMake build type.
  cmake -S plugin -B build -G Ninja -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build build

  # The greetd greeter. greetd speaks only an authentication protocol -- no
  # user list, no session list, no power actions and no theme config -- so the
  # greeter is a binary that supplies those and drives the conversation.
  cmake -S greetd-greeter -B build-greeter -G Ninja \
    -DCMAKE_BUILD_TYPE=None -DCMAKE_INSTALL_PREFIX=/usr
  cmake --build build-greeter
}

check() {
  cd "$srcdir/$pkgname"
  # The plugin's own suite, first: a failing library or module test stops the
  # package before anything else runs.
  ctest --test-dir build --output-on-failure --no-tests=error
  # Every one of these stubs the machine it tests (pacman, lspci, systemctl,
  # $HOME), so they are safe to run mid-build and mean the package cannot be
  # built out of a tree whose scripts are broken. The two exceptions still are:
  # test-greeter.sh renders the greeter's QML with qml6 offscreen, and
  # test-lockscreen.sh has hyprlock validate its own config against a Wayland
  # display that does not exist -- neither can touch a running session, and both
  # skip themselves when the tool is not installed (in a clean chroot, neither
  # is).
  for t in tests/*.sh; do "$t"; done
  # From hypr/, because these resolve their own require("conf/...") relative to
  # the working directory.
  cd hypr
  lua ../tests/test-monitors.lua
  lua ../tests/test-gpu.lua
  # The pure modules conf/monitors.lua is built on: the json decoder, the JSON
  # encoder the state file needs, and the validators that stand between a
  # hand-edited displays.json and hl.monitor().
  lua conf/selftest.lua
}

package() {
  cd "$srcdir/$pkgname"

  # The configs are shipped read-only under /usr/share and copied into the
  # user's ~/.config by c7shell-setup: hyprland and quickshell both read
  # their config only from $XDG_CONFIG_HOME, and the user is expected to edit
  # what lands there. The shell ships as the named quickshell config
  # `quickshell/c7shell`, so it lands in ~/.config/quickshell/c7shell and
  # leaves any other config in ~/.config/quickshell alone (`qs -c c7shell`).
  install -dm755 "$pkgdir/usr/share/$pkgname"
  cp -a hypr quickshell xdg-desktop-portal "$pkgdir/usr/share/$pkgname/"
  # Dev-facing only, and setup copies whatever is here into the user's config.
  rm -rf "$pkgdir/usr/share/$pkgname/quickshell/c7shell/docs"
  # check() runs the tests in this tree first, and any that runs a .py script
  # leaves a __pycache__ whose bytecode embeds $srcdir.
  find "$pkgdir/usr/share/$pkgname" -type d -name __pycache__ -prune -exec rm -rf {} +
  # The preview harness has to live beside shell.qml to resolve `qs.*`, but it
  # is a development tool -- and PreviewRegistry.qml is generated, so a stale
  # one would ship naming components the release no longer has.
  rm -f "$pkgdir/usr/share/$pkgname/quickshell/c7shell/preview.qml" \
        "$pkgdir/usr/share/$pkgname/quickshell/c7shell/PreviewRegistry.qml"
  chmod -R u=rwX,go=rX "$pkgdir/usr/share/$pkgname"
  chmod 755 "$pkgdir/usr/share/$pkgname/quickshell/c7shell/scripts/c7shell-appmenud.py" \
            "$pkgdir/usr/share/$pkgname/quickshell/c7shell/bin/screenshare-picker.sh"

  install -Dm755 bin/c7shell-setup "$pkgdir/usr/bin/c7shell-setup"
  # Autostarted by hypr/conf/autostart.lua; relaunches the shell after a crash.
  install -Dm755 bin/c7shell-session "$pkgdir/usr/bin/c7shell-session"
  # Checks what depends= cannot: the Hyprland version, the QML modules
  # quickshell was built with, the DRM device, and whether the configs have
  # been copied into ~/.config yet.
  install -Dm755 bin/c7shell-doctor "$pkgdir/usr/bin/c7shell-doctor"
  # Re-runnable after install: drivers, greeter, services and fonts are system
  # state a package must not touch itself, so it stays a command you invoke.
  install -Dm755 bin/c7shell-bootstrap "$pkgdir/usr/bin/c7shell-bootstrap"
  # The only way an installed c7shell gets a newer version: pacman has no
  # repository to upgrade a locally built package from.
  install -Dm755 bin/c7shell-upgrade "$pkgdir/usr/bin/c7shell-upgrade"
  # The two live lines on the lock screen (now playing, network/battery).
  # hyprlock.conf calls it by name from a label's cmd[]: hyprlang does no
  # variable expansion, so the config cannot spell out a path under $HOME, and
  # a copy shipped beside the config would arrive without its execute bit --
  # c7shell-upgrade writes new files with a shell redirect. PATH solves both.
  install -Dm755 bin/c7shell-lock-info "$pkgdir/usr/bin/c7shell-lock-info"
  # What SUPER+L, the power menu and hypridle actually run. It draws the glow
  # and the grid the design doc puts behind the lock screen -- an image sized to
  # the monitor, which is something only a program running at lock time can
  # author -- and then execs hyprlock. Any failure falls through to plain
  # hyprlock, so the lock screen never depends on the decoration working.
  install -Dm755 bin/c7shell-lock "$pkgdir/usr/bin/c7shell-lock"

  # The update flow's backend. c7up is the unprivileged half -- the dry run,
  # all the parsing, the NDJSON the shell binds to -- and is on PATH because
  # the shell, the wizard's "view diff" and the pacnew "merge…" all invoke it
  # by name. The other two are reached only through pkexec and have no business
  # on anyone's PATH.
  install -Dm755 bin/c7up "$pkgdir/usr/bin/c7up"
  # The trust boundary: it takes a fixed verb, never a command line, and the
  # polkit action below names it by absolute path.
  install -Dm755 bin/c7up-root "$pkgdir/usr/lib/c7shell/c7up-root"
  # What the AUR helper's --sudo lands on, so paru's install step goes through
  # the same authorisation as the repo half instead of a password prompt on a
  # TTY the shell does not have.
  install -Dm755 bin/c7up-sudo "$pkgdir/usr/lib/c7shell/c7up-sudo"
  # The power page's root half: the charge limit, the lid action and enabling
  # tuned.service. Same trust boundary and the same place as c7up-root -- a
  # fixed verb, never a command line, and nowhere near anyone's PATH.
  install -Dm755 bin/c7power-root "$pkgdir/usr/lib/c7shell/c7power-root"
  # Sourced by c7shell-bootstrap, c7shell-upgrade and c7shell-doctor: the
  # theme parse and the drop-in body they all have to agree about. Not on PATH
  # and not executable -- it is a library, so it sits with the other non-PATH
  # helpers and the three scripts find it there once installed.
  # The same, for greetd. /etc/greetd/config.toml is system state a package must
  # not write, so the body lives here and bootstrap/upgrade install it.
  install -Dm644 share/c7shell-greetd.sh "$pkgdir/usr/lib/c7shell/c7shell-greetd.sh"
  # Sourced from ~/.zshrc and ~/.bashrc (c7shell-setup adds the line): an
  # interactive `sudo CMD` becomes `run0 CMD`, which asks through polkit.
  install -Dm644 share/sudo-run0.sh "$pkgdir/usr/lib/c7shell/sudo-run0.sh"

  # auth_admin_keep, so one authorisation covers the repo half and the AUR half
  # of the same run. Without this pkexec falls back to its generic action,
  # whose dialog names a binary rather than the task.
  install -Dm644 share/polkit-1/actions/io.crimson7.c7shell.policy \
    "$pkgdir/usr/share/polkit-1/actions/io.crimson7.c7shell.policy"

  # The password prompt's backend. c7-authd registers as the session's polkit
  # authentication agent and serves the socket c7-askpass connects to, so
  # pkexec, `sudo -A` and c7up's own root helper all prompt through the shell's
  # panel. Both are on PATH by name: the shell spawns c7-authd by name, and
  # hypr/conf/environment.lua points SUDO_ASKPASS at c7-askpass by absolute
  # path -- hyprlang does no variable expansion, so it cannot name one under
  # $HOME.
  install -Dm755 bin/c7-authd "$pkgdir/usr/bin/c7-authd"
  install -Dm755 bin/c7-askpass "$pkgdir/usr/bin/c7-askpass"
  install -Dm644 share/c7shell.desktop \
    "$pkgdir/usr/share/wayland-sessions/c7shell.desktop"


  # The greetd greeter: a binary, and the QML in sddm/themes/c7shell with
  # greetd-greeter/Main.qml in place of the sddm one. Main.qml is the adapter --
  # everything it adapts to lives in that one file -- so the rest is copied as
  # it is.
  DESTDIR="$pkgdir" cmake --install build-greeter
  install -dm755 "$pkgdir/usr/share/c7shell/greeter"
  cp -a sddm/themes/c7shell/. "$pkgdir/usr/share/c7shell/greeter/"
  install -Dm644 greetd-greeter/Main.qml "$pkgdir/usr/share/c7shell/greeter/Main.qml"
  chmod -R u=rwX,go=rX "$pkgdir/usr/share/c7shell/greeter"

  # Where the greeter remembers the last account, and where it writes its log.
  # Both are written as user `greeter`, into directories root owns, so both
  # have to exist and be owned by it before greetd starts: without the log the
  # greeter's stderr redirect fails before cage is exec'd and the login screen
  # never draws; without the directory the greeter runs but never preselects an
  # account.
  #
  # The ownership cannot be set here -- makepkg has no such user -- and not by
  # a tmpfiles entry either: `greeter` comes with greetd, which is an optdepend,
  # and an entry naming a missing user fails the pacman hook on every machine
  # running another display manager. c7shell.install does it, guarded on the
  # user existing, and c7shell-bootstrap does it too.
  install -dm755 "$pkgdir/var/lib/c7shell-greeter"

  # What the greeter's network pill reads. The greeter is QML with no D-Bus
  # binding, running as the greeter user before any session exists, so it cannot
  # ask NetworkManager what it is connected to -- this runs as root on every
  # connection change and writes the answer where the greeter can read it.
  # /usr/lib, not /etc/NetworkManager/dispatcher.d: it is a program, and
  # NetworkManager has read both directories since 1.36.
  install -Dm755 share/c7shell-network-dispatcher \
    "$pkgdir/usr/lib/NetworkManager/dispatcher.d/50-c7shell-greeter"

  # The settings window is a launchable app, so its entry and icon go where
  # every launcher already looks. They also travel inside the shipped config
  # above (the shell reads its own Assets), but a copy under ~/.config is not
  # on any launcher's search path -- these two lines are what make the app
  # appear in the launcher's "apps" tab, wofi, rofi and any app grid.
  install -Dm644 quickshell/c7shell/Assets/applications/c7shell-settings.desktop \
    "$pkgdir/usr/share/applications/c7shell-settings.desktop"
  install -Dm644 quickshell/c7shell/Assets/applications/c7shell-settings.svg \
    "$pkgdir/usr/share/icons/hicolor/scalable/apps/c7shell-settings.svg"
  install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"
  # MIT is not one of the licences pacman ships in /usr/share/licenses/common,
  # so the text has to travel with the package.
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"

  # The C7 QML module, to /usr/lib/qt6/qml/C7, where Qt finds every system
  # module: the shell's `import C7` needs nothing on QML_IMPORT_PATH.
  DESTDIR="$pkgdir" cmake --install build
}
