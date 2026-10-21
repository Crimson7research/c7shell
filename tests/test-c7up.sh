#!/usr/bin/env bash
# Self-check for bin/c7up. Run it directly: tests/test-c7up.sh
#
# c7up's whole job is to turn six unstructured command-line tools into one
# NDJSON contract the shell can bind to, so the test builds a fake system out
# of stubs -- checkupdates, pacman, paru, pacdiff, flatpak -- and asserts on
# the JSON that comes out. Nothing here touches the real package manager, and
# nothing here needs root: `verdict`, the part with all the parsing in it, is
# unprivileged by design.
set -euo pipefail

# shellcheck source=fixtures/harness.sh
. "$(dirname -- "$0")/fixtures/harness.sh"
c7up=$here/../bin/c7up
mktmp

bin=$tmp/bin
mkdir -p "$bin" "$tmp/state" "$tmp/cache" "$tmp/config"

command -v python3 >/dev/null || { echo 'SKIP: python3 not installed'; exit 0; }

# The real tools c7up leans on that are not worth stubbing.
for helper in bash sed awk grep tr cut wc date mktemp rm cat diff paste head tail \
              printf sort timeout dirname uname mkdir touch mkfifo; do
  p=$(command -v "$helper" 2>/dev/null) && ln -sf "$p" "$bin/$helper"
done

stub() { printf '%s\n' "#!/bin/sh" "$2" > "$bin/$1"; chmod +x "$bin/$1"; }

run_verdict() {
  env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" \
      bash "$c7up" verdict 2>"$tmp/err"
}

# A verdict is one line of JSON; this pulls one field out of it.
field() { python3 -c "import json,sys;print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }
jq_py() { python3 -c "import json,sys;d=json.load(sys.stdin);print(eval(sys.argv[1],{'d':d}))" "$1"; }

# --------------------------------------------------------------------------
# 1. The clean path: four routine bumps, nothing that needs a decision.
# --------------------------------------------------------------------------
stub checkupdates 'cat <<EOF
mesa 25.1.2 -> 25.1.4
pipewire 1.4.1 -> 1.4.2
git 2.51.0 -> 2.51.1
curl 8.15.0 -> 8.16.0
EOF'
# %s is the download size in bytes; four packages, 100 MB total.
stub pacman 'case "$*" in
  *--print-format*) echo 25000000; echo 25000000; echo 25000000; echo 25000000 ;;
  *--print*) echo "https://mirror/extra/mesa.pkg.tar.zst" ;;
  *-Qoq*) echo filesystem ;;
  *-Qii*) echo "MODIFIED	/etc/pacman.conf" ;;
esac
exit 0'
stub paru 'exit 0'
stub pacdiff 'exit 0'
stub flatpak 'exit 0'

out=$(run_verdict) || fail "verdict exited non-zero:\n$(cat "$tmp/err")"
python3 -c 'import json,sys;json.loads(sys.stdin.read())' <<<"$out" \
  || fail "verdict is not valid JSON:\n$out"

[[ $(field clean <<<"$out") == True ]] \
  || fail "four routine bumps were not the clean path:\n$out"
[[ $(field size <<<"$out") == 100000000 ]] \
  || fail "download size was not summed from --print-format: $(field size <<<"$out")"
[[ $(jq_py "len(d['sources'][0]['items'])" <<<"$out") == 4 ]] \
  || fail "the pacman source did not carry four packages:\n$out"
# The versions are what the whole design's old -> new rendering is built on.
[[ $(jq_py "d['sources'][0]['items'][0]['old']" <<<"$out") == 25.1.2 ]] \
  || fail "old versions were dropped:\n$out"
[[ $(jq_py "d['sources'][0]['items'][0]['new']" <<<"$out") == 25.1.4 ]] \
  || fail "new versions were dropped:\n$out"

# arch-update's state files are the contract with arch-update itself: its timer
# and its tray applet read these, and a run that did not write them would leave
# the two halves disagreeing about what is pending.
[[ -s $tmp/state/arch-update/last_updates_check_packages ]] \
  || fail "arch-update's package state file was not written"
grep -q '^mesa 25.1.2 -> 25.1.4$' "$tmp/state/arch-update/last_updates_check_packages" \
  || fail "the state file is not in arch-update's format:\n$(cat "$tmp/state/arch-update/last_updates_check_packages")"
[[ -s $tmp/state/arch-update/last_updates_check_time ]] \
  || fail "the check timestamp was not written"

# --------------------------------------------------------------------------
# 2. A kernel in the set escalates, and predicts a reboot.
# --------------------------------------------------------------------------
stub checkupdates 'cat <<EOF
mesa 25.1.2 -> 25.1.4
linux 6.15.4 -> 6.16.1
EOF'
out=$(run_verdict) || fail "verdict exited non-zero on the kernel case"
[[ $(field clean <<<"$out") == False ]] || fail "a kernel update did not escalate:\n$out"
[[ $(field reboot <<<"$out") == True ]] || fail "a kernel update did not predict a reboot:\n$out"
[[ $(jq_py "[x['kind'] for x in d['decisions']]" <<<"$out") == "['kernel']" ]] \
  || fail "the kernel was not the only decision:\n$out"
[[ $(jq_py "d['decisions'][0]['detail']" <<<"$out") == "6.15.4 → 6.16.1" ]] \
  || fail "the kernel decision lost its versions:\n$out"

# mesa is in most weeks' updates. Treating a graphics package as a decision
# would mean the clean path never happens, which is the one thing the merged
# design cannot afford -- so it must NOT be a driver match.
stub checkupdates 'echo "mesa 25.1.2 -> 25.1.4"'
out=$(run_verdict)
[[ $(field clean <<<"$out") == True ]] || fail "mesa alone escalated:\n$out"

