// The resources of a Windows executable (the .rsrc section of pe.al): the application
// manifest (always), the icon (`--icon`) and the version information (`--version-info`).
//
// The section is a tree of directories, three levels deep: resource type, resource id,
// language (all of them English (United States), 0x409). A directory is 16 bytes (the last
// u16: the number of entries) and 8 per entry (id, offset in the section; bit 31: of a
// directory); a leaf is a data entry (16 bytes: the RVA and the size of the data). Ids ascend.

priv const RT_ICON = 3
priv const RT_GROUP_ICON = 14
priv const RT_VERSION = 16
priv const RT_MANIFEST = 24

// The application manifest (resource 1 of type 24), read by Windows when the process starts:
// - asInvoker: the program runs with the rights of whoever starts it (without this entry,
//   Windows guesses from the file name whether an old program is an installer to elevate);
// - supportedOS: Windows 10 and 11 (one id for both), so that the system reports its real
//   version and behaves as on these versions;
// - dpiAwareness: per-monitor (v2), else system aware (dpiAware, for Windows before 10 1607):
//   what std.window asks for at run time (std/window_windows.al): sizes are physical pixels
//   and the system scales nothing, for every program, with or without a std.window window;
// - longPathAware: paths over 260 characters work where the system allows them
//   (LongPathsEnabled in the registry; Windows 10 1607);
// - activeCodePage UTF-8 (Windows 10 1903): the `A` functions of Windows and of C libraries
//   that a program declares take and return UTF-8, which is what AL strings are. The run-time
//   library itself only calls `W` functions, with its own conversion, so its behaviour is the
//   same with and without the setting, on every version of Windows.
priv const MANIFEST = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2, system</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
      <activeCodePage xmlns="http://schemas.microsoft.com/SMI/2019/WindowsSettings">UTF-8</activeCodePage>
    </windowsSettings>
  </application>
