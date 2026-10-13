# VM setup test: bare Arch to a running c7shell session

## Goal

One command on a dedicated test laptop proves that a named c7shell branch takes
a freshly installed, non-graphical Arch system to a working session: SDDM
greeter, password login, Hyprland, and the c7shell bar. The test needs no human
input and finishes with `PASS` or with `FAIL` naming the phase that broke.

Success criteria:

- `tests/vm/run.sh --branch main` passes on the test laptop.
- A branch with a deliberate break fails, and the report names the right phase.
- Every run starts from the same known base image, and no run changes it.

## Out of scope

- Real GPU drivers. The VM uses virtio-gpu, so the GPU branch of
  `c7shell-bootstrap` is only checked for detection (the `mesa` path), never
  for `nvidia-open-dkms` or `vulkan-intel`. A manual bare-metal test from a USB
  stick can cover that later. It is not part of this harness.
- CI. The harness exits non-zero on failure and needs no terminal, so a cron
  job or a self-hosted runner can call it later unchanged.
- Testing unpushed work. The run installs a pushed branch through the existing
  `C7SHELL_BRANCH` variable of `install.sh`.

## Test host: the spare laptop

The laptop is the KVM host. It runs the VMs and is never itself reinstalled.

- Arch Linux with VT-x or AMD-V enabled in the firmware, so `/dev/kvm` exists.
- 16 GB RAM recommended (8 GB minimum; the VM gets 4 GB), about 40 GB free
  disk.
- Network access, and SSH from the developer's machine.
- `tests/vm/setup-host.sh` installs `qemu-full`, `edk2-ovmf`, `socat`,
  `openssh`, `libisoburn` (for the seed image), `git` and `imagemagick`. It
  checks `/dev/kvm` and membership of the `kvm` group, and creates
  `~/.cache/c7shell-vmtest/` for the ISO, the base image and run overlays.
  It is idempotent.

## Run flow

`tests/vm/run.sh --branch <name> [--keep] [--rebuild-base]` runs these phases
in order and stops at the first failure.

1. **Base image (cached).** If `base.qcow2` is missing, `--rebuild-base` is
   given, or the pinned ISO version or `archinstall.json` changed since the
   last build, `build-base.sh` rebuilds it (see below).
2. **Overlay.** `run-<timestamp>.qcow2` is created with `base.qcow2` as its
   backing file. The base image is never written.
3. **Install.** The VM boots, and the harness waits for SSH as `c7test` with
   the per-host key. It then runs:

   ```bash
   git clone --branch <name> https://github.com/<org>/c7shell.git
   cd c7shell
   C7SHELL_BRANCH=<name> C7SHELL_SKIP_OPTIONAL=1 ./install.sh --yes --noconfirm
   c7shell-setup
   ```

   `--noconfirm` reaches `makepkg` and pacman, which still ask their own
   questions under `--yes`. Passwordless `sudo` for `c7test` comes from the
   base image.
4. **Reboot to the greeter.** The harness reboots the VM and waits until
   `systemctl is-active sddm` reports `active` over SSH and a QMP
   `screendump` is not a single colour.
5. **Log in through the real greeter.** The harness types the `c7test`
   password and `Return` with QMP `send-key` events. No autologin is
   configured.
6. **Assert the session.** Over SSH, inside the logged-in user's session
   environment:
   - `hyprctl version` exits 0.
   - A `quickshell` process runs for `c7test`.
   - `c7shell-doctor` exits 0.
   - `journalctl --user -b` holds no line matching QML errors
     (`qrc:|\.qml:[0-9]+: `).
   - A `grim` screenshot's top bar region differs from the wallpaper region
     below it, so the bar is drawn.
7. **Report.** See "Results".

## Base image build

`build-base.sh` makes the known starting point from two checked-in files:

