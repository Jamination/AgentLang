#!/usr/bin/env python3
"""Checks of the Windows executables alc writes (src/pe.al, src/rsrc.al), without Windows.

  check.py reloc A.exe B.exe   A and B are the same program built for two image bases
                               (ALC_PE_BASE). Applies the base relocation table of A for the
                               base of B: the result must be B byte for byte, so the table
                               lists every absolute address of the image (one it missed would
                               still hold A's base) and nothing else. Also: the table is well
                               formed, every entry is a 64-bit address inside the image, and
                               none lies in the code.
  check.py rsrc A.exe          prints the resources (manifest, icon group, icons, version
                               information) as text, after checking the resource directory.
  check.py headers A.exe       prints the header fields that say how the image is loaded.

Exit status 0 if everything holds, 1 with a message otherwise.
"""
import struct
import sys
import zlib


def fail(msg):
    print("FAIL: " + msg)
    sys.exit(1)


class PE:
    def __init__(self, path):
        self.path = path
        self.data = bytearray(open(path, "rb").read())
        d = self.data
        if d[:2] != b"MZ":
            fail(f"{path}: no MZ header")
        self.pe = struct.unpack_from("<I", d, 0x3C)[0]
        if d[self.pe:self.pe + 4] != b"PE\0\0":
            fail(f"{path}: no PE signature")
        (self.machine, nsec, _, _, _, optsize, self.characteristics) = struct.unpack_from("<HHIIIHH", d, self.pe + 4)
        self.opt = self.pe + 24
        if struct.unpack_from("<H", d, self.opt)[0] != 0x20B:
            fail(f"{path}: not PE32+")
        self.entry = struct.unpack_from("<I", d, self.opt + 16)[0]
        self.base = struct.unpack_from("<Q", d, self.opt + 24)[0]
        self.sect_align, self.file_align = struct.unpack_from("<II", d, self.opt + 32)
        self.size_of_image, self.size_of_headers = struct.unpack_from("<II", d, self.opt + 56)
        self.subsystem, self.dll_characteristics = struct.unpack_from("<HH", d, self.opt + 68)
        ndirs = struct.unpack_from("<I", d, self.opt + 108)[0]
        self.dirs = [struct.unpack_from("<II", d, self.opt + 112 + 8 * i) for i in range(ndirs)]
        self.sections = []
        at = self.opt + optsize
        for i in range(nsec):
            name = bytes(d[at:at + 8]).rstrip(b"\0").decode()
            vsize, rva, rawsize, raw = struct.unpack_from("<IIII", d, at + 8)
            flags = struct.unpack_from("<I", d, at + 36)[0]
            self.sections.append((name, rva, vsize, raw, rawsize, flags))
            at += 40
        self.check_layout()

    def check_layout(self):
        """sections ascend without gaps or overlaps and fill SizeOfImage; directories lie in sections"""
        p = self.path
        if self.base % 0x10000 != 0:
            fail(f"{p}: image base {self.base:#x} is not a multiple of 64 KiB")
        end = self.sect_align
        for (name, rva, vsize, raw, rawsize, flags) in self.sections:
            if rva != end:
                fail(f"{p}: section {name} at RVA {rva:#x}, expected {end:#x}")
            if vsize == 0:
                fail(f"{p}: section {name} is empty")
            if rawsize and (raw % self.file_align or raw + rawsize > len(self.data)):
                fail(f"{p}: section {name}: raw data outside the file")
            end = (rva + vsize + self.sect_align - 1) // self.sect_align * self.sect_align
        if end != self.size_of_image:
            fail(f"{p}: SizeOfImage {self.size_of_image:#x}, the sections end at {end:#x}")
        for i, (rva, size) in enumerate(self.dirs):
            if size and self.section_of(rva, size) is None:
                fail(f"{p}: data directory {i} ({rva:#x}, {size:#x}) is not inside a section")
        if self.section_of(self.entry, 1)[0] != ".text":
            fail(f"{p}: the entry point is not in .text")

    def section_of(self, rva, size=1):
        for s in self.sections:
            if s[1] <= rva and rva + size <= s[1] + s[2]:
                return s
        return None

    def offset(self, rva, size=1):
        """file offset of RVA (inside the initialised part of a section) or None"""
        s = self.section_of(rva, size)
        if s is None or rva + size > s[1] + s[4]:
            return None
        return s[3] + rva - s[1]

    def bytes_at(self, rva, size):
        o = self.offset(rva, size)
        if o is None:
            fail(f"{self.path}: RVA {rva:#x} (+{size:#x}) is not in the file")
        return bytes(self.data[o:o + size])

    def relocs(self):
        """the RVAs of the base relocation table's entries (all must be DIR64)"""
        rva, size = self.dirs[5]
        out = []
        if size == 0:
            return out
        if self.characteristics & 1:
            fail(f"{self.path}: relocations present but the header says they are stripped")
        sec = self.section_of(rva, size)
        if sec[0] != ".reloc" or not sec[5] & 0x02000000:
            fail(f"{self.path}: the relocation table is not in a discardable .reloc section")
        t = self.bytes_at(rva, size)
        at = 0
        last_page = -1
        while at < size:
            page, block = struct.unpack_from("<II", t, at)
            if block < 8 or block % 4 or at + block > size or page % 4096 or page <= last_page:
                fail(f"{self.path}: bad relocation block at {at:#x}: page {page:#x}, size {block}")
            last_page = page
            n = (block - 8) // 2
            prev = -1
            for k in range(n):
                e = struct.unpack_from("<H", t, at + 8 + 2 * k)[0]
                kind, off = e >> 12, e & 0xFFF
                if kind == 0:
                    if k != n - 1 or off != 0:
                        fail(f"{self.path}: padding entry in the middle of a relocation block")
                    continue
                if kind != 10:
                    fail(f"{self.path}: relocation type {kind} (only DIR64, 10, is expected)")
                if off <= prev:
                    fail(f"{self.path}: relocations of page {page:#x} are not ascending")
                prev = off
                out.append(page + off)
            at += block
        return out


