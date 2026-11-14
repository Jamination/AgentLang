// Generates std/vk.al (AL bindings for Vulkan) from the Khronos registry vk.xml.
// Run it from the root of the repository:
//
//     ./build/alc run tools/gen_vk.al                writes std/vk.al
//     ./build/alc run tools/gen_vk.al -- --verify    also writes a C and an AL program to
//                                                    tmp/VulkanBindings/ that print every struct
//                                                    size, field offset and constant value, builds
//                                                    and runs them (a C compiler is needed) and
//                                                    compares what they print
//
// The registry and the Vulkan loader (commands it does not export are listed, not bound) are
// read from the system. The hand-written macros of vulkan_core.h in tools/vk_helpers.al are
// embedded and appended verbatim to the generated bindings.
use std.os

// ---- what to generate -------------------------------------------------------------------------
priv const VERSIONS = [_]str{"1.0", "1.1", "1.2", "1.3"}
priv const EXTENSIONS = [_]str{
    "VK_KHR_surface",
    "VK_KHR_swapchain",
    "VK_KHR_xlib_surface",
    "VK_KHR_xcb_surface",
    "VK_KHR_wayland_surface",
    "VK_EXT_debug_utils",
}
priv const REGISTRY = "/usr/share/vulkan/registry/vk.xml"
priv const LOADER = "/usr/lib/libvulkan.so.1"
priv const LIB = "libvulkan.so.1"
priv const HELPERS = embed("vk_helpers.al")

// paths relative to the root of the repository
priv const SELF = "tools/gen_vk.al"
priv const OUT = "std/vk.al"
priv const SCRATCH = "tmp/VulkanBindings"

// AL type and size of a C scalar or window-system type; size 0 marks an opaque type that only
// ever appears behind a pointer, -1 a name that is none of them.
priv fn c_scalar(name: str) -> (str, i64) {
    match name {
        "void", "Display", "xcb_connection_t", "wl_display", "wl_surface" => ("u8", 0)
        "char", "uint8_t" => ("u8", 1)
        "int8_t" => ("i8", 1)
        "int16_t" => ("i16", 2)
        "uint16_t" => ("u16", 2)
        "int32_t", "int" => ("i32", 4)
        "uint32_t", "xcb_window_t", "xcb_visualid_t" => ("u32", 4)
        "float" => ("f32", 4)
        "int64_t" => ("i64", 8)
        "uint64_t", "size_t", "Window", "VisualID" => ("u64", 8)
        "double" => ("f64", 8)
        _ => ("", -1)
    }
}

// The macro that makes vulkan.h declare the types of a window system.
priv fn platform_define(platform: str) -> str {
    match platform {
        "xlib" => "VK_USE_PLATFORM_XLIB_KHR"
        "xcb" => "VK_USE_PLATFORM_XCB_KHR"
        "wayland" => "VK_USE_PLATFORM_WAYLAND_KHR"
        _ => fail(concat("no macro known for platform ", platform))
    }
}

// A C name that is a reserved word of AL (LEXER_KEYWORDS in src/lexer.al) gets a trailing `_`.
priv fn al_name(name: str) -> str {
    match name {
        "fn", "struct", "enum", "const", "test", "use", "if", "else", "while", "loop", "for", "in",
        "by", "return", "break", "continue", "assert", "match", "defer", "inline", "noinline",
        "true", "false", "nil", "extern", "priv" => concat(name, "_")
        _ => name
    }
}

// ---- helpers ----------------------------------------------------------------------------------
priv fn fail(msg: str) -> never {
    eprint(concat("gen_vk: ", msg))
    exit(1)
}

// `a`, or `b` if `a` is empty.
priv fn or(a: str, b: str) -> str { if a != "" { a } else { b } }

// The value of a decimal or 0x literal.
priv fn to_int(s: str) -> i64 {
    n, ok := parse_i64(s, 0)
    if !ok { fail(concat("not a number: ", s)) }
    n
}

// 255 -> 0xFF
priv fn hex_literal(x: i64) -> str { concat("0x", to_upper(hex(u64(x)))) }

// VkInstanceCreateInfo -> vk_instance_create_info: a word starts at a capital that follows a
// small letter or a digit, and at the last capital of a run before a small letter.
priv fn snake(name: str) -> str {
    out := vec[u8]()
    for i, c in name {
        if i > 0 && is_upper(c) {
            prev := name[i - 1]
            if is_lower(prev) || is_digit(prev) || (i + 1 < name.len && is_lower(name[i + 1])) { out.push('_') }
        }
        out.push(c)
    }
    to_lower(out.items())
}

// C text with every run of white space reduced to one space, none at the ends or before `*`.
priv fn squeeze(s: str) -> str { replace(join(fields(s), " "), " *", "*") }

