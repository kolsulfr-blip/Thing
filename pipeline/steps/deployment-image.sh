# shellcheck shell=bash
# Phase 1, step 1: build the gated filesystem head and learn SCRATCH_OFFSET.
#
# Exports SCRATCH_OFFSET for downstream steps (build_initramfs patches it into
# the per-drive init -- ISSUES.md #3, this is now a hard build dependency).

build_deployment_image() {
    require_cmd python3
    require_config DISK_SIZE_BYTES HIDDEN_TOTAL_BYTES SCRATCH_SIZE_BYTES
    mkdir -p "$BUILD_DIR"
    local out="$BUILD_DIR/$DEPLOYMENT_IMG_NAME"

    case "$BULK_FS" in
        fat32)
            # make_deployment_image.py prints a summary including a line
            # "  SCRATCH_OFFSET=<n>" and self-verifies the gate.
            local rpt
            rpt="$(run python3 "$REPO_ROOT/make_deployment_image.py" \
                --disk-size  "$DISK_SIZE_BYTES" \
                --hidden-size "$HIDDEN_TOTAL_BYTES" \
                --scratch-size "$SCRATCH_SIZE_BYTES" \
                --output "$out")" || die "deployment image build failed"
            printf '%s\n' "$rpt" >&2
            SCRATCH_OFFSET="$(printf '%s\n' "$rpt" \
                | sed -n 's/.*SCRATCH_OFFSET=\([0-9]\+\).*/\1/p' | head -n1)"
            ;;
        exfat)
            # DECISION 1 / TODO: emit an exFAT head with the hidden tail marked
            # used in the allocation bitmap (partition still spans the tail; the
            # allocator just can't reach it). Needs an exfat-aware emitter --
            # extend make_deployment_image.py or add a sibling tool that prints
            # the same SCRATCH_OFFSET= line.
            die "exfat gating not implemented yet (DECISION 1)"
            ;;
        *) die "unknown BULK_FS: $BULK_FS" ;;
    esac

    [ -n "${SCRATCH_OFFSET:-}" ] || die "could not parse SCRATCH_OFFSET from builder output"
    export SCRATCH_OFFSET
    log "deployment image: $out   SCRATCH_OFFSET=$SCRATCH_OFFSET"
}