# An out-of-tree module built against the running kernel is a different story.
stub checkupdates 'echo "nvidia-dkms 570.1 -> 575.0"'
out=$(run_verdict)
[[ $(field clean <<<"$out") == False ]] || fail "a dkms module did not escalate:\n$out"
[[ $(jq_py "d['decisions'][0]['kind']" <<<"$out") == driver ]] \
  || fail "a dkms module was not classified as a driver:\n$out"

# --------------------------------------------------------------------------
# 3. A replacement is read out of pacman's own transaction, not guessed.
# --------------------------------------------------------------------------
stub checkupdates 'echo "mesa 25.1.2 -> 25.1.4"'
stub pacman 'case "$*" in
  *--print-format*) echo 1000 ;;
  *--print*) echo ":: Replace jack2 with extra/pipewire-jack?" ;;
esac
exit 0'
out=$(run_verdict)
[[ $(field clean <<<"$out") == False ]] || fail "a replacement did not escalate:\n$out"
[[ $(jq_py "d['decisions'][0]['kind']" <<<"$out") == replace ]] \
  || fail "the replacement was not classified:\n$out"
[[ $(jq_py "d['decisions'][0]['title']" <<<"$out") == "jack2 → pipewire-jack" ]] \
  || fail "the replacement lost its two package names:\n$out"

# --------------------------------------------------------------------------
# 4. A failed transaction is a decision, not a surprise halfway through a run.
# --------------------------------------------------------------------------
stub pacman 'case "$*" in
  *--print-format*) echo 1000 ;;
  *--print*) echo "error: failed to prepare transaction (could not satisfy dependencies)" ;;
esac
exit 0'
out=$(run_verdict)
[[ $(jq_py "any(x['kind']=='conflict' for x in d['decisions'])" <<<"$out") == True ]] \
  || fail "an unpreparable transaction was not surfaced:\n$out"

# --------------------------------------------------------------------------
# 5. A pacnew waiting from an earlier run is a decision too.
# --------------------------------------------------------------------------
stub pacman 'case "$*" in
  *--print-format*) echo 1000 ;;
  *-Qoq*) echo filesystem ;;
  *-Qii*) printf "MODIFIED\t/etc/pacman.conf\n" ;;
esac
exit 0'
stub pacdiff 'echo /etc/pacman.conf.pacnew'
out=$(run_verdict)
[[ $(jq_py "any(x['kind']=='pacnew' for x in d['decisions'])" <<<"$out") == True ]] \
  || fail "a parked pacnew did not escalate:\n$out"

# --------------------------------------------------------------------------
# 6. Every string that reaches the shell must survive JSON. pacman's output is
#    full of ANSI and control bytes, and one raw byte invalidates the line for
#    the parser on the other side -- which is a silently empty dropdown.
# --------------------------------------------------------------------------
stub checkupdates 'printf "we\x1b[31mird\"pkg\x07 1.0 -> 2.0\n"'
stub pacdiff 'exit 0'
out=$(run_verdict)
python3 -c 'import json,sys;json.loads(sys.stdin.read())' <<<"$out" \
  || fail "a package name with ANSI and a quote in it broke the JSON:\n$out"

# --------------------------------------------------------------------------
# 7. No network: the dropdown must be told, not left showing a stale count as
#    though it were fresh.
# --------------------------------------------------------------------------
stub checkupdates 'exit 1'
out=$(run_verdict) && fail "a failed sync exited zero"
[[ $(jq_py "'error' in d" <<<"$out") == True ]] \
  || fail "a failed sync did not report an error:\n$out"

# --------------------------------------------------------------------------
# 8. c7up-root is the trust boundary: it takes a verb, never a command line.
# --------------------------------------------------------------------------
root=$here/../bin/c7up-root
out=$(bash "$root" 'sync; rm -rf /' 2>&1 || true)
[[ $out == *"unknown verb"* ]] || fail "c7up-root accepted a compound verb: $out"
out=$(bash "$root" sync 'evil;name' 2>&1 || true)
[[ $out == *"implausible package name"* ]] \
  || fail "c7up-root accepted a package name with a semicolon in it: $out"
out=$(bash "$root" pacnew-take /etc/../root/.ssh/authorized_keys 2>&1 || true)
[[ $out == *"path traversal"* || $out == *"not a config path"* ]] \
  || fail "c7up-root accepted a traversal path: $out"
out=$(bash "$root" restart-services 'foo.service; reboot' 2>&1 || true)
[[ $out == *"not a service unit"* ]] || fail "c7up-root accepted a crafted unit name: $out"

# --------------------------------------------------------------------------
# 8b. The `pacman` verb is what the AUR helper's --sudo shim lands on, so it
#     has to accept the command line the helper actually writes. paru writes
#     it in long options with an end-of-options marker; yay writes -U. Both
#     have to get through, and what pacman is finally handed must still be the
#     narrow command line the verb promises.
# --------------------------------------------------------------------------
mkdir -p "$tmp/pac"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$@"' > "$tmp/pac/pacman"
chmod +x "$tmp/pac/pacman"
built=$tmp/foo-1-1-x86_64.pkg.tar.zst
: > "$built"
runpac() { PATH="$tmp/pac:$PATH" bash "$root" pacman "$@" 2>&1; }
# One argument per line out of the stub, so position is greppable.
argline() { grep -nxF -- "$1" <<<"$2" | head -1 | cut -d: -f1; }

# Verbatim from `paru --sudo <shim> -U <file>` -- the line issue #59 hit.
out=$(runpac --upgrade --color=never --noconfirm -- "$built") \
  || fail "c7up-root rejected paru's own install command line:\n$out"
