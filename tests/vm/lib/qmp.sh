#!/usr/bin/env bash
# QMP, the QEMU machine protocol, over socat. Sourced, not executed.
#
# The harness uses QMP for what SSH cannot do: see the screen before anyone
# is logged in, type at the greeter, and power the VM off. Every command
# opens a fresh connection, so there is no session state to get wrong.

# qmp <socket> <json>
qmp() {
  local out
  out=$(printf '%s\n' '{"execute":"qmp_capabilities"}' "$2" \
        | ${C7VT_SOCAT:-socat} -t 5 - "UNIX-CONNECT:$1") || return 1
  printf '%s\n' "$out"
  ! grep -q '"error"' <<<"$out"
}

qmp_screendump() {
  qmp "$1" "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$2\",\"format\":\"png\"}}"
}

# qmp_key <socket> <qcode>... -- the qcodes are pressed together, as a chord.
qmp_key() {
  local sock=$1 keys='' k; shift
  for k; do keys+="${keys:+,}{\"type\":\"qcode\",\"data\":\"$k\"}"; done
  qmp "$sock" "{\"execute\":\"send-key\",\"arguments\":{\"keys\":[$keys]}}"
}

# qmp_type <socket> <text> -- letters and digits only, which is all the
# generated password ever holds; anything else is refused, not guessed at.
qmp_type() {
  local sock=$1 text=$2 i c
  for ((i = 0; i < ${#text}; i++)); do
    c=${text:i:1}
    case $c in
      [a-z0-9]) qmp_key "$sock" "$c" ;;
      [A-Z]) qmp_key "$sock" shift "${c,,}" ;;
      *) echo "qmp_type: cannot type '$c'" >&2; return 2 ;;
    esac || return 1
  done
}

qmp_powerdown() { qmp "$1" '{"execute":"system_powerdown"}'; }
qmp_quit() { qmp "$1" '{"execute":"quit"}'; }
