#!/usr/bin/env python3
"""
make_deployment_image.py -- build the deployment FAT32 boot artifact.

The deployment image is a partition table plus a FAT32 metadata head that,
once dd'd to the front of the disk, makes the WHOLE disk present as a single
FAT32 volume whose only writable area is a "scratch" band positioned
immediately before the hidden volumes at the tail of the disk.

Layout produced (raw disk offsets, low -> high):

    0                     MBR: one partition that claims the whole disk
    --part-start (1 MiB)  FAT32 volume boot record + FSInfo (+ backups)
    + reserved + N*FAT    FAT tables. Every cluster entry is 0x00000001
                          (reserved) EXCEPT the scratch band, which is left
                          0x00000000 (free). The FAT allocator can therefore
                          only ever hand out scratch clusters -- this is the
                          write gate that keeps every write off the hidden
                          volumes (and off everything else on the disk).
    cluster 2             empty root directory
    ...                   data region == the physical disk; NOT stored here
    scratch band          free clusters, length == --scratch-size, ending
                          exactly at the start of the hidden volumes
    hidden volumes        --hidden-size bytes at the very end of the disk;
                          their clusters are gated reserved and never touched

Only the head (MBR .. root cluster) is written out -- about 25 MiB for a
~100 GB disk, dominated by the FAT tables that must map the whole disk. dd it
to offset 0 of the target disk.

The scratch byte offset and length this tool prints MUST match the
SCRATCH_OFFSET and regenerated length used by the initramfs restore (init).
They are cluster-aligned here; treat this tool's output as the source of
truth and reconcile init against it.

Usage:
    make_deployment_image.py --disk-size 100030242816 \\
        --hidden-size 31675670528 --scratch-size 512M -o deployment-fat.img

    make_deployment_image.py --device /dev/sdb \\
        --hidden-size 30G --scratch-size 512M
"""

import argparse
import math
import os
import struct
import sys
import zlib


SECTOR_DEFAULT = 512
PART_START_DEFAULT = 1 << 20          # 1 MiB, the conventional first-partition LBA
RESERVED_SECTORS = 32                 # FAT32 standard reserved region
FSINFO_SECTOR = 1                     # within the reserved region
BACKUP_BOOT_SECTOR = 6                # within the reserved region
BACKUP_FSINFO_SECTOR = 7
MEDIA_DESCRIPTOR = 0xF8

FAT_RESERVED = 0x00000001             # the write-gate value: "do not allocate"
FAT_FREE = 0x00000000
FAT_EOC = 0x0FFFFFF8                  # end-of-chain (used for the root dir)


class BuildError(Exception):
    pass


def parse_size(text):
    """Parse an integer byte size with an optional binary suffix (K/M/G/T)."""
    text = text.strip()
    if not text:
        raise ValueError("empty size")
    units = {"B": 1, "K": 1024, "M": 1024 ** 2, "G": 1024 ** 3, "T": 1024 ** 4}
    suffix = text[-1].upper()
    if suffix in units:
        return int(text[:-1]) * units[suffix]
    return int(text)


