#!/usr/bin/env bash
# Self-check for bin/c7-authd and bin/c7-askpass. Run it directly:
#   tests/test-authd.sh
#
# The polkit half cannot be exercised here: registering as the session's
# authentication agent needs polkitd on the system bus, and a real PAM
# conversation needs a real password. What this file does cover is everything
# either side of that -- the queue, the NDJSON contract the shell binds to, the
# askpass socket, and the checks that stop a prompt being raised on behalf of a
# caller nobody can name. --no-polkit is in the daemon for exactly this reason.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
authd=$here/../bin/c7-authd
askpass=$here/../bin/c7-askpass
tmp=$(mktemp -d)
daemon_pid=''
helper_pids=()   # anything else started in the background, blocked or not
cleanup() {
  # Any of these may have exited already; under set -e a failed kill would
  # end the trap before the rest of it ran.
  [[ -n $daemon_pid ]] && kill "$daemon_pid" 2>/dev/null || true
  ((${#helper_pids[@]})) && kill "${helper_pids[@]}" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

sock=$tmp/askpass.sock
out=$tmp/out.ndjson
err=$tmp/err.log
cmds=$tmp/cmds

# The command channel stays open for the daemon's whole life: a plain file
# redirect gives it EOF immediately and it shuts down before the first test.
mkfifo "$cmds"
: > "$out"
"$authd" --no-polkit --socket "$sock" < "$cmds" > "$out" 2> "$err" &
daemon_pid=$!
exec 9> "$cmds"

send() { printf '%s\n' "$1" >&9; }

# Wait for a line matching a pattern to appear in the event stream, so the test
# never races the daemon. Everything here is sub-second in practice; the
# timeout only decides how a genuine hang is reported.
wait_for() {
  local pattern=$1 label=$2 i
  for ((i = 0; i < 100; i++)); do
    grep -q -- "$pattern" "$out" && return 0
    sleep 0.05
  done
  fail "timed out waiting for $label
events so far:
$(cat "$out")
stderr:
$(cat "$err")"
}

# wait_for for any file and any test: polls until the check passes. Set dump
# to a file to have its contents, as they are at the timeout, in the FAIL.
wait_until() {
  local label=$1 i; shift
  for ((i = 0; i < 200; i++)); do "$@" && return 0; sleep 0.05; done
  fail "timed out waiting for $label${dump:+
$(cat "$dump" 2>&1)}"
}
gone() { ! kill -0 "$1" 2>/dev/null; }
# A daemon run to completion. One that does not exit is a named FAIL, not a
# suite that hangs. Callers redirect its stderr to a file, so the FAIL goes to
# the test's own stderr, saved as fd 3.
exec 3>&2
authd_once() {
  local rc=0
  # -k: the daemon handles SIGTERM in its main loop, which a hang has stopped.
  timeout -k 2 10 "$authd" "$@" 9>&- || rc=$?
  ((rc != 124 && rc != 137)) || { exec 2>&3; fail "c7-authd $* did not exit"; }
  return "$rc"
}

event_id() {
  # The id of the first event matching the pattern.
  grep -m1 -- "$1" "$out" | sed 's/.*"id":"\([^"]*\)".*/\1/'
}

# --- 1. it announces itself before anything else --------------------------
# The shell keys its whole state off this line: without it, it cannot tell a
# daemon that came up without polkit from one that has not started yet.
wait_for '"ev":"ready"' 'the ready event'
head -1 "$out" | grep -q '"ev":"ready"' || fail "ready was not the first event:
$(cat "$out")"
head -1 "$out" | grep -q '"polkit":false' \
  || fail "--no-polkit still reported itself as the polkit agent: $(head -1 "$out")"
head -1 "$out" | grep -q "\"askpass\":\"$sock\"" \
  || fail "ready did not name the socket it is listening on: $(head -1 "$out")"

[[ -S $sock ]] || fail 'no askpass socket was created'
# It carries passwords in both directions; anyone else's read is a password.
perm=$(stat -c '%a' "$sock")
[[ $perm == 600 ]] || fail "askpass socket is mode $perm, expected 600"
dirperm=$(stat -c '%a' "$(dirname "$sock")")
[[ $dirperm == 7?? ]] || fail "askpass socket directory is mode $dirperm, expected 7xx"

# --- 2. a request arrives, is drawn, and answers its caller ---------------
# Every one of these runs with 9>&-: a child that inherits the command channel
# holds the fifo's write end open, and section 7 -- which closes fd 9 to stand
# in for the shell dying -- would then wait forever for an EOF that cannot
# arrive.
#
# Stands in for sudo: c7-askpass refuses to prompt unless its own parent is
# sudo, so the test gives it one. A copy of the shell named `sudo` is enough --
# /proc/<pid>/comm is what the check reads, and what an attacker could not
# forge without already being able to run a process of that name as this user.
mkdir -p "$tmp/fakebin"
cp "$(command -v bash)" "$tmp/fakebin/sudo"
# A quoted heredoc: everything the wrapper needs arrives in the environment
# instead, so nothing in it is expanded twice. (An unquoted one ate the `$?`
# below, and the wrapper then reported success for every cancelled prompt.)
cat > "$tmp/run-askpass" <<'SH'
#!/usr/bin/env bash
# Execs the copy named sudo, which then RUNS c7-askpass rather than exec'ing
# it: the check reads the parent's comm, so the parent has to still be there.
# The trailing exit is load-bearing twice over -- bash execs the last command
# of a -c script without forking, which would leave c7-askpass with no sudo
# parent at all, and it is what carries c7-askpass's own status out, which
# several assertions below turn on.
exec "$FAKE_SUDO" -c '"$0" "$@"; exit $?' "$ASKPASS" "Password:"
SH
export FAKE_SUDO=$tmp/fakebin/sudo ASKPASS=$askpass
chmod +x "$tmp/run-askpass"

C7_AUTHD_SOCKET=$sock "$tmp/run-askpass" > "$tmp/secret.out" 2> "$tmp/askpass.err" 9>&- &
askpass_pid=$!

wait_for '"ev":"request"' 'the sudo request'
req=$(event_id '"ev":"request"')
[[ -n $req ]] || fail "the request event carried no id: $(cat "$out")"

grep -q '"kind":"sudo"' "$out" || fail "the request was not marked as a sudo prompt:
$(cat "$out")"
# The design's first rule: always name the caller. A sudo prompt that cannot
# say which command it is for is the shape of a phishing dialog.
grep -q '"command":' "$out" || fail "the sudo request named no command:
$(cat "$out")"
# It must become the head of the queue on its own -- nothing else is in front.
wait_for '"ev":"active"' 'the request becoming active'
grep -q '"ev":"prompt"' "$out" || fail "no prompt event, so the field never unlocks:
$(cat "$out")"

send "{\"cmd\":\"respond\",\"id\":\"$req\",\"secret\":\"hunter2\"}"
wait_for '"ev":"close"' 'the request closing'

wait_until 'c7-askpass to exit after its answer' gone "$askpass_pid"
wait "$askpass_pid" || fail "c7-askpass exited non-zero after a successful answer:
$(cat "$tmp/askpass.err")"
[[ $(cat "$tmp/secret.out") == hunter2 ]] \
  || fail "the secret did not reach sudo: got $(cat "$tmp/secret.out")"

# The identity row names the user and stops there. It carried a "wheel" chip
# once, filled in by looking up the account's group membership -- which reads
# next to a password field as "this is why you may answer this", while being a
# fact about the account and not about the request. polkit resolves identities
# to a user before the agent sees them, so there is no group to report; putting
# one there again would be asserting a reason nothing checked.
grep -q '"group"' "$out" \
  && fail "an event carries a group field again:\n$(grep '\"group\"' "$out")"
grep -q '"user":' "$out" || fail "no event names the user authenticating:\n$(cat "$out")"

# --- 3. the secret is never written anywhere it could be read -------------
# Not to stderr, not to the event stream. This is the one assertion in the file
# that is about a leak rather than a behaviour, so it is checked over the whole
# transcript rather than one line.
grep -q hunter2 "$out" && fail "the password was echoed back into the event stream"
grep -q hunter2 "$err" && fail "the password was logged to stderr"

# --- 4. cancelling refuses the caller rather than hanging it --------------
C7_AUTHD_SOCKET=$sock "$tmp/run-askpass" > "$tmp/secret2.out" 2>/dev/null 9>&- &
askpass2=$!
for ((i = 0; i < 100; i++)); do
  req2=$(grep '"ev":"request"' "$out" | sed -n '2s/.*"id":"\([^"]*\)".*/\1/p')
  [[ -n $req2 ]] && break
  sleep 0.05
done
[[ -n ${req2:-} ]] || fail "the second request never arrived:
$(cat "$out")"

send "{\"cmd\":\"cancel\",\"id\":\"$req2\"}"
wait_until 'a cancelled c7-askpass to exit' gone "$askpass2"
rc=0; wait "$askpass2" || rc=$?
((rc != 0)) || fail 'a cancelled prompt still handed sudo a password'
[[ ! -s $tmp/secret2.out ]] || fail 'a cancelled prompt wrote something to stdout'

# --- 5. only sudo may raise a sudo prompt ---------------------------------
# Run directly, so the parent is this shell rather than sudo. A helper that
# prompts for anyone is a password box any program can raise on demand.
rc=0
C7_AUTHD_SOCKET=$sock "$askpass" "Password:" > "$tmp/direct.out" 2> "$tmp/direct.err" || rc=$?
((rc != 0)) || fail 'c7-askpass prompted for a caller that was not sudo'
grep -qi 'refusing' "$tmp/direct.err" \
  || fail "the refusal did not say why: $(cat "$tmp/direct.err")"
[[ ! -s $tmp/direct.out ]] || fail 'the refused call still wrote to stdout'

# --- 6. no shell, no prompt, and a way out --------------------------------
# sudo -A with a dead socket must fail with something a person can act on, not
# hang or print a stack trace.
rc=0
C7_AUTHD_SOCKET=$tmp/nothing.sock "$tmp/run-askpass" > /dev/null 2> "$tmp/nosock.err" || rc=$?
((rc != 0)) || fail 'c7-askpass succeeded with no daemon listening'
grep -q 'c7shell' "$tmp/nosock.err" \
  || fail "the no-daemon message does not say what is missing: $(cat "$tmp/nosock.err")"
grep -q 'without -A' "$tmp/nosock.err" \
  || fail "the no-daemon message offers no way to authenticate: $(cat "$tmp/nosock.err")"
grep -q Traceback "$tmp/nosock.err" && fail "c7-askpass crashed instead of failing:
$(cat "$tmp/nosock.err")"

# --- 6b. a caller that gives up takes its prompt with it ------------------
# A Ctrl-C'd `sudo -A` closes its end of the socket. Its prompt must close, or
# it sits on screen with nobody to answer and blocks every request queued
# behind it. Request ids count up from r1, so the next one is known ahead.
next_id() { echo "r$(($(grep -c '"ev":"request"' "$out") + 1))"; }
caller() { C7_AUTHD_SOCKET=$sock "$tmp/run-askpass" > /dev/null 2>&1 9>&- & }
# Either may already be gone -- the fake sudo exits as soon as its child does.
hang_up() { pkill -P "$1" 2>/dev/null || true; kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
fds_before=$(ls "/proc/$daemon_pid/fd" | wc -l)
head_id=$(next_id); caller; head_pid=$!
wait_for "\"ev\":\"active\",\"id\":\"$head_id\"" 'the first caller to become active'
queued_id=$(next_id); caller; queued_pid=$!
wait_for "\"ev\":\"request\",\"id\":\"$queued_id\"" 'the second caller to queue'
last_id=$(next_id); caller; last_pid=$!
wait_for "\"ev\":\"request\",\"id\":\"$last_id\"" 'the third caller to queue'
# One queued behind the prompt on screen gives up. The prompt on screen must
# not be activated again: the shell would take that as a new prompt starting,
# and stop accepting the password already being typed.
hang_up "$queued_pid"
wait_for "\"ev\":\"close\",\"id\":\"$queued_id\",\"ok\":false" 'a queued caller that gave up to close'
# The one on screen gives up: it closes, and the queue moves on.
hang_up "$head_pid"
wait_for "\"ev\":\"close\",\"id\":\"$head_id\",\"ok\":false" 'the prompt of a caller that gave up to close'
# Counted only now: a wrong re-activation would have been written straight
# after the queued caller's close, and the head's close came later still.
(($(grep -c "\"ev\":\"active\",\"id\":\"$head_id\"" "$out") == 1)) \
  || fail "a queued caller giving up re-activated the prompt on screen:
$(cat "$out")"
wait_for "\"ev\":\"active\",\"id\":\"$last_id\"" 'the queue to move past a caller that gave up'
# A sudo prompt is live only once it is on screen. The shell clears its prompt
# on "active", so the one promoted here needs its "prompt" after that -- and
# one still queued must not send one over the prompt on screen.
line_of() { grep -n -- "$1" "$out" | tail -1 | cut -d: -f1; }
wait_for "\"ev\":\"prompt\",\"id\":\"$last_id\"" 'the promoted request to prompt'
(($(line_of "\"ev\":\"prompt\",\"id\":\"$last_id\"") > $(line_of "\"ev\":\"active\",\"id\":\"$last_id\""))) \
  || fail "a sudo request promoted to the head got no prompt after it became active:
$(cat "$out")"
grep -q "\"ev\":\"prompt\",\"id\":\"$queued_id\"" "$out" \
  && fail "a sudo request still in the queue sent a prompt over the one on screen:
$(cat "$out")"
send "{\"cmd\":\"cancel\",\"id\":\"$last_id\"}"
wait_until 'the cancelled third caller to exit' gone "$last_pid"
wait "$last_pid" 2>/dev/null || true

# The raw clients below take turns with the test through fifos. The test opens
# each read-write, so no open ever waits for the other end, and it reads with a
# time limit: a client that died early is a named FAIL, not a hang.
handshake() { mkfifo "$tmp/$1"; exec {fd}<>"$tmp/$1"; printf -v "$2" %s "$fd"; }
heard() { read -t 10 -r _ <&"$1" || fail "no word from $2"; }

# Anything a caller sends after its request is not it leaving: the request
# stays open and still gets its answer.
handshake go go_fd; handshake sent sent_fd
chatty_id=$(next_id)
python3 - "$sock" "$tmp/go" "$tmp/sent" > "$tmp/chatty.out" 9>&- <<'PY' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(json.dumps({"prompt": "Password:", "command": "chatty"}).encode() + b"\n")
go, sent = open(sys.argv[2]), open(sys.argv[3], "w")
go.readline()                     # the test says when the request is on screen
s.sendall(b"more\n")
sent.write("sent\n"); sent.flush()   # ...and hears when the bytes are out
print(json.loads(s.makefile().readline()).get("secret", ""))
PY
chatty_pid=$!; helper_pids+=("$chatty_pid")
wait_for "\"ev\":\"active\",\"id\":\"$chatty_id\"" 'a caller that keeps talking to become active'
echo go >&"$go_fd"
heard "$sent_fd" 'the talking caller'
send "{\"cmd\":\"respond\",\"id\":\"$chatty_id\",\"secret\":\"hunter3\"}"
wait_until 'the talking caller to get its answer' gone "$chatty_pid"
wait "$chatty_pid" || true
[[ $(cat "$tmp/chatty.out") == hunter3 ]] \
  || fail "bytes after a request were taken for the caller leaving:
$(cat "$out")"
# A caller that talked first and then hangs up still takes its prompt with it.
talker_id=$(next_id)
handshake go2 go2_fd; handshake sent2 sent2_fd
python3 - "$sock" "$tmp/go2" "$tmp/sent2" 9>&- <<'PY' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(json.dumps({"prompt": "Password:", "command": "talker"}).encode() + b"\n")
go, sent = open(sys.argv[2]), open(sys.argv[3], "w")
go.readline()
s.sendall(b"more\n")
sent.write("sent\n"); sent.flush()
go.readline()                     # the bytes are out; now leave
s.close()
PY
talker_pid=$!; helper_pids+=("$talker_pid")
wait_for "\"ev\":\"active\",\"id\":\"$talker_id\"" 'a talking caller to become active'
echo go >&"$go2_fd"
heard "$sent2_fd" 'the caller that talks and then hangs up'
echo go >&"$go2_fd"
wait_until 'the caller that hangs up to exit' gone "$talker_pid"
wait "$talker_pid" || true
wait_for "\"ev\":\"close\",\"id\":\"$talker_id\",\"ok\":false" 'a caller that talked and then hung up to close'

# A caller that shuts down only its writing half withdraws too: it has said
# all it will, and the socket is the contract.
half_id=$(next_id)
python3 - "$sock" > "$tmp/half.out" 9>&- <<'PY' &
import json, socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.sendall(json.dumps({"prompt": "Password:", "command": "half"}).encode() + b"\n")
s.shutdown(socket.SHUT_WR)
print(repr(s.recv(4096)))          # still reading: EOF once the daemon lets go
PY
half_pid=$!; helper_pids+=("$half_pid")
wait_for "\"ev\":\"close\",\"id\":\"$half_id\",\"ok\":false" 'a caller that shut down its writing half to close'
wait_until 'the half-closed caller to be let go' gone "$half_pid"
wait "$half_pid" || true
[[ $(cat "$tmp/half.out") == "b''" ]] || fail "a half-closed caller was not let go: $(cat "$tmp/half.out")"

# --- 6c. a second daemon leaves the first one's socket alone -------------
# A second shell, or a stray restart, starts another c7-authd. Taking over the
# socket would strand the first daemon's callers: it is still alive, but no
# new sudo can reach it, and the socket it removes on the way out is then the
# new daemon's. The second one serves no askpass and says so.
ino=$(stat -c %i "$sock")
authd_once --no-polkit --socket "$sock" < /dev/null > "$tmp/second.out" 2> "$tmp/second.err"
[[ -S $sock && $(stat -c %i "$sock") == "$ino" ]] \
  || fail "a second daemon replaced or removed the first one's socket:
$(cat "$tmp/second.err")"
grep -q '"askpass":""' "$tmp/second.out" \
  || fail "the second daemon claimed a socket it does not serve: $(cat "$tmp/second.out")"
grep -q 'already serving' "$tmp/second.err" \
  || fail "the second daemon did not say why it serves no askpass: $(cat "$tmp/second.err")"
kill -0 "$daemon_pid" 2>/dev/null || fail "the first daemon did not survive the second one's probe:
$(cat "$err")"

# Nor does a daemon told not to serve one at all.
authd_once --no-polkit --no-askpass --socket "$tmp/unused.sock" < /dev/null > "$tmp/noaskpass.out" 2>/dev/null
grep -q '"askpass":""' "$tmp/noaskpass.out" \
  || fail "--no-askpass still named a socket: $(cat "$tmp/noaskpass.out")"

# A second daemon takes the socket over once its holder is gone: a restarted
# shell's daemon can start while the old one is still on its way out. The
# holder here counts the retries' probes, so "still alive" is waited for, not
# slept through.
python3 - "$tmp/handover.sock" "$tmp/probes" 9>&- <<'PY' &
import socket, sys
srv = socket.socket(socket.AF_UNIX); srv.bind(sys.argv[1]); srv.listen(8)
n = 0
while True:
    c, _ = srv.accept(); c.close(); n += 1
    open(sys.argv[2], "w").write(f"{n}\n")
PY
holder_pid=$!; helper_pids+=("$holder_pid")
wait_until 'the holder to bind its socket' test -S "$tmp/handover.sock"
ino=$(stat -c %i "$tmp/handover.sock")
mkfifo "$tmp/later.cmds"
C7_AUTHD_ASKPASS_RETRY_MS=100 \
  "$authd" --no-polkit --socket "$tmp/handover.sock" < "$tmp/later.cmds" > "$tmp/later.out" 2> "$tmp/later.err" 9>&- &
later_pid=$!; helper_pids+=("$later_pid")
exec 6> "$tmp/later.cmds"
# The holder rewrites the file, so it can be read empty in between.
probes() { local n; n=$(cat "$tmp/probes" 2>/dev/null) || true; ((${n:-0} >= $1)); }
dump=$tmp/later.err wait_until 'five probes of a live holder' probes 5
[[ $(stat -c %i "$tmp/handover.sock") == "$ino" ]] \
  || fail "the later daemon took the socket over while its holder was alive: $(cat "$tmp/later.err")"
kill "$holder_pid"; wait "$holder_pid" 2>/dev/null || true   # its socket file stays, refusing
dump=$tmp/later.err wait_until 'the later daemon to take the socket over' grep -q 'serving askpass at' "$tmp/later.err"
[[ -S $tmp/handover.sock && $(stat -c %i "$tmp/handover.sock") != "$ino" ]] \
  || fail "the later daemon said it took the socket over, but did not bind it"
exec 6>&-
wait_until 'the later daemon to exit' gone "$later_pid"
wait "$later_pid" 2>/dev/null || true
[[ ! -e $tmp/handover.sock ]] || fail 'a daemon that took a socket over left it behind on exit'

# A daemon that is alive but not accepting -- stalled, or stopped in a debugger
# -- still holds the socket. Its backlog fills and a connect would block; that
# is a listener, not a stale file.
python3 - "$tmp/busy.sock" "$tmp/busy.ready" 9>&- <<'PY' &
import os, signal, socket, sys
srv = socket.socket(socket.AF_UNIX); srv.bind(sys.argv[1]); srv.listen(0)
held = []
while True:                       # fill the backlog until a connect would block
    c = socket.socket(socket.AF_UNIX); c.setblocking(False)
    try:
        c.connect(sys.argv[1]); held.append(c)
    except BlockingIOError:
        break
open(sys.argv[2], "w").close()
signal.pause()
PY
busy_pid=$!; helper_pids+=("$busy_pid")
wait_until 'the busy listener to fill its backlog' test -e "$tmp/busy.ready"
ino=$(stat -c %i "$tmp/busy.sock")
authd_once --no-polkit --socket "$tmp/busy.sock" < /dev/null > "$tmp/busy.out" 2> "$tmp/busy.err"
[[ $(stat -c %i "$tmp/busy.sock") == "$ino" ]] \
  || fail "a listener with a full backlog was taken for a stale socket: $(cat "$tmp/busy.err")"
grep -q 'already serving' "$tmp/busy.err" || fail "a busy listener was not named: $(cat "$tmp/busy.err")"
kill "$busy_pid" 2>/dev/null || true

# A daemon removes only the socket it bound. If another took the path over --
# two daemons that both found it free in the same instant -- the one leaving
# must not remove the other's.
mkfifo "$tmp/owner.cmds"
"$authd" --no-polkit --socket "$tmp/owner.sock" < "$tmp/owner.cmds" > /dev/null 2>/dev/null 9>&- &
owner_pid=$!; helper_pids+=("$owner_pid")
exec 5> "$tmp/owner.cmds"
wait_until 'the owner to bind its socket' test -S "$tmp/owner.sock"
rm -f -- "$tmp/owner.sock"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$tmp/owner.sock"
ino=$(stat -c %i "$tmp/owner.sock")
exec 5>&-
wait_until 'the owner daemon to exit' gone "$owner_pid"
wait "$owner_pid" 2>/dev/null || true
[[ -e $tmp/owner.sock && $(stat -c %i "$tmp/owner.sock") == "$ino" ]] \
  || fail 'a daemon on its way out removed a socket another had bound in its place'

# A path the daemon cannot use -- too long for a unix socket, under a file,
# or a directory itself -- is reported as what it is. The daemon carries on
# without askpass: it may still be the session's polkit agent.
# A file or a fifo at the path is somebody's, not a stale socket: it stays.
: > "$tmp/plainfile"; mkdir "$tmp/adir"
echo precious > "$tmp/afile"; mkfifo "$tmp/afifo"
for bad in "$tmp/$(printf 'x%.0s' {1..120}).sock" "$tmp/plainfile/a.sock" "$tmp/adir" "$tmp/afile" "$tmp/afifo"; do
  authd_once --no-polkit --socket "$bad" < /dev/null > "$tmp/bad.out" 2> "$tmp/bad.err" \
    || fail "a daemon given an unusable socket path failed: $(cat "$tmp/bad.err")"
  grep -q 'already serving' "$tmp/bad.err" && fail "an unusable path was taken for a live daemon: $(cat "$tmp/bad.err")"
  grep -q 'cannot serve askpass' "$tmp/bad.err" || fail "an unusable path was not reported: $(cat "$tmp/bad.err")"
  grep -q '"askpass":""' "$tmp/bad.out" || fail "a daemon named a socket it could not serve: $(cat "$tmp/bad.out")"
done
[[ -d $tmp/adir ]] || fail 'the daemon removed a directory standing at its socket path'
[[ $(cat "$tmp/afile") == precious ]] || fail 'the daemon replaced a file standing at its socket path'
[[ -p $tmp/afifo ]] || fail 'the daemon replaced a fifo standing at its socket path'

# A socket file nobody answers is left by a daemon that died: it is replaced.
python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$tmp/stale.sock"
authd_once --no-polkit --socket "$tmp/stale.sock" < /dev/null > "$tmp/stale.out" 2> "$tmp/stale.err"
grep -qF "\"askpass\":\"$tmp/stale.sock\"" "$tmp/stale.out" \
  || fail "a daemon did not take over a stale socket: $(cat "$tmp/stale.out") $(cat "$tmp/stale.err")"
grep -q 'already serving' "$tmp/stale.err" && fail "a stale socket was taken for a live daemon: $(cat "$tmp/stale.err")"

# Every caller above is gone, and so is the second daemon's probe, so every
# socket the daemon held for them is closed: nothing leaks a descriptor.
(($(ls "/proc/$daemon_pid/fd" | wc -l) == fds_before)) \
  || fail "the daemon holds $(($(ls "/proc/$daemon_pid/fd" | wc -l) - fds_before)) more fds than before its callers came and went"

# --- 7. losing the shell releases every caller ----------------------------
# The daemon is a child of qs. If qs dies while a prompt is up, sudo must be
# told no rather than left waiting on a socket nobody is reading.
#
# The refusal here is belt and braces: closing the socket would release the
# caller on its own, so this assertion passes with or without the explicit
# {"ok":false} the daemon sends first. What it does pin down is that the daemon
# neither outlives the shell nor leaves its socket behind -- a stale socket is
# worse than none, since the next c7-askpass connects to it and waits.
before=$(grep -c '"ev":"request"' "$out")
C7_AUTHD_SOCKET=$sock "$tmp/run-askpass" > /dev/null 2>&1 9>&- &
askpass3=$!
for ((i = 0; i < 100; i++)); do
  n=$(grep -c '"ev":"request"' "$out")
  ((n > before)) && break
  sleep 0.05
done
((n > before)) || fail "the last request never arrived:
$(cat "$out")"

exec 9>&-           # EOF on the command channel: the shell has gone
wait_until 'c7-askpass to be refused as the shell goes' gone "$askpass3"
rc=0; wait "$askpass3" || rc=$?
((rc != 0)) || fail 'the daemon shut down without refusing the prompt it was holding'

for ((i = 0; i < 100; i++)); do
  kill -0 "$daemon_pid" 2>/dev/null || break
  sleep 0.05
done
kill -0 "$daemon_pid" 2>/dev/null && fail 'the daemon outlived the shell that started it'
daemon_pid=''
[[ ! -e $sock ]] || fail 'the daemon left its socket behind on the way out'

# --- the polkit race between a finger and a password ----------------------
# polkitd cannot run here, so the PAM sessions are fakes with the same signals
# PolkitAgent.Session has. What is under test is the bookkeeping: which session
# owns the reader, which one the typed password goes to, and that the loser of
# the race is cancelled instead of being counted as a wrong password.
python3 - "$authd" <<'PY' || fail 'the finger / password session race went wrong (see above)'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("authd", sys.argv[1])
spec = importlib.util.spec_from_loader("authd", loader)
authd = importlib.util.module_from_spec(spec)
loader.exec_module(authd)

class Session:
    made = []
    def __init__(self):
        self.handlers, self.cancelled, self.answers = {}, False, []
        Session.made.append(self)
    def connect(self, sig, fn, req): self.handlers[sig] = (fn, req)
    def initiate(self): pass
    def response(self, secret): self.answers.append(secret)
    def cancel(self):
        self.cancelled = True
        self.fire("completed", False)
    def fire(self, sig, *args):
        fn, req = self.handlers[sig]
        fn(self, *args, req)

authd.PolkitAgent.Session.new = staticmethod(lambda identity, cookie: Session())
lid_shut_on_dock = False
authd.reader_out_of_reach = lambda: lid_shut_on_dock
events = []
d = object.__new__(authd.Daemon)
d.queue, d.by_cookie = [], {}
d.emit = lambda **e: events.append(e)
d._finish_polkit = lambda req: None

def fresh():
    Session.made.clear(); events.clear()
    req = authd.Request("polkit")
    req.cookie = "c"
    d.push(req)
    return req

def evs(name): return [e for e in events if e["ev"] == name]
def check(ok, msg):
    if not ok:
        print("FAIL:", msg, events); sys.exit(1)

# 1. The reader answers first: a second session starts for the password, the
#    typed secret goes to it, and only it.
req = fresh()
reader = Session.made[0]
reader.fire("show-info", "Place your finger on the fingerprint reader")
check(len(Session.made) == 2, "claiming the reader did not start a password session")
check(evs("factor"), "the shell was not told the reader is live")
pw = Session.made[1]
pw.fire("request", "Password: ", False)
check(evs("prompt"), "the password session's prompt never reached the shell")
d.respond(req, "hunter2")
check(pw.answers == ["hunter2"] and reader.answers == [], "the password went to the wrong session")

# 2. A wrong password is counted and retried; the reader keeps listening.
pw.fire("completed", False)
check(evs("failed") and evs("failed")[0]["tries"] == 1, "a wrong password was not counted")
check(not reader.cancelled and len(Session.made) == 3, "a wrong password stopped the reader")

# 3. The finger wins: the password session is cancelled, and not counted.
reader.fire("completed", True)
check(Session.made[2].cancelled, "the losing password session was left running")
check(len(evs("failed")) == 1, "cancelling the loser was counted as a wrong password")
check(evs("close") and evs("close")[0]["ok"], "the request did not close as authorized")

# 4. The reader gives up and its stack falls through to a password prompt:
#    it is retired, not drawn as a second field.
req = fresh()
reader = Session.made[0]
reader.fire("show-info", "Place your finger on the fingerprint reader")
Session.made[1].fire("request", "Password: ", False)
before = len(evs("prompt"))
reader.fire("request", "Password: ", False)
check(reader.cancelled and evs("factorend"), "a timed-out reader was not retired")
check(len(evs("prompt")) == before and not evs("failed"), "the retired reader drew a prompt or counted a try")

# 5. Cancel stops both.
d.deny(req)
check(all(s.cancelled for s in Session.made), "cancel left a session running")

# 6. Lid shut on a dock: the reader still takes its session, so the password
#    session starts at once -- but no print is offered for a sensor under the lid.
lid_shut_on_dock = True
req = fresh()
Session.made[0].fire("show-info", "Place your finger on the fingerprint reader")
check(len(Session.made) == 2, "a hidden reader did not start the password session")
check(not evs("factor"), "the print was offered with the lid shut on a dock")
lid_shut_on_dock = False
print("race ok")
PY

# Nothing above may have thrown inside the daemon: PyGObject prints an
# exception in a callback and carries on, so only stderr shows it.
grep -q Traceback "$err" && fail "the daemon raised an exception:
$(cat "$err")"
echo 'PASS: c7-authd / c7-askpass'