priv fn save(path: str, text: str) {
    if !write_file(path, text) { fail(fmt("cannot write ", path, ": ", error_text(io_error()))) }
}

// ---- XML: as much of it as vk.xml uses --------------------------------------------------------
// Elements, attributes, text, the entities of XML itself; comments and processing instructions
// are skipped. No CDATA, DOCTYPE, character references or namespaces.
priv struct Attr { name: str, value: str }

priv struct Node {
    tag: str
    attrs: []Attr
    text: str               // the text before the first child
    tail: str               // the text between the end of this element and the next one
    kids: []*Node
}

priv struct Xml { src: str, pos: i64 }

// The root element of a document.
priv fn xml_parse(src: str) -> *Node {
    p := Xml{src, 0}
    document: Node
    p.content(&document)
    if p.pos < src.len || document.kids.len != 1 { p.malformed() }
    document.kids[0]
}

priv fn malformed(p: *Xml) -> never {
    fail(fmt(REGISTRY, ": malformed XML at byte ", p.pos))
}

priv fn at(p: *Xml, s: str) -> bool { starts_with(p.src[p.pos..], s) }

priv fn skip_past(p: *Xml, s: str) {
    i := find(p.src[p.pos..], s)
    if i < 0 { p.malformed() }
    p.pos += i + s.len
}

// A tag or attribute name.
priv fn ident(p: *Xml) -> str {
    start := p.pos
    while p.pos < p.src.len && index_of(" \n\t=/>", p.src[p.pos]) < 0 { p.pos += 1 }
    if p.pos == start { p.malformed() }
    p.src[start..p.pos]
}

// `s` with its entities replaced.
priv fn unescape(s: str) -> str {
    parts := split(s, '&')
    if parts.len == 1 { return s }
    out := vec_of(parts[0])
    for part in parts[1..] {
        semicolon := find(part, ";")
        out.push(match part[..max(semicolon, 0)] {
            "lt" => '<'
            "gt" => '>'
            "amp" => '&'
            "quot" => '"'
            "apos" => '\''
            _ => fail(fmt(REGISTRY, ": unknown entity in `", s, "`"))
        })
        out.extend(part[semicolon + 1..])
    }
    out.items()
}

// The text up to the next tag, without comments and processing instructions.
priv fn char_data(p: *Xml) -> str {
    out := ""
    loop {
        start := p.pos
        while p.pos < p.src.len && p.src[p.pos] != '<' { p.pos += 1 }
        piece := unescape(p.src[start..p.pos])
        out = if out == "" { piece } else { concat(out, piece) }
        if p.at("<!--") {
            p.skip_past("-->")
        } else if p.at("<?") {
            p.skip_past("?>")
        } else {
            return out
        }
    }
}

// What stands between the tags of `parent`: its text, its children and their tails.
priv fn content(p: *Xml, parent: *Node) {
    kids := vec[*Node]()
    loop {
        text := p.char_data()
        if kids.is_empty() { parent.text = text } else { kids.last().tail = text }
        if p.pos >= p.src.len || p.at("</") { break }
        kids.push(p.element())
    }
    parent.kids = kids.items()
}

// The element that starts at the `<` the reader stands on.
priv fn element(p: *Xml) -> *Node {
    p.pos += 1
    n := &Node{tag: p.ident()}
    attrs := vec[Attr]()
    loop {
        while p.pos < p.src.len && p.src[p.pos] <= ' ' { p.pos += 1 }
        if p.at("/>") || p.at(">") { break }
        key := p.ident()
        if !p.at("=\"") && !p.at("='") { p.malformed() }
        quote := p.src[p.pos + 1..p.pos + 2]
        p.pos += 2
        start := p.pos
        p.skip_past(quote)
        attrs.push(Attr{key, unescape(p.src[start..p.pos - 1])})
    }
    n.attrs = attrs.items()
    if p.at("/>") {
        p.pos += 2
        return n
    }
    p.pos += 1
    p.content(n)
    if !p.at("</") { p.malformed() }
    p.pos += 2
    if p.ident() != n.tag { p.malformed() }
    p.skip_past(">")
    n
}

// The value of an attribute, "" if the element has none of that name.
priv fn attr(n: *Node, name: str) -> str {
    for a in n.attrs {
        if a.name == name { return a.value }
    }
    ""
}

// The first child with that tag, or nil.
priv fn child(n: *Node, tag: str) -> *Node {
    for k in n.kids {
        if k.tag == tag { return k }
    }
    nil
}

// The text of the first child with that tag, "" if there is none.
priv fn child_text(n: *Node, tag: str) -> str {
    k := n.child(tag)
    if k == nil { "" } else { k.text }
}

