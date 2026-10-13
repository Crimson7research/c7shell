# Operating the VM setup test

This is the runbook for the VM setup test in `tests/vm/`. It describes how you reach the test laptop, its VMs and their screens, and how to continue the work. For the design, read `docs/superpowers/specs/2026-10-13-vm-setup-test-design.md`. For plain usage, read `tests/vm/README.md`.

## Status on 2026-10-13

- **Positive run passes.** `tests/vm/run.sh --branch jv/vmtest-laptop-fixes` passed on the laptop: base, install (441 s), greeter (11 s), login (5 s), assert (1 s).
- **Fixes not merged yet.** The fixes from the laptop runs are on `jv/vmtest-laptop-fixes`, in draft PR Jonohas/c7shell#257. That PR closes Jonohas/c7shell#256 (`install.sh --yes` still prompted). Until it merges, `main` cannot pass the test.
- **Negative run passes.** On a throwaway branch where `c7shell-setup` exits 1, the run reported `FAIL: install`. `PKGBUILD check()` caught the break before the package installed. The throwaway branch is deleted.
- **Open:** Jonohas/c7shell#254 tracks the laptop verification. One item is left: once #257 merges, run against `main` to confirm.

## The three machines

```
your machine ──SSH (key)──▶ test laptop (c7@10.249.158.253)
                              │  runs QEMU/KVM
                              ├─ SSH to 127.0.0.1:<port> ─▶ VM (c7test)
                              └─ QMP socket (socat)      ─▶ QEMU: screen + keyboard
```

## 1. Your machine to the laptop: SSH

- **Login.** Connect with `ssh -o BatchMode=yes c7@10.249.158.253`. The user installed the developer machine's public key (`~/.ssh/id_ed25519.pub`) with `ssh-copy-id`. With `BatchMode=yes`, SSH fails instead of asking for a password. Never type the password; if key login fails, ask the user to fix it.
- **Sudo.** `c7` has passwordless sudo through `/etc/sudoers.d/c7`. That lets `setup-host.sh` and `pacman` run over SSH without prompts.
- **Getting code onto the laptop.** The laptop clones from GitHub:
  - `~/c7shell` tracks `main`.
  - `~/c7shell-pr` tracks `jv/vmtest-laptop-fixes`.

  After you push, run `git pull` in the matching clone. To try a change before committing, stream it from your worktree; the laptop has no `rsync`:

  ```bash
  tar -C tests -cf - vm | ssh c7@10.249.158.253 'tar -C c7shell-pr/tests -xf -'
  ```

  Never change the files of a clone while a run uses it. Bash reads a script as it runs, so a swapped file breaks the run. Use a separate clone for a parallel run.
- **Long jobs survive disconnects.** Start each run as a transient systemd user unit:

  ```bash
  systemd-run --user --unit=c7vt-run-pr -E C7VT_POLL=5 \
    --working-directory=$HOME/c7shell-pr $HOME/c7shell-pr/tests/vm/run.sh --branch <branch>
  ```

  Lingering is enabled (`loginctl enable-linger c7`), so units keep running with nobody logged in. An earlier `nohup` launch died silently with its SSH session, which is why runs moved to units. Before reusing a unit name, run `systemctl --user reset-failed <unit>`.
- **Waiting for a run.** Run a background SSH command that polls `systemctl --user is-active -q <unit>` every 15–20 s. When the unit ends, it prints `summary.txt` and the tails of the phase logs. Between polls, read `~/.cache/c7shell-vmtest/results/<newest>/summary.txt` and the tail of the current `<phase>.log`.
- **Never `pgrep -f` or `pkill -f` over SSH with a pattern that appears in your own command line.** It matches the SSH shell itself. A `pgrep -f build-base.sh` watcher looped forever this way, and a `pkill -f qemu-system` killed its own session. Match the process name with `pgrep -x qemu-system-x86`, or check the unit with `systemctl --user is-active`.

## 2. The laptop to a VM: QEMU

`vm_start` in `tests/vm/lib/qemu.sh` starts each VM with:

- KVM, q35, 4 vCPUs, 4 GB RAM, and OVMF UEFI firmware, read-only and with no vars file. Boot works because archinstall installs a removable-path bootloader.
- A qcow2 overlay on `base.qcow2` as the disk. Runs never write `base.qcow2`.
- `-device virtio-vga -display none`, with no GL. Under `virtio-vga-gl` with `egl-headless`, QMP `screendump` answered `"no surface"`. As a result, the guest renders in software (llvmpipe).
- User-mode networking with `hostfwd=tcp:127.0.0.1:<port>-:22`. The port is the first free one from 2222, picked under a `flock` on `$C7VT_CACHE/port.lock`. The daemonized QEMU does not inherit the lock. When it did, a second run blocked until the first VM died.
- `-qmp unix:<run>/qmp.sock`, `-serial file:<run>/serial.log`, `-pidfile`, and `-daemonize`.

Each run has its own directory, `$C7VT_CACHE/runs/<timestamp>-<branch>/`. It holds `disk.qcow2`, `qmp.sock`, `serial.log`, `qemu.pid` and `ssh.port`. Two VMs never share anything.

## 3. The laptop into the VM: SSH as `c7test`

- **Credentials.** `build-base.sh` generates a key pair in `$C7VT_CACHE/id_ed25519` and a random alphanumeric `c7test.password`. Both have mode 600 and are never committed. archinstall's `custom_commands` write the public key to `/home/c7test/.ssh/authorized_keys` and give `c7test` passwordless sudo.
- **Connecting.** `vm_ssh <run> <cmd>` runs:

  ```bash
  ssh -p <port> -i id_ed25519 -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null c7test@127.0.0.1
  ```
