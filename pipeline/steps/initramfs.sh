# shellcheck shell=bash
# Phase 1, step 2: surgically rebuild the tails initrd with our modifications.
# See PIPELINE.md "initramfs surgery". DECISION 2 = merge-into-main (strip the
# main archive's trailer, append ours); the separate-segment fallback is noted.
#
# Inputs : $1 = initrd extracted from the tails ISO
#          SCRATCH_OFFSET (from build_deployment_image), SECRETS_DIR (gen_secrets)
# Output : $BUILD_DIR/$INITRD_NAME  (per-drive: carries the secrets)

build_initramfs() {
    require_cmd cpio python3 dd cat
    require_config SCRATCH_OFFSET
    local iso_initrd="$1"
    local py="$PIPELINE_DIR/lib/initramfs.py"
    local out="$BUILD_DIR/$INITRD_NAME"
    local w="$BUILD_DIR/initramfs"; rm -rf "$w"; mkdir -p "$w"

    # 1. Find where the compressed main archive begins, and which compressor.
    local split; split="$(run python3 "$py" split "$iso_initrd")" \
        || die "could not parse initrd segment layout"
    local LEADING_BYTES COMPRESSOR; eval "$split"
    log "leading uncompressed region: $LEADING_BYTES bytes; main compressor: $COMPRESSOR"
    local DECOMPRESS COMPRESS; compressor_tools "$COMPRESSOR"
    require_cmd "${DECOMPRESS[0]}" "${COMPRESS[0]}"

    # 2. Split: leading region (kept verbatim) + the compressed main archive.
    run dd if="$iso_initrd" of="$w/leading.bin"        bs="$LEADING_BYTES" count=1 status=none
    run dd if="$iso_initrd" of="$w/main.$COMPRESSOR"   bs="$LEADING_BYTES" skip=1 status=none

    # 3. Decompress main -> main.cpio.
    "${DECOMPRESS[@]}" < "$w/main.$COMPRESSOR" > "$w/main.cpio" || die "decompress failed"

    # 4. Drop main's terminating TRAILER so our cpio merges into one archive.
    #    (If a kernel unpack test ever shows this is unnecessary, switch to the
    #    separate-segment approach: skip strip + just append mods as a trailing
    #    cpio, the way launch already appends baseline-head.cpio.)
    run python3 "$py" strip-trailer "$w/main.cpio" "$w/main.notrailer.cpio"

    # 5. Build mods.cpio (our init, restore binaries, per-drive secrets).
    gen_mods_cpio "$w/mods.cpio"

    # 6. Concatenate and recompress as the new main archive.
    cat "$w/main.notrailer.cpio" "$w/mods.cpio" > "$w/combined.cpio"
    "${COMPRESS[@]}" < "$w/combined.cpio" > "$w/main.new.$COMPRESSOR" || die "recompress failed"

    # 7. Reassemble [leading][new main]; 4-byte pad so launch can cat
    #    baseline-head.cpio onto the end cleanly (launch relies on this).
    cat "$w/leading.bin" "$w/main.new.$COMPRESSOR" > "$out"
    run python3 "$py" pad4 "$out"

    # 8. TODO(verify): unpack-test $out before trusting it -- decompress the
    #    main segment, `cpio -t`, confirm OUR /init and /etc/luks.* are present
    #    and win over the stock entries. Ideally a throwaway-VM boot smoke test.
    log "initrd.img written: $out ($(stat -c%s "$out") bytes)"
}

# Stage the modification tree and pack it as a newc cpio. Later cpio entries
# win, so our /init overlays the stock tails /init.
gen_mods_cpio() {
    local out="$1"
    require_config SECRETS_DIR
    local tree="$BUILD_DIR/mods"; rm -rf "$tree"; mkdir -p "$tree"

    # Our init (patched with the aligned offset + target device).
    install -D -m 0755 "$REPO_ROOT/init" "$tree/init"
    patch_init "$tree/init"

    # Restore binaries init depends on (config: INITRAMFS_EXTRA_BINS, ISSUES.md #5).
    local b
    for b in "${INITRAMFS_EXTRA_BINS[@]}"; do
        if [ -e "$b" ]; then
            install -D -m 0755 "$b" "$tree$b"
        else
            warn "initramfs binary missing, fill in from PoC: $b"
        fi
    done

    # Per-drive secrets the custom init reads. scratch-seed MUST be exactly
    # 32 bytes with no trailing newline (ISSUES.md #5).
    install -D -m 0400 "$SECRETS_DIR/luks.hdr"     "$tree/etc/luks.hdr"
    install -D -m 0400 "$SECRETS_DIR/luks.key"     "$tree/etc/luks.key"
    install -D -m 0400 "$SECRETS_DIR/scratch-seed" "$tree/scratch-seed"
    [ "$(stat -c%s "$tree/scratch-seed")" -eq "$SCRATCH_SEED_BYTES" ] \
        || die "scratch-seed must be exactly $SCRATCH_SEED_BYTES bytes (ISSUES.md #5)"

    ( cd "$tree" && find . -mindepth 1 -printf '%P\0' \
        | cpio --null --create --format=newc --quiet ) > "$out" \
        || die "could not pack mods.cpio"
}

# Patch the device + cluster-aligned scratch offset into our init copy.
patch_init() {
    local f="$1"
    require_config SCRATCH_OFFSET TARGET_DISK
    run sed -i \
        -e "s|^SCRATCH_OFFSET=.*|SCRATCH_OFFSET=${SCRATCH_OFFSET}|" \
        -e "s|^DISK_ID=.*|DISK_ID=${TARGET_DISK}|" \
        "$f"
    grep -q "^SCRATCH_OFFSET=${SCRATCH_OFFSET}$" "$f" \
        || die "failed to patch SCRATCH_OFFSET into init"
    # TODO(ISSUES.md #1): if /bin/sh in the built initramfs is dash/ash, the
    # bashisms in init's custom insert ([[ ]], set -o pipefail) fail open.
    # Either guarantee bash, or rewrite the insert in POSIX sh.
}