// True if the element belongs to the desktop Vulkan API (not only to Vulkan SC).
priv fn api_ok(n: *Node) -> bool {
    api := n.attr("api")
    api == "" || contains(split(api, ','), "vulkan")
}

// The children with that tag that belong to the desktop API.
priv fn children(n: *Node, tag: str) -> []*Node {
    out := vec[*Node]()
    for k in n.kids {
        if k.tag == tag && api_ok(k) { out.push(k) }
    }
    out.items()
}

// ---- the registry -----------------------------------------------------------------------------
// A struct member, a command parameter or the <proto> of a command.
priv struct Decl {
    base: str               // name of the C type
    name: str
    nptr: i64               // pointer depth
    dims: Vec[str]          // array sizes: numbers or names of constants
    bitfield: bool
    ctext: str              // the declaration as C text
    values: str             // attribute `values`: the sType of a struct
}

priv struct EnumVal {
    name: str
    value: i64
    alias: str              // if not "": the value is that of this other name of the enum
}

priv struct Const { name: str, al: str, value: str }     // al: the AL type, "" for an untyped one

priv struct Layout { size: i64, align: i64, offsets: []i64 }

priv struct Reg {
    root: *Node
    types: Map[str, *Node]          // the <type> elements by name, in the order of the registry
    enum_blocks: Map[str, *Node]    // the <enums> elements by name
    commands: Map[str, *Node]
    // what the chosen versions and extensions require:
    req_commands: Vec[str]
    req_enums: Vec[(*Node, i64)]    // <enum> and the number of its extension (0 inside a version)
    platforms: Vec[str]
    used: Map[str, bool]            // the set of required types and of all they refer to
    consts: Vec[Const]
    enums: Map[str, Vec[EnumVal]]   // the values of each used enum type
    layouts: Map[str, Layout]       // filled by layout()
}

priv fn decl(e: *Node) -> Decl {
    d := Decl{base: e.child_text("type"), values: e.attr("values")}
    text := vec_of(e.text)          // the C text without the name and without comments
    name_at := 0
    for k in e.kids {
        if k.tag == "name" {
            d.name = k.text
            name_at = text.len
        } else if k.tag != "comment" {
            text.extend(k.text)
        }
        text.extend(k.tail)
    }
    after := trim(text[name_at..])
    for i, piece in split(after, '[') {
        close := find(piece, "]")
        if i > 0 && close > 0 { d.dims.push(piece[..close]) }
    }
    d.nptr = count(text.items(), "*")
    d.bitfield = starts_with(after, ":")
    d.ctext = fmt(squeeze(text[..name_at]), " ", d.name, after)
    d
}

// The name of a <type> or <command>: an attribute, or a <name> inside it or inside its <proto>.
priv fn decl_name(e: *Node) -> str {
    name := e.attr("name").or(e.child_text("name"))
    proto := e.child("proto")
    if name == "" && proto != nil { proto.child_text("name") } else { name }
}

priv fn load(xml: str) -> Reg {
    r := Reg{root: xml_parse(xml)}
    for section in r.root.kids {
        match section.tag {
            "types" => for t in section.children("type") {
                name := decl_name(t)
                if name != "" && !r.types.has(name) { r.types.set(name, t) }
            }
            "enums" => r.enum_blocks.set(section.attr("name"), section)
            "commands" => for c in section.children("command") {
                name := decl_name(c)
                if !r.commands.has(name) { r.commands.set(name, c) }
            }
            _ => {}
        }
    }
    r.select()
    r.collect_enums()
    r
}

priv fn type_of(r: *Reg, name: str) -> *Node {
    t := r.types.get_or(name, nil)
    if t == nil { fail(concat("unmapped C type ", name)) }
    t
}

// The <command> of a name; an alias gives the command it stands for.
priv fn command(r: *Reg, name: str) -> *Node {
    c := r.commands.get_or(name, nil)
    if c == nil { fail(concat("the registry has no command ", name)) }
    if c.attr("alias") != "" { r.command(c.attr("alias")) } else { c }
}

// ---- selection --------------------------------------------------------------------------------
// Collects the types, commands and enum values that the chosen versions and extensions require.
priv fn select(r: *Reg) {
    extensions := map[str, *Node]()
    for section in r.root.kids {
        if section.tag == "feature" && api_ok(section) && contains(VERSIONS[..], section.attr("number")) {
            r.require(section, 0)
        } else if section.tag == "extensions" {
            for e in section.kids { extensions.set(e.attr("name"), e) }
        }
    }
    for name in EXTENSIONS {
        e := extensions.get_or(name, nil)
        if e == nil { fail(concat("the registry has no extension ", name)) }
        r.require(e, to_int(e.attr("number")))
        if e.attr("platform") != "" { r.platforms.push(e.attr("platform")) }
    }
    for name in r.req_commands {
        c := r.command(name)
        r.use_type(c.child("proto").child_text("type"))
        for p in c.children("param") { r.use_type(p.child_text("type")) }
    }
}

