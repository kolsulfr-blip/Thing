#!/usr/bin/env bash
# Phase 1 -- Artifact build (the "auto-build").
#
# Pure data-in/data-out: no target disk is touched. Produces the deployment
# head, the modified initrd, the tails system volume (B), and the launcher
# squashfs (A). Phase 2 (provision.sh) consumes these.
#
# Usage: build.sh            build all artifacts into $OUT_DIR
#        build.sh --help
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$PIPELINE_DIR/config.sh"
# shellcheck source=lib/common.sh
. "$PIPELINE_DIR/lib/common.sh"
for s in "$PIPELINE_DIR"/steps/*.sh; do . "$s"; done

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
[ "${1:-}" = "--help" ] && usage

# --- Phase 1 sub-steps that orchestrate the step library --------------------

# Verify + stage the source ISOs (DECISION 4). Fetched URLs MUST verify against
# the pinned signing keys before any byte is built in.
verify_sources() {
    require_config TAILS_ISO
    require_cmd gpg
    # TODO(DECISION 4): if $TAILS_ISO / $SYSRESCUE_ISO are URLs, fetch with
    # `retry` then gpg --verify the detached signature against the pinned key
    # ($TAILS_SIGNING_KEY / _FPR). Refuse to proceed on any verification gap.
    [ -f "$TAILS_ISO" ] || die "TAILS_ISO not found / not yet fetched: $TAILS_ISO"
    warn "TODO: signature verification not implemented (DECISION 4)"
}

# Pull vmlinuz / initrd / filesystem.squashfs out of the tails ISO.
extract_sources() {
    require_root
    require_cmd mount cp
    local mnt; mnt="$(mktemp -d)"; on_exit "umount '$mnt' 2>/dev/null; rmdir '$mnt' 2>/dev/null"
    run mount -o loop,ro "$TAILS_ISO" "$mnt"
    mkdir -p "$BUILD_DIR/src"
    # TODO(PoC): confirm the in-ISO paths for your tails version.
    run cp "$mnt/live/vmlinuz"            "$BUILD_DIR/src/vmlinuz"
    run cp "$mnt/live/initrd.img"         "$BUILD_DIR/src/initrd.img"
    run cp "$mnt/live/filesystem.squashfs" "$BUILD_DIR/src/filesystem.squashfs"
    run umount "$mnt"
    TAILS_VMLINUZ="$BUILD_DIR/src/vmlinuz"
    TAILS_INITRD="$BUILD_DIR/src/initrd.img"
    TAILS_SQUASHFS="$BUILD_DIR/src/filesystem.squashfs"
}

# Generate per-drive secrets into a ramfs dir. luks.hdr is produced later by
# build_tails_volume (luksFormat --header). scratch-seed: exactly 32 bytes,
# NO trailing newline (ISSUES.md #5).
gen_secrets() {
    require_cmd dd
    SECRETS_DIR="$(new_ramfs_dir)"; export SECRETS_DIR
    run dd if=/dev/urandom of="$SECRETS_DIR/luks.key"     bs=64 count=1 status=none
    run dd if=/dev/urandom of="$SECRETS_DIR/scratch-seed" bs="$SCRATCH_SEED_BYTES" count=1 status=none
    chmod 0400 "$SECRETS_DIR/luks.key" "$SECRETS_DIR/scratch-seed"
}

write_manifest() {
    local m="$OUT_DIR/manifest.txt"
    {
        echo "built: $(date -u +%FT%TZ)"
        echo "bulk_fs: $BULK_FS"
        echo "scratch_offset: ${SCRATCH_OFFSET:-?}"
        echo "scratch_size: $SCRATCH_SIZE_BYTES"
        echo "disk_size: $DISK_SIZE_BYTES"
        echo "hidden_total: $HIDDEN_TOTAL_BYTES (A=$VOL_A_BYTES B=$VOL_B_BYTES)"
        for f in "$OUT_DIR/$VOL_A_NAME" "$OUT_DIR/$VOL_B_NAME" "$BUILD_DIR/$DEPLOYMENT_IMG_NAME" "$BUILD_DIR/$INITRD_NAME"; do
            [ -f "$f" ] && echo "artifact: $f ($(stat -c%s "$f") bytes)"
        done
    } | tee "$m" >&2
}

main() {
    require_root   # ISO mounts, ramfs, loop devices, LVM
    mkdir -p "$BUILD_DIR" "$OUT_DIR"

    verify_sources
    extract_sources
    gen_secrets

    build_deployment_image                       # -> SCRATCH_OFFSET
    build_tails_volume   "$TAILS_SQUASHFS"        # -> vol-b (uses luks.key, makes luks.hdr)
    build_initramfs      "$TAILS_INITRD"          # -> initrd.img (needs SCRATCH_OFFSET + secrets)
    build_launcher_squashfs "$TAILS_VMLINUZ"      # -> vol-a (bundles initrd.img, secrets, scripts)

    write_manifest
    log "Phase 1 complete. Artifacts in $OUT_DIR"
}

main "$@"
