# shellcheck shell=bash
# Central configuration for the build / provision / update pipeline.
# Everything that varies per drive or per environment lives here. Source this
# first; values may be overridden from the environment (all use :- defaults).

# ---- Sources (Phase 1 inputs) ------------------------------------------------
# Local ISO paths, or URLs (build.sh fetches + verifies URLs before use).
TAILS_ISO="${TAILS_ISO:-}"             # e.g. /srv/iso/tails-amd64-x.y.iso
SYSRESCUE_ISO="${SYSRESCUE_ISO:-}"     # e.g. /srv/iso/systemrescue-x.y.iso

# DECISION 4: pinned signing material. Fetched ISOs MUST verify against these
# before anything is built in. Fingerprints have no spaces.
TAILS_SIGNING_KEY="${TAILS_SIGNING_KEY:-$PIPELINE_DIR/keys/tails-signing.gpg}"
TAILS_SIGNING_FPR="${TAILS_SIGNING_FPR:-}"
SYSRESCUE_SIGNING_KEY="${SYSRESCUE_SIGNING_KEY:-$PIPELINE_DIR/keys/sysrescue-signing.gpg}"
SYSRESCUE_SIGNING_FPR="${SYSRESCUE_SIGNING_FPR:-}"

# ---- Target geometry ---------------------------------------------------------
# TARGET_DISK is also compiled into init/launch as DISK_ID -- keep in sync.
# build_initramfs patches this value into the per-drive copy of init.
TARGET_DISK="${TARGET_DISK:-/dev/disk/by-id/usb-HTS72101_0G9SA00_0123456789CB-0:0}"
DISK_SIZE_BYTES="${DISK_SIZE_BYTES:-}"       # total target disk size, bytes
HIDDEN_TOTAL_BYTES="${HIDDEN_TOTAL_BYTES:-}" # combined size of hidden vols A+B

# Scratch band the hidden system regenerates each boot. init regenerates
# exactly 128 * 4 MiB -- keep this identical to that loop (ISSUES.md #3).
SCRATCH_SIZE_BYTES="${SCRATCH_SIZE_BYTES:-$((128 * 4 * 1024 * 1024))}"   # 512 MiB

# Raw head captured verbatim at launch and restored on boot (launch: bs=1M
# count=64; init: /baseline-head-64M.img).
BASELINE_HEAD_BYTES="${BASELINE_HEAD_BYTES:-$((64 * 1024 * 1024))}"      # 64 MiB

# Hidden volume sizing. A = launcher squashfs, B = tails system.
# A + B must equal HIDDEN_TOTAL_BYTES; provision.sh lays them at the disk tail.
VOL_A_BYTES="${VOL_A_BYTES:-}"   # hidden volume A (launcher squashfs, immutable)
VOL_B_BYTES="${VOL_B_BYTES:-}"   # hidden volume B (LUKS -> LVM VG VOLUME -> tails)

# ---- Filesystem choices ------------------------------------------------------
# DECISION 1: bulk filesystem the hidden tail is gated within.
#   fat32 -> reserved-cluster gating (make_deployment_image.py today)
#   exfat -> allocation-bitmap gating (TODO: exfat emitter)
BULK_FS="${BULK_FS:-fat32}"

# ---- Update behaviour --------------------------------------------------------
# DECISION 3: how an update lands.
#   replicate -> build a fresh drive, leave the current one static (keeps
#                volume A's ciphertext unchanging; preferred for deniability)
#   inplace   -> full reprovision of A/B on the current disk
UPDATE_MODE="${UPDATE_MODE:-replicate}"

# ---- initramfs payload -------------------------------------------------------
# Binaries the custom init needs that the stock tails initramfs may lack
# (ISSUES.md #5). Staged into mods.cpio at the paths init expects.
INITRAMFS_EXTRA_BINS=(
    /opt/dd                  # static dd used for the restore
    # /usr/bin/openssl       # full openssl: busybox can't do -aes-256-ctr
    # /usr/bin/xxd
    # /usr/bin/head
)
SCRATCH_SEED_BYTES="${SCRATCH_SEED_BYTES:-32}"  # 256-bit AES-CTR key; EXACTLY 32

# ---- Layout / outputs --------------------------------------------------------
REPO_ROOT="$(cd "$PIPELINE_DIR/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$REPO_ROOT/build}"   # intermediate artifacts
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"         # final artifacts (squashfs, images)

# Artifact filenames -- the deployment image name matches what launch expects.
case "$BULK_FS" in
    fat32) DEPLOYMENT_IMG_NAME="${DEPLOYMENT_IMG_NAME:-deployment-fat.img}" ;;
    exfat) DEPLOYMENT_IMG_NAME="${DEPLOYMENT_IMG_NAME:-deployment-exfat.img}" ;;
    *)     DEPLOYMENT_IMG_NAME="${DEPLOYMENT_IMG_NAME:-deployment.img}" ;;
esac
INITRD_NAME="${INITRD_NAME:-initrd.img}"        # launch cats baseline-head onto this
VOL_A_NAME="${VOL_A_NAME:-vol-a-launcher.squashfs}"
VOL_B_NAME="${VOL_B_NAME:-vol-b-tails.img}"