// Notes what the <require> elements of a version or extension list.
priv fn require(r: *Reg, block: *Node, number: i64) {
    for req in block.children("require") {
        for item in req.kids {
            if !api_ok(item) { continue }
            name := item.attr("name")
            match item.tag {
                "type" => r.use_type(name)
                "command" => if !r.req_commands.contains(name) { r.req_commands.push(name) }
                "enum" => r.req_enums.push((item, number))
                _ => {}
            }
        }
    }
}

// Marks a type as used, and all types it refers to.
priv fn use_type(r: *Reg, name: str) {
    t := r.types.get_or(name, nil)
    if t == nil || r.used.has(name) { return }
    r.used.set(name, true)
    r.use_type(t.attr("alias"))
    match t.attr("category") {
        "struct", "union" => for m in t.children("member") { r.use_type(m.child_text("type")) }
        "bitmask" => r.use_type(t.attr("requires").or(t.attr("bitvalues")))
        _ => {}
    }
}

// The used types of a category, in the order of the registry.
priv fn selected(r: *Reg, category: str) -> []str {
    out := vec[str]()
    for name in r.types.keys() {
        if r.used.has(name) && r.type_of(name).attr("category") == category { out.push(name) }
    }
    out.items()
}

// ---- enums and constants ----------------------------------------------------------------------
priv fn enum_al_type(r: *Reg, name: str) -> str {
    block := r.enum_blocks.get_or(name, nil)
    if block == nil {
        "i32"
    } else if block.attr("bitwidth") == "64" {
        "u64"
    } else if block.attr("type") == "bitmask" {
        "u32"
    } else {
        "i32"
    }
}

// The value an <enum> element gives its name; `number`: of the extension that requires it.
priv fn enum_value(e: *Node, number: i64) -> EnumVal {
    v := EnumVal{name: e.attr("name"), alias: e.attr("alias")}
    if v.alias != "" { return v }
    v.value = if e.attr("bitpos") != "" {
        1 << to_int(e.attr("bitpos"))
    } else if e.attr("offset") != "" {
        extension := if e.attr("extnumber") != "" { to_int(e.attr("extnumber")) } else { number }
        x := 1000000000 + (extension - 1) * 1000 + to_int(e.attr("offset"))
        if e.attr("dir") == "-" { -x } else { x }
    } else {
        to_int(e.attr("value"))
    }
    v
}

priv fn index_of(vals: *Vec[EnumVal], name: str) -> i64 {
    for i, v in vals {
        if v.name == name { return i }
    }
    -1
}

// "(~0U)" and "(~0ULL)" as hexadecimal literals; other values as they are.
priv fn complement_literal(value: str) -> str {
    wide := ends_with(value, "ULL)")
    if !starts_with(value, "(~") || !(wide || ends_with(value, "U)")) { return value }
    n, ok := parse_i64(value[2..value.len - (if wide { 4 } else { 2 })])
    if !ok { return value }
    hex_literal(if wide { ~n } else { 0xFFFFFFFF - n })
}

// Fills r.enums and r.consts.
priv fn collect_enums(r: *Reg) {
    for name in r.selected("enum") {
        if r.type_of(name).attr("alias") != "" { continue }
        vals := vec[EnumVal]()
        block := r.enum_blocks.get_or(name, nil)
        if block != nil {
            for e in block.children("enum") { vals.push(enum_value(e, 0)) }
        }
        r.enums.set(name, vals)
    }
    api := map[str, *Node]()        // the API constants: their values stand here, not in <require>
    for e in r.enum_blocks.get_or("API Constants", &Node{}).kids {
        if e.tag == "enum" { api.set(e.attr("name"), e) }
    }
    seen := map[str, bool]()
    for q in r.req_enums {
        e, number := q
        name := e.attr("name")
        if e.attr("extends") != "" {            // one more value of an enum type
            vals := r.enums.ptr(e.attr("extends"))
            if vals != nil && vals.index_of(name) < 0 { vals.push(enum_value(e, number)) }
            continue
        }
        if seen.has(name) { continue }
        seen.set(name, true)
        src := api.get_or(name, e)
        if src.attr("alias") != "" { src = api.get_or(src.attr("alias"), src) }
        value := src.attr("value")
        if value == "" { continue }
        al := match src.attr("type") {
            "float" => "f32"
            "uint32_t" => "u32"
            "uint64_t" => "u64"
            _ => ""
        }
        if al == "f32" { value = trim_right(value, "fF") }
        r.consts.push(Const{name, al, complement_literal(value)})
    }
    for name in r.enums.keys() {
        vals := r.enums.ptr(name)
        for i in 0..vals.len {
            j := i
            while vals[j].alias != "" { j = vals.index_of(vals[j].alias) }
            vals[i].value = vals[j].value
        }
    }
}

