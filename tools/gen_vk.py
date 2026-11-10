#!/usr/bin/env python3
"""Generates std/vk.al (AL bindings for Vulkan) from the Khronos registry vk.xml.

    python3 tools/gen_vk.py            write std/vk.al
    python3 tools/gen_vk.py --verify   also write a C and an AL program to tmp/VulkanBindings/
                                       that print every struct size, field offset and constant
                                       value, build both and compare their output

Only the python3 standard library is used. The hand-written convenience layer
tools/vk_helpers.al is appended verbatim to the generated bindings.
"""
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

# ---- what to generate -------------------------------------------------------------------------
VERSIONS = ["1.0", "1.1", "1.2", "1.3"]
EXTENSIONS = [
    "VK_KHR_surface",
    "VK_KHR_swapchain",
    "VK_KHR_xlib_surface",
    "VK_KHR_xcb_surface",
    "VK_KHR_wayland_surface",
    "VK_EXT_debug_utils",
]
REGISTRY = "/usr/share/vulkan/registry/vk.xml"
LOADER = "/usr/lib/libvulkan.so.1"
LIB = "libvulkan.so.1"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "std", "vk.al")
HELPERS = os.path.join(ROOT, "tools", "vk_helpers.al")
SCRATCH = os.path.join(ROOT, "tmp", "VulkanBindings")
ALC = os.path.join(ROOT, "target", "release", "alc")

AL_KEYWORDS = set(
    "fn struct enum const var test use if else while loop for in by return break continue "
    "assert match defer inline noinline true false nil extern".split()
)

# C scalar and window-system types: name -> (AL type, size). Size 0 marks an opaque type that
# only ever appears behind a pointer.
SCALARS = {
    "void": ("u8", 0), "char": ("u8", 1), "float": ("f32", 4), "double": ("f64", 8),
    "int8_t": ("i8", 1), "uint8_t": ("u8", 1), "int16_t": ("i16", 2), "uint16_t": ("u16", 2),
    "int32_t": ("i32", 4), "uint32_t": ("u32", 4), "int": ("i32", 4),
    "int64_t": ("i64", 8), "uint64_t": ("u64", 8), "size_t": ("u64", 8),
    "Display": ("u8", 0), "Window": ("u64", 8), "VisualID": ("u64", 8),
    "xcb_connection_t": ("u8", 0), "xcb_window_t": ("u32", 4), "xcb_visualid_t": ("u32", 4),
    "wl_display": ("u8", 0), "wl_surface": ("u8", 0),
}
PLATFORM_DEFINES = {
    "xlib": "VK_USE_PLATFORM_XLIB_KHR", "xcb": "VK_USE_PLATFORM_XCB_KHR",
    "wayland": "VK_USE_PLATFORM_WAYLAND_KHR",
}


def api_ok(elem):
    """True if the element belongs to the desktop Vulkan API (not only Vulkan SC)."""
    api = elem.get("api")
    return api is None or "vulkan" in api.split(",")


def al_name(name):
    return name + "_" if name in AL_KEYWORDS else name


def snake(name):
    """VkInstanceCreateInfo -> vk_instance_create_info."""
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", s)
    return s.lower()


class Decl:
    """A struct member or command parameter: base C type, pointer depth, array sizes."""

    def __init__(self, elem):
        text = elem.text or ""
        after_name = ""
        seen_name = False
        for ch in elem:
            piece = (ch.tail or "") if ch.tag == "comment" else (ch.text or "") + (ch.tail or "")
            if ch.tag == "name":
                seen_name = True
                piece = ch.tail or ""
                after_name += piece
            elif seen_name:
                after_name += piece
            text += piece
        self.base = elem.find("type").text
        self.name = elem.find("name").text
        self.nptr = text.count("*")
        self.dims = re.findall(r"\[([^\]]+)\]", after_name)
        self.bitfield = re.match(r"\s*:\s*\d+", after_name) is not None
        self.ctext = " ".join((text[: text.rfind(after_name)] if after_name else text).split())
        self.ctext = re.sub(r"\s*\*", "*", self.ctext + " " + self.name + after_name.strip())
        self.values = elem.get("values")