[[ $(argline --upgrade "$out") ]] || fail "the operation was dropped:\n$out"
[[ $(argline "$built" "$out") ]] || fail "the built package was dropped:\n$out"
# Nothing that looks like a flag may land behind the marker: past it pacman
# reads every word as a package file, so a trailing --noconfirm becomes a file
# it cannot find.
if sed -n "$(( $(argline -- "$out") + 1 )),\$p" <<<"$out" | grep -q '^-'; then
  fail "a flag landed after the end-of-options marker:\n$out"
fi
[[ $(argline --noconfirm "$out") ]] || fail "--noconfirm was dropped:\n$out"
(( $(argline "$built" "$out") > $(argline -- "$out") )) \
  || fail "the target landed in front of the end-of-options marker:\n$out"

# The repo-dependency and mark-as-dependency halves of the same flow.
out=$(runpac --sync --color=never --noconfirm --ignore=foo -- cowsay) \
  || fail "c7up-root rejected paru's repo-dependency command line:\n$out"
out=$(runpac --database --asdeps -- cowsay) \
  || fail "c7up-root rejected the mark-as-dependency step:\n$out"
# paru names repo dependencies the way it resolved them, repo and all, and a
# real update died on "refusing implausible package name: extra/edk2-aarch64".
out=$(runpac --sync --noconfirm -- extra/edk2-aarch64 multilib/lib32-glibc) \
  || fail "c7up-root rejected a repo-qualified target:\n$out"
[[ $(argline extra/edk2-aarch64 "$out") ]] \
  || fail "the repo-qualified target was dropped:\n$out"
# One repo segment and nothing path-shaped: the slash must not open a door.
for bad in extra/../etc/passwd 'extra/evil;name' a/b/c ./cowsay extra/; do
  out=$(runpac --sync -- "$bad" || true)
  [[ $out == *"implausible package name"* ]] \
    || fail "c7up-root accepted $bad as a target: $out"
done
# yay's spelling of the same thing, and --color as two tokens.
out=$(runpac -U --color never --noconfirm --needed "$built") \
  || fail "c7up-root rejected the short-option spelling:\n$out"

# Widening it is still the thing to avoid. --root, --dbpath and --config each
# point pacman at a tree the caller chose, which is a root install of packages
# nobody authorised.
for flag in --root=/ --dbpath=/tmp/db --config=/tmp/pacman.conf --hookdir=/tmp; do
  out=$(runpac --upgrade "$flag" -- "$built" || true)
  [[ $out == *"unexpected pacman flag"* ]] \
    || fail "c7up-root accepted $flag from the AUR helper: $out"
done
out=$(runpac --sync -- 'evil;name' || true)
[[ $out == *"implausible package name"* ]] \
  || fail "a target behind the marker skipped the name check: $out"
out=$(runpac --upgrade -- /etc/passwd || true)
[[ $out == *"not a built package"* ]] || fail "c7up-root installed a path that is not a package: $out"
out=$(runpac --upgrade -- "$tmp/missing.pkg.tar.zst" || true)
[[ $out == *"not a built package"* ]] || fail "c7up-root accepted a package file that is not there: $out"
out=$(runpac --color=never --noconfirm -- cowsay || true)
[[ $out == *"no pacman operation"* ]] || fail "c7up-root ran pacman with no operation: $out"
out=$(runpac --upgrade --color=/etc -- "$built" || true)
[[ $out == *"unexpected --color value"* ]] || fail "c7up-root passed --color anything: $out"
out=$(runpac --sync --ignore 'evil;name' -- cowsay || true)
[[ $out == *"implausible package name"* ]] || fail "c7up-root passed --ignore anything: $out"

# The shim in front of it. sudo's contract is `sudo <program> <args...>`, so
# the helper names pacman as the first word; if that word survives the trip it
# arrives at root as a package to install.
sudoshim=$here/../bin/c7up-sudo
printf '%s\n' '#!/bin/sh' 'shift; printf "%s\n" "$@"' > "$tmp/pac/pkexec"
chmod +x "$tmp/pac/pkexec"
out=$(PATH="$tmp/pac:$PATH" bash "$sudoshim" pacman --upgrade --noconfirm -- "$built" 2>&1) \
  || fail "c7up-sudo rejected what paru hands its sudo:\n$out"
[[ $(head -1 <<<"$out") == pacman ]] \
  || fail "c7up-sudo did not pass the verb through as itself:\n$out"
[[ $(sed -n 2p <<<"$out") == --upgrade ]] \
  || fail "c7up-sudo left pacman's own name in the argument list:\n$out"
out=$(PATH="$tmp/pac:$PATH" bash "$sudoshim" bash -c 'id' 2>&1 || true)
[[ $out == *"only pacman is routed here"* ]] \
  || fail "c7up-sudo would run something other than pacman as root: $out"

# --------------------------------------------------------------------------
# 9. The run's streaming contract. This is the half that cannot be exercised
#    against a real system in a test -- it installs packages -- so the stubs
#    stand in for pkexec and the root helper, and the assertions are on the
#    event stream the wizard's progress bar and log are bound to.
# --------------------------------------------------------------------------
mkdir -p "$tmp/lib"
# pkexec's only job here is to run what it is handed; the authorisation it
# normally performs has no analogue in a test. Each call is counted, because
# "how many times does one run ask for a password" is the assertion below.
stub pkexec 'echo "$@" >> "$TMPDIR/pkexec.log"; exec "$@"'

