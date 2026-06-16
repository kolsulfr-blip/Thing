#!/usr/bin/env python3
"""initramfs surgery helpers for the build pipeline.

The tails initrd is a concatenation of cpio (newc) segments: one or more
leading *uncompressed* archives (microcode, kernel modules) followed by a
single *compressed* archive holding the main initramfs body.

This tool does only the deterministic, fiddly parsing. The bash step around it
(steps/initramfs.sh) does the decompress / cat / recompress.

Subcommands:
  split <initrd>            print  LEADING_BYTES=<n>  and  COMPRESSOR=<name>,
                            where <n> is the byte offset at which the
                            compressed main archive begins.
  strip-trailer <in> <out>  copy <in> to <out> with the terminating TRAILER!!!
                            record (and its padding) removed, so a second cpio
                            can be concatenated into a single logical archive.
  pad4 <file>               zero-pad <file> in place to a 4-byte boundary.
"""

import os
import sys

NEWC_MAGICS = (b"070701", b"070702")   # newc, newc+crc
HEADER_LEN = 110                       # 6 magic + 13 * 8 hex fields

# Kernel-supported initramfs compressors, keyed by leading magic bytes.
COMPRESSOR_MAGICS = [
    (b"\x1f\x8b",                "gzip"),
    (b"\xfd7zXZ\x00",            "xz"),
    (b"\x28\xb5\x2f\xfd",        "zstd"),
    (b"\x42\x5a\x68",            "bzip2"),
    (b"\x5d\x00\x00",            "lzma"),
    (b"\x89LZO\x00\r\n\x1a\n",   "lzo"),
    (b"\x02\x21\x4c\x18",        "lz4"),   # kernel legacy lz4
    (b"\x04\x22\x4d\x18",        "lz4"),   # lz4 frame
]


def align4(n):
    return (n + 3) & ~3


def _read(path):
    with open(path, "rb") as f:
        return f.read()


def _field(buf, off, i):
    """The i-th 8-char hex header field of the entry starting at off."""
    s = off + 6 + i * 8
    return int(buf[s:s + 8], 16)


def _entry_bounds(buf, pos):
    """Given a cpio entry header at pos, return (name, next_pos)."""
    if buf[pos:pos + 6] not in NEWC_MAGICS:
        raise ValueError("no cpio magic at offset %d (got %r)"
                         % (pos, buf[pos:pos + 6]))
    namesize = _field(buf, pos, 11)
    filesize = _field(buf, pos, 6)
    name_off = pos + HEADER_LEN
    name = buf[name_off:name_off + namesize]
    pos = align4(name_off + namesize)   # skip name + its padding
    pos = align4(pos + filesize)        # skip file data + its padding
    return name, pos


def _archive_end(buf, start):
    """Return the offset just past the TRAILER!!! of the archive at start."""
    pos = start
    while True:
        name, pos = _entry_bounds(buf, pos)
        if name.rstrip(b"\x00") == b"TRAILER!!!":
            return pos


def detect_compressor(head):
    for magic, name in COMPRESSOR_MAGICS:
        if head.startswith(magic):
            return name
    return None


def split(path):
    buf = _read(path)
    n = len(buf)
    pos = 0
    # Walk every leading *uncompressed* cpio archive verbatim.
    while buf[pos:pos + 6] in NEWC_MAGICS:
        pos = _archive_end(buf, pos)
        while pos < n and buf[pos] == 0:   # skip whole-archive zero padding
            pos += 1
    comp = detect_compressor(buf[pos:pos + 16])
    if comp is None:
        raise ValueError("no known compressor magic at offset %d: %s"
                         % (pos, buf[pos:pos + 8].hex()))
    print("LEADING_BYTES=%d" % pos)
    print("COMPRESSOR=%s" % comp)


def strip_trailer(src, dst):
    """Write src to dst without its terminating TRAILER!!! record + padding."""
    buf = _read(src)
    pos = 0
    while True:
        entry_start = pos
        name, pos = _entry_bounds(buf, pos)
        if name.rstrip(b"\x00") == b"TRAILER!!!":
            with open(dst, "wb") as f:
                f.write(buf[:entry_start])
            return
        if pos >= len(buf):
            raise ValueError("reached EOF without a TRAILER!!! record")


def pad4(path):
    pad = (-os.path.getsize(path)) % 4
    if pad:
        with open(path, "ab") as f:
            f.write(b"\x00" * pad)


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[1]
    try:
        if cmd == "split" and len(argv) == 3:
            split(argv[2])
        elif cmd == "strip-trailer" and len(argv) == 4:
            strip_trailer(argv[2], argv[3])
        elif cmd == "pad4" and len(argv) == 3:
            pad4(argv[2])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except (ValueError, OSError) as e:
        print("error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