def cmd_reloc(a_path, b_path):
    a, b = PE(a_path), PE(b_path)
    if a.base == b.base:
        fail("both images have the same base")
    for img in (a, b):
        if not img.dll_characteristics & 0x40:
            fail(f"{img.path}: DYNAMIC_BASE is not set")
        if not img.dll_characteristics & 0x20 or img.base < 1 << 32:
            fail(f"{img.path}: HIGH_ENTROPY_VA needs a base above 4 GiB")
    fix = a.relocs()
    if fix != b.relocs():
        fail("the two images have different relocation tables")
    delta = b.base - a.base
    out = bytearray(a.data)
    covered = set()
    for rva in fix:
        sec = a.section_of(rva, 8)
        if sec is None or sec[5] & 0x20:
            fail(f"relocation at RVA {rva:#x} is in the code or outside the image")
        o = a.offset(rva, 8)
        if o is None:
            fail(f"relocation at RVA {rva:#x} is not in initialised data")
        v = struct.unpack_from("<Q", out, o)[0]
        if not a.base <= v < a.base + a.size_of_image:
            fail(f"relocation at RVA {rva:#x}: {v:#x} is not an address of the image")
        if covered & set(range(o, o + 8)):
            fail(f"relocation at RVA {rva:#x} overlaps another one")
        covered.update(range(o, o + 8))
        struct.pack_into("<Q", out, o, v + delta)
    struct.pack_into("<Q", out, a.opt + 24, b.base)
    if out != b.data:
        diffs = [i for i in range(min(len(out), len(b.data))) if out[i] != b.data[i]]
        where = []
        for i in diffs[:8]:
            s = next((s for s in a.sections if s[3] <= i < s[3] + s[4]), None)
            where.append(f"{i:#x}" + (f" ({s[0]}+{i - s[3]:#x})" if s else " (headers)"))
        fail(f"{a.path} relocated to {b.base:#x} differs from {b.path} in {len(diffs)} bytes"
             f" (sizes {len(out)}, {len(b.data)}): " + ", ".join(where))
    print(f"ok: {len(fix)} relocations; relocated from {a.base:#x} to {b.base:#x} the image is the other build")