class Registry:
    def __init__(self, path):
        self.root = ET.parse(path).getroot()
        self.types = {}          # name -> <type> element
        self.type_order = []
        for t in self.root.find("types"):
            if t.tag != "type" or not api_ok(t):
                continue
            name = t.get("name") or t.findtext("name") or t.findtext("proto/name")
            if name and name not in self.types:
                self.types[name] = t
                self.type_order.append(name)
        self.enum_blocks = {e.get("name"): e for e in self.root.findall("enums")}
        self.commands = {}
        self.command_order = []
        for c in self.root.find("commands"):
            if c.tag != "command" or not api_ok(c):
                continue
            name = c.get("name") or c.find("proto").findtext("name")
            if name not in self.commands:
                self.commands[name] = c
                self.command_order.append(name)
        self.select()
        self.collect_enums()
        self.layouts = {}

    # ---- selection ----------------------------------------------------------------------------
    def select(self):
        """Collects the types, commands and enum requirements of the chosen versions/extensions."""
        self.req_types = set()
        self.req_commands = []
        self.req_enums = []      # (element, extension number or None)
        self.platforms = []
        blocks = []
        for f in self.root.findall("feature"):
            if api_ok(f) and f.get("number") in VERSIONS:
                blocks.append((f, None))
        exts = {e.get("name"): e for e in self.root.find("extensions")}
        for name in EXTENSIONS:
            e = exts[name]
            blocks.append((e, int(e.get("number"))))
            if e.get("platform"):
                self.platforms.append(e.get("platform"))
        for block, number in blocks:
            for req in block.findall("require"):
                if not api_ok(req):
                    continue
                for item in req:
                    if not api_ok(item):
                        continue
                    if item.tag == "type":
                        self.req_types.add(item.get("name"))
                    elif item.tag == "command" and item.get("name") not in self.req_commands:
                        self.req_commands.append(item.get("name"))
                    elif item.tag == "enum":
                        self.req_enums.append((item, number))
        # transitive closure over command parameters and struct members
        todo = list(self.req_types)
        for c in self.req_commands:
            cmd = self.resolve_command(c)
            todo.append(cmd.find("proto").findtext("type"))
            todo += [p.findtext("type") for p in cmd.findall("param") if api_ok(p)]
        self.used = set()
        while todo:
            name = todo.pop()
            if name in self.used or name not in self.types:
                continue
            self.used.add(name)
            t = self.types[name]
            if t.get("alias"):
                todo.append(t.get("alias"))
            if t.get("category") in ("struct", "union"):
                todo += [m.findtext("type") for m in t.findall("member") if api_ok(m)]
            if t.get("category") == "bitmask" and (t.get("requires") or t.get("bitvalues")):
                todo.append(t.get("requires") or t.get("bitvalues"))

    def resolve_command(self, name):
        c = self.commands[name]
        return self.commands[c.get("alias")] if c.get("alias") else c

    # ---- enums and constants ------------------------------------------------------------------
    def enum_al_type(self, name):
        block = self.enum_blocks.get(name)
        if block is not None and block.get("bitwidth") == "64":
            return "u64"
        if block is not None and block.get("type") == "bitmask":
            return "u32"
        return "i32"

    def collect_enums(self):
        """self.enums: enum type -> [(name, value)], self.consts: [(name, AL type, literal)]."""
        raw = {}                 # enum type -> {name: value or ("alias", name)}
        for name in self.type_order:
            if name not in self.used or self.types[name].get("category") != "enum":
                continue
            if self.types[name].get("alias"):
                continue
            vals = raw.setdefault(name, {})
            for e in self.enum_blocks[name].findall("enum") if name in self.enum_blocks else []:
                if api_ok(e):
                    vals[e.get("name")] = self.enum_value(e, None)
        api_block = {e.get("name"): e for e in self.enum_blocks["API Constants"] if e.tag == "enum"}
        self.consts = []
        seen = set()
        for e, number in self.req_enums:
            name = e.get("name")
            if e.get("extends"):
                if e.get("extends") in raw:
                    raw[e.get("extends")].setdefault(name, self.enum_value(e, number))
                continue
            if name in seen:
                continue
            seen.add(name)
            src = api_block.get(name, e)
            if src.get("alias"):
                src = api_block[src.get("alias")]
            value = src.get("value")
            if value is None:
                continue
            if value.startswith('"'):
                self.consts.append((name, "", value))
            elif src.get("type") == "float":
                self.consts.append((name, "f32", value.rstrip("Ff")))
            else:
                ctype = src.get("type")
                al = {"uint32_t": "u32", "uint64_t": "u64"}.get(ctype, "")
                m = re.match(r"\(~(\d+)U(LL)?\)$", value)
                if m:
                    bits = 64 if m.group(2) else 32
                    value = "0x%X" % ((1 << bits) - 1 - int(m.group(1)))
                self.consts.append((name, al, value))
        self.enums = {}
        for tname, vals in raw.items():
            out = []
            for name, v in vals.items():
                while isinstance(v, tuple):
                    v = vals[v[1]]
                out.append((name, v))
            self.enums[tname] = out

    def enum_value(self, e, number):
        if e.get("alias"):
            return ("alias", e.get("alias"))
        if e.get("bitpos"):
            return 1 << int(e.get("bitpos"))
        if e.get("offset"):
            ext = int(e.get("extnumber") or number)
            v = 1000000000 + (ext - 1) * 1000 + int(e.get("offset"))
            return -v if e.get("dir") == "-" else v
        return int(e.get("value"), 0)

    # ---- type mapping -------------------------------------------------------------------------
    def scalar(self, name):
        """(AL type, size, is_aggregate) of a C type name; aggregates are sized by layout()."""
        if name in SCALARS:
            return SCALARS[name] + (False,)
        t = self.types[name]
        cat = t.get("category")
        if t.get("alias"):
            return self.scalar(t.get("alias"))
        if cat == "basetype":
            return self.scalar(t.findtext("type"))
        if cat == "bitmask":
            return ("u64", 8, False) if t.findtext("type") == "VkFlags64" else ("u32", 4, False)
        if cat == "handle":
            return ("*u8", 8, False) if t.findtext("type") == "VK_DEFINE_HANDLE" else ("u64", 8, False)
        if cat == "enum":
            al = self.enum_al_type(name)
            return (al, 8 if al == "u64" else 4, False)
        if cat == "funcpointer":
            return ("*u8", 8, False)
        if cat in ("struct", "union"):
            return (name, 0, True)
        raise SystemExit("gen_vk: unmapped C type " + name)

    def al_type(self, d, param=False):
        """(AL type text, size, alignment) of a member or parameter declaration."""
        al, size, aggregate = self.scalar(d.base)
        align = size
        nptr, dims = d.nptr, d.dims
        if param and dims:
            nptr, dims = nptr + 1, []
        if nptr:
            al, size, align = "*" * nptr + al, 8, 8
        elif aggregate:
            size, align = self.layout(d.base)[:2]
        for dim in reversed(dims):
            n = int(dim) if dim.isdigit() else int(dict((c[0], c[2]) for c in self.consts)[dim])
            al, size = "[%s]%s" % (dim, al), size * n
        return al, size, align

    def members(self, name):
        return [Decl(m) for m in self.types[name].findall("member") if api_ok(m)]

    def layout(self, name):
        """(size, alignment, [field offsets]) of a struct or union under the C rules."""
        if name in self.layouts:
            return self.layouts[name]
        t = self.types[name]
        if t.get("alias"):
            return self.layout(t.get("alias"))
        union = t.get("category") == "union"
        size, align, offsets = 0, 1, []
        for d in self.members(name):
            _, fsize, falign = self.al_type(d)
            align = max(align, falign)
            if union:
                size = max(size, fsize)
                offsets.append(0)
            else:
                size = (size + falign - 1) // falign * falign
                offsets.append(size)
                size += fsize
        size = (size + align - 1) // align * align
        self.layouts[name] = (size, align, offsets)
        return self.layouts[name]

    def selected(self, category):
        return [n for n in self.type_order
                if n in self.used and self.types[n].get("category") == category]

    def exported(self):
        """Names the loader exports, or None if that cannot be determined."""
        try:
            out = subprocess.run(["nm", "-D", "--defined-only", LOADER], capture_output=True,
                                 text=True, check=True).stdout
        except (OSError, subprocess.CalledProcessError):
            return None
        return set(line.split()[-1] for line in out.splitlines() if line.strip())