priv fn const_value(r: *Reg, name: str) -> i64 {
    for c in r.consts {
        if c.name == name { return to_int(c.value) }
    }
    fail(concat("the registry requires no constant ", name))
}

// ---- type mapping -----------------------------------------------------------------------------
// (AL type, size, is an aggregate) of a C type name; aggregates are sized by layout().
priv fn scalar(r: *Reg, name: str) -> (str, i64, bool) {
    al, size := c_scalar(name)
    if size >= 0 { return (al, size, false) }
    t := r.type_of(name)
    if t.attr("alias") != "" { return r.scalar(t.attr("alias")) }
    inner := t.child_text("type")
    match t.attr("category") {
        "basetype" => r.scalar(inner)
        "bitmask" => if inner == "VkFlags64" { ("u64", 8, false) } else { ("u32", 4, false) }
        "handle" => if inner == "VK_DEFINE_HANDLE" { ("*u8", 8, false) } else { ("u64", 8, false) }
        "enum" => {
            ty := r.enum_al_type(name)
            (ty, if ty == "u64" { 8 } else { 4 }, false)
        }
        "funcpointer" => ("*u8", 8, false)
        "struct", "union" => (name, 0, true)
        _ => fail(concat("unmapped C type ", name))
    }
}

// (AL type, size, alignment) of a member, or of a parameter (where an array is a pointer).
priv fn al_type(r: *Reg, d: Decl, param: bool) -> (str, i64, i64) {
    al, size, aggregate := r.scalar(d.base)
    align := size
    nptr := d.nptr
    dims := d.dims[..]
    if param && dims.len > 0 {
        nptr += 1
        dims = nil
    }
    if nptr > 0 {
        al = concat(repeat("*", nptr), al)
        size = 8
        align = 8
    } else if aggregate {
        l := r.layout(d.base)
        size = l.size
        align = l.align
    }
    for i in dims.len - 1..=0 by -1 {
        n, is_number := parse_i64(dims[i])
        al = fmt("[", dims[i], "]", al)
        size *= if is_number { n } else { r.const_value(dims[i]) }
    }
    (al, size, align)
}

priv fn members(r: *Reg, name: str) -> []Decl {
    out := vec[Decl]()
    for m in r.type_of(name).children("member") { out.push(decl(m)) }
    out.items()
}

priv fn has_bitfield(decls: []Decl) -> bool {
    for d in decls {
        if d.bitfield { return true }
    }
    false
}

// Size, alignment and field offsets of a struct or union under the C rules.
priv fn layout(r: *Reg, name: str) -> Layout {
    known, found := r.layouts.get(name)
    if found { return known }
    t := r.type_of(name)
    if t.attr("alias") != "" { return r.layout(t.attr("alias")) }
    is_union := t.attr("category") == "union"
    l := Layout{align: 1}
    offsets := vec[i64]()
    for d in r.members(name) {
        _, fsize, falign := r.al_type(d, false)
        l.align = max(l.align, falign)
        if is_union {
            l.size = max(l.size, fsize)
            offsets.push(0)
        } else {
            l.size = (l.size + falign - 1) / falign * falign
            offsets.push(l.size)
            l.size += fsize
        }
    }
    l.size = (l.size + l.align - 1) / l.align * l.align
    l.offsets = offsets.items()
    r.layouts.set(name, l)
    l
}

// The structs and unions the bindings declare: no second names, no structs with bit-fields.
priv fn bound_structs(r: *Reg) -> []str {
    out := vec[str]()
    for name in r.types.keys() {
        t := r.type_of(name)
        category := t.attr("category")
        if !r.used.has(name) || t.attr("alias") != "" { continue }
        if category == "union" || (category == "struct" && !has_bitfield(r.members(name))) { out.push(name) }
    }
    out.items()
}

// The C type of a field whose AL type hides it (enum, flags, handle, char*, void*); else "".
priv fn c_kind(r: *Reg, d: Decl) -> str {
    hidden := if c_scalar(d.base).1 >= 0 {
        d.nptr > 0 && (d.base == "char" || d.base == "void")
    } else {
        match r.type_of(d.base).attr("category") {
            "enum", "bitmask", "handle", "basetype", "funcpointer" => true
            _ => false
        }
    }
    if hidden { concat(d.base, repeat("*", d.nptr)) } else { "" }
}

