#!/usr/bin/env python3
"""Rewrite one pre-indexed STP in the ARM64EC ntdll.dll (Madeira 0.1.1) so the
store emulator can handle it without an app rebuild.

RtlCreateHeap links a new heap into the process heap list with

    0x26fb0  aa1403ea  mov  x10, x20
    0x26fbc  a9882149  stp  x9, x8, [x10, #0x80]!

When the heap is executable (.NET's HeapCreate(HEAP_CREATE_ENABLE_EXECUTE)),
that store lands in an anon RWX alias and faults; the Mach store emulator in
0.1.1 decodes only signed-offset STP, so the guest takes an access violation
and coreclr fails fast (0xc0000602) -- issue #123, Slay the Spire 2,
Barotrauma. The equivalent pair

    0x26fb0  9102028a  add  x10, x20, #0x80
    0x26fbc  a9002149  stp  x9, x8, [x10]

leaves memory and x10 exactly as before and is decoded. The real fix is the
GPR STP writeback emulation in build/ntdll-unix/signal_arm64_ios.c; this is
for the shipped binary only, and refuses any ntdll.dll whose bytes differ.

usage: patch-ntdll-heap-stp.py ntdll.dll
"""
import struct
import sys

PATCHES = [  # (rva, original, replacement)
    (0x26FB0, 0xAA1403EA, 0x9102028A),
    (0x26FBC, 0xA9882149, 0xA9002149),
]
CONTEXT = (0x26FB0, [0xAA1403EA, 0xF8480D09, 0x91014100, 0xA9882149,
                     0xF9400109, 0xF900052A, 0xF900010A])


def rva_to_offset(data, rva):
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    sec = pe + 24 + opt_size
    for i in range(nsec):
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, sec + i * 40 + 8)
        if vaddr <= rva < vaddr + max(vsize, rsize):
            return raddr + (rva - vaddr)
    raise SystemExit("rva 0x%x is in no section" % rva)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    data = bytearray(open(path, "rb").read())

    words = [struct.unpack_from("<I", data, rva_to_offset(data, CONTEXT[0] + 4 * i))[0]
             for i in range(len(CONTEXT[1]))]
    patched = list(CONTEXT[1])
    for rva, old, new in PATCHES:
        patched[(rva - CONTEXT[0]) // 4] = new
    if words == patched:
        print("ntdll.dll: already patched")
        return
    if words != CONTEXT[1]:
        raise SystemExit("ntdll.dll: unexpected bytes at 0x%x: %s -- not the 0.1.1 build, refusing"
                         % (CONTEXT[0], " ".join("%08x" % w for w in words)))
    for rva, old, new in PATCHES:
        struct.pack_into("<I", data, rva_to_offset(data, rva), new)
        print("ntdll.dll: rva 0x%x %08x -> %08x" % (rva, old, new))
    open(path, "wb").write(data)


if __name__ == "__main__":
    main()
