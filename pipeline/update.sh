#!/usr/bin/env bash
# Phase 4 -- Update / replication (the "auto-update").
#
# Lives in volume A so a booted drive can update itself and birth new drives.
# DECISION 3 (UPDATE_MODE):
#   replicate -> build fresh artifacts and provision a NEW target; the current
#                drive is left untouched (volume A's ciphertext stays static --
#                preferred for deniability).
#   inplace   -> rebuild A/B and rewrite those regions on the current disk as a
#                single full-reprovision step (never an incremental write).
#
# Usage: update.sh [--check-only] [--target /dev/disk/by-id/...]
set -euo pipefail

PIPELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
. "$PIPELINE_DIR/config.sh"
# shellcheck source=lib/common.sh
. "$PIPELINE_DIR/lib/common.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

CHECK_ONLY=0
TARGET="$TARGET_DISK"
while [ $# -gt 0 ]; do
    case "$1" in
        --check-only) CHECK_ONLY=1 ;;
        --target)     TARGET="$2"; shift ;;
        --help)       usage 0 ;;
        *)            die "unknown flag: $1" ;;
    esac
    shift
done

# Return 0 if a newer signed tails/SystemRescue is available (DECISION 4).
updates_available() {
    require_cmd gpg
    # TODO(DECISION 4): fetch latest version info over the network (respecting
    # this environment's policy), verify signatures against the pinned keys,
    # compare to the installed versions recorded in the manifest. Refuse to
    # report "available" on any verification failure.
    warn "TODO: update check not implemented (DECISION 4)"
    return 1
}

replicate_to_new_drive() {
    # Fresh secrets + fresh artifacts, then provision a different physical disk.
    require_config TARGET
    run "$PIPELINE_DIR/build.sh"
    run "$PIPELINE_DIR/provision.sh" --commit --target "$TARGET"
}

reprovision_in_place() {
    # Rebuild A/B and rewrite their tail regions on the CURRENT disk in one shot
    # (treat as a wipe-class operation, not an incremental edit, so the region
    # goes from one static blob straight to the next). TODO(PoC): rewrite only
    # the hidden-volume regions + refresh the front, reusing provision.sh's
    # write_hidden_volumes / install_systemrescue without re-wiping user data.
    die "inplace update not implemented yet (DECISION 3)"
}

main() {
    if updates_available; then
        log "update available"
    else
        log "no update available (or check not yet implemented)"
        [ "$CHECK_ONLY" = 1 ] && exit 0
    fi
    [ "$CHECK_ONLY" = 1 ] && exit 0

    case "$UPDATE_MODE" in
        replicate) replicate_to_new_drive ;;
        inplace)   reprovision_in_place ;;
        *)         die "unknown UPDATE_MODE: $UPDATE_MODE" ;;
    esac
}

main "$@"