</assembly>
`

// the names `--version-info NAME=VALUE` takes: the strings of a version resource
priv const VERSION_KEYS = [_]str{"Comments", "CompanyName", "FileDescription", "FileVersion", "InternalName", "LegalCopyright",
    "LegalTrademarks", "OriginalFilename", "PrivateBuild", "ProductName", "ProductVersion", "SpecialBuild"}

priv struct Res {
    kind: i64
    id: i64
    data: []u8
}

priv fn rd16(s: []u8, at: i64) -> i64 {
    return i64(s[at]) | (i64(s[at + 1]) << 8)
}

priv fn rd32(s: []u8, at: i64) -> i64 {
    return rd16(s, at) | (rd16(s, at + 2) << 16)
}

priv fn is_png(d: []u8) -> bool {
    return len(d) >= 26 && d[0] == 0x89 && d[1] == 'P' && d[2] == 'N' && d[3] == 'G'
}

// What is wrong with the bytes of an icon file (.ico), or "". The file: a header (0, 1, the
// number of images), 16 bytes per image (width, height, colours, 0, planes, bits per pixel,
// size, offset in the file), then the images: a bitmap without its file header, or a PNG.
fn ico_error(f: str) -> str {
    if len(f) < 6 || rd16(f, 0) != 0 || rd16(f, 2) != 1 {
        return "is not an icon file (.ico)"
    }
    n := rd16(f, 4)
    if n == 0 {
        return "holds no image"
    }
    if 6 + 16 * n > len(f) {
        return "is cut off"
    }
    for k in 0..n {
        size := rd32(f, 6 + 16 * k + 8)
        at := rd32(f, 6 + 16 * k + 12)
        if at < 6 + 16 * n || size < 40 || at + size > len(f) {
            return fmt("is cut off or damaged (image ", k + 1, " of ", n, " is not inside the file)")
        }
        if rd32(f, at) != 40 && !is_png(f[at..at + size]) {
            return fmt("holds an image that is neither a bitmap nor a PNG (image ", k + 1, " of ", n, ")")
        }
    }
    ""
}

// `--version-info NAME=VALUE` (s: the text after the option): adds the pair to pe_version;
// what is wrong with it, or "".
fn version_info_add(s: str) -> str {
    eq := find(s, "=")
    if eq < 0 {
        return fmt("--version-info needs NAME=VALUE, not ", s)
    }
    name := s[..eq]
    if index_of(VERSION_KEYS[..], name) < 0 {
        return fmt("--version-info: unknown name ", name, " (one of ", join(VERSION_KEYS[..], ", "), ")")
    }
    if name == "FileVersion" || name == "ProductVersion" {
        _, ok := version_number(s[eq + 1..])
        if !ok {
            return fmt("--version-info: ", name, " is up to four numbers below 65536 with dots between them (1.2.3), not ", s[eq + 1..])
        }
    }
    for v in pe_version {
        if v.0 == name {
            return fmt("--version-info: ", name, " is given twice")
        }
    }
    pe_version.push((name, s[eq + 1..]))
    ""
}

// "1.2.3" as four 16-bit numbers (missing ones 0)
priv fn version_number(s: str) -> ([4]i64, bool) {
    v: [4]i64
    parts := split(s, '.')
    if len(parts) > 4 {
        return (v, false)
    }
    for k, p in parts {
        x, ok := parse_i64(p)
        if !ok || x < 0 || x > 0xFFFF || p[0] == '-' || p[0] == '+' {
            return (v, false)
        }
        v[k] = x
    }
    (v, true)
}

// appends s (UTF-8; a byte that is not part of a character becomes U+FFFD) as UTF-16 with a
// terminating 0; the number of 16-bit units, the 0 included
priv fn utf16z(b: *Vec[u8], s: str) -> i64 {
    units := 1
    i := 0
    while i < len(s) {
        c := i64(s[i])
        n := if c < 0x80 { 1 } else if c >= 0xC2 && c < 0xE0 { 2 } else if c >= 0xE0 && c < 0xF0 { 3 } else if c >= 0xF0 && c < 0xF5 { 4 } else { 0 }
        cp := if n == 1 { c } else { c & (0x3F >> (n - 1)) }
        ok := n != 0 && i + n <= len(s)
        if ok {
            for j in 1..n {
                x := i64(s[i + j])
                ok = ok && x & 0xC0 == 0x80
                cp = (cp << 6) | (x & 0x3F)
            }
        }
        // (overlong forms, surrogates and values past U+10FFFF are not characters)
        least := [5]i64{0, 0, 0x80, 0x800, 0x10000}
        if !ok || cp < least[n] || (cp >= 0xD800 && cp < 0xE000) || cp > 0x10FFFF {
            cp = 0xFFFD
            n = 1
        }
        i += n
        if cp >= 0x10000 {
            put16(b, 0xD800 + ((cp - 0x10000) >> 10))
            put16(b, 0xDC00 + ((cp - 0x10000) & 0x3FF))
            units += 2
        } else {
            put16(b, cp)
            units += 1
        }
    }
    put16(b, 0)
    units
}

// A node of the version resource starts here (4-byte aligned): u16 length (set by ver_end),
// u16 length of its value, u16 type (1: text), its name as UTF-16, padding; then the value
// and the nodes inside it. Returns where it starts.
priv fn ver_node(b: *Vec[u8], name: str, value_len: i64, text: bool) -> i64 {
    b.resize(align_up(b.len, 4), 0)
    at := b.len
    put16(b, 0)
    put16(b, value_len)
    put16(b, i64(text))
    utf16z(b, name)
    b.resize(align_up(b.len, 4), 0)
    at
}

priv fn ver_end(b: *Vec[u8], at: i64) {
    n := b.len - at
    b[at] = u8(n)
    b[at + 1] = u8(n >> 8)
}

// The version resource (VS_VERSIONINFO) for the strings of `--version-info`: the fixed part
// (the file and product versions as numbers; a Windows application), the strings (language
// 0x409, code page 1200: Unicode) and the translation list that names this language.
// ProductVersion is FileVersion unless given.
priv fn version_resource() -> Vec[u8] {
    file: [4]i64
    product: [4]i64
    have_product := false
    for v in pe_version {
        if v.0 == "FileVersion" {
            file, _ = version_number(v.1)
        } else if v.0 == "ProductVersion" {
            product, _ = version_number(v.1)
            have_product = true
        }
    }
    if !have_product {
        product = file
    }
    b := vec[u8]()
    root := ver_node(&b, "VS_VERSION_INFO", 52, false)
    put32(&b, 0xFEEF04BD) // signature
    put32(&b, 0x10000)    // structure version 1.0
    put32(&b, (file[0] << 16) | file[1])
    put32(&b, (file[2] << 16) | file[3])
    put32(&b, (product[0] << 16) | product[1])
    put32(&b, (product[2] << 16) | product[3])
    put32(&b, 0x3F)    // flags mask
    put32(&b, 0)       // flags: a release build
    put32(&b, 0x40004) // operating system: Windows NT, 32-bit API
    put32(&b, 1)       // file type: application
    put32(&b, 0)
    put64(&b, 0)       // no date
    strings := ver_node(&b, "StringFileInfo", 0, true)
    table := ver_node(&b, "040904B0", 0, true)
    for v in pe_version {
        s := ver_node(&b, v.0, 0, true)
        units := utf16z(&b, v.1)
        b[s + 2] = u8(units)
        b[s + 3] = u8(units >> 8)
        ver_end(&b, s)
    }
    if !have_product {
        for v in pe_version {
            if v.0 == "FileVersion" {
                s := ver_node(&b, "ProductVersion", 0, true)
                units := utf16z(&b, v.1)
                b[s + 2] = u8(units)
                b[s + 3] = u8(units >> 8)
                ver_end(&b, s)
            }
        }
    }
    ver_end(&b, table)
    ver_end(&b, strings)
    vars := ver_node(&b, "VarFileInfo", 0, true)
    tr := ver_node(&b, "Translation", 4, false)
    put16(&b, 0x409)
    put16(&b, 1200)
    ver_end(&b, tr)
    ver_end(&b, vars)
    ver_end(&b, root)
    b
}

// a directory with n entries (ids, no names)
priv fn res_dir(b: *Vec[u8], n: i64) {
    put64(b, 0)
    put32(b, 0)
    put16(b, 0)
    put16(b, n)
}

// The .rsrc section, placed at `rva`.
fn pe_resources(rva: i64) -> Vec[u8] {
    res := vec[Res]() // ascending by type, then id
    group := vec[u8]()
    if len(pe_icon) != 0 {
        // the images: icon resources 1..n; the group that lists them (resource 1 of type 14,
        // the icon Explorer shows and std.window gives its windows): the header and per image
        // the first 12 bytes of its entry in the file, then its resource id. Planes and bits
        // per pixel that the file leaves 0 are taken from the image, as resource compilers do.
        f: []u8 = pe_icon
        n := rd16(f, 4)
        group.extend(f[..6])
        for k in 0..n {
            e := 6 + 16 * k
            at := rd32(f, e + 12)
            img := f[at..at + rd32(f, e + 8)]
            res.push(Res{kind: RT_ICON, id: k + 1, data: img})
            group.extend(f[e..e + 4])
            planes := rd16(f, e + 4)
            bits := rd16(f, e + 6)
            if is_png(img) {
                // (bit depth, then the colour type: 2 colour, 4 alpha, 3 palette)
                ch := match img[25] {
                    2 => 3
                    4 => 2
                    6 => 4
                    _ => 1
                }
                put16(&group, 1)
                put16(&group, if bits != 0 { bits } else { i64(img[24]) * ch })
            } else {
                put16(&group, if planes != 0 { planes } else { rd16(img, 12) })
                put16(&group, if bits != 0 { bits } else { rd16(img, 14) })
            }
            group.extend(f[e + 8..e + 12])
            put16(&group, k + 1)
        }
        res.push(Res{kind: RT_GROUP_ICON, id: 1, data: group.items()})
    }
    version := if pe_version.is_empty() { vec[u8]() } else { version_resource() }
    if !version.is_empty() {
        res.push(Res{kind: RT_VERSION, id: 1, data: version.items()})
    }
    res.push(Res{kind: RT_MANIFEST, id: 1, data: MANIFEST})
    n := res.len
    kinds := vec[(i64, i64)]() // (type, its resources)
    for r in res {
        if kinds.is_empty() || kinds.last().0 != r.kind {
            kinds.push((r.kind, 0))
        }
        kinds[kinds.len - 1].1 += 1
    }
    // the root, the directory of each type, a language directory and a data entry per resource
    type_at := 16 + 8 * kinds.len
    lang_at := type_at + 16 * kinds.len + 8 * n
    entry_at := lang_at + 24 * n
    b := vec[u8]()
    res_dir(&b, kinds.len)
    at := type_at
    for k in kinds {
        put32(&b, k.0)
        put32(&b, 0x8000_0000 | at)
        at += 16 + 8 * k.1
    }
    i := 0
    for k in kinds {
        res_dir(&b, k.1)
        for _ in 0..k.1 {
            put32(&b, res[i].id)
            put32(&b, 0x8000_0000 | (lang_at + 24 * i))
            i += 1
        }
    }
    for j in 0..n {
        res_dir(&b, 1)
        put32(&b, 0x409)
        put32(&b, entry_at + 16 * j)
    }
    at = entry_at + 16 * n
    for r in res {
        put32(&b, rva + at)
        put32(&b, len(r.data))
        put64(&b, 0) // code page, reserved
        at = align_up(at + len(r.data), 8)
    }
    for r in res {
        b.extend(r.data)
        b.resize(align_up(b.len, 8), 0)
    }
    b
}
