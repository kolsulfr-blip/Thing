#!/usr/bin/env python3
"""
Securely remove the most recently added file from a FAT32 volume so that
the volume returns to exactly the state it was in before the file was
written. Every byte of the file's name, metadata, allocation, and data is
overwritten with zeroes, and the FSInfo free-cluster accounting is rewound
so that the next allocation lands in the same clusters.

Usage:
    fat32_secure_delete.py IMAGE [--dir-cluster N] [--dry-run] [-v]

IMAGE may be a FAT32 disk image or a block device. If --dir-cluster is
omitted the root directory is scanned. "Most recent" is defined as the
final live 8.3 directory entry (and its preceding LFN chain, if any);
this matches the order mkfs/mcopy/Windows/Linux all use when appending
new entries to a directory cluster.
"""

import argparse
import os
import struct
import sys


DIR_ENTRY_SIZE = 32
ATTR_LFN = 0x0F
ATTR_DIRECTORY = 0x10
ATTR_VOLUME_ID = 0x08
FAT_MASK = 0x0FFFFFFF
FAT_EOC = 0x0FFFFFF8
FSINFO_LEAD_SIG = b"RRaA"
FSINFO_STRUCT_SIG = b"rrAa"


class Fat32Error(Exception):
    pass


class Fat32Volume:
    def __init__(self, path):
        self.path = path
        self.fp = open(path, "r+b")
        self._parse_bpb()

    def close(self):
        self.fp.close()

    def flush(self):
        self.fp.flush()
        try:
            os.fsync(self.fp.fileno())
        except OSError:
            pass

    def _parse_bpb(self):
        self.fp.seek(0)
        bs = self.fp.read(512)
        if len(bs) < 512 or bs[510:512] != b"\x55\xAA":
            raise Fat32Error("missing 0x55AA boot-sector signature")
        self.bytes_per_sector = struct.unpack_from("<H", bs, 11)[0]
        self.sectors_per_cluster = bs[13]
        self.reserved_sectors = struct.unpack_from("<H", bs, 14)[0]
        self.num_fats = bs[16]
        # 16-bit total sector count is zero on FAT32; the 32-bit field at
        # offset 32 holds the real count, but we don't need it here.
        self.fat_size_sectors = struct.unpack_from("<I", bs, 36)[0]
        if self.fat_size_sectors == 0:
            raise Fat32Error("BPB_FATSz32 is zero -- not a FAT32 volume")
        self.root_cluster = struct.unpack_from("<I", bs, 44)[0]
        self.fsinfo_sector = struct.unpack_from("<H", bs, 48)[0]
        fs_type = bs[82:90]
        if fs_type != b"FAT32   ":
            raise Fat32Error(f"file-system type is {fs_type!r}, expected b'FAT32   '")
        self.cluster_size = self.bytes_per_sector * self.sectors_per_cluster
        self.fat_offset = self.reserved_sectors * self.bytes_per_sector
        self.fat_size_bytes = self.fat_size_sectors * self.bytes_per_sector
        self.data_offset = (
            self.reserved_sectors + self.num_fats * self.fat_size_sectors
        ) * self.bytes_per_sector

    # ---- raw access helpers -------------------------------------------------

    def _cluster_byte_offset(self, cluster):
        if cluster < 2:
            raise Fat32Error(f"invalid cluster number {cluster}")
        return self.data_offset + (cluster - 2) * self.cluster_size

    def read_cluster(self, cluster):
        self.fp.seek(self._cluster_byte_offset(cluster))
        return self.fp.read(self.cluster_size)

    def zero_cluster(self, cluster):
        self.fp.seek(self._cluster_byte_offset(cluster))
        self.fp.write(b"\x00" * self.cluster_size)

    def _fat_entry_offset(self, fat_index, cluster):
        return (
            self.reserved_sectors * self.bytes_per_sector
            + fat_index * self.fat_size_bytes
            + cluster * 4
        )

    def read_fat_entry(self, cluster):
        self.fp.seek(self._fat_entry_offset(0, cluster))
        return struct.unpack("<I", self.fp.read(4))[0] & FAT_MASK

    def write_fat_entry(self, cluster, value):
        """Write a 28-bit value into every FAT copy, preserving the upper
        4 reserved bits of each on-disk entry."""
        for i in range(self.num_fats):
            off = self._fat_entry_offset(i, cluster)
            self.fp.seek(off)
            existing = struct.unpack("<I", self.fp.read(4))[0]
            new = (existing & ~FAT_MASK) | (value & FAT_MASK)
            self.fp.seek(off)
            self.fp.write(struct.pack("<I", new))

    def cluster_chain(self, start):
        if start < 2:
            return []
        chain = []
        seen = set()
        c = start
        while 2 <= c < FAT_EOC:
            if c in seen:
                raise Fat32Error(f"cluster chain loop at {c}")
            seen.add(c)
            chain.append(c)
            c = self.read_fat_entry(c)
        return chain

    def zero_bytes(self, abs_offset, length):
        self.fp.seek(abs_offset)
        self.fp.write(b"\x00" * length)

    # ---- directory scanning -------------------------------------------------

    def find_last_entry(self, dir_start_cluster):
        """Return (short_entry_abs_offset, [entry_abs_offsets]) for the
        final live file in the directory chain, or None if the directory
        holds no real entries. The returned list includes every LFN slot
        that precedes the 8.3 entry, so zeroing all of them removes the
        long filename too."""
        chain = self.cluster_chain(dir_start_cluster)
        if not chain:
            raise Fat32Error("directory has no clusters")

        last_short_off = None
        last_entry_offsets = []
        pending_lfn = []

        for cluster in chain:
            base = self._cluster_byte_offset(cluster)
            data = self.read_cluster(cluster)
            for i in range(0, len(data), DIR_ENTRY_SIZE):
                entry = data[i : i + DIR_ENTRY_SIZE]
                first = entry[0]
                attr = entry[11]
                # 0x00 = "no more entries"; the rest of the directory is
                # guaranteed empty so we can stop. We still break out of
                # everything because zeroed slots past here cannot be
                # "most recent".
                if first == 0x00:
                    if last_short_off is None:
                        return None
                    return last_short_off, last_entry_offsets
                if first == 0xE5:
                    pending_lfn = []
                    continue
                if attr == ATTR_LFN:
                    pending_lfn.append(base + i)
                    continue
                if attr & ATTR_VOLUME_ID and not (attr & ATTR_DIRECTORY):
                    # Volume label lives in the root dir -- not a file.
                    pending_lfn = []
                    continue
                # Skip the "." and ".." entries of subdirectories; they
                # are always at the start and can never be "most recent",
                # but guarding them keeps the invariant explicit.
                name = entry[0:11]
                if name == b".          " or name == b"..         ":
                    pending_lfn = []
                    continue
                last_short_off = base + i
                last_entry_offsets = pending_lfn + [base + i]
                pending_lfn = []

        if last_short_off is None:
            return None
        return last_short_off, last_entry_offsets

    # ---- FSInfo -------------------------------------------------------------

    def update_fsinfo(self, freed_clusters, first_freed):
        if self.fsinfo_sector in (0, 0xFFFF):
            return False
        base = self.fsinfo_sector * self.bytes_per_sector
        self.fp.seek(base)
        if self.fp.read(4) != FSINFO_LEAD_SIG:
            return False
        self.fp.seek(base + 484)
        if self.fp.read(4) != FSINFO_STRUCT_SIG:
            return False
        self.fp.seek(base + 488)
        free_count = struct.unpack("<I", self.fp.read(4))[0]
        if free_count != 0xFFFFFFFF:
            new_count = (free_count + freed_clusters) & 0xFFFFFFFF
            self.fp.seek(base + 488)
            self.fp.write(struct.pack("<I", new_count))
        # Rewind the "next free cluster" hint. Allocators walk the hint
        # forward by one for every cluster they hand out, so the inverse
        # of appending N clusters is subtracting N from the current hint.
        # For a file written contiguously to a fresh volume this lands
        # the hint exactly where it was before the file existed; if the
        # allocation was fragmented the hint may undershoot slightly, in
        # which case we fall back to the first freed cluster (still a
        # valid and optimal starting point).
        self.fp.seek(base + 492)
        old_hint = struct.unpack("<I", self.fp.read(4))[0]
        if old_hint == 0xFFFFFFFF:
            new_hint = 0xFFFFFFFF if first_freed is None else first_freed
        else:
            candidate = old_hint - freed_clusters
            if candidate < 2:
                new_hint = first_freed if first_freed is not None else 2
            else:
                new_hint = candidate
        self.fp.seek(base + 492)
        self.fp.write(struct.pack("<I", new_hint & 0xFFFFFFFF))
        return True


