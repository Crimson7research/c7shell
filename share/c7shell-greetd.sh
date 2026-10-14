# Shared by c7shell-bootstrap, c7shell-upgrade and c7shell-doctor: the greetd
# config c7shell wants, in one place rather than three copies that drift.
#
# /etc/greetd/config.toml is
# system state, so a package must not write it -- bootstrap does it on a fresh
# machine and upgrade on an existing one, the same arrangement sddm's drop-in
# has.

GREETD_CONFIG=${GREETD_CONFIG:-/etc/greetd/config.toml}

# Which VT greetd runs the greeter on. 7 by convention: below it are the text
# consoles a user switches to with ctrl+alt+F1..F6.
GREETD_VT=${GREETD_VT:-7}

greetd_config_body() {
  cat <<CONF
# Written by ${0##*/}. c7shell on greetd.
#
# The greeter is a wayland client inside cage, so there is no X server, no DRM
# master to hand over and no VT shared between greeter and session. greetd
# drives only the PAM conversation, and never answers a prompt on the greeter's
# behalf -- so a mistyped PIN costs one attempt rather than being replayed, and
# a second question (enrolling a PIN, changing an expired password) reaches the
# user instead of looping.

[terminal]
vt = ${GREETD_VT}

[default_session]
# QML_XHR_ALLOW_FILE_READ: the greeter's hostname line reads /proc/version and
# the battery out of /sys through QML's XMLHttpRequest, which refuses file://
# reads without it.
#
# stderr goes to a log rather than the console: it would otherwise print onto
# the VT the greeter is about to hand to the session. Set C7_GREETER_DEBUG=1
# there to add a trace of the greetd conversation (message types only, never a
# secret).
command = "sh -c 'export QML_XHR_ALLOW_FILE_READ=1; exec cage -s -- /usr/bin/c7shell-greeter >>/var/log/c7greeter.log 2>&1'"
user = "greeter"
CONF
}

# True when greetd is configured to run our greeter.
greetd_is_c7shell() {
  local root=${1:-}
  grep -q 'c7shell-greeter' "${root}${GREETD_CONFIG}" 2>/dev/null
}

# Which display manager the machine is set up to use, as a bare word: greetd,
# sddm, the name of whatever else owns display-manager.service, or nothing at
# all. systemd keeps that as a symlink, which is the only place the answer is
# unambiguous -- several display managers can be installed at once, and more
# than one can even be enabled.
c7shell_display_manager() {
  local root=${1:-}
  local link=$root/etc/systemd/system/display-manager.service
  [[ -L $link ]] || return 0
  local target
  target=$(readlink "$link" 2>/dev/null) || return 0
  target=${target##*/}
  printf '%s\n' "${target%.service}"
}