// The names of the dynamic symbols that a shared library defines (what `nm -D --defined-only`
// lists), and whether the file could be read as an ELF64 file.
priv fn exported(path: str) -> (Map[str, bool], bool) {
    names := map[str, bool]()
    f, ok := read_file(path)
    if !ok || f.len < 64 || f[..5] != "\x7fELF\x02" { return (names, false) }
    fn le(bytes: str, at: i64, n: i64) -> i64 {         // a little-endian number of n bytes
        x := 0
        for i in n - 1..=0 by -1 { x = x << 8 | i64(bytes[at + i]) }
        x
    }
    sections := f[le(f, 0x28, 8)..]
    section_size := le(f, 0x3A, 2)
    for i in 0..le(f, 0x3C, 2) {
        s := sections[i * section_size..]
        if le(s, 4, 4) != 11 { continue }                // 11: the dynamic symbol table
        strings := f[le(sections[le(s, 0x28, 4) * section_size..], 0x18, 8)..]
        symbols := f[le(s, 0x18, 8)..][..le(s, 0x20, 8)]
        for sym in 0..symbols.len by 24 {
            defined := le(symbols, sym + 6, 2) != 0
            if defined { names.set(from_cstr(ptr(strings[le(symbols, sym, 4)..])), true) }
        }
    }
    (names, true)
}

// ---- std/vk.al --------------------------------------------------------------------------------
priv fn bindings(r: *Reg) -> str {
    out := vec[str]()               // the lines
    out.push(fmt("// std.vk: bindings for Vulkan ", VERSIONS[0], "-", VERSIONS[VERSIONS.len - 1], " and ",
        join(EXTENSIONS[..], ", "), "."))
    out.push(`// GENERATED by tools/gen_vk.al from vk.xml; do not edit. The version macros at the end
// come from tools/vk_helpers.al. See docs/std/vk.md.
//
// Mapping: dispatchable handles (VkInstance, VkDevice, ...) are *u8, non-dispatchable handles
// (VkBuffer, VkImage, ...) are u64, enums are i32, flags are u32 (u64 for 64-bit flag types),
// VkBool32 is u32, VkDeviceSize and size_t are u64; structs have the C layout.

// ---- constants ----
const VK_NULL_HANDLE: u64 = 0`)
    for v in VERSIONS {
        part := split(v, '.')
        packed := hex(u64(to_int(part[0]) << 22 | to_int(part[1]) << 12), 8)
        out.push(fmt("const VK_API_VERSION_", part[0], "_", part[1], ": u32 = 0x", to_upper(packed)))
    }
    for c in r.consts {
        out.push(fmt("const ", c.name, if c.al != "" { ": " } else { "" }, c.al, " = ", c.value))
    }

    out.push("\n// ---- handles ----")
    pointers := vec[str]()
    numbers := vec[str]()
    for name in r.selected("handle") {
        if r.scalar(name).0 == "*u8" { pointers.push(name) } else { numbers.push(name) }
    }
    out.push(concat("// *u8: ", join(pointers[..], ", ")))
    out.push(concat("// u64: ", join(numbers[..], ", ")))

    out.push("\n// ---- enums and flag bits ----")
    for name in r.selected("enum") {
        vals := r.enums.get_or(name, vec[EnumVal]())
        if vals.is_empty() { continue }
        al := r.enum_al_type(name)
        out.push(concat("// ", name))
        for v in vals {
            out.push(fmt("const ", v.name, ": ", al, " = ", if al == "i32" { fmt(v.value) } else { hex_literal(v.value) }))
        }
    }

    out.push("\n// ---- structs ----")
    constructors := vec[str]()
    unions := vec[str]()            // a constructor per union member: AL has no unions
    for name in r.types.keys() {
        t := r.type_of(name)
        category := t.attr("category")
        if !r.used.has(name) || (category != "struct" && category != "union") { continue }
        if t.attr("alias") != "" {
            out.push(fmt("// ", name, " is another name of ", t.attr("alias")))
            continue
        }
        decls := r.members(name)
        if category == "union" {
            l := r.layout(name)
            ctexts := vec[str]()
            for d in decls { ctexts.push(d.ctext) }
            out.push(fmt("// union ", name, " { ", join(ctexts[..], "; "), " }"))
            out.push(fmt("struct ", name, " { data: [", l.size / l.align, "]u", l.align * 8, " }"))
            for d in decls {
                ty := r.al_type(d, false).0
                unions.push(fmt("// ", name, " holding its member ", d.name, ", as C's `", name, " u = {.", d.name, " = v}`."))
                unions.push(fmt("fn ", snake(name), "_", snake(d.name), "(v: ", ty, ") -> ", name, " { u: ", name,
                    "; memcopy(&u, &v, sizeof[", ty, "]()); u }"))
            }
            continue
        }
        if has_bitfield(decls) {
            out.push(fmt("// ", name, " is not bound: it contains bit-fields"))
            continue
        }
        out.push(fmt("struct ", name, " {"))
        for d in decls {
            kind := r.c_kind(d)
            out.push(fmt("    ", al_name(d.name), ": ", r.al_type(d, false).0, if kind != "" { "    // " } else { "" }, kind))
        }
        out.push("}")
        if decls.len > 0 && decls[0].name == "sType" && decls[0].values != "" {
            constructors.push(fmt("// ", name, " with sType set."))
            constructors.push(fmt("fn ", snake(name), "() -> ", name, " { ", name, "{sType: ", split(decls[0].values, ',')[0], "} }"))
        }
    }

    out.push("\n// ---- commands ----")
    loader, loader_known := exported(LOADER)
    missing := vec[str]()
    for name in r.req_commands {
        c := r.command(name)
        proto := decl(c.child("proto"))
        types := vec[str]()
        params := vec[str]()
        ctexts := vec[str]()
        for p in c.children("param") {
            d := decl(p)
            types.push(r.al_type(d, true).0)
            params.push(fmt(al_name(d.name), ": ", types.last()))
            ctexts.push(d.ctext)
        }
        result := if proto.base != "void" || proto.nptr > 0 { concat(" -> ", r.al_type(proto, false).0) } else { "" }
        if loader_known && !loader.has(name) {
            missing.push(fmt("//   ", name, ": fn(", join(types[..], ", "), ")", result))
            continue
        }
        out.push(fmt("// ", proto.base, repeat("*", proto.nptr), " ", name, "(", join(ctexts[..], ", "), ")"))
        out.push(fmt("extern \"", LIB, "\" fn ", name, "(", join(params[..], ", "), ")", result))
    }
    if !missing.is_empty() {
        out.push(`// Not exported by the loader; get the address with vkGetInstanceProcAddr and cast it to
// the function type shown: cast[fn(...) -> i32](vkGetInstanceProcAddr(instance, ptr("vkName")))`)
        out.extend(missing[..])
    }

    out.push("\n// ---- constructors: a zeroed struct with sType filled in ----")
    out.extend(constructors[..])

    out.push("\n// ---- unions: one constructor per member ----")
    out.extend(unions[..])

    out.push(`
// ---- result names ----
// Name of a VkResult value ("VK_SUCCESS", "VK_ERROR_DEVICE_LOST", ...).
fn vk_result_name(result: i32) -> str {
    match result {`)
    seen := map[i64, bool]()
    for v in r.enums.get_or("VkResult", vec[EnumVal]()) {
        if seen.has(v.value) { continue }
        seen.set(v.value, true)
        out.push(fmt("        ", v.name, " => \"", v.name, "\""))
    }
    out.push(`        _ => "VkResult(unknown)"
    }
}

`)
    concat(join(out[..], "\n"), HELPERS)
}