RES_TYPES = {3: "icon", 14: "group-icon", 16: "version", 24: "manifest"}


def res_tree(pe):
    """[(type, id, language, data)] in directory order, after checking the directory"""
    rva, size = pe.dirs[2]
    if size == 0:
        fail(f"{pe.path}: no resource directory")
    sec = pe.section_of(rva, size)
    if sec[0] != ".rsrc" or sec[1] != rva:
        fail(f"{pe.path}: the resource directory is not the .rsrc section")
    t = pe.bytes_at(rva, size)

    def entries(at, level):
        if at + 16 > size:
            fail(f"{pe.path}: resource directory at {at:#x} is outside the section")
        named, ids = struct.unpack_from("<HH", t, at + 12)
        if named:
            fail(f"{pe.path}: named resource entries are not expected")
        out = []
        prev = -1
        for k in range(ids):
            ident, off = struct.unpack_from("<II", t, at + 16 + 8 * k)
            if ident <= prev:
                fail(f"{pe.path}: resource ids at level {level} are not ascending")
            prev = ident
            is_dir = bool(off & 0x80000000)
            if is_dir != (level < 2):
                fail(f"{pe.path}: resource tree is not three levels deep")
            out.append((ident, off & 0x7FFFFFFF))
        return out

    res = []
    for (ty, o1) in entries(0, 0):
        for (ident, o2) in entries(o1, 1):
            for (lang, o3) in entries(o2, 2):
                drva, dsize, codepage, reserved = struct.unpack_from("<IIII", t, o3)
                if not (rva <= drva and drva + dsize <= rva + size):
                    fail(f"{pe.path}: resource {ty}/{ident} data is outside .rsrc")
                res.append((ty, ident, lang, t[drva - rva:drva - rva + dsize]))
    return res


def version_text(v):
    """the version resource as lines"""
    lines = []

    def node(at, depth):
        length, vlen, vtype = struct.unpack_from("<HHH", v, at)
        if length < 6 or at + length > len(v):
            fail(f"version node at {at:#x}: bad length {length}")
        k = at + 6
        while v[k:k + 2] != b"\0\0":
            k += 2
        key = v[at + 6:k].decode("utf-16-le")
        k = (k + 2 + 3) & ~3
        end = at + length
        if depth == 0:
            if key != "VS_VERSION_INFO" or vlen != 52 or vtype != 0:
                fail("version resource does not start with VS_VERSION_INFO")
            f = struct.unpack_from("<13I", v, k)
            if f[0] != 0xFEEF04BD or f[1] != 0x10000:
                fail("bad VS_FIXEDFILEINFO signature")
            ver = lambda ms, ls: f"{ms >> 16}.{ms & 0xFFFF}.{ls >> 16}.{ls & 0xFFFF}"
            lines.append(f"  fixed: file {ver(f[2], f[3])} product {ver(f[4], f[5])} flags {f[7]:#x}/{f[6]:#x} os {f[8]:#x} type {f[9]}")
            k += 52
        elif key == "Translation":
            if vlen != 4 or vtype != 0:
                fail("bad Translation value")
            lang, cp = struct.unpack_from("<HH", v, k)
            lines.append(f"  translation: language {lang:#06x} code page {cp}")
            k += 4
        elif vlen:
            if vtype != 1:
                fail(f"string {key} is not text")
            val = v[k:k + 2 * vlen].decode("utf-16-le")
            if not val.endswith("\0") or "\0" in val[:-1]:
                fail(f"string {key}: the value length does not end at its terminator")
            lines.append(f"  {key}={val[:-1]}")
            k += 2 * vlen
        else:
            if vtype != 1:
                fail(f"node {key} is not text")
            if key not in ("StringFileInfo", "VarFileInfo"):
                lines.append(f"  table {key}")
        k = (k + 3) & ~3
        while k < end:
            k = (node(k, depth + 1) + 3) & ~3
        return end

    if node(0, 0) != len(v):
        fail("the version resource is longer than its root node")
    return lines