# Stands in for the root helper, session loop and all: a run drives one of
# these down a pipe now rather than starting one per privileged step. The
# argument is the shell the `sync` verb runs, and the (n/m) lines in it are the
# only progress either half of a real run emits -- the whole bar is driven off
# them.
root_stub() {
  cat > "$tmp/lib/c7up-root" <<EOF
#!/bin/bash
mark=\$'\036'
[ "\${1-}" = session ] || exit 2
while IFS=\$'\t' read -r -a req; do
  rc=0
  case \${req[0]} in
    ping) ;;
    sync) $1 ;;
    # What the AUR helper's --sudo shim asks for. Printing something is how the
    # test can see that its request really travelled down the session's pipe.
    pacman) echo "installing myaurpkg... done" ;;
    *) ;;
  esac
  printf '\n%s%s\n' "\$mark" "\$rc"
done
EOF
  chmod +x "$tmp/lib/c7up-root"
}
root_stub '
    echo "(1/3) upgrading mesa... done"
    echo "(2/3) upgrading pipewire... done"
    printf ":: \033[1mrunning post-transaction hooks\033[0m\n"
    echo "(3/3) upgrading systemd... done"'
: > "$tmp/pkexec.log"

state=$tmp/state/arch-update
mkdir -p "$state"
printf 'mesa 1 -> 2
pipewire 1 -> 2
systemd 1 -> 2
' > "$state/last_updates_check_packages"
: > "$state/last_updates_check_aur"
: > "$state/last_updates_check_flatpak"
stub pacdiff 'exit 0'
stub checkservices 'exit 0'

out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp"       XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache"       XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib"       bash "$c7up" run 2>"$tmp/err") || fail "run exited non-zero:\n$(cat "$tmp/err")"

# Every line the shell receives has to parse on its own -- the QML side reads
# this with a SplitParser and one bad line is a dropped event, not an error.
while IFS= read -r line; do
  [[ -n $line ]] || continue
  python3 -c 'import json,sys;json.loads(sys.stdin.read())' <<<"$line" \
    || fail "a run event is not valid JSON: $line"
done <<<"$out"