def device_size(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        return os.lseek(fd, 0, os.SEEK_END)
    finally:
        os.close(fd)


def pick_sectors_per_cluster(partition_sectors):
    """Microsoft's default cluster sizing for FAT32 (512-byte sectors)."""
    thresholds = [
        (532480, 1),          # <= 260 MiB
        (16777216, 8),        # <= 8 GiB
        (33554432, 16),       # <= 16 GiB
        (67108864, 32),       # <= 32 GiB
    ]
    for limit, spc in thresholds:
        if partition_sectors <= limit:
            return spc
    return 64                 # > 32 GiB -> 32 KiB clusters


def fat_size_sectors(partition_sectors, sectors_per_cluster, num_fats):
    """Sectors per FAT, per the fatgen103 reference formula (FAT32)."""
    tmp1 = partition_sectors - RESERVED_SECTORS
    tmp2 = ((256 * sectors_per_cluster) + num_fats) // 2
    return (tmp1 + (tmp2 - 1)) // tmp2


def chs_bytes(lba, heads=255, spt=63):
    """3-byte packed CHS, with the 0xFEFFFF sentinel once we overflow CHS."""
    cyl = lba // (heads * spt)
    head = (lba // spt) % heads
    sec = (lba % spt) + 1
    if cyl > 1023:
        return b"\xFE\xFF\xFF"
    return bytes([head & 0xFF, ((cyl >> 2) & 0xC0) | (sec & 0x3F), cyl & 0xFF])


class Geometry:
    def __init__(self, disk_size, hidden_size, scratch_size, *,
                 sector_size, part_start, num_fats, sectors_per_cluster):
        self.disk_size = disk_size
        self.hidden_size = hidden_size
        self.scratch_size = scratch_size
        self.sector_size = sector_size
        self.part_start = part_start
        self.num_fats = num_fats

        self.part_start_lba = part_start // sector_size
        if self.part_start_lba * sector_size != part_start:
            raise BuildError("partition start is not a multiple of the sector size")
        self.partition_sectors = (disk_size - part_start) // sector_size
        if self.partition_sectors <= 0:
            raise BuildError("disk is smaller than the partition start offset")

        self.sectors_per_cluster = (
            sectors_per_cluster or pick_sectors_per_cluster(self.partition_sectors))
        self.cluster_bytes = self.sectors_per_cluster * sector_size

        self.fat_sectors = fat_size_sectors(
            self.partition_sectors, self.sectors_per_cluster, num_fats)
        self.fat_bytes = self.fat_sectors * sector_size

        data_sectors = (self.partition_sectors
                        - RESERVED_SECTORS - num_fats * self.fat_sectors)
        if data_sectors <= 0:
            raise BuildError("no room left for data clusters; check geometry")
        self.cluster_count = data_sectors // self.sectors_per_cluster
        if self.cluster_count < 65525:
            raise BuildError(
                f"only {self.cluster_count} clusters -- below the FAT32 minimum "
                f"of 65525 (volume too small or cluster size too large)")
        if self.cluster_count + 1 > 0x0FFFFFF6:
            raise BuildError("too many clusters for FAT32; use a larger cluster size")

        # Raw disk byte offset of data cluster 2.
        self.data_region_raw = (
            part_start + (RESERVED_SECTORS + num_fats * self.fat_sectors) * sector_size)

        self._place_scratch()

    def cluster_raw_offset(self, cluster):
        return self.data_region_raw + (cluster - 2) * self.cluster_bytes

    def _place_scratch(self):
        self.hidden_start = self.disk_size - self.hidden_size
        self.scratch_end_req = self.hidden_start
        self.scratch_start_req = self.hidden_start - self.scratch_size
        if self.scratch_start_req <= self.data_region_raw:
            raise BuildError("scratch would overlap the FAT/metadata head; "
                             "disk too small or hidden/scratch too large")

        cb = self.cluster_bytes
        # Clusters whose whole extent lies inside [scratch_start, scratch_end).
        # Clamping to fully-contained clusters guarantees no free cluster ever
        # overlaps the hidden volumes (a write there would corrupt them).
        k_first = math.ceil((self.scratch_start_req - self.data_region_raw) / cb)
        k_last = math.floor((self.scratch_end_req - self.data_region_raw) / cb) - 1
        k_first = max(k_first, 1)                      # never the root cluster (k=0)
        k_last = min(k_last, self.cluster_count - 1)   # last addressable cluster
        if k_last < k_first:
            raise BuildError("scratch band is smaller than one cluster")

        self.first_scratch = k_first + 2
        self.last_scratch = k_last + 2
        self.num_scratch = k_last - k_first + 1
        self.scratch_offset = self.cluster_raw_offset(self.first_scratch)
        self.scratch_len = self.num_scratch * cb

        end = self.scratch_offset + self.scratch_len
        assert self.scratch_offset >= self.scratch_start_req
        assert end <= self.hidden_start, "scratch overruns into the hidden volumes"

    # ---- image construction ------------------------------------------------

    def build_boot_sector(self, volume_id, label):
        bs = bytearray(self.sector_size)
        bs[0:3] = b"\xEB\x58\x90"
        bs[3:11] = b"MSDOS5.0"
        struct.pack_into("<H", bs, 11, self.sector_size)
        bs[13] = self.sectors_per_cluster
        struct.pack_into("<H", bs, 14, RESERVED_SECTORS)
        bs[16] = self.num_fats
        struct.pack_into("<H", bs, 17, 0)             # root entries (0 on FAT32)
        struct.pack_into("<H", bs, 19, 0)             # total sectors 16 (0 -> use 32)
        bs[21] = MEDIA_DESCRIPTOR
        struct.pack_into("<H", bs, 22, 0)             # FAT size 16 (0 on FAT32)
        struct.pack_into("<H", bs, 24, 63)            # sectors per track
        struct.pack_into("<H", bs, 26, 255)           # heads
        struct.pack_into("<I", bs, 28, self.part_start_lba)   # hidden sectors
        struct.pack_into("<I", bs, 32, self.partition_sectors)
        struct.pack_into("<I", bs, 36, self.fat_sectors)
        struct.pack_into("<H", bs, 40, 0)             # ext flags (both FATs active)
        struct.pack_into("<H", bs, 42, 0)             # filesystem version
        struct.pack_into("<I", bs, 44, 2)             # root cluster
        struct.pack_into("<H", bs, 48, FSINFO_SECTOR)
        struct.pack_into("<H", bs, 50, BACKUP_BOOT_SECTOR)
        bs[64] = 0x80                                 # drive number
        bs[66] = 0x29                                 # extended boot signature
        struct.pack_into("<I", bs, 67, volume_id)
        bs[71:82] = label.encode("ascii", "replace").ljust(11)[:11]
        bs[82:90] = b"FAT32   "
        bs[510:512] = b"\x55\xAA"
        return bytes(bs)

    def build_fsinfo(self):
        fs = bytearray(self.sector_size)
        fs[0:4] = b"RRaA"
        fs[484:488] = b"rrAa"
        struct.pack_into("<I", fs, 488, self.num_scratch)      # free cluster count
        struct.pack_into("<I", fs, 492, self.first_scratch)    # next-free hint
        fs[508:512] = b"\x00\x00\x55\xAA"
        return bytes(fs)

    def build_fat(self):
        """One FAT copy: all clusters reserved (0x00000001) except the scratch
        band (free, 0x00000000). Cluster 2 holds the root directory."""
        cap = self.fat_bytes // 4                              # entry capacity
        ent0 = 0x0FFFFF00 | MEDIA_DESCRIPTOR
        ent1 = 0x0FFFFFFF
        res = struct.pack("<I", FAT_RESERVED)
        free = struct.pack("<I", FAT_FREE)

        n_before = self.first_scratch - 3                      # entries 3 .. first-1
        n_after = (self.cluster_count + 1) - self.last_scratch # last+1 .. lastValid
        n_tail = cap - (self.cluster_count + 2)                # unused FAT capacity

        fat = b"".join((
            struct.pack("<III", ent0, ent1, FAT_EOC),          # entries 0,1,2
            res * n_before,
            free * self.num_scratch,
            res * n_after,
            b"\x00\x00\x00\x00" * n_tail,
        ))
        assert len(fat) == self.fat_bytes, (len(fat), self.fat_bytes)
        return fat

    def build_mbr(self, part_type):
        mbr = bytearray(self.sector_size)
        end_lba = self.part_start_lba + self.partition_sectors - 1
        entry = bytearray(16)
        entry[0] = 0x80                                        # bootable flag
        entry[1:4] = chs_bytes(self.part_start_lba)
        entry[4] = part_type
        entry[5:8] = chs_bytes(end_lba)
        struct.pack_into("<I", entry, 8, self.part_start_lba)
        struct.pack_into("<I", entry, 12, self.partition_sectors)
        mbr[446:462] = entry
        mbr[510:512] = b"\x55\xAA"
        return bytes(mbr)

    def build_image(self, *, volume_id, label, part_type):
        ss = self.sector_size
        head_end = self.data_region_raw + self.cluster_bytes  # through root cluster
        img = bytearray(head_end)

        img[0:ss] = self.build_mbr(part_type)

        boot = self.build_boot_sector(volume_id, label)
        fsinfo = self.build_fsinfo()
        vbr = self.part_start
        img[vbr:vbr + ss] = boot
        img[vbr + FSINFO_SECTOR * ss: vbr + FSINFO_SECTOR * ss + ss] = fsinfo
        img[vbr + BACKUP_BOOT_SECTOR * ss: vbr + BACKUP_BOOT_SECTOR * ss + ss] = boot
        img[vbr + BACKUP_FSINFO_SECTOR * ss: vbr + BACKUP_FSINFO_SECTOR * ss + ss] = fsinfo

        fat = self.build_fat()
        fat_off = vbr + RESERVED_SECTORS * ss
        for i in range(self.num_fats):
            img[fat_off + i * self.fat_bytes: fat_off + (i + 1) * self.fat_bytes] = fat

        # Root directory cluster is left empty (zeros). EFI/BOOT is created at
        # launch time, in scratch -- see issue #2 in ISSUES.md.
        return bytes(img)


def verify(geo, image, volume_id):
    """Re-parse the produced head and assert the gate is correct."""
    ss = geo.sector_size
    if image[510:512] != b"\x55\xAA":
        raise BuildError("verify: MBR signature missing")
    vbr = geo.part_start
    if image[vbr + 510:vbr + 512] != b"\x55\xAA":
        raise BuildError("verify: VBR signature missing")
    if image[vbr + 82:vbr + 90] != b"FAT32   ":
        raise BuildError("verify: FS type is not FAT32")
    if struct.unpack_from("<I", image, vbr + 36)[0] != geo.fat_sectors:
        raise BuildError("verify: FAT size mismatch")

    fat_off = vbr + RESERVED_SECTORS * ss
    ent = lambda c: struct.unpack_from("<I", image, fat_off + c * 4)[0] & 0x0FFFFFFF
    if ent(2) != FAT_EOC:
        raise BuildError("verify: root cluster is not end-of-chain")
    if geo.first_scratch > 3 and ent(geo.first_scratch - 1) != FAT_RESERVED:
        raise BuildError("verify: cluster before scratch is not reserved")
    if ent(geo.first_scratch) != FAT_FREE or ent(geo.last_scratch) != FAT_FREE:
        raise BuildError("verify: scratch band is not free")
    if geo.last_scratch < geo.cluster_count + 1 and ent(geo.last_scratch + 1) != FAT_RESERVED:
        raise BuildError("verify: cluster after scratch is not reserved")

    scratch_slice = image[fat_off + geo.first_scratch * 4:
                          fat_off + (geo.last_scratch + 1) * 4]
    if scratch_slice != b"\x00" * (geo.num_scratch * 4):
        raise BuildError("verify: scratch band has non-free entries")

    free_count = struct.unpack_from("<I", image, vbr + FSINFO_SECTOR * ss + 488)[0]
    next_free = struct.unpack_from("<I", image, vbr + FSINFO_SECTOR * ss + 492)[0]
    if free_count != geo.num_scratch or next_free != geo.first_scratch:
        raise BuildError("verify: FSInfo free-cluster accounting is wrong")
    if struct.unpack_from("<I", image, vbr + 67)[0] != volume_id:
        raise BuildError("verify: volume id mismatch")


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.2f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def print_summary(geo, image, out_path, volume_id):
    p = lambda label, value: print(f"  {label:<26} {value}")
    print("\nDeployment image geometry")
    print("-" * 64)
    p("disk size", f"{geo.disk_size} ({human(geo.disk_size)})")
    p("partition start", f"{geo.part_start} (LBA {geo.part_start_lba})")
    p("partition sectors", geo.partition_sectors)
    p("sectors/cluster", f"{geo.sectors_per_cluster} ({human(geo.cluster_bytes)} clusters)")
    p("FATs", f"{geo.num_fats} x {geo.fat_sectors} sectors ({human(geo.fat_bytes)} each)")
    p("data clusters", geo.cluster_count)
    p("volume id", f"0x{volume_id:08X}")
    p("image (head) size", f"{len(image)} ({human(len(image))})")
    p("output", out_path)

    print("\nScratch band  (cluster-aligned; everything else is write-gated)")
    print("-" * 64)
    p("hidden volumes start", f"{geo.hidden_start} ({human(geo.hidden_start)})")
    p("requested scratch", f"[{geo.scratch_start_req}, {geo.scratch_end_req})")
    p("clusters", f"{geo.first_scratch}..{geo.last_scratch} ({geo.num_scratch} clusters)")
    head_slack = geo.scratch_offset - geo.scratch_start_req
    tail_slack = geo.hidden_start - (geo.scratch_offset + geo.scratch_len)
    if head_slack or tail_slack:
        p("alignment slack", f"{head_slack} B at front, {tail_slack} B at back")

    print("\n>>> These MUST match the initramfs restore (init) <<<")
    print("-" * 64)
    print(f"  SCRATCH_OFFSET={geo.scratch_offset}")
    print(f"  scratch length={geo.scratch_len} ({human(geo.scratch_len)})")
    if geo.scratch_len % (4 << 20) == 0:
        print(f"  (= {geo.scratch_len // (4 << 20)} * 4 * 1024 * 1024,"
              f" i.e. {geo.scratch_len // (4 << 20)} blocks at dd's 4M bs)")
    print()


def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__.strip().splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--disk-size", type=parse_size,
                     help="total size of the target disk in bytes (K/M/G/T ok)")
    src.add_argument("--device", help="target block device to query for its size")
    ap.add_argument("--hidden-size", type=parse_size, required=True,
                    help="combined size of the two hidden volumes at the disk tail")
    ap.add_argument("--scratch-size", type=parse_size, required=True,
                    help="size of the scratch band (ends where the hidden volumes begin)")
    ap.add_argument("-o", "--output", default="deployment-fat.img",
                    help="output path for the deployment head (default: %(default)s)")
    ap.add_argument("--cluster-size", type=parse_size, default=None,
                    help="force a cluster size (default: chosen from disk size)")
    ap.add_argument("--part-start", type=parse_size, default=PART_START_DEFAULT,
                    help="first-partition byte offset (default: 1 MiB)")
    ap.add_argument("--num-fats", type=int, default=2)
    ap.add_argument("--sector-size", type=parse_size, default=SECTOR_DEFAULT)
    ap.add_argument("--label", default="NO NAME", help="FAT volume label (BPB field)")
    ap.add_argument("--part-type", default="0x0C",
                    help="MBR partition type byte (default: 0x0C, FAT32 LBA)")
    ap.add_argument("--volume-id", default=None,
                    help="hex volume id (default: derived deterministically from geometry)")
    ap.add_argument("--no-verify", action="store_true",
                    help="skip the post-build self-check")
    args = ap.parse_args(argv)

    try:
        disk_size = args.disk_size if args.disk_size is not None else device_size(args.device)

        spc = None
        if args.cluster_size is not None:
            if args.cluster_size % args.sector_size:
                raise BuildError("cluster size must be a multiple of the sector size")
            spc = args.cluster_size // args.sector_size
            if spc & (spc - 1):
                raise BuildError("cluster size (in sectors) must be a power of two")

        geo = Geometry(disk_size, args.hidden_size, args.scratch_size,
                       sector_size=args.sector_size, part_start=args.part_start,
                       num_fats=args.num_fats, sectors_per_cluster=spc)

        if args.volume_id is not None:
            volume_id = int(args.volume_id, 16) & 0xFFFFFFFF
        else:
            seed = f"{disk_size}:{args.hidden_size}:{args.scratch_size}".encode()
            volume_id = zlib.crc32(seed) & 0xFFFFFFFF

        part_type = int(args.part_type, 16) & 0xFF
        image = geo.build_image(volume_id=volume_id, label=args.label, part_type=part_type)

        if not args.no_verify:
            verify(geo, image, volume_id)

        with open(args.output, "wb") as fh:
            fh.write(image)

        print_summary(geo, image, args.output, volume_id)
        if not args.no_verify:
            print("self-check: PASS\n")
        return 0
    except (BuildError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
