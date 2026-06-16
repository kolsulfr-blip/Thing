# shellcheck shell=bash
# Shared helpers. Source after config.sh.

# Loud, fail-fast logging (everything to stderr so stdout stays capturable).
log()  { printf '[%s] %s\n'          "$(date +%H:%M:%S)" "$*" >&2; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[%s] FATAL: %s\n'   "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# Echo a command, then run it. Keeps the skeleton auditable while it is still
# full of destructive operations.
run() { log "+ $*"; "$@"; }

require_cmd() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done
}

require_root() { [ "$(id -u)" -eq 0 ] || die "must run as root"; }

# Validate that named config vars are non-empty (deferred so --help works).
require_config() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "config: $v is unset (edit pipeline/config.sh)"
    done
}

# Network retry with exponential backoff (2,4,8,16s), per the repo git policy.
retry() {
    local n=0 max=5 delay=2
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && die "command failed after $max attempts: $*"
        warn "attempt $n failed; retrying in ${delay}s: $*"
        sleep "$delay"; delay=$((delay * 2))
    done
}

# Cleanup stack: register teardown actions, run them on EXIT in reverse order.
_CLEANUP=()
on_exit() { _CLEANUP+=("$*"); }
_run_cleanup() { local i; for ((i=${#_CLEANUP[@]} - 1; i >= 0; i--)); do eval "${_CLEANUP[i]}" || true; done; }
trap _run_cleanup EXIT

# A ramfs scratch dir so secrets / intermediates never touch disk (mirrors the
# ramfs staging launch already uses). Prints the path on stdout.
new_ramfs_dir() {
    require_root
    local d; d="$(mktemp -d)"
    run mount -t ramfs ramfs "$d"
    on_exit "umount '$d' 2>/dev/null; rmdir '$d' 2>/dev/null"
    printf '%s\n' "$d"
}

# Guard a destructive whole-disk op behind an explicit device check.
confirm_target_disk() {
    local dev="$1"
    [ -b "$dev" ] || die "not a block device: $dev"
    [ "$dev" = "$TARGET_DISK" ] || die "refusing: $dev != configured TARGET_DISK"
    # TODO(safety): interactive "type the serial to continue" prompt before any
    # Phase 2 / Phase 4 wipe.
}

# Map a kernel-supported compressor name to decompress/compress argv. Sets the
# DECOMPRESS and COMPRESS arrays. Match the level tails ships if structural
# parity matters; detection only guarantees the kernel can decode it.
compressor_tools() {
    case "$1" in
        gzip)  DECOMPRESS=(gzip  -dc);              COMPRESS=(gzip  -9c) ;;
        xz)    DECOMPRESS=(xz    -dc);              COMPRESS=(xz    -9c --check=crc32) ;;
        zstd)  DECOMPRESS=(zstd  -dc);              COMPRESS=(zstd  -19 -c) ;;
        bzip2) DECOMPRESS=(bzip2 -dc);              COMPRESS=(bzip2 -9c) ;;
        lzma)  DECOMPRESS=(xz    -dc --format=lzma); COMPRESS=(xz   -9c --format=lzma) ;;
        lzo)   DECOMPRESS=(lzop  -dc);              COMPRESS=(lzop  -9c) ;;
        lz4)   DECOMPRESS=(lz4   -dc);              COMPRESS=(lz4   -9 -l -c) ;;  # -l: kernel legacy
        *)     die "unsupported initramfs compressor: $1" ;;
    esac
}
