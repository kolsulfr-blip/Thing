# shellcheck shell=bash
# Phase 1, step 4: build hidden volume A -- the launcher squashfs.
#
# This is the immutable image SystemRescue opens and sources `launch` from.
# It must contain everything launch references plus the boot payload:
#   launch, init (source), cmdline, vmlinuz, initrd.img (modified), the EFI
#   stub, the deployment head, the restore binaries, the per-drive secrets, and
#   the update/provision scripts.
#
# Because it is squashfs (write-once) its ciphertext never changes once dm-crypt
# wrapped -- that static-region property is the whole point (see PIPELINE.md).
#
# Inputs : $1 = vmlinuz extracted from the tails ISO
#          BUILD_DIR/$INITRD_NAME, BUILD_DIR/$DEPLOYMENT_IMG_NAME, SECRETS_DIR
# Output : $OUT_DIR/$VOL_A_NAME

build_launcher_squashfs() {
    require_cmd mksquashfs
    require_config SECRETS_DIR
    mkdir -p "$OUT_DIR"
    local vmlinuz="$1"
    local out="$OUT_DIR/$VOL_A_NAME"
    local stage="$BUILD_DIR/launcher"; rm -rf "$stage"; mkdir -p "$stage"

    # Boot payload assembled by launch's objcopy.
    install -m 0755 "$REPO_ROOT/launch"                  "$stage/launch"
    install -m 0644 "$REPO_ROOT/cmdline"                 "$stage/cmdline"        2>/dev/null \
        || warn "no cmdline in repo root; provide the kernel cmdline file"
    install -m 0644 "$vmlinuz"                           "$stage/vmlinuz"
    install -m 0644 "$BUILD_DIR/$INITRD_NAME"            "$stage/initrd.img"
    install -m 0644 "$BUILD_DIR/$DEPLOYMENT_IMG_NAME"    "$stage/$DEPLOYMENT_IMG_NAME"
    # launch reads it as deployment-fat.img regardless of BULK_FS naming.
    [ "$DEPLOYMENT_IMG_NAME" = "deployment-fat.img" ] \
        || ln -sf "$DEPLOYMENT_IMG_NAME" "$stage/deployment-fat.img"
    # TODO(PoC): the EFI stub launch objcopies into (linuxx64.efi.stub) and the
    # os-release it references. Confirm whether os-release comes from the running
    # SystemRescue (/usr/lib/os-release, absolute) or must be staged here too.
    install -m 0644 "$REPO_ROOT/linuxx64.efi.stub"       "$stage/linuxx64.efi.stub" 2>/dev/null \
        || warn "no linuxx64.efi.stub in repo root; launch's objcopy needs it"

    # Restore binaries (also embedded in initrd.img; launch stages from here).
    local b
    for b in "${INITRAMFS_EXTRA_BINS[@]}"; do
        [ -e "$b" ] && install -D -m 0755 "$b" "$stage$b"
    done

    # Update / provision scripts so a booted drive can replicate + self-update.
    install -d "$stage/pipeline"
    run cp -a "$PIPELINE_DIR/." "$stage/pipeline/"

    # Per-drive secrets. NOTE: these live unencrypted inside volume A, which is
    # itself the dm-crypt-wrapped squashfs -- that wrapping is their protection.
    install -D -m 0400 "$SECRETS_DIR/scratch-seed" "$stage/scratch-seed"
    install -D -m 0400 "$SECRETS_DIR/luks.hdr"     "$stage/etc/luks.hdr"
    install -D -m 0400 "$SECRETS_DIR/luks.key"     "$stage/etc/luks.key"

    # Reproducible-ish squashfs (deterministic apart from the per-drive secrets).
    run mksquashfs "$stage" "$out" -noappend -no-fragments -all-time 0 -mkfs-time 0 \
        -comp zstd \
        || die "mksquashfs failed"
    log "launcher squashfs (A) written: $out ($(stat -c%s "$out") bytes)"
}