# ---- emitting std/vk.al -----------------------------------------------------------------------
def c_kind(reg, base):
    """Comment naming the C type of a field whose AL type hides it (enum, flags, handle)."""
    if base in SCALARS:
        return ""
    cat = reg.types[base].get("category")
    return base if cat in ("enum", "bitmask", "handle", "basetype", "funcpointer") else ""


def generate(reg):
    out = []
    w = out.append
    w("// std.vk: bindings for Vulkan %s and %s." % (VERSIONS[0] + "-" + VERSIONS[-1], ", ".join(EXTENSIONS)))
    w("// GENERATED by tools/gen_vk.py from vk.xml; do not edit. The convenience layer at the end")
    w("// comes from tools/vk_helpers.al. See docs/std/vk.md.")
    w("//")
    w("// Mapping: dispatchable handles (VkInstance, VkDevice, ...) are *u8, non-dispatchable handles")
    w("// (VkBuffer, VkImage, ...) are u64, enums are i32, flags are u32 (u64 for 64-bit flag types),")
    w("// VkBool32 is u32, VkDeviceSize and size_t are u64; structs have the C layout.")
    w("")
    w("// ---- constants ----")
    w("const VK_NULL_HANDLE u64 = 0")
    for v in VERSIONS:
        major, minor = v.split(".")
        w("const VK_API_VERSION_%s_%s u32 = 0x%08X" % (major, minor, int(major) << 22 | int(minor) << 12))
    for name, al, value in reg.consts:
        w("const %s%s = %s" % (name, " " + al if al else "", value))

    w("")
    w("// ---- handles ----")
    disp = [n for n in reg.selected("handle") if reg.scalar(n)[0] == "*u8"]
    nondisp = [n for n in reg.selected("handle") if reg.scalar(n)[0] == "u64"]
    w("// *u8: " + ", ".join(disp))
    w("// u64: " + ", ".join(nondisp))

    w("")
    w("// ---- enums and flag bits ----")
    for name in reg.selected("enum"):
        vals = reg.enums.get(name)
        if not vals:
            continue
        al = reg.enum_al_type(name)
        w("// " + name)
        for vname, v in vals:
            lit = str(v) if al == "i32" else "0x%X" % v
            w("const %s %s = %s" % (vname, al, lit))

    w("")
    w("// ---- structs ----")
    reg.struct_names = []
    reg.skipped = []
    ctors = []
    for name in reg.type_order:
        if name not in reg.used:
            continue
        t = reg.types[name]
        cat = t.get("category")
        if cat not in ("struct", "union"):
            continue
        if t.get("alias"):
            w("// %s is another name of %s" % (name, t.get("alias")))
            continue
        members = reg.members(name)
        if cat == "union":
            size, align, _ = reg.layout(name)
            word = {1: "u8", 2: "u16", 4: "u32", 8: "u64"}[align]
            w("// union %s { %s }" % (name, "; ".join(d.ctext for d in members)))
            w("struct %s { data [%d]%s }" % (name, size // align, word))
            reg.struct_names.append(name)
            continue
        if any(d.bitfield for d in members):
            w("// %s is not bound: it contains bit-fields" % name)
            reg.skipped.append(name)
            continue
        w("struct %s {" % name)
        for d in members:
            al = reg.al_type(d)[0]
            kind = c_kind(reg, d.base)
            note = ""
            if kind:
                note = "    // " + kind + "*" * d.nptr
            elif d.base in ("char", "void") and d.nptr:
                note = "    // " + d.base + "*" * d.nptr
            w("    %s %s%s" % (al_name(d.name), al, note))
        w("}")
        reg.struct_names.append(name)
        if members and members[0].name == "sType" and members[0].values:
            ctors.append((name, members[0].values.split(",")[0]))

    w("")
    w("// ---- commands ----")
    exported = reg.exported()
    missing = []
    for name in reg.req_commands:
        cmd = reg.resolve_command(name)
        proto = Decl(cmd.find("proto"))
        params = [Decl(p) for p in cmd.findall("param") if api_ok(p)]
        ret = ""
        if proto.base != "void" or proto.nptr:
            ret = " " + reg.al_type(proto)[0]
        sig = "(%s)%s" % (
            ", ".join("%s %s" % (al_name(p.name), reg.al_type(p, True)[0]) for p in params), ret)
        if exported is not None and name not in exported:
            missing.append("%s: fn(%s)%s" % (
                name, ", ".join(reg.al_type(p, True)[0] for p in params), ret))
            continue
        w("// %s %s(%s)" % (proto.base + "*" * proto.nptr, name, ", ".join(p.ctext for p in params)))
        w('extern "%s" fn %s%s' % (LIB, name, sig))
    if missing:
        w("// Not exported by the loader; get the address with vkGetInstanceProcAddr and cast it to")
        w("// the function type shown: cast[fn(...) i32](vkGetInstanceProcAddr(instance, ptr(\"vkName\")))")
        for line in missing:
            w("//   " + line)

    w("")
    w("// ---- constructors: a zeroed struct with sType filled in ----")
    for name, stype in ctors:
        w("// %s with sType set." % name)
        w("fn %s() %s { %s{sType: %s} }" % (snake(name), name, name, stype))

    w("")
    w("// ---- result names ----")
    w("// Name of a VkResult value (\"VK_SUCCESS\", \"VK_ERROR_DEVICE_LOST\", ...).")
    w("fn vk_result_name(result i32) str {")
    w("    match result {")
    seen = set()
    for vname, v in reg.enums["VkResult"]:
        if v not in seen:
            seen.add(v)
            w('        %s => "%s"' % (vname, vname))
    w('        _ => "VkResult(unknown)"')
    w("    }")
    w("}")
    w("")
    with open(HELPERS) as f:
        return "\n".join(out) + "\n" + f.read()


# ---- layout verification ----------------------------------------------------------------------
def verify(reg):
    os.makedirs(SCRATCH, exist_ok=True)
    c = ["#define %s" % PLATFORM_DEFINES[p] for p in reg.platforms]
    c += ["#include <vulkan/vulkan.h>", "#include <stdio.h>", "#include <stddef.h>", "int main(void) {"]
    al = ["use std.vk", "fn o(base i64, p i64) { put(\" \", p - base) }"]
    calls = []
    nfields = 0
    for name in reg.struct_names:
        union = reg.types[name].get("category") == "union"
        fields = [] if union else reg.members(name)
        nfields += len(fields)
        c.append('    printf("%s %%zu%s\\n", sizeof(%s)%s);' % (
            name, " %zu" * len(fields), name,
            "".join(", offsetof(%s, %s)" % (name, d.name) for d in fields)))
        al.append("fn l_%s() {" % name)
        al.append("    var s %s" % name)
        al.append("    b := cast[i64](&s)")
        al.append('    put("%s ", sizeof[%s]())' % (name, name))
        for d in fields:
            al.append("    o(b, cast[i64](&s.%s))" % al_name(d.name))
        al.append("    putc('\\n')")
        al.append("}")
        calls.append("l_%s()" % name)
    consts = [(n, a) for n, a, v in reg.consts if a != "f32" and not v.startswith('"')]
    for tname in reg.selected("enum"):
        consts += [(n, reg.enum_al_type(tname)) for n, _ in reg.enums.get(tname, [])]
    for i, (name, a) in enumerate(consts):
        if a == "u32" or a == "u64":
            c.append('    printf("%s %%llu\\n", (unsigned long long)%s);' % (name, name))
        else:
            c.append('    printf("%s %%lld\\n", (long long)%s);' % (name, name))
        if i % 200 == 0:
            if i:
                al.append("}")
            al.append("fn c_%d() {" % (i // 200))
            calls.append("c_%d()" % (i // 200))
        al.append('    print("%s", %s)' % (name, name))
    al.append("}")
    c += ["    return 0;", "}"]
    al += ["fn main() {"] + ["    " + x for x in calls] + ["}"]
    cpath, alpath = os.path.join(SCRATCH, "layout.c"), os.path.join(SCRATCH, "layout.al")
    with open(cpath, "w") as f:
        f.write("\n".join(c) + "\n")
    with open(alpath, "w") as f:
        f.write("\n".join(al) + "\n")
    env = dict(os.environ, ALC_STD_DIR=os.path.join(ROOT, "std"))
    subprocess.run(["clang", "-o", os.path.join(SCRATCH, "layout_c"), cpath], check=True)
    subprocess.run([ALC, "build", alpath, "-o", os.path.join(SCRATCH, "layout_al")], check=True, env=env)
    want = subprocess.run([os.path.join(SCRATCH, "layout_c")], capture_output=True, text=True, check=True).stdout
    got = subprocess.run([os.path.join(SCRATCH, "layout_al")], capture_output=True, text=True, check=True).stdout
    # the generator's own layout computation (used to size unions) must agree as well
    own = {n: reg.layout(n) for n in reg.struct_names}
    bad = 0
    wl, gl = want.splitlines(), got.splitlines()
    for i in range(max(len(wl), len(gl))):
        a = wl[i] if i < len(wl) else "(missing)"
        b = gl[i] if i < len(gl) else "(missing)"
        if a != b:
            bad += 1
            print("MISMATCH  C: %s\n          AL: %s" % (a, b))
            continue
        parts = a.split()
        if parts[0] in own:
            size, _, offsets = own[parts[0]]
            mine = [size] + (offsets if len(parts) > 2 else [])
            if [int(x) for x in parts[1:]] != mine:
                bad += 1
                print("MISMATCH  C: %s\n      python: %s" % (a, mine))
    print("layout: %d structs (%d fields), %d constants compared, %d mismatches" % (
        len(reg.struct_names), nfields, len(consts), bad))
    if reg.skipped:
        print("skipped (bit-fields): " + ", ".join(reg.skipped))
    return bad == 0


def main():
    reg = Registry(REGISTRY)
    text = generate(reg)
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote %s: %d lines, %d structs, %d commands" % (
        os.path.relpath(OUT, ROOT), text.count("\n"), len(reg.struct_names),
        text.count("\nextern ")))
    if "--verify" in sys.argv[1:] and not verify(reg):
        sys.exit(1)


if __name__ == "__main__":
    main()
