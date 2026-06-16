# Known issues / follow-ups

Items raised during review that we've deliberately deferred rather than
fixed in place. Severity in parentheses.

## 1. `init` custom insert uses bash syntax under `#!/bin/sh` (HIGH)

The restore block added to the initramfs `init` uses `[[ -f ... ]]` and
`set -o pipefail`, both bashisms. The initramfs `/bin/sh` on Debian/Ubuntu is
usually dash or busybox `ash`:

- Under dash, `[[` is an unknown command, so
  `if [[ -f /baseline-head-64M.img ]]` evaluates false and the **entire
  restore block is silently skipped**. Boot then proceeds straight to
  `cryptsetup open` on a disk whose head is still the deployment image ->
  LUKS/LVM fails -> panic, with the hidden volume left exposed. The guard
  fails *open*.
- `set -o pipefail` is also unsupported by dash (non-fatal there, but the
  scratch-regen pipeline loses its only failure check).

Fix: either guarantee `/bin/sh` in the built initramfs is bash, or rewrite the
insert in POSIX sh (`[ -f ... ]`, and restructure the pipeline so it doesn't
need `pipefail`). First step is to confirm what `/bin/sh` actually resolves to
in the produced initramfs.

## 2. `launch` does not create `EFI/BOOT` before writing the UKI (HIGH)

`launch` runs `objcopy ... "$UKIFAT/EFI/BOOT/BOOTX64.EFI"`, but the freshly
written deployment FAT has an empty root directory and `objcopy` will not
create parent directories -- so the UKI assembly fails unless `EFI/BOOT`
already exists.

These directories cannot be baked into the deployment image: their data
clusters would live in the scratch band, which the initramfs regenerates
(keystream) on every boot, wiping them. So they must be created at launch
time, in scratch, e.g. `mkdir -p "$UKIFAT/EFI/BOOT"` before the objcopy.
(Cleaned on restore like everything else in scratch.)

## 3. SCRATCH_OFFSET / scratch length must stay in sync across tools (INVARIANT)

`make_deployment_image.py` computes the scratch band's byte offset and length
from (disk size, combined hidden size, scratch size) and cluster-aligns them.
The initramfs `init` hard-codes these (`SCRATCH_OFFSET`, and the
`128 * 4 * 1024 * 1024` regen length). If they drift, the UKI can land partly
outside the regenerated region and survive a "restore". Treat the tool's
printed values as the source of truth and paste them into `init`.

Note: `init` currently has `SCRATCH_OFFSET=67817701376`; reconcile it against
the tool's output for the real disk/hidden/scratch geometry.

## 4. Restore erases the head before the scratch (MEDIUM)

`init` restores the 64 MiB head first, then regenerates scratch. The sensitive
bytes -- the UKI, which carries `luks.hdr` + `luks.key` -- live in scratch, so
they are the last thing erased. Consider regenerating scratch first, then the
head, so key material dies as early as possible. The running kernel/initrd are
already in RAM, so wiping the on-disk UKI mid-boot is safe.

## 5. initramfs must bundle the restore binaries; seed must be exactly 32 bytes (MEDIUM)

The restore needs a full `openssl` (busybox can't do `-aes-256-ctr`), plus
`xxd`, `head`, and the `/opt/dd` already referenced. `/scratch-seed` must be
exactly 32 bytes: a trailing newline makes `xxd -p -c 64` emit 66 hex chars
and openssl rejects the key, panicking the restore.
