#!/usr/bin/env bash
# Deadline polling for the VM setup test. Sourced, not executed.
#
# The only place in tests/vm that pauses: every "wait until the VM has
# done X" goes through wait_for, so every wait has a deadline and the
# test suite can run them instantly with a fake clock.

_vt_now() { ${C7VT_CLOCK:-date +%s}; }

# wait_for <seconds> <command> [args...]
wait_for() {
  local limit=$1; shift
  local deadline=$(( $(_vt_now) + limit ))
  until "$@"; do
    (( $(_vt_now) < deadline )) || return 1
    ${C7VT_SLEEP:-sleep} "${C7VT_POLL:-2}"
  done
}
