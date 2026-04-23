#!/usr/bin/env bash
# Demonstration & verification for fat32_secure_delete.py.
#
# Builds a small FAT32 image, adds two files, saves a snapshot at every
# stage, runs the secure-delete script on the most recent file, and
# confirms that the resulting image is byte-identical to the snapshot
# taken before the most recent file was ever written. It then re-adds
# a different "most recent" file and verifies that it lands in the same
# clusters the deleted file used.
#
# Requires: mkfs.vfat (dosfstools), mcopy (mtools), cmp, python3.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

img="$work/fat.img"
script="$here/fat32_secure_delete.py"

say() { printf '\n== %s ==\n' "$*"; }

# mtools: don't probe /etc/mtab, speak only to our image file.
export MTOOLS_SKIP_CHECK=1
mtools_cfg="$work/mtoolsrc"
cat >"$mtools_cfg" <<EOF
drive z: file="$img" exclusive
EOF
export MTOOLSRC="$mtools_cfg"

# --- build a blank 8 MiB FAT32 image -------------------------------------
truncate -s 8M "$img"
# -F 32 force FAT32, fixed volume-id so the boot sector is reproducible,
# no backup boot sector randomness, small cluster size so we can see
# multi-cluster behavior even with tiny files.
mkfs.vfat -F 32 -s 1 -S 512 -i deadbeef -n TESTVOL "$img" >/dev/null

cp "$img" "$work/00_blank.img"
say "blank image built: $(stat -c%s "$img") bytes"

# --- seed deterministic source files -------------------------------------
# Fixed mtime so mcopy -m produces deterministic directory entries.
printf 'alpha contents -- one cluster worth of payload.\n' >"$work/ALPHA.TXT"
# Bravo spans multiple clusters with a 512-byte cluster size, so we
# exercise chain walking.
python3 -c "open('$work/BRAVO.TXT','w').write('bravo '*400)"
touch -d '2020-01-01T00:00:00' "$work/ALPHA.TXT" "$work/BRAVO.TXT"

# --- state 1: only alpha --------------------------------------------------
mcopy -m -i "$img" "$work/ALPHA.TXT" "::ALPHA.TXT"
cp "$img" "$work/10_A.img"
say "added ALPHA.TXT"
mdir -i "$img" -/ ::

# --- state 2: alpha + bravo ----------------------------------------------
mcopy -m -i "$img" "$work/BRAVO.TXT" "::BRAVO.TXT"
cp "$img" "$work/20_AB.img"
say "added BRAVO.TXT"
mdir -i "$img" -/ ::

# --- secure delete of the most recent file -------------------------------
python3 "$script" "$img" -v
cp "$img" "$work/30_after_delete.img"
say "secure-deleted most recent"
mdir -i "$img" -/ ::

# --- invariant 1: delete undoes the add exactly --------------------------
if cmp -s "$work/10_A.img" "$work/30_after_delete.img"; then
    echo "PASS: post-delete image is byte-identical to pre-BRAVO image"
else
    echo "FAIL: post-delete image differs from pre-BRAVO image"
    cmp -l "$work/10_A.img" "$work/30_after_delete.img" | head -20
    exit 1
fi

# --- invariant 2: the freed clusters are actually zero -------------------
# Pull the starting cluster that BRAVO used out of state 2, then inspect
# that same region in state 3.
read -r bravo_start bravo_bytes <<<"$(python3 - "$work/20_AB.img" <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read()
bps  = struct.unpack_from('<H', img, 11)[0]
spc  = img[13]
res  = struct.unpack_from('<H', img, 14)[0]
nfat = img[16]
fsz  = struct.unpack_from('<I', img, 36)[0]
root = struct.unpack_from('<I', img, 44)[0]
cluster_size = bps * spc
data_off = (res + nfat*fsz) * bps
# walk root directory (single cluster is plenty here)
root_off = data_off + (root-2)*cluster_size
last_short = None
for i in range(root_off, root_off+cluster_size, 32):
    e = img[i:i+32]
    if e[0] == 0: break
    if e[0] == 0xE5 or e[11] == 0x0F: continue
    last_short = e
hi = struct.unpack('<H', last_short[20:22])[0]
lo = struct.unpack('<H', last_short[26:28])[0]
size = struct.unpack('<I', last_short[28:32])[0]
print((hi<<16)|lo, size)
PY
)"

say "BRAVO occupied start_cluster=$bravo_start ($bravo_bytes bytes)"

python3 - "$work/30_after_delete.img" "$bravo_start" "$bravo_bytes" <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read()
start = int(sys.argv[2]); size = int(sys.argv[3])
bps  = struct.unpack_from('<H', img, 11)[0]
spc  = img[13]
res  = struct.unpack_from('<H', img, 14)[0]
nfat = img[16]
fsz  = struct.unpack_from('<I', img, 36)[0]
cluster_size = bps * spc
data_off = (res + nfat*fsz) * bps
off = data_off + (start-2)*cluster_size
region = img[off:off+size]
assert region == b'\x00'*len(region), "freed data region is not zero!"
print(f"PASS: {len(region)} bytes of freed data region are all zero")
PY

# --- invariant 3: next file lands in the same clusters -------------------
# Add a *different* file now and verify its start cluster matches BRAVO's.
printf 'charlie replaces bravo in exactly the same space\n' >"$work/CHARLIE.TXT"
touch -d '2020-01-01T00:00:00' "$work/CHARLIE.TXT"
mcopy -m -i "$img" "$work/CHARLIE.TXT" "::CHARLIE.TXT"
cp "$img" "$work/40_readd.img"
say "re-added CHARLIE.TXT over the hole"
mdir -i "$img" -/ ::

read -r charlie_start _ <<<"$(python3 - "$work/40_readd.img" <<'PY'
import struct, sys
img = open(sys.argv[1], 'rb').read()
bps  = struct.unpack_from('<H', img, 11)[0]
spc  = img[13]
res  = struct.unpack_from('<H', img, 14)[0]
nfat = img[16]
fsz  = struct.unpack_from('<I', img, 36)[0]
root = struct.unpack_from('<I', img, 44)[0]
cluster_size = bps * spc
data_off = (res + nfat*fsz) * bps
root_off = data_off + (root-2)*cluster_size
last_short = None
for i in range(root_off, root_off+cluster_size, 32):
    e = img[i:i+32]
    if e[0] == 0: break
    if e[0] == 0xE5 or e[11] == 0x0F: continue
    last_short = e
hi = struct.unpack('<H', last_short[20:22])[0]
lo = struct.unpack('<H', last_short[26:28])[0]
print((hi<<16)|lo, struct.unpack('<I', last_short[28:32])[0])
PY
)"

if [[ "$charlie_start" == "$bravo_start" ]]; then
    echo "PASS: new file allocated at the same start_cluster ($charlie_start)"
else
    echo "FAIL: new file start_cluster=$charlie_start, expected $bravo_start"
    exit 1
fi

# --- invariant 4: delete the middle file too, back to blank --------------
# First delete CHARLIE (now the only file is ALPHA), then delete ALPHA.
python3 "$script" "$img"
python3 "$script" "$img"
cp "$img" "$work/50_empty.img"
say "deleted both files -- should match original blank image"

if cmp -s "$work/00_blank.img" "$work/50_empty.img"; then
    echo "PASS: twice-deleted image matches the freshly-formatted image"
else
    echo "FAIL: twice-deleted image differs from freshly-formatted image"
    cmp -l "$work/00_blank.img" "$work/50_empty.img" | head -20
    exit 1
fi

echo
echo "All invariants held. Snapshots preserved in $work (cleaned on exit)."