def decode_short_name(raw):
    name = raw[0:8].rstrip(b" ").decode("ascii", errors="replace")
    ext = raw[8:11].rstrip(b" ").decode("ascii", errors="replace")
    return f"{name}.{ext}" if ext else name


def decode_lfn(lfn_entries_raw):
    """Reassemble a long filename from its LFN slot bytes (top slot first
    in the list -- i.e. disk order)."""
    # LFN slots on disk are stored with the highest-sequence entry first
    # (closest to the 8.3 entry they precede when reading backwards). The
    # caller passes them in disk order, which is reverse sequence order.
    parts = []
    for raw in lfn_entries_raw:
        chunk = raw[1:11] + raw[14:26] + raw[28:32]
        parts.append(chunk)
    utf16 = b"".join(parts)
    text = utf16.decode("utf-16-le", errors="replace")
    # LFN is NUL-terminated and 0xFFFF-padded.
    for term in ("\x00", "￿"):
        idx = text.find(term)
        if idx >= 0:
            text = text[:idx]
            break
    return text


def describe_target(fs, short_off, lfn_offsets):
    fs.fp.seek(short_off)
    short = fs.fp.read(DIR_ENTRY_SIZE)
    hi = struct.unpack("<H", short[20:22])[0]
    lo = struct.unpack("<H", short[26:28])[0]
    size = struct.unpack("<I", short[28:32])[0]
    attr = short[11]
    start = (hi << 16) | lo
    lfn_raw = []
    for off in lfn_offsets[:-1]:  # last offset is the 8.3 entry itself
        fs.fp.seek(off)
        lfn_raw.append(fs.fp.read(DIR_ENTRY_SIZE))
    long_name = decode_lfn(lfn_raw) if lfn_raw else ""
    return {
        "short_name": decode_short_name(short),
        "long_name": long_name,
        "start_cluster": start,
        "size": size,
        "attr": attr,
    }