ev() { python3 -c "
import json,sys
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    d=json.loads(l)
    if d.get('ev')==sys.argv[1]: print(json.dumps(d))
" "$1"; }

[[ $(ev start <<<"$out" | wc -l) == 1 ]] || fail "the run did not announce a start:\n$out"
[[ $(ev start <<<"$out" | field total) == 3 ]] \
  || fail "the run's total did not come from the state files:\n$out"

# The progress bar and the "11 of 18" headline are both bound to these.
[[ $(ev progress <<<"$out" | wc -l) == 3 ]] \
  || fail "the (n/m) lines did not become progress events:\n$(ev progress <<<"$out")"
[[ $(ev progress <<<"$out" | tail -1 | field done) == 3 ]] \
  || fail "progress did not reach the end:\n$(ev progress <<<"$out")"

# One authorisation event pair, so the wizard can say what it is waiting for
# rather than looking hung while the polkit dialog is up.
[[ $(ev auth <<<"$out" | head -1 | field state) == waiting ]] \
  || fail "the run did not announce that it was waiting on authorisation:\n$out"
[[ $(ev auth <<<"$out" | tail -1 | field state) == granted ]] \
  || fail "the run never cleared its waiting-on-authorisation state:\n$out"

# And exactly one pkexec for the whole run. The repo sync, the AUR helper's
# install and the post-run service check used to be one each, which was one
# password prompt each as soon as the run outlived polkit's keep window.
[[ $(wc -l < "$tmp/pkexec.log") == 1 ]] \
  || fail "one run asked for authorisation more than once:\n$(cat "$tmp/pkexec.log")"
[[ $(cat "$tmp/pkexec.log") == *session ]] \
  || fail "the run's one pkexec was not the root session:\n$(cat "$tmp/pkexec.log")"

[[ $(ev done <<<"$out" | field ok) == True ]] || fail "the run did not report success:\n$out"
# Step 3 is built from this payload, so an absent key is a card that never
# appears rather than a card that says zero.
[[ $(ev done <<<"$out" | jq_py "'orphans' in d") == True ]] \
  || fail "the run's done event carried no orphan list:\n$out"
# A run that leaves the counts it started from in place would have the bar
# still advertising updates that are now installed.
[[ ! -s $state/last_updates_check_packages ]] \
  || fail "a successful run left arch-update's pending list populated"

# The log the wizard's "view log" opens.
log=$(ev done <<<"$out" | field log)
[[ -s $log ]] || fail "the run wrote no log at $log"
grep -q 'upgrading mesa' "$log" || fail "the log did not capture the run's output"
# ANSI belongs in a terminal, not in a file the shell renders -- and not in the
# JSON either, where an escape byte would take the whole line down with it.
if grep -q $'\033' "$log"; then fail "escape sequences reached the log"; fi
if grep -q $'\033' <<<"$out"; then fail "escape sequences reached the event stream"; fi
if ! grep -q 'post-transaction hooks' "$log"; then
  fail "the coloured line was dropped instead of being stripped:\n$(cat "$log")"
fi

# --------------------------------------------------------------------------
# 10. A failed run says so, and says the transaction was rolled back rather
#     than leaving the user to guess what state the machine is in.
# --------------------------------------------------------------------------
printf 'mesa 1 -> 2\n' > "$state/last_updates_check_packages"
root_stub '
    echo "(1/1) upgrading mesa..."
    echo "error: failed to commit transaction (conflicting files)" >&2
    rc=1'

out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib" \
      bash "$c7up" run 2>/dev/null) && fail "a failed run exited zero"
[[ $(ev done <<<"$out" | field ok) == False ]] || fail "a failed run reported success:\n$out"
[[ $(ev done <<<"$out" | field failed) == pacman ]] \
  || fail "the failed run did not name the source that failed:\n$out"
[[ $(ev done <<<"$out" | jq_py "'error' in d and d['error']") != "" ]] \
  || fail "the failed run carried no error text for the wizard to show:\n$out"
# The pending list must survive a failure: those packages really are still
# pending, and clearing it would blank the badge over a machine that did not
# update.
[[ -s $state/last_updates_check_packages ]] \
  || fail "a failed run cleared arch-update's pending list"

# --------------------------------------------------------------------------
# 11. The three hand-offs to a terminal must not name a program the machine
#     may not have. `less` is not part of base, and the first version of this
#     shipped a "log" button that opened a terminal just long enough to print
#     "Failed to launch child: less" and close again.
# --------------------------------------------------------------------------
# No QML file may name a pager or an editor: choosing one is c7up's job,
# because only c7up runs at the moment of use and can look.
qml=$here/../quickshell/c7shell
# Comments stripped first, then any mention at all -- the first attempt at this
# check only matched a quoted token and sailed straight past a `| less` inside
# a template literal, which is exactly the form the bug shipped in.
bad=$(find "$qml" -name '*.qml' -exec sed 's|//.*||' {} + \
  | grep -nE '\b(less|most|vimdiff|nvim|nano)\b' || true)
[[ -z $bad ]] || fail "a QML file names a pager or editor directly; c7up picks
  those at the point of use so a machine without it still gets something:\n$bad"

logdir=$tmp/cache/c7up
mkdir -p "$logdir"
printf 'line one\nline two\n' > "$logdir/$(date +%F).log"

# stdin from /dev/null and a timeout: a pager that decided to be interactive
# would otherwise hang the suite on whatever terminal it was started from.
runc7up() {
  timeout 20 env -i PATH="$1" HOME="$tmp" TERM=dumb \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" \
      bash "$c7up" "${@:2}" </dev/null || true
  # `|| true` so a c7up that dies (an exec onto a program that is not there
  # exits 127) reaches the assertion below and reports what went wrong, rather
  # than set -e killing this file with no message at all.
}

# A machine with a pager uses it.
stub less 'echo "LESS SAW: $*"'
out=$(runc7up "$bin:/usr/bin:/bin" log)
[[ $out == *"LESS SAW:"* ]] || fail "the log verb did not use the pager it found:\n$out"

# A machine with no less at all still shows the log rather than failing to
# launch. `more` is util-linux, so it is there on any Arch install.
rm -f "$bin/less"
out=$(runc7up "$bin:/usr/bin:/bin" log 2>&1)
[[ $out == *"line one"* ]] \
  || fail "with no less installed the log was not shown at all:\n$out"
[[ $out != *"No such file"* && $out != *"command not found"* ]] \
  || fail "the log verb tried to launch a pager that is not installed:\n$out"

# Not even more: it must still print the log and hold the terminal open, not
# flash it shut.
barebin=$tmp/barebin; mkdir -p "$barebin"
# diff too: the merge fallback below shows a diff when no merge tool exists.
for h in bash cat date ls head printf read sed rm mkdir tr grep diff; do
  p=$(command -v "$h" 2>/dev/null) && ln -sf "$p" "$barebin/$h"
done
out=$(runc7up "$barebin" log 2>&1)
[[ $out == *"line one"* ]] || fail "with no pager at all the log was not printed:\n$out"
[[ $out == *"press enter"* ]] \
  || fail "with no pager the terminal would close before anything could be read:\n$out"

# $PAGER is the user's choice and wins over anything we would pick.
out=$(PAGER=cat runc7up "$bin:/usr/bin:/bin" log 2>&1)
[[ $out == *"line one"* ]] || fail "PAGER was not honoured:\n$out"

# No log yet is a sentence, not a stack trace.
out=$(timeout 20 env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" XDG_CACHE_HOME="$tmp/nothing" \
        XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" \
        bash "$c7up" log </dev/null 2>&1)
[[ $out == *"no update log yet"* ]] || fail "an absent log was not explained:\n$out"

# And a merge with no merge tool installed shows the difference instead of
# exec'ing something that is not there.
target=$tmp/etc-conf
printf 'a\nb\n' > "$target"
printf 'a\nc\n' > "$target.pacnew"
out=$(PAGER=cat runc7up "$barebin" resolve merge "$target" 2>&1)
[[ $out == *"no merge tool found"* ]] \
  || fail "a missing merge tool was not reported:\n$out"
[[ $out == *"-b"* && $out == *"+c"* ]] \
  || fail "with no merge tool the difference itself was not shown:\n$out"

# --------------------------------------------------------------------------
# 12. The merge writes through root, on a copy.
#     /etc is root-owned, so an editor run as the user opens and then cannot
#     save. Running the editor AS root is not the fix: with auth_admin_keep
#     that would be an arbitrary program exec'd as root for five minutes after
#     every update. The editor stays with the user, only the bytes go up.
# --------------------------------------------------------------------------
target=$tmp/merge-target
printf 'original\n' > "$target"
printf 'shipped\n' > "$target.pacnew"

# Stands in for the editor: writes a merged result into the working copy it is
# handed. If c7up passed it the real file this would fail on a root-owned one.
stub fakemerge 'printf "merged\n" > "$1"'
# pkexec here just runs what it is given; the real one authenticates first.
stub pkexec 'exec "$@"'
mkdir -p "$tmp/lib"
cp "$here/../bin/c7up-root" "$tmp/lib/c7up-root"

mergerun() {
  timeout 20 env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" TERM=dumb DIFFPROG=fakemerge \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib" \
      C7UP_TEST_ROOT="$tmp" \
      bash "$c7up" resolve merge "$1" </dev/null 2>&1 || true
}

out=$(mergerun "$target")
[[ $(cat "$target") == merged ]] \
  || fail "the merged result never reached the target file:\n$out\n$(cat "$target")"
[[ ! -e $target.pacnew ]] || fail "the .pacnew survived a completed merge:\n$out"

# The editor must be handed a COPY, never the live file: that is the whole
# reason this works on a root-owned path.
printf 'original\n' > "$target"
printf 'shipped\n' > "$target.pacnew"
stub fakemerge 'case "$1" in '"$tmp"'/merge-target) echo "EDITED THE LIVE FILE" >&2; exit 1 ;; esac
printf "merged\n" > "$1"'
out=$(mergerun "$target")
[[ $out != *"EDITED THE LIVE FILE"* ]] \
  || fail "the editor was pointed at the live file instead of a copy:\n$out"

# A merge the user abandoned without changing anything must not touch /etc, and
# must not delete the .pacnew -- the review is still outstanding.
printf 'original\n' > "$target"
printf 'shipped\n' > "$target.pacnew"
stub fakemerge 'exit 0'
out=$(mergerun "$target")
[[ $(cat "$target") == original ]] || fail "an abandoned merge still wrote:\n$out"
[[ -e $target.pacnew ]] || fail "an abandoned merge removed the .pacnew:\n$out"
[[ $out == *"nothing changed"* ]] || fail "an abandoned merge said nothing:\n$out"

# pacnew-write is as narrow as pacnew-take: a path with a .pacnew beside it,
# and a real file as the source. Anything else is a caller bug at best.
out=$(bash "$tmp/lib/c7up-root" pacnew-write /etc/../root/.ssh/authorized_keys "$target" 2>&1 || true)
[[ $out == *"path traversal"* || $out == *"not a config path"* ]] \
  || fail "pacnew-write accepted a traversal path: $out"
ln -sf /etc/shadow "$tmp/evil-link"
# Both halves must exist, or the check under test is not the one that fires.
printf 'x\n' > "$tmp/fake"
printf 'y\n' > "$tmp/fake.pacnew"
out=$(C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$tmp/fake" "$tmp/evil-link" 2>&1 || true)
[[ $out == *"not a regular file"* ]] \
  || fail "pacnew-write did not reject a symlink as its source: $out"
[[ $(cat "$tmp/fake") == x ]] || fail 'pacnew-write wrote despite rejecting the source' 

# Root reads the source, so it has to be the caller's own file: otherwise
# pacnew-write copies something only root can read (/etc/shadow) into a file
# that may be world-readable. PKEXEC_UID is how pkexec names the caller.
printf 'x\n' > "$tmp/fake"; printf 'y\n' > "$tmp/fake.pacnew"; printf 'z\n' > "$tmp/src"
out=$(PKEXEC_UID=4242 C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$tmp/fake" "$tmp/src" 2>&1 || true)
[[ $out == *"not owned by the caller"* ]] || fail "pacnew-write read a source the caller does not own: $out"
[[ $(cat "$tmp/fake") == x ]] || fail 'pacnew-write wrote from a source it should have refused'
# The caller's own file goes through, written whole: the live file is replaced
# by rename, so an interruption can never leave it half written.
chmod 644 "$tmp/fake"
inode=$(stat -c %i "$tmp/fake")
out=$(PKEXEC_UID=$(id -u) C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$tmp/fake" "$tmp/src" 2>&1) \
  || fail "pacnew-write refused the caller's own file: $out"
[[ $(cat "$tmp/fake") == z ]] || fail 'pacnew-write did not write the merge'
[[ $(stat -c %i "$tmp/fake") != "$inode" ]] || fail 'pacnew-write rewrote the live file in place'
[[ $(stat -c %a "$tmp/fake") == 644 ]] || fail "pacnew-write lost the live file's mode: $(stat -c %a "$tmp/fake")"

# A source swapped for a symlink to a root-only file after it was named is read
# through the descriptor that was checked -- here the swap happens up front, and
# the check must refuse the link's target rather than follow it blindly.
printf 'x\n' > "$tmp/fake2"; printf 'y\n' > "$tmp/fake2.pacnew"
out=$(PKEXEC_UID=4242 C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$tmp/fake2" /etc/hostname 2>&1 || true)
[[ $out == *"not owned by the caller"* ]] || fail "pacnew-write read a file the caller does not own: $out"

# Any spelling of a path but its canonical one is refused, so the
# privileged-config list cannot be walked around with // or /./.
for odd in "$tmp//fake2" "$tmp/./fake2"; do
  out=$(C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$odd" "$tmp/src" 2>&1 || true)
  [[ $out == *"not a canonical path"* ]] || fail "pacnew-write accepted $odd: $out"
done
ln -sf "$tmp/fake2" "$tmp/fake-link"; : > "$tmp/fake-link.pacnew"
out=$(C7UP_TEST_ROOT="$tmp" bash "$tmp/lib/c7up-root" pacnew-write "$tmp/fake-link" "$tmp/src" 2>&1 || true)
[[ $out == *"not a canonical path"* ]] || fail "pacnew-write wrote through a symlink: $out"
rm -f "$tmp/fake-link" "$tmp/fake-link.pacnew"
[[ ! -e $tmp/fake.pacnew ]] || fail 'pacnew-write left the .pacnew behind'
[[ -z $(find "$tmp" -maxdepth 1 -name 'fake.*' -o -maxdepth 1 -name '.fake.*') ]] \
  || fail "pacnew-write left files behind: $(ls -a "$tmp" | grep fake)"

# The merge refuses those files before the editor opens, not after the user
# has spent a merge on one.
stub fakemerge 'echo "EDITOR OPENED" >&2; exit 0'
out=$(mergerun /etc/sudoers || true)
[[ $out != *"EDITOR OPENED"* ]] || fail "the merge opened an editor on sudoers:\n$out"
[[ $out == *"decides who gets root"* ]] || fail "the merge did not say why it refused sudoers:\n$out"

# Files that decide who gets root are not merged through a GUI round trip:
# arbitrary bytes into sudoers is root for whoever holds the polkit grant.
for f in sudoers sudoers.d/wheel shadow gshadow passwd group pam.d/sudo polkit-1/rules.d/x.rules; do
  out=$(bash "$tmp/lib/c7up-root" pacnew-write "/etc/$f" "$tmp/src" 2>&1 || true)
  [[ $out == *"merge it in a terminal"* ]] || fail "pacnew-write would write /etc/$f: $out"
done

# The same ownership rule for a package file pacman -U installs: another user's
# file in /tmp is not something this caller built.
out=$(PKEXEC_UID=4242 runpac -U "$built" || true)
[[ $out == *"not owned by the caller"* ]] || fail "c7up-root installed a package the caller does not own: $out"
chmod o+w "$built"
out=$(PKEXEC_UID=$(id -u) runpac -U "$built" || true)
[[ $out == *"writable by others"* ]] || fail "c7up-root installed a world-writable package: $out"
chmod o-w "$built"
# The caller's own package goes through, but pacman is handed a copy outside
# the caller's reach: a path the caller can still swap is not what was checked.
out=$(PKEXEC_UID=$(id -u) runpac -U "$built") || fail "c7up-root refused the caller's own package: $out"
[[ $(argline "$built" "$out") ]] && fail "pacman was handed the caller's path, not a checked copy:\n$out"
grep -q '/c7up-root-.*/foo-1-1-x86_64.pkg.tar.zst$' <<<"$out" || fail "pacman got no copy of the package:\n$out"

# --------------------------------------------------------------------------
# 13. Orphan packages: arch-update's own post-update question, which this
#     flow computed and never showed. They are cleanup, not a decision --
#     every machine that has ever removed a package has some, and putting
#     them in front of the clean path would mean nobody ever gets one click.
# --------------------------------------------------------------------------
stub checkupdates 'echo "mesa 25.1.2 -> 25.1.4"'
stub pacdiff 'exit 0'
stub paru 'exit 0'
stub pacman 'case "$*" in
  *--print-format*) echo 1000 ;;
  *--print*) echo "https://mirror/extra/mesa.pkg.tar.zst" ;;
  *-Qtdq*) echo oldlib; echo stale-thing ;;
  *-Qii*) printf "MODIFIED\t/etc/pacman.conf\n" ;;
  *-Qi*) cat <<EOF
Name            : oldlib
Version         : 1.0-1
Installed Size  : 12.00 MiB
Description     : nothing depends on this

Name            : stale-thing
Version         : 2.0-1
Installed Size  : 512.00 KiB
Description     : nor this
EOF
  ;;
esac
exit 0'

out=$(run_verdict) || fail "verdict exited non-zero with orphans present:\n$(cat "$tmp/err")"
[[ $(jq_py "[x['name'] for x in d['orphans']]" <<<"$out") == "['oldlib', 'stale-thing']" ]] \
  || fail "the verdict did not carry the orphan list:\n$out"
# The size is the only reason to care about an orphan, and MiB/KiB is what
# pacman prints -- a naive parse turns 512.00 KiB into 512 bytes.
[[ $(jq_py "d['orphans'][0]['size']" <<<"$out") == 12582912 ]] \
  || fail "an orphan's MiB size was not converted to bytes:\n$out"
[[ $(jq_py "d['orphans'][1]['size']" <<<"$out") == 524288 ]] \
  || fail "an orphan's KiB size was not converted to bytes:\n$out"
# Cleanup, not a decision: two orphans and a routine mesa bump is still the
# one-click path.
[[ $(field clean <<<"$out") == True ]] || fail "orphans escalated the clean path:\n$out"
[[ $(jq_py "len(d['decisions'])" <<<"$out") == 0 ]] \
  || fail "an orphan became a decision:\n$out"

# The standalone verb, which is what the shell re-reads after a removal --
# taking one orphan away can orphan the next.
out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" \
      bash "$c7up" orphans 2>"$tmp/err") || fail "the orphans verb exited non-zero:\n$(cat "$tmp/err")"
[[ $(jq_py "[x['name'] for x in d['packages']]" <<<"$out") == "['oldlib', 'stale-thing']" ]] \
  || fail "the orphans verb did not list them:\n$out"

# A machine with none says so in JSON rather than emitting a bare comma.
stub pacman 'case "$*" in
  *-Qtdq*) exit 1 ;;