// ---- layout verification ----------------------------------------------------------------------
// The members whose offsets are compared: those of a struct, none of a union.
priv fn struct_fields(r: *Reg, name: str) -> []Decl {
    if r.type_of(name).attr("category") == "union" { []Decl{} } else { r.members(name) }
}

// The constants and enum values that are integers, with their AL types.
priv fn int_consts(r: *Reg) -> []Const {
    out := vec[Const]()
    for c in r.consts {
        if c.al != "f32" && c.value[0] != '"' { out.push(c) }
    }
    for name in r.selected("enum") {
        for v in r.enums.get_or(name, vec[EnumVal]()) { out.push(Const{name: v.name, al: r.enum_al_type(name)}) }
    }
    out.items()
}

// A C program that prints "Struct size offset..." and "CONSTANT value" lines. It only compiles
// if the generator's own layout computation (it sizes the unions) agrees with the C compiler.
priv fn verify_c(r: *Reg) -> str {
    out := vec[str]()
    for p in r.platforms { out.push(concat("#define ", platform_define(p))) }
    out.push(`#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stddef.h>
int main(void) {`)
    for name in r.bound_structs() {
        l := r.layout(name)
        printed := vec_of([]str{fmt("sizeof(", name, ")")})
        own := vec_of([]str{fmt("sizeof(", name, ") == ", l.size)})
        for i, d in r.struct_fields(name) {
            printed.push(fmt("offsetof(", name, ", ", d.name, ")"))
            own.push(fmt(printed.last(), " == ", l.offsets[i]))
        }
        out.push(fmt("    _Static_assert(", join(own[..], " && "), ", \"gen_vk.al lays out ", name, " differently\");"))
        out.push(fmt("    printf(\"", name, repeat(" %zu", printed.len), `\n", `, join(printed[..], ", "), ");"))
    }
    for c in r.int_consts() {
        if c.al == "u32" || c.al == "u64" {
            out.push(fmt(`    printf("`, c.name, ` %llu\n", (unsigned long long)`, c.name, ");"))
        } else {
            out.push(fmt(`    printf("`, c.name, ` %lld\n", (long long)`, c.name, ");"))
        }
    }
    out.push("    return 0;\n}\n")
    join(out[..], "\n")
}