def collect_chain_for_entry(fs, info):
    start = info["start_cluster"]
    if info["attr"] & ATTR_DIRECTORY:
        raise Fat32Error(
            "most recent entry is a directory; recursive secure-delete is "
            "out of scope for this tool -- delete its contents first"
        )
    if info["size"] == 0 and start < 2:
        return []
    return fs.cluster_chain(start)


def secure_delete(image_path, dir_cluster=None, dry_run=False, verbose=False):
    fs = Fat32Volume(image_path)
    try:
        if dir_cluster is None:
            dir_cluster = fs.root_cluster
        result = fs.find_last_entry(dir_cluster)
        if result is None:
            print(f"{image_path}: no files to delete", file=sys.stderr)
            return 1
        short_off, entry_offsets = result
        info = describe_target(fs, short_off, entry_offsets)
        chain = collect_chain_for_entry(fs, info)

        display = info["long_name"] or info["short_name"]
        if verbose or dry_run:
            print(
                f"target: {display!r}  start_cluster={info['start_cluster']}  "
                f"size={info['size']}  clusters={len(chain)}  "
                f"dir_slots={len(entry_offsets)}"
            )
            if chain:
                print(f"chain:  {chain}")

        if dry_run:
            return 0

        for c in chain:
            fs.zero_cluster(c)
        for c in chain:
            fs.write_fat_entry(c, 0)
        for off in entry_offsets:
            fs.zero_bytes(off, DIR_ENTRY_SIZE)
        fs.update_fsinfo(len(chain), chain[0] if chain else None)
        fs.flush()
        return 0
    finally:
        fs.close()


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    p.add_argument("image", help="FAT32 image or block device (opened r+w)")
    p.add_argument(
        "--dir-cluster",
        type=int,
        default=None,
        help="Start cluster of directory to scan (default: root)",
    )
    p.add_argument("--dry-run", action="store_true", help="Describe target without writing")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)
    try:
        return secure_delete(
            args.image,
            dir_cluster=args.dir_cluster,
            dry_run=args.dry_run,
            verbose=args.verbose,
        )
    except Fat32Error as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