esac
exit 0'
out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" \
      bash "$c7up" orphans 2>/dev/null)
python3 -c 'import json,sys;json.loads(sys.stdin.read())' <<<"$out" \
  || fail "no orphans at all did not produce valid JSON:\n$out"
[[ $(jq_py "d['packages']" <<<"$out") == "[]" ]] \
  || fail "no orphans should be an empty list:\n$out"

# Root re-derives the list rather than trusting its argv: -Rns on a package
# something still depends on takes that something with it, and the caller is
# not in a position to promise otherwise.
stub pacman 'case "$*" in
  *-Qtdq*) echo oldlib ;;
  *) echo "REMOVED: $*" ;;
esac
exit 0'
out=$(PATH="$bin:/usr/bin:/bin" bash "$root" remove-orphans oldlib 2>&1 || true)
[[ $out == *"REMOVED:"* && $out == *"-Rns"* ]] \
  || fail "c7up-root did not remove a genuine orphan: $out"
out=$(PATH="$bin:/usr/bin:/bin" bash "$root" remove-orphans systemd 2>&1 || true)
[[ $out == *"not an orphan package"* ]] \
  || fail "c7up-root removed a package that is not an orphan: $out"
out=$(PATH="$bin:/usr/bin:/bin" bash "$root" remove-orphans 'oldlib; reboot' 2>&1 || true)
[[ $out == *"implausible package name"* ]] \
  || fail "c7up-root accepted a crafted package name: $out"