- `tests/vm/archinstall.json`: UEFI, one ext4 root partition, kernel `linux`,
  profile minimal, packages `openssh git sudo`, NetworkManager, timezone UTC,
  locale `en_US.UTF-8`. No desktop and no greeter, so c7shell's bootstrap
  does all graphical setup.
- `tests/vm/cloud-init/user-data.in`: a NoCloud seed for the Arch ISO's
  built-in cloud-init. It writes the archinstall config and creds, runs
  `archinstall --config … --creds … --silent`, installs the host's public
  key for `c7test`, grants `c7test` passwordless sudo, enables `sshd`, and
  powers off.

Steps: download the pinned ISO into the cache, verify it against Arch's
`sha256sums.txt` and its signature, generate `creds.json` with a random
`c7test` password stored in the cache (never committed), build the seed ISO
with `xorriso`, boot headless with the serial console logged, and wait for
power-off. The build fails if QEMU exits non-zero or the deadline passes.

The pinned ISO version lives in `tests/vm/iso.version`. Bumping it is a
reviewed change.

## Components

All harness files live in `tests/vm/`. It is a subdirectory, so
`for t in tests/*.sh` and `PKGBUILD check()` never start a VM.

| File | Responsibility |
| --- | --- |
| `run.sh` | Entry point: argument parsing and the phase sequence. |
| `build-base.sh` | Builds `base.qcow2` as described above. |
| `setup-host.sh` | One-time, idempotent laptop setup. |
| `archinstall.json`, `iso.version`, `cloud-init/user-data.in` | The known starting point. |
| `lib/qemu.sh` | Starts and stops a VM: KVM, OVMF, 4 GB, 4 vCPU, virtio-gpu, user-mode networking with SSH forwarded to a free host port, a QMP socket, a serial log. |
| `lib/qmp.sh` | QMP commands over `socat`: `screendump`, `send-key` (with a text-to-keycode map), `system_powerdown`, `quit`. |
| `lib/wait.sh` | `wait_for <seconds> <command…>`: polls until the command succeeds or the deadline passes. The other scripts have no bare `sleep`. |
| `lib/screen.sh` | Pure screenshot checks with ImageMagick: "image is not uniform" and "region A differs from region B". |
| `README.md` | How to set up the laptop and run a test. |

## Failure handling

| Phase | Timeout |
| --- | --- |
| Base image build | 30 min |
| Install | 45 min |
| Reboot to greeter | 3 min |
| Login to bar | 2 min |
| Each assertion | 30 s |

On any timeout or failed command the harness saves a QMP screendump, the last
200 serial lines and the verbatim command output, then kills the VM. It exits
1 for a test failure and 2 for a harness or host problem (no `/dev/kvm`, ISO
checksum mismatch, port in use), so a caller can tell the two apart.

## Results

`~/.cache/c7shell-vmtest/results/<timestamp>-<branch>/` holds:

- `summary.txt`: the branch, its commit hash, the ISO version, each phase with
  its duration, and one final `PASS` or `FAIL: <phase>` line.
- `serial.log`, one `<phase>.log` per SSH phase, and `screens/<phase>.png`.

The overlay is deleted after a pass and kept after a failure, or always with
`--keep`, so you can boot it and look.

## Testing the harness

Test first, following the repository's rule:

- `tests/test-vmtest-lib.sh` runs in the normal suite without QEMU. It covers
  `wait_for` deadlines (with a fake clock command), the screen checks against
  fixture PNGs in `tests/fixtures/vmtest/`, the QMP JSON that `qmp.sh` sends
  (with `socat` replaced by a recording fake on `PATH`), the keycode map, and
  `run.sh` argument parsing and exit codes.
- End-to-end proof on the laptop: one passing run against `main`, and one run
  against a throwaway branch that breaks `c7shell-setup`, which must report
  `FAIL: install`.
- `shellcheck` is clean on every script in `tests/vm/`.

## Open items for the user

- Create the throwaway branch for the negative run when the harness is ready.
- Confirm the repository URL the VM clones from (`origin` of this checkout by
  default).
