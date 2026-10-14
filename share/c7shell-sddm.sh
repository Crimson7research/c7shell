# The two things bin/c7shell-bootstrap, bin/c7shell-upgrade and
# bin/c7shell-doctor all have to agree about: what "the current sddm theme" is,
# and what the c7shell drop-in says. Sourced, never executed.
#
# Three hand-kept copies of the parse existed and had already drifted -- only
# bootstrap's stripped the CR off a CRLF sddm.conf, so upgrade and doctor read
# the theme name as "c7shell\r" on such a file and concluded another greeter
# owned the machine.
#
# It lives in share/ rather than bin/ because it is not a command: the package
# installs it to /usr/lib/c7shell, beside the other non-PATH helpers, and the
# three scripts find it with the C7SHELL_LIB stanza each carries.

# The theme sddm will actually use, or the empty string when nothing selects
# one. $1 prefixes /etc so the callers can be exercised against a fake tree.
#
# Last [Theme] Current= wins: sddm reads sddm.conf first, then the drop-ins in
# name order. Parsed in bash rather than with sed and tail, because
# c7shell-bootstrap runs this before anything is installed and only pacman is
# guaranteed to be there.
sddm_theme_current() {
  local prefix=${1:-} f line value=''
  for f in "$prefix"/etc/sddm.conf "$prefix"/etc/sddm.conf.d/*.conf; do
    [[ -f $f ]] || continue
    while IFS= read -r line; do
      line=${line%$'\r'}
      [[ $line =~ ^[[:space:]]*Current[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
      value=${BASH_REMATCH[1]}
      value=${value%"${value##*[![:space:]]}"}
    done < "$f"
  done
  printf '%s' "$value"
}

# The body of /etc/sddm.conf.d/10-c7shell.conf. Named after whichever script is
# writing it, so the file says who to blame.
sddm_dropin_body() {
  cat <<CONF
# Written by ${0##*/}. Delete this file (or add a drop-in that sorts
# after it) to go back to another greeter theme.
[Theme]
Current=c7shell

[General]
# The greeter's hostname line reads the kernel version out of /proc/version and
# the battery out of /sys, both through QML's XMLHttpRequest -- which refuses
# file:// reads unless this is set. Without it the greeter still comes up; the
# line just loses everything but the session name.
GreeterEnvironment=QML_XHR_ALLOW_FILE_READ=1

[Users]
# sddm builds its user list from NSS and then drops anything outside this
# window. A directory backend that derives uids by hash puts them far above
# the 60513 default -- Himmelblau's range is 200000-2000200000 -- so an Entra
# account enumerates perfectly well and is thrown away before it reaches the
# greeter. Widen the window to cover it.
MinimumUid=1000
MaximumUid=2000200000

# Widening it also admits the system accounts that live between the two
# ranges: nobody at 65534, and a daemon running as a systemd DynamicUser.
# Filter those by shell rather than by name or uid -- a DynamicUser's uid is
# assigned at start and moves between reboots, so there is no stable name or
# number to exclude. Real accounts keep a login shell and are unaffected.
HideShells=/usr/bin/nologin,/sbin/nologin,/usr/bin/false,/bin/false
CONF
}