- **Running the install.** `remote_install_script` writes the install script, with the branch and URL `%q`-quoted. The harness copies it into the VM as `c7vt-install.sh` and runs it with stdin from `/dev/null`. Piping it into `bash -s` let a pacman prompt eat the script's next line.
- **Running the checks.** The harness pipes `lib/session.sh` into `bash -s` inside the VM. It finds the session's `HYPRLAND_INSTANCE_SIGNATURE` and `WAYLAND_DISPLAY` under `/run/user/<uid>`, then asserts:
  - `hyprctl version` answers.
  - `qs` is running. The shell runs as `qs -c c7shell`, not as `quickshell`.
  - The `c7shell-bar` layer is mapped.
  - `c7shell-doctor` exits 0.
  - The user journal has no QML errors.
  - `c7shell-session` runs, and after `kill -KILL` on its `qs` child a new shell maps the bar and a new `c7-authd` starts within 60 s. (On SIGSEGV quickshell relaunches itself inside the same process, so SIGKILL is what tests the supervisor.)

## 4. Screenshots and keyboard: QMP

QMP is QEMU's JSON control socket. `lib/qmp.sh` opens a fresh `socat` connection per command. It sends `{"execute":"qmp_capabilities"}` and then the command. It counts the command as successful only if two `"return"` replies come back and no line starts with `{"error"`.

- **Before login.** `qmp_screendump <sock> <file.png>` sends `{"execute":"screendump","arguments":{"filename":…,"format":"png"}}`, and QEMU writes the PNG on the laptop. That's how the harness sees the SDDM greeter, and how a failed phase captures `screens/<phase>-fail.png`.
- **After login.** `grim /tmp/c7vt-shot.png` runs inside the session. The harness copies the PNG out with `vm_ssh … cat` into `screens/session.png`.
- **Typing at the greeter.** `qmp_type` sends one `send-key` chord per character, with an uppercase letter sent as `shift` plus the lowercase key. Then `qmp_key ret` presses Return. This is a real keyboard login; no autologin is configured.
- **Seeing a screenshot yourself.** Copy the PNG with `scp` from the laptop to your scratchpad and open it. To see a VM at any moment, call `qmp_screendump` on its `qmp.sock` from the laptop. A screendump like that once showed a stuck VM sitting at the `c7test login:` prompt.

## 5. Checking pixels

`lib/screen.sh` uses ImageMagick for one check only, `screen_not_uniform`: a greyscale standard deviation above 0.01, which means "something is drawn". The earlier "bar strip differs from the middle" check is gone. On the dark theme those two regions differ by under 1% in brightness, so `session.sh` now confirms the bar through `hyprctl layers`.

## 6. The serial console

The VM's serial port goes to `serial.log`. It's only useful while the base image builds:

- cloud-init writes `C7VT-INSTALL-OK` or `C7VT-INSTALL-FAILED` to `/dev/ttyS0`.
- After the VM powers off, `build-base.sh` searches `serial.log` for that marker.

The installed system doesn't log to serial. A failed phase's `<phase>-serial-tail.log` therefore usually shows only the firmware and the boot menu.

## 7. Where results land on the laptop

```
~/.cache/c7shell-vmtest/
  archlinux-<ver>-x86_64.iso   base.qcow2   id_ed25519   c7test.password
  runs/<ts>-<branch>/       VM disk, sockets, pid (kept on failure or --keep)
  results/<ts>-<branch>/    summary.txt, <phase>.log, screens/*.png
```

`summary.txt` lists each phase with its duration and the built package (`pacman -Q c7shell`). It ends in `PASS` or `FAIL: <phase>`.

## Pitfalls already found

Each of these cost a run. Check this list before you debug from scratch.

| Symptom | Cause |
| --- | --- |
| `install` fails in about 20 s, and the log ends at `Proceed with installation? [Y/n] c7shell-setup` | A prompt read the piped script. The harness now copies the script into the VM as a file. |
| `install` fails, and the log ends at a bootstrap pacman prompt | `install.sh --yes` must pass `--noconfirm-pacman` to the bootstrap. That fix is in #257. |
| `install` hangs at `Enter a number (default=1): error: invalid number: y` | Something pipes `yes` into pacman. Pass `--noconfirm` instead. |
| `install.log` stays empty for many minutes | `vm_start` is waiting on `port.lock`, or SSH into the VM hangs. Take a screendump of the VM. |
| `login` fails while the screenshot shows the bar | The harness waited for the wrong process name. The shell runs as `qs`. |
| `assert: no bar drawn` on a visible bar | A pixel heuristic. The check now uses `hyprctl layers`. |
| `screendump` answers `"no surface"` | A GL display device. Keep `virtio-vga -display none`. |
| archinstall config errors | `archinstall.json` follows archinstall 4.5's parser (`lib/args.py`, `lib/models/device.py` on the laptop). Creds use `!root-password` and `!password`; `root_enc_password` expects a hash. |
| `setup-host.sh` fails on a mirror on a fresh host | A stale package database. The script runs `pacman -Syu`. |
| The ISO URL returns 404 | The pinned ISO left `geo.mirror.pkgbuild.com`. Bump `tests/vm/iso.version` to a listed version, or add an `archive.archlinux.org` fallback. |
