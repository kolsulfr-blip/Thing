# Build / provision / update pipeline

Skeleton that formalises the by-hand proof-of-concept into four phases. Scripts
are scaffolding: deterministic parts (cpio surgery, geometry parsing) are real;
the destructive disk operations and PoC-specific commands are stubbed and marked
`TODO(PoC)`. Open forks are marked `DECISION n` and tracked at the bottom.

## Artifact map

| Artifact | Built by | Lives in | Notes |
|----------|----------|----------|-------|
| Deployment head (`deployment-fat.img`) | `make_deployment_image.py` | volume A | gated FS metadata; prints `SCRATCH_OFFSET` |
| Modified `initrd.img` | `steps/initramfs.sh` | volume A | **per-drive** (carries the secrets) |
| Hidden volume A (launcher) | `steps/launcher-squashfs.sh` | disk tail | dm-crypt → squashfs (immutable → static ciphertext) |
| Hidden volume B (tails) | `steps/tails-volume.sh` | disk tail | LUKS (detached header) → LVM VG `VOLUME` → tails |
| Front | `provision.sh` | disk front | SystemRescue (FAT/ESP + UKI) + exFAT bulk over the gated tail |

The secrets (`luks.hdr`, `luks.key`, 32-byte `scratch-seed`) live in A's
initramfs, so the modified initrd — and therefore A's squashfs — is per-drive.

## The four phases

**Phase 1 — Artifact build** (`build.sh`, no disk touched):
verify+extract ISOs → gen per-drive secrets → deployment head (learns
`SCRATCH_OFFSET`) → volume B → modified initrd (patched with `SCRATCH_OFFSET`
+ device, secrets embedded) → volume A squashfs → manifest.

**Phase 2 — Provision** (`provision.sh`, destructive, dry-run unless `--commit`):
high-entropy wipe → SystemRescue front + exFAT bulk → write gated head → write
hidden A and B at the disk tail.

**Phase 3 — Launch / refresh** (`../launch`, already implemented, runs on-target):
capture the 64 MiB baseline-head → write the gated head → objcopy the UKI
(`initrd.img` + trailing `baseline-head.cpio`) → poweroff. Next boot, `../init`
restores head + regenerates scratch from the seed, then opens B.

**Phase 4 — Update / replication** (`update.sh`, runs from A):
check for signed updates → `replicate` (build + provision a fresh drive, leaving
the current one static) or `inplace` (full reprovision of A/B).

## The initramfs surgery (`steps/initramfs.sh` + `lib/initramfs.py`)

The tails initrd is `[leading uncompressed cpios (microcode, modules)][final
compressed cpio (main body)]`. To inject our modifications:

1. `initramfs.py split` walks the leading newc archives to find where the
   compressed main begins and detects its compressor (by magic).
2. Split off the leading region (kept verbatim) and the compressed main.
3. Decompress main → `main.cpio`.
4. `initramfs.py strip-trailer` drops main's terminating `TRAILER!!!` so our
   cpio merges into a single archive (DECISION 2).
5. `cat main.notrailer.cpio mods.cpio` → recompress with the **same** compressor.
6. Reassemble `[leading][new main]` and `pad4` to a 4-byte boundary — `launch`
   relies on this so it can `cat` `baseline-head.cpio` on at deploy time.

`mods.cpio` carries our `init` (overlays tails' `/init`), the restore binaries
(`/opt/dd`, full `openssl`, `xxd`, `head`), and the per-drive secrets.

## Invariants (don't let these drift)

- **`SCRATCH_OFFSET` sync** — the tool's printed offset is the source of truth;
  `build_initramfs` patches it into the per-drive `init` (ISSUES.md #3).
- **4-byte alignment** — `initrd.img` must be 4-byte aligned for the trailing
  `baseline-head.cpio`.
- **scratch length** — `SCRATCH_SIZE_BYTES` must equal init's `128 * 4 MiB`.
- **`scratch-seed` is exactly 32 bytes**, no trailing newline (ISSUES.md #5).
- **Volume A never changes** between (re)provisions — it's why A is squashfs.

## Open decisions

1. **exFAT gating.** Bulk is exFAT but the gater emits FAT32 today. exFAT gating
   = mark the hidden tail used in the allocation bitmap (partition still spans
   the tail). Needs an exFAT emitter; `BULK_FS=exfat` currently aborts.
2. **initramfs merge.** strip-trailer-and-recompress (implemented) vs append as
   a separate trailing segment (proven to work — that's how `launch` adds
   `baseline-head.cpio`). Either way, add the unpack smoke-test (step 8 TODO).
3. **Update model.** `replicate` (default, keeps A static) vs `inplace`.
4. **Build/update host + trust boundary.** Where Phase 1/4 run, network policy,
   and mandatory OpenPGP verification of fetched ISOs against pinned keys.
