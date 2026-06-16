#!/usr/bin/env bash
# Phase 2 -- Provision a drive.
#
# Consumes Phase 1 artifacts and writes a physical disk:
#   high-entropy wipe -> SystemRescue front + exFAT bulk -> gated head ->
#   hidden volume A (launcher) and B (tails) at the disk tail.
#
# DESTRUCTIVE. Dry-run by default; pass --commit to actually write.
#
# Usage: provision.sh --commit [--target /dev/disk/by-id/...]
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$PIPELINE_DIR/config.sh"
# shellcheck source=lib/common.sh
. "$PIPELINE_DIR/lib/common.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

COMMIT=0
TARGET="$TARGET_DISK"
while [ $# -gt 0 ]; do
    case "$1" in
        --commit) COMMIT=1 ;;
        --target) TARGET="$2"; shift ;;
        --help)   usage 0 ;;
        *)        die "unknown flag: $1" ;;
    esac
    shift
done

# In dry-run, `run` only prints; nothing is executed.
[ "$COMMIT" = 1 ] || run() { log "DRY-RUN + $*"; }

# Disk-tail layout for the hidden volumes (DECISION: confirm A-before-B order).
HIDDEN_START=$(( DISK_SIZE_BYTES - HIDDEN_TOTAL_BYTES ))
VOL_A_OFFSET=$(( HIDDEN_START ))
VOL_B_OFFSET=$(( HIDDEN_START + VOL_A_BYTES ))

wipe_disk() {
    # High-entropy full-disk wipe so the hidden volumes are indistinguishable
    # from baseline. TODO(PoC): use your fast keystream wipe (AES-CTR over zeros
    # piped to dd) rather than /dev/urandom across a whole HDD.
    log "wipe $TARGET ($(numfmt --to=iec "$DISK_SIZE_BYTES" 2>/dev/null || echo "$DISK_SIZE_BYTES"))"
    run dd if=/dev/urandom of="$TARGET" bs=4M status=progress   # placeholder
}

partition_disk() {
    # DECISION 1: SystemRescue ESP at the front + exFAT spanning the rest (the
    # exFAT partition deliberately covers the gated hidden tail). TODO(PoC):
    # your exact partition table (type, sizes, GPT vs MBR).
    require_cmd sgdisk mkfs.exfat
    warn "TODO: create SystemRescue ESP + exFAT bulk (DECISION 1)"
}

install_systemrescue() {
    require_config SYSRESCUE_ISO
    # TODO(PoC): lay SystemRescue onto the front partition (its files + the
    # bootloader entry that opens hidden volume A and sources launch). Requires
    # copytoram + checksum on its cmdline (launch enforces both).
    warn "TODO: install SystemRescue to the front partition"
}

write_gated_head() {
    # The deployment head makes the bulk filesystem's allocator unable to reach
    # the hidden tail. Written at offset 0 over the freshly-made FS metadata.
    run dd if="$BUILD_DIR/$DEPLOYMENT_IMG_NAME" of="$TARGET" bs=4M conv=notrunc status=progress
}

write_hidden_volumes() {
    # B (tails): LUKS-detached image from build_tails_volume, written raw.
    run dd if="$OUT_DIR/$VOL_B_NAME" of="$TARGET" bs=4M seek="$VOL_B_OFFSET" \
        oflag=seek_bytes conv=notrunc status=progress
    # A (launcher): dm-crypt-wrapped squashfs. TODO(PoC): wrap $OUT_DIR/$VOL_A_NAME
    # in the plain dm-crypt mapping SystemRescue opens, then write the ciphertext
    # at VOL_A_OFFSET. (Plain/no-header keeps the region header-less for
    # deniability; the key is whatever SystemRescue uses to open it.)
    warn "TODO: dm-crypt-wrap volume A and write at offset $VOL_A_OFFSET"
}

main() {
    require_root
    confirm_target_disk "$TARGET"
    [ -f "$OUT_DIR/$VOL_A_NAME" ] && [ -f "$OUT_DIR/$VOL_B_NAME" ] \
        || die "Phase 1 artifacts missing; run build.sh first"
    [ "$COMMIT" = 1 ] || warn "DRY-RUN: pass --commit to write to $TARGET"

    wipe_disk
    partition_disk
    install_systemrescue
    write_gated_head
    write_hidden_volumes
    run sync
    log "Provision complete on $TARGET"
}

main "$@"
