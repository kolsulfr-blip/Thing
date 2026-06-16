# shellcheck shell=bash
# Phase 1, step 3: build hidden volume B -- the tails system.
#
# Layout (matches init's open path):
#   LUKS (DETACHED header) -> LVM PV -> VG "VOLUME" -> LV(s) -> tails live media
# The detached header is written to $SECRETS_DIR/luks.hdr and shipped inside the
# initramfs (init: cryptsetup open --header=/etc/luks.hdr --key-file=/etc/luks.key);
# nothing LUKS-shaped ever lands on the disk.
#
# Inputs : $1 = tails filesystem.squashfs extracted from the ISO
#          SECRETS_DIR (luks.key from gen_secrets)
# Output : $OUT_DIR/$VOL_B_NAME (raw image of the volume, written at the disk
#          tail by provision.sh)

build_tails_volume() {
    require_root
    require_cmd cryptsetup lvm mksquashfs truncate
    require_config VOL_B_BYTES SECRETS_DIR
    mkdir -p "$OUT_DIR"
    local tails_squashfs="$1"
    local img="$OUT_DIR/$VOL_B_NAME"
    local hdr="$SECRETS_DIR/luks.hdr"
    local key="$SECRETS_DIR/luks.key"

    # Backing image sized to the on-disk slot for volume B.
    run truncate -s "$VOL_B_BYTES" "$img"
    local loop; loop="$(run losetup --show -f "$img")" || die "losetup failed"
    on_exit "losetup -d '$loop' 2>/dev/null"

    # DETACHED header + key file -> this is the header init ships in /etc/luks.hdr.
    run cryptsetup luksFormat --type luks2 --header "$hdr" --key-file "$key" \
        --batch-mode "$loop" \
        || die "luksFormat (detached header) failed"
    run cryptsetup open --header "$hdr" --key-file "$key" "$loop" tails_build \
        || die "cryptsetup open failed"
    on_exit "cryptsetup close tails_build 2>/dev/null"

    # LVM stack init expects: VG must be named VOLUME.
    run pvcreate -ff -y /dev/mapper/tails_build
    run vgcreate VOLUME /dev/mapper/tails_build
    # TODO(PoC): recreate the exact LV layout / names / sizes you used by hand.
    run lvcreate -l 100%FREE -n live VOLUME

    # TODO(PoC): place the tails live media where tails' own boot scripts expect
    # to find the squashfs once the VG is active (init then chains to
    # /scripts/local + mountroot). This may be a filesystem holding
    # live/filesystem.squashfs rather than the squashfs written raw.
    run dd if="$tails_squashfs" of=/dev/VOLUME/live bs=4M status=progress
    : "${tails_squashfs:?}"  # referenced; silence shellcheck on the TODO path

    run sync
    run vgchange -an VOLUME
    run cryptsetup close tails_build
    run losetup -d "$loop"
    log "tails volume (B) written: $img"
}