def image_kind(img):
    if img[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack_from(">II", img, 16)
        return f"png {w}x{h}"
    if struct.unpack_from("<I", img, 0)[0] == 40:
        w, h, planes, bits = struct.unpack_from("<iiHH", img, 4)
        return f"bitmap {w}x{h // 2} {bits} bits"
    fail("icon image is neither a bitmap nor a PNG")


def cmd_rsrc(path):
    pe = PE(path)
    res = res_tree(pe)
    icons = {ident: data for (ty, ident, lang, data) in res if ty == 3}
    seen = set()
    for (ty, ident, lang, data) in res:
        name = RES_TYPES.get(ty)
        if name is None:
            fail(f"unexpected resource type {ty}")
        if lang != 0x409:
            fail(f"{name} {ident}: language {lang:#x}")
        if ty == 3:
            print(f"icon {ident}: {len(data)} bytes, {image_kind(data)}, crc {zlib.crc32(data):08x}")
        elif ty == 14:
            zero, kind, n = struct.unpack_from("<HHH", data, 0)
            if (zero, kind) != (0, 1) or len(data) != 6 + 14 * n:
                fail("bad icon group")
            print(f"group-icon {ident}: {n} image(s)")
            for k in range(n):
                w, h, colors, r, planes, bits, size, iid = struct.unpack_from("<BBBBHHIH", data, 6 + 14 * k)
                if iid not in icons or len(icons[iid]) != size:
                    fail(f"icon group entry {k}: icon {iid} is missing or has another size")
                if planes != 1 or bits == 0:
                    fail(f"icon group entry {k}: planes {planes}, bits {bits}")
                seen.add(iid)
                print(f"  {w or 256}x{h or 256} {bits} bits -> icon {iid}")
        elif ty == 16:
            print(f"version {ident}:")
            for line in version_text(data):
                print(line)
        else:
            if ident != 1:
                fail("the manifest must be resource 1 (the one Windows reads for an executable)")
            print(f"manifest {ident}:")
            sys.stdout.write(data.decode("utf-8").replace("\r\n", "\n"))
    if seen != set(icons):
        fail("icons that no group lists")
    if not any(ty == 24 for (ty, _, _, _) in res):
        fail("no manifest")


def cmd_headers(path):
    pe = PE(path)
    names = {0x20: "HIGH_ENTROPY_VA", 0x40: "DYNAMIC_BASE", 0x100: "NX_COMPAT", 0x8000: "TERMINAL_SERVER_AWARE"}
    flags = [n for (bit, n) in sorted(names.items()) if pe.dll_characteristics & bit]
    other = pe.dll_characteristics & ~sum(names)
    print(f"base {pe.base:#x}")
    print(f"characteristics {pe.characteristics:#06x}" + (" RELOCS_STRIPPED" if pe.characteristics & 1 else ""))
    print("dll-characteristics " + " ".join(flags) + (f" other {other:#x}" if other else ""))
    print(f"subsystem {pe.subsystem}")
    print("sections " + " ".join(s[0] for s in pe.sections))
    print(f"relocations {len(pe.relocs())}")


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "reloc":
        cmd_reloc(a[1], a[2])
    elif len(a) == 2 and a[0] == "rsrc":
        cmd_rsrc(a[1])
    elif len(a) == 2 and a[0] == "headers":
        cmd_headers(a[1])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