out=$(PATH="$bin:/usr/bin:/bin" bash "$root" remove-orphans 2>&1 || true)
[[ $out == *"no package named"* ]] \
  || fail "c7up-root accepted an empty removal: $out"

# --------------------------------------------------------------------------
# 14. The AUR half goes through the same authorisation as the repo half. paru
#     builds as the user for as long as a build takes and then wants root to
#     install what it built; a pkexec of its own there was a second password
#     prompt for one run, because a build routinely outlasts the five minutes
#     polkit keeps an admin authorisation for.
# --------------------------------------------------------------------------
stub pkexec 'echo "$@" >> "$TMPDIR/pkexec.log"; exec "$@"'
root_stub '
    echo "(1/1) upgrading mesa... done"'
: > "$tmp/pkexec.log"
stub pacdiff 'exit 0'
stub checkservices 'exit 0'
# What paru does once the build is done: it installs through the --sudo shim.
stub paru 'case "$*" in
  *-Sua*) exec sh '"$here"'/../bin/c7up-sudo pacman --upgrade --noconfirm -- /tmp/x.pkg.tar.zst ;;
esac
exit 0'
mkdir -p "$tmp/config/arch-update"
echo 'aur_helper=paru' > "$tmp/config/arch-update/arch-update.conf"
printf 'mesa 1 -> 2\n' > "$state/last_updates_check_packages"
printf 'myaurpkg 1 -> 2\n' > "$state/last_updates_check_aur"
: > "$state/last_updates_check_flatpak"

