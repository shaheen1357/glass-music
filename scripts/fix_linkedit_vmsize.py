#!/usr/bin/env python3
"""
Work around a dyld launch crash on re-signed (sideloaded) builds:

    Termination: DYLD, "segment '__LINKEDIT' filesize exceeds vmsize"

The modern linker sizes __LINKEDIT.vmsize with no slack (vmsize == filesize).
When a re-signer (Sideloader / a free Apple ID) embeds a larger code signature
it grows __LINKEDIT.filesize past vmsize, and dyld refuses to load the binary.

We inflate __LINKEDIT.vmsize (page-aligned, with generous headroom) on the
UNSIGNED Mach-O before packaging, so the re-signed signature always fits.
__LINKEDIT is the last segment, so growing its vmsize only extends the tail of
the address space (zero-filled) — nothing overlaps. The ad-hoc signature this
invalidates is replaced by the sideloader anyway.

Usage: fix_linkedit_vmsize.py <path-to-macho-executable>
"""
import sys
import struct

LC_SEGMENT_64 = 0x19
PAGE  = 0x4000     # 16 KB arm64 page
SLACK = 0x40000    # 256 KB headroom for the re-signed signature


def round_up(value, align):
    return (value + align - 1) & ~(align - 1)


def patch_thin(buf, base):
    """Patch one thin Mach-O whose header starts at `base`. Returns True if it
    is a 64-bit LE Mach-O we handled."""
    magic = struct.unpack_from("<I", buf, base)[0]
    if magic != 0xfeedfacf:  # MH_MAGIC_64 (little-endian on disk)
        print(f"  [skip] offset {base}: not a 64-bit LE Mach-O (magic {magic:#x})")
        return False
    ncmds = struct.unpack_from("<I", buf, base + 16)[0]
    off = base + 32  # past mach_header_64 (8 * uint32)
    found = False
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", buf, off)
        if cmd == LC_SEGMENT_64:
            segname = buf[off + 8:off + 24].split(b"\0", 1)[0]
            if segname == b"__LINKEDIT":
                vmsize   = struct.unpack_from("<Q", buf, off + 32)[0]
                filesize = struct.unpack_from("<Q", buf, off + 48)[0]
                new_vmsize = round_up(filesize + SLACK, PAGE)
                if new_vmsize > vmsize:
                    struct.pack_into("<Q", buf, off + 32, new_vmsize)
                    print(f"  __LINKEDIT: filesize={filesize:#x} vmsize {vmsize:#x} -> {new_vmsize:#x}")
                else:
                    print(f"  __LINKEDIT: filesize={filesize:#x} vmsize {vmsize:#x} already ample")
                found = True
        off += cmdsize
    if not found:
        print(f"  [warn] offset {base}: no __LINKEDIT segment")
    return found


def main(path):
    with open(path, "rb") as f:
        buf = bytearray(f.read())

    fat_magic = struct.unpack_from(">I", buf, 0)[0]  # fat headers are big-endian
    handled = False
    if fat_magic in (0xcafebabe, 0xcafebabf):
        nfat = struct.unpack_from(">I", buf, 4)[0]
        is64 = fat_magic == 0xcafebabf
        entry = 8
        for _ in range(nfat):
            if is64:
                offset = struct.unpack_from(">Q", buf, entry + 8)[0]
                entry += 32
            else:
                offset = struct.unpack_from(">I", buf, entry + 8)[0]
                entry += 20
            handled = patch_thin(buf, offset) or handled
    else:
        handled = patch_thin(buf, 0)

    if not handled:
        print("::error::no Mach-O __LINKEDIT segment patched", file=sys.stderr)
        sys.exit(1)

    with open(path, "wb") as f:
        f.write(buf)
    print("Patched:", path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: fix_linkedit_vmsize.py <macho>", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1])
