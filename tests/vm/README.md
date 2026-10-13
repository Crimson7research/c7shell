# VM setup test

Installs a pushed c7shell branch onto a fresh, non-graphical Arch VM, logs in
through the real SDDM greeter, and checks the session. It runs on a dedicated
KVM machine, never in `tests/*.sh`.

Design: `docs/superpowers/specs/2026-10-13-vm-setup-test-design.md`.
Operating it (the test laptop, SSH, QMP, pitfalls): `docs/vm-setup-test-operations.md`.

## Set up the test machine

You need Arch with VT-x or AMD-V enabled, 16 GB RAM (8 GB minimum), and about
40 GB free disk.

```bash
tests/vm/setup-host.sh
```

Before the first build, check `archinstall.json` against the archinstall on
the pinned ISO: boot the ISO once, run
`archinstall --config archinstall.json --dry-run`, fix any key it rejects, and
replace the `disk_config` placeholder with the default ext4 layout on
`/dev/vda`.

## Run a test

```bash
tests/vm/run.sh --branch main
```

The first run builds the base image (up to 30 minutes). Later runs reuse it
until `iso.version` or `archinstall.json` changes, or you pass
`--rebuild-base`.

Results go to `~/.cache/c7shell-vmtest/results/<timestamp>-<branch>/`:
`summary.txt` ends in `PASS`, `FAIL: <phase>`, or `FAIL: interrupted` when the run
was stopped from outside (exit 2). A failed run keeps its VM
disk in `~/.cache/c7shell-vmtest/runs/`; `--keep` keeps it after a pass too.

Exit codes: `0` pass, `1` test failure, `2` harness or host problem.

## Known gap

The VM uses virtio-gpu, so the NVIDIA and Intel driver paths of
`c7shell-bootstrap` are not exercised.