out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib" \
      bash "$c7up" run 2>"$tmp/err") \
  || fail "a run with an AUR package exited non-zero:\n$(cat "$tmp/err")"

[[ $(ev phase <<<"$out" | grep -c '"aur".*"done"') == 1 ]] \
  || fail "the AUR phase did not finish:\n$out"
[[ $out == *"installing myaurpkg"* ]] \
  || fail "the AUR install did not go through the run's root session:\n$out"
[[ $(wc -l < "$tmp/pkexec.log") == 1 ]] \
  || fail "the AUR half raised an authorisation of its own:\n$(cat "$tmp/pkexec.log")"

# --------------------------------------------------------------------------
# 14. A failed AUR run names its error, not its last 20 lines (#116).
#     paru builds every package before it installs any, so the line that says
#     what failed is often far above a tail of build and hook output that reads
#     like success -- which is all the wizard used to show.
# --------------------------------------------------------------------------
stub paru 'case "$*" in
  *-Sua*)
    echo "==> ERROR: A failure occurred in build()."
    echo "error: packages failed to build: broken-pkg-1-1"
    for i in $(seq 30); do echo "upgrading visual-studio-code-bin... $i"; done
    echo "(3/3) Updating the desktop file MIME type cache..."
    exit 1 ;;
esac
exit 0'
printf 'mesa 1 -> 2\n' > "$state/last_updates_check_packages"
printf 'broken-pkg 1 -> 2\n' > "$state/last_updates_check_aur"

out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib" \
      bash "$c7up" run 2>/dev/null) && fail "a failed AUR run exited zero"
err=$(ev done <<<"$out" | jq_py "d['error']")
[[ $(ev done <<<"$out" | field failed) == aur ]] || fail "the failed AUR run named another source:\n$out"
[[ $err == *"packages failed to build: broken-pkg-1-1"* ]] \
  || fail "the AUR helper's error line was not in the error text:\n$err"
[[ $err == *"==> ERROR: A failure occurred in build()."* ]] \
  || fail "makepkg's error line was not in the error text:\n$err"
[[ $err == *"paru exited with status 1"* ]] \
  || fail "the error text did not say how the AUR helper exited:\n$err"
# Earlier phases and earlier runs share the day's log; neither is this error.
[[ $err != *"upgrading mesa"* ]] || fail "the repo phase's output leaked into the AUR error:\n$err"
grep -q 'paru exited with status 1' "$(ev done <<<"$out" | field log)" \
  || fail "the log did not record how the AUR helper exited"

# A failure with no recognisable error line still says something: the end of
# that phase's own output, and the exit status.
stub paru 'case "$*" in *-Sua*) echo "segfault somewhere"; exit 139 ;; esac; exit 0'
printf 'mesa 1 -> 2\n' > "$state/last_updates_check_packages"
printf 'broken-pkg 1 -> 2\n' > "$state/last_updates_check_aur"
out=$(env -i PATH="$bin:/usr/bin:/bin" HOME="$tmp" \
      XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
      XDG_CONFIG_HOME="$tmp/config" TMPDIR="$tmp" C7UP_LIBDIR="$tmp/lib" \
      bash "$c7up" run 2>/dev/null) && fail "a crashed AUR helper exited zero"
err=$(ev done <<<"$out" | jq_py "d['error']")
[[ $err == *"segfault somewhere"* && $err == *"paru exited with status 139"* ]] \
  || fail "an AUR failure without an error line lost its output or status:\n$err"
[[ $err != *"packages failed to build"* ]] \
  || fail "the previous run's error leaked into this one:\n$err"

echo 'test-c7up.sh: all checks passed'