// An AL program that prints the same lines from std.vk.
priv fn verify_al(r: *Reg) -> str {
    out := vec[str]()
    main := vec[str]()              // the calls of the functions below
    out.push("use std.vk")
    out.push("fn o(base: i64, p: i64) { put(\" \", p - base) }")
    for name in r.bound_structs() {
        out.push(fmt("fn l_", name, "() {"))
        out.push(fmt("    s: ", name))
        out.push("    b := cast[i64](&s)")
        out.push(fmt("    put(\"", name, " \", sizeof[", name, "]())"))
        for d in r.struct_fields(name) { out.push(fmt("    o(b, cast[i64](&s.", al_name(d.name), "))")) }
        out.push("    putc('\\n')")
        out.push("}")
        main.push(fmt("    l_", name, "()"))
    }
    for i, c in r.int_consts() {
        if i % 200 == 0 {               // 200 to a function
            if i > 0 { out.push("}") }
            out.push(fmt("fn c_", i / 200, "() {"))
            main.push(fmt("    c_", i / 200, "()"))
        }
        out.push(fmt("    print(\"", c.name, "\", ", c.name, ")"))
    }
    out.push("}")
    out.push("fn main() {")
    out.extend(main[..])
    out.push("}\n")
    join(out[..], "\n")
}

// Runs a command of the verification; anything but success ends the generator.
priv fn must_run(argv: []str) {
    status := run(argv)
    if status < 0 { fail(fmt("cannot run ", argv[0], ": ", error_text(io_error()))) }
    if status != 0 { fail(fmt(join(argv, " "), ": exit status ", status)) }
}

// What a program of the verification prints.
priv fn output_of(program: str) -> []str {
    out, status := run_capture([]str{program})
    if status != 0 { fail(fmt(program, ": exit status ", status)) }
    lines(out)
}

fn main() {
    verify := args().len == 2 && args()[1] == "--verify"
    if args().len > 1 && !verify { fail("usage: ./build/alc run tools/gen_vk.al [-- --verify]") }
    if !file_exists(SELF) { fail(fmt("run it from the root of the repository (there is no ", SELF, " here)")) }
    xml, ok := read_file(REGISTRY)
    if !ok { fail(fmt("cannot read the Vulkan registry ", REGISTRY, ": ", error_text(io_error()))) }
    r := load(xml)
    text := r.bindings()
    save(OUT, text)
    print(fmt("wrote ", OUT, ": ", count(text, "\n"), " lines, ", r.bound_structs().len, " structs, ",
        count(text, "\nextern "), " commands"))
    if !verify { return }

    // The same lines from C (the Vulkan headers) and from the new std/vk.al.
    if !make_dir(SCRATCH) { fail(fmt("cannot create ", SCRATCH, ": ", error_text(io_error()))) }
    save(concat(SCRATCH, "/layout.c"), r.verify_c())
    save(concat(SCRATCH, "/layout.al"), r.verify_al())
    compiled := false
    for cc in []str{"clang", "gcc", "cc"} {
        status := run([]str{cc, "-o", concat(SCRATCH, "/layout_c"), concat(SCRATCH, "/layout.c")})
        if status < 0 { continue }              // not installed: try the next one
        if status != 0 { fail(fmt(cc, " does not compile ", SCRATCH, "/layout.c (exit status ", status, ")")) }
        compiled = true
        break
    }
    if !compiled { fail("cannot verify the layouts: no C compiler (clang, gcc or cc) is installed") }
    // (ALC_STD_DIR: the compiler has the previous std/vk.al inside)
    must_run([]str{"env", "ALC_STD_DIR=std", "./build/alc", "build", concat(SCRATCH, "/layout.al"), "-o", concat(SCRATCH, "/layout_al")})
    c := output_of(concat(SCRATCH, "/layout_c"))
    al := output_of(concat(SCRATCH, "/layout_al"))
    mismatches := abs(c.len - al.len)
    for i in 0..min(c.len, al.len) {
        if c[i] == al[i] { continue }
        mismatches += 1
        if mismatches <= 20 { eprint(fmt("layout: C has `", c[i], "`, std.vk has `", al[i], "`")) }
    }
    if mismatches > 0 { fail(fmt("layout: ", mismatches, " of ", c.len, " lines differ")) }
    print(fmt("layout: no mismatches in ", c.len, " lines"))
}
