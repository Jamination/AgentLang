// Generates std/wayland.al (AL bindings for Wayland clients) from the protocol descriptions.
// Run it from the root of the repository:
//
//     ./build/alc run tools/gen_wayland.al                writes std/wayland.al
//     ./build/alc run tools/gen_wayland.al -- --verify    also writes a C and an AL program to
//                                                         tmp/WaylandBindings/ that print every
//                                                         interface table, opcode and enum value,
//                                                         builds and runs them (wayland-scanner, a
//                                                         C compiler and the libwayland headers
//                                                         are needed) and compares what they print
//
// What `wayland-scanner client-header` and `private-code` produce for C comes out as AL: per
// interface an opaque struct, the enum values, the opcodes, the listener struct, one function
// per request, and the wl_interface tables. The hand-written part tools/wayland_helpers.al
// (the functions of libwayland-client, libxkbcommon and libwayland-cursor) is embedded and put
// in front of the generated declarations.
use std.os

// ---- what to generate -------------------------------------------------------------------------
priv const PROTOCOLS = [_]str{
    "/usr/share/wayland/wayland.xml",
    "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml",
    "/usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml",
}
priv const LIB = "libwayland-client.so.0"
priv const HELPERS = embed("wayland_helpers.al")

// paths relative to the root of the repository
priv const SELF = "tools/gen_wayland.al"
priv const OUT = "std/wayland.al"
priv const SCRATCH = "tmp/WaylandBindings"

// A protocol name that is a reserved word of AL (LEXER_KEYWORDS in src/lexer.al) gets a
// trailing `_`.
priv fn al_name(name: str) -> str {
    match name {
        "fn", "struct", "enum", "const", "test", "use", "if", "else", "while", "loop", "for", "in",
        "by", "return", "break", "continue", "assert", "match", "defer", "inline", "noinline",
        "true", "false", "nil", "extern", "priv" => concat(name, "_")
        _ => name
    }
}

// ---- helpers ----------------------------------------------------------------------------------
priv source: str            // the file being read, for messages

priv fn fail(msg: str) -> never {
    eprint(concat("gen_wayland: ", msg))
    exit(1)
}

// The value of a decimal or 0x literal.
priv fn to_int(s: str) -> i64 {
    n, ok := parse_i64(s, 0)
    if !ok { fail(concat("not a number: ", s)) }
    n
}

// wl_data_device -> WlDataDevice
priv fn camel(name: str) -> str {
    out := vec[u8]()
    for part in split(name, '_') {
        if part.len == 0 { continue }
        out.extend(to_upper(part[..1]))
        out.extend(part[1..])
    }
    out.items()
}

// Text with every run of white space reduced to one space, none at the ends.
priv fn squeeze(s: str) -> str { join(fields(s), " ") }

priv fn save(path: str, text: str) {
    if !write_file(path, text) { fail(fmt("cannot write ", path, ": ", error_text(io_error()))) }
}

// ---- XML: as much of it as the protocol files use (the reader of tools/gen_vk.al) -------------
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
    fail(fmt(source, ": malformed XML at byte ", p.pos))
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
            _ => fail(fmt(source, ": unknown entity in `", s, "`"))
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

// The children with that tag.
priv fn children(n: *Node, tag: str) -> []*Node {
    out := vec[*Node]()
    for k in n.kids {
        if k.tag == tag { out.push(k) }
    }
    out.items()
}

// The one-line summary of an element: its own attribute, or that of its <description>.
priv fn summary(n: *Node) -> str {
    s := n.attr("summary")
    d := n.child("description")
    if s == "" && d != nil { s = d.attr("summary") }
    squeeze(s)
}

// ---- the protocols ----------------------------------------------------------------------------
priv struct Arg {
    name: str               // as in the protocol
    kind: str               // int uint fixed string object new_id array fd
    iface: str              // interface of an object / new_id, "" if any
    nullable: bool
    enum_: str              // "interface.enum" if the value is one of an enum
    summary: str
}

priv struct Msg {
    name: str
    since: i64
    destructor: bool
    summary: str
    args: []Arg
}

priv struct Entry { name: str, value: str, summary: str, since: i64 }

priv struct Enum {
    name: str
    bitfield: bool
    summary: str
    entries: []Entry
}

priv struct Iface {
    name: str
    version: i64
    summary: str
    protocol: str
    index: i64              // in the interface table
    requests: []Msg
    events: []Msg
    enums: []Enum
}

priv fn load_message(f: *Node, n: *Node) -> Msg {
    m := Msg{name: n.attr("name"), since: to_int(or(n.attr("since"), "1")),
        destructor: n.attr("type") == "destructor", summary: n.summary()}
    args := vec[Arg]()
    for a in n.children("arg") {
        kind := a.attr("type")
        if index_of([]str{"int", "uint", "fixed", "string", "object", "new_id", "array", "fd"}, kind) < 0 {
            fail(fmt(source, ": ", f.attr("name"), ".", m.name, ": unknown argument type `", kind, "`"))
        }
        e := a.attr("enum")
        if e != "" && find(e, ".") < 0 { e = fmt(f.attr("name"), ".", e) }
        args.push(Arg{name: a.attr("name"), kind: kind, iface: a.attr("interface"),
            nullable: a.attr("allow-null") == "true", enum_: e, summary: squeeze(a.attr("summary"))})
    }
    m.args = args.items()
    m
}

// `a`, or `b` if `a` is empty.
priv fn or(a: str, b: str) -> str { if a != "" { a } else { b } }

priv fn load(path: str, into: *Vec[Iface]) {
    source = path
    xml, ok := read_file(path)
    if !ok { fail(fmt("cannot read ", path, ": ", error_text(io_error()))) }
    root := xml_parse(xml)
    if root.tag != "protocol" { fail(fmt(path, ": not a Wayland protocol description")) }
    for n in root.children("interface") {
        f := Iface{name: n.attr("name"), version: to_int(n.attr("version")), summary: n.summary(),
            protocol: root.attr("name"), index: into.len}
        requests := vec[Msg]()
        for r in n.children("request") { requests.push(load_message(n, r)) }
        events := vec[Msg]()
        for e in n.children("event") { events.push(load_message(n, e)) }
        enums := vec[Enum]()
        for e in n.children("enum") {
            entries := vec[Entry]()
            for v in e.children("entry") {
                to_int(v.attr("value"))
                entries.push(Entry{v.attr("name"), v.attr("value"), v.summary(), to_int(or(v.attr("since"), "1"))})
            }
            enums.push(Enum{e.attr("name"), e.attr("bitfield") == "true", e.summary(), entries.items()})
        }
        f.requests = requests.items()
        f.events = events.items()
        f.enums = enums.items()
        into.push(f)
    }
}

priv fn find_iface(all: []Iface, name: str) -> *Iface {
    for i in 0..all.len {
        if all[i].name == name { return &all[i] }
    }
    fail(fmt("interface ", name, " is used but not described by the protocols read"))
}

// The signature string of struct wl_message, as wayland-scanner writes it.
priv fn signature(m: *Msg) -> str {
    out := vec[u8]()
    if m.since > 1 { out.extend(fmt(m.since)) }
    for a in m.args {
        if a.nullable { out.push('?') }
        match a.kind {
            "int" => out.push('i')
            "uint" => out.push('u')
            "fixed" => out.push('f')
            "string" => out.push('s')
            "object" => out.push('o')
            "array" => out.push('a')
            "fd" => out.push('h')
            _ => {
                if a.iface == "" { out.extend("su") }
                out.push('n')
            }
        }
    }
    out.items()
}

// The interface (index, -1 for none) of every component of the signature.
priv fn type_refs(all: []Iface, m: *Msg) -> []i64 {
    out := vec[i64]()
    for a in m.args {
        if (a.kind == "object" || a.kind == "new_id") && a.iface != "" {
            out.push(find_iface(all, a.iface).index)
            continue
        }
        if a.kind == "new_id" {
            out.push(-1)
            out.push(-1)
        }
        out.push(-1)
    }
    out.items()
}

// The AL type of an argument: of a request parameter, or of a handler parameter.
priv fn al_type(a: *Arg, request: bool) -> str {
    match a.kind {
        "int", "fixed", "fd" => "i32"
        "uint" => "u32"
        "string" => if request { "str" } else { "*u8" }
        "array" => "*WlArray"
        _ => if a.iface != "" { concat("*", camel(a.iface)) } else { "*u8" }
    }
}

// What a reader must know about an argument beyond its AL type, "" if nothing.
priv fn arg_note(a: *Arg) -> str {
    if a.enum_ != "" { return a.enum_ }
    match a.kind {
        "fixed" => "wl_fixed"
        "fd" => "fd"
        _ => ""
    }
}

// The upper-case prefix of the constants of an interface.
priv fn prefix(f: *Iface) -> str { to_upper(f.name) }

// The lines `text  // comment` with the comments aligned.
priv fn push_commented(out: *Vec[str], rows: [](str, str)) {
    width := 0
    for r in rows {
        if r.1 != "" && r.0.len < 60 { width = max(width, r.0.len) }
    }
    for r in rows {
        if r.1 == "" {
            out.push(r.0)
        } else {
            out.push(fmt(pad_right(r.0, width, ' '), "    // ", r.1))
        }
    }
}

priv fn since_note(since: i64) -> str { if since > 1 { fmt(" (since version ", since, ")") } else { "" } }

// Names the generated request functions use themselves.
priv const RESERVED = [_]str{"argv", "top", "made", "mark", "release", "cstr", "ptr", "cast", "u32", "u64", "nil"}

// One request as a function.
priv fn request_fn(out: *Vec[str], f: *Iface, m: *Msg) {
    self := f.name
    params := vec_of([]str{fmt(self, ": *", camel(f.name))})
    values := vec[str]()
    notes := vec[str]()
    seen := vec_of([]str{self})
    result := ""
    new_iface := "nil"
    version := fmt("wl_proxy_get_version(cast[*u8](", self, "))")
    strings := false
    for i in 0..m.args.len {
        a := &m.args[i]
        name := al_name(a.name)
        if a.kind == "new_id" {
            if result != "" { fail(fmt(f.name, ".", m.name, ": two new objects")) }
            if a.iface == "" {
                // the caller says what the object is, as in wl_registry.bind
                for extra in []str{"interface", "version"} {
                    if seen.contains(extra) { fail(fmt(f.name, ".", m.name, ": argument `", extra, "` clashes")) }
                    seen.push(extra)
                }
                params.push("interface: *WlInterface")
                params.push("version: u32")
                values.push("cast[u64](interface.name)")
                values.push("u64(version)")
                result = "*u8"
                new_iface = "interface"
                version = "version"
            } else {
                result = concat("*", camel(a.iface))
                new_iface = fmt(a.iface, "_interface()")
            }
            values.push("0")
            continue
        }
        if seen.contains(name) || contains(RESERVED[..], name) {
            fail(fmt(f.name, ".", m.name, ": the argument name `", name, "` clashes"))
        }
        seen.push(name)
        params.push(fmt(name, ": ", al_type(a, true)))
        match a.kind {
            "int", "fixed", "fd" => values.push(fmt("u64(u32(", name, "))"))
            "uint" => values.push(fmt("u64(", name, ")"))
            "string" => {
                strings = true
                values.push(fmt("cast[u64](", if a.nullable { "wl_cstr_or_nil" } else { "cstr" }, "(", name, "))"))
            }
            _ => values.push(fmt("cast[u64](", name, ")"))
        }
        note := arg_note(a)
        if a.nullable {
            note = fmt(if note != "" { concat(note, ", ") } else { "" },
                if a.kind == "string" { "\"\" for none" } else { "may be nil" })
        }
        if note != "" { notes.push(fmt("`", name, "`: ", note)) }
    }
    doc := fmt("// ", f.name, ".", m.name, since_note(m.since), if m.summary != "" { ": " } else { "" }, m.summary)
    if !notes.is_empty() { doc = fmt(doc, ". ", join(notes[..], "; ")) }
    if m.destructor { doc = concat(doc, ". Destroys the object.") }
    out.push(doc)
    out.push(fmt("fn ", f.name, "_", m.name, "(", join(params[..], ", "), ")",
        if result != "" { " -> " } else { "" }, result, " {"))
    if strings { out.push("    top := mark()") }
    if !values.is_empty() { out.push(fmt("    argv := [", values.len, "]u64{", join(values[..], ", "), "}")) }
    call := fmt("wl_proxy_marshal_array_flags(cast[*u8](", self, "), ", prefix(f), "_", to_upper(m.name), ", ",
        new_iface, ", ", version, ", ", if m.destructor { "WL_MARSHAL_FLAG_DESTROY" } else { "0" }, ", ",
        if values.is_empty() { "nil" } else { "ptr(argv)" }, ")")
    typed := if result == "*u8" || result == "" { call } else { fmt("cast[", result, "](", call, ")") }
    if strings && result != "" {
        out.push(fmt("    made := ", typed))
        out.push("    release(top)")
        out.push("    made")
    } else {
        out.push(concat("    ", typed))
        if strings { out.push("    release(top)") }
    }
    out.push("}")
}

// Everything of one interface except its tables.
priv fn interface_decls(out: *Vec[str], f: *Iface) {
    self := f.name
    ty := camel(f.name)
    is_display := f.name == "wl_display"
    out.push(fmt("\n// ---- ", f.name, " (version ", f.version, ")", if f.summary != "" { ": " } else { "" }, f.summary, " ----"))
    out.push(fmt("struct ", ty, " {}"))
    out.push(fmt("fn ", self, "_interface() -> *WlInterface { wl_interface_at(", f.index, ") }"))

    for e in f.enums {
        out.push(fmt("// ", f.name, ".", e.name, if e.bitfield { " (bits)" } else { "" },
            if e.summary != "" { ": " } else { "" }, e.summary))
        rows := vec[(str, str)]()
        for v in e.entries {
            rows.push((fmt("const ", prefix(f), "_", to_upper(e.name), "_", to_upper(v.name), " = ", v.value),
                concat(v.summary, since_note(v.since))))
        }
        push_commented(out, rows[..])
    }

    if f.requests.len > 0 {
        out.push(fmt("// opcodes of the requests of ", f.name))
        for i, m in f.requests {
            out.push(fmt("const ", prefix(f), "_", to_upper(m.name), ": u32 = ", i))
        }
    }

    if f.events.len > 0 && !is_display {
        out.push(fmt("// The handlers of the events of ", f.name, ", in protocol order."))
        out.push(fmt("struct ", ty, "Listener {"))
        for i in 0..f.events.len {
            m := &f.events[i]
            names := vec_of([]str{"data", self})
            types := vec_of([]str{"*u8", concat("*", ty)})
            for k in 0..m.args.len {
                a := &m.args[k]
                note := arg_note(a)
                names.push(if note != "" { fmt(a.name, ": ", note) } else { a.name })
                types.push(al_type(a, false))
            }
            out.push(fmt("    // ", m.summary, since_note(m.since), if m.summary != "" { ": " } else { "" },
                "(", join(names[..], ", "), ")"))
            out.push(fmt("    ", al_name(m.name), ": fn(", join(types[..], ", "), ")"))
        }
        out.push("}")
        out.push(fmt("// Sets the event handlers of a ", f.name, " (see `Listeners` at the top of this file)."))
        out.push(fmt("fn ", self, "_add_listener(", self, ": *", ty, ", listener: *", ty, "Listener, data: *u8) -> i32 {"))
        out.push(fmt("    wl_listen(cast[*u8](", self, "), cast[*u8](listener), ", f.events.len, ", data)"))
        out.push("}")
    } else if is_display {
        out.push("// (the events of wl_display, error and delete_id, are handled by libwayland itself)")
    }

    out.push(fmt("fn ", self, "_set_user_data(", self, ": *", ty, ", data: *u8) { wl_proxy_set_user_data(cast[*u8](", self, "), data) }"))
    out.push(fmt("fn ", self, "_get_user_data(", self, ": *", ty, ") -> *u8 { wl_proxy_get_user_data(cast[*u8](", self, ")) }"))
    out.push(fmt("fn ", self, "_get_version(", self, ": *", ty, ") -> u32 { wl_proxy_get_version(cast[*u8](", self, ")) }"))
    has_destroy := false
    for m in f.requests {
        if m.name == "destroy" { has_destroy = true }
    }
    if !has_destroy && !is_display {
        out.push("// Frees the client-side object; the compositor is not told (the protocol has no `destroy` request for it).")
        out.push(fmt("fn ", self, "_destroy(", self, ": *", ty, ") { wl_proxy_destroy(cast[*u8](", self, ")) }"))
    }
    for i in 0..f.requests.len {
        request_fn(out, f, &f.requests[i])
    }
}

// The constant tables the interface tables are built from (wl_interface_at in the helpers).
priv fn tables(out: *Vec[str], all: []Iface) {
    // a run of "no interface" at the start serves every message without object arguments
    null_run := 1
    nmessages := 0
    for i in 0..all.len {
        f := &all[i]
        nmessages += f.requests.len + f.events.len
        for k in 0..f.requests.len { null_run = max(null_run, type_refs(all, &f.requests[k]).len) }
        for k in 0..f.events.len { null_run = max(null_run, type_refs(all, &f.events[k]).len) }
    }
    types := vec_fill(null_run, -1)
    messages := vec[(str, str)]()
    interfaces := vec[str]()
    for i in 0..all.len {
        f := &all[i]
        interfaces.push(fmt("    WlInterfaceDesc{\"", f.name, "\", ", f.version, ", ", f.requests.len, ", ", f.events.len, "},"))
        for pass in 0..2 {
            list := if pass == 0 { f.requests } else { f.events }
            for k in 0..list.len {
                m := &list[k]
                refs := type_refs(all, m)
                at := 0
                for r in refs {
                    if r >= 0 { at = types.len }
                }
                if at > 0 { types.extend(refs) }
                messages.push((fmt("    WlMessageDesc{\"", m.name, "\", \"", signature(m), "\", ", at, "},"),
                    if k == 0 { fmt(f.name, if pass == 0 { " requests" } else { " events" }) } else { "" }))
            }
        }
    }
    out.push(`
// ---- interface tables ----
// What wayland-scanner writes as C data (private-code): per interface its name, version and
// numbers of requests and events; per message (the requests, then the events of each interface
// in turn) its name, its signature and where its argument types start in WL_TYPES, which holds
// the interface number of every object argument (-1: none).`)
    out.push(fmt("priv const WL_INTERFACE_COUNT = ", all.len))
    out.push(fmt("priv const WL_MESSAGE_COUNT = ", nmessages))
    out.push(fmt("priv const WL_TYPE_COUNT = ", types.len))
    out.push("priv const WL_INTERFACES = [WL_INTERFACE_COUNT]WlInterfaceDesc{")
    out.extend(interfaces[..])
    out.push("}")
    out.push("priv const WL_MESSAGES = [WL_MESSAGE_COUNT]WlMessageDesc{")
    push_commented(out, messages[..])
    out.push("}")
    out.push("priv const WL_TYPES = [WL_TYPE_COUNT]i8{")
    for i in 0..types.len by 20 {
        row := vec[str]()
        for t in types[i..min(i + 20, types.len)] { row.push(fmt(t)) }
        out.push(fmt("    ", join(row[..], ", "), ","))
    }
    out.push("}\n")
}

// ---- std/wayland.al ---------------------------------------------------------------------------
priv fn bindings(all: []Iface) -> str {
    protocols := vec[str]()
    for f in all {
        if !protocols.contains(f.protocol) { protocols.push(f.protocol) }
    }
    out := vec[str]()
    out.push(fmt("// std.wayland: bindings for Wayland clients: libwayland-client.so.0 and the protocols ",
        join(protocols[..], ", "), ";"))
    out.push(`// the parts of libxkbcommon.so.0 (keyboard) and libwayland-cursor.so.0 (pointer image) that a
// window needs.
// GENERATED by tools/gen_wayland.al from the protocol XML files; do not edit. The first part
// (down to "protocols") comes from tools/wayland_helpers.al. See docs/std/wayland.md.
//
// Mapping from the C API (what wayland-scanner generates), per interface, here wl_surface:
//   struct wl_surface *            *WlSurface (an opaque struct; nil is NULL)
//   &wl_surface_interface          wl_surface_interface()
//   wl_surface_attach(s, b, x, y)  the same name and arguments: one function per request
//   WL_SURFACE_ERROR_...           the same constants (enum entries), and the opcodes
//   struct wl_surface_listener     WlSurfaceListener, wl_surface_add_listener(s, &listener, data)
// Argument types: int, fixed (wl_fixed_to_double) and fd are i32, uint is u32, an object is a
// pointer to its struct (*u8 where the protocol names no interface), an array is *WlArray. A
// string is a str in a request (copied; "" stands for a null string where one is allowed) and
// a C string (*u8: from_cstr) in an event handler.
//
// Listeners: an event handler is a plain function
//     fn(data: *u8, object: *WlSurface, <the arguments of the event>)
// (any function, also a nested one: it sees no local variables). The listener struct has one
// field per event; fields left nil are set to a handler that ignores the event when the
// listener is added. libwayland keeps the pointer to the struct: it must stay alive and in
// place as long as the object does, so make it a global variable
//     listener := WlSurfaceListener{enter: on_enter}
// or allocate it (&WlSurfaceListener{...}), not a local variable. Handlers run inside
// wl_display_dispatch / wl_display_roundtrip / wl_display_poll, on the calling thread.
`)
    out.push(trim_right(HELPERS))
    protocol := ""
    for i in 0..all.len {
        f := &all[i]
        if f.protocol != protocol {
            protocol = f.protocol
            out.push(fmt("\n// ==== protocol ", protocol, " ===="))
        }
        interface_decls(&out, f)
    }
    tables(&out, all)
    join(out[..], "\n")
}

// ---- verification -----------------------------------------------------------------------------
// A C program that prints every interface table of the code wayland-scanner generates, and
// every opcode and enum value of its headers.
priv fn verify_c(all: []Iface, headers: []str) -> str {
    out := vec[str]()
    out.push("#include <stdio.h>\n#include <ctype.h>\n#include <wayland-client.h>")
    for h in headers { out.push(fmt("#include \"", h, "\"")) }
    out.push(`static void message(const char *kind, const struct wl_message *m) {
    printf("%s %s %s", kind, m->name, m->signature);
    int i = 0;
    for (const char *s = m->signature; *s; s++) {
        if (isdigit((unsigned char)*s) || *s == '?') continue;
        int generic = *s == 'n' && s - m->signature >= 2 && s[-1] == 'u' && s[-2] == 's';
        if ((*s == 'o' || *s == 'n') && !generic) printf(" %s", m->types[i] ? m->types[i]->name : "-");
        i++;
    }
    printf("\n");
}
static void interface(const struct wl_interface *f) {
    printf("interface %s %d %d %d\n", f->name, f->version, f->method_count, f->event_count);
    for (int i = 0; i < f->method_count; i++) message("request", &f->methods[i]);
    for (int i = 0; i < f->event_count; i++) message("event", &f->events[i]);
}
int main(void) {`)
    for f in all { out.push(fmt("    interface(&", f.name, "_interface);")) }
    for i in 0..all.len {
        f := &all[i]
        for m in f.requests {
            name := fmt(prefix(f), "_", to_upper(m.name))
            out.push(fmt("    printf(\"", name, " %lld\\n\", (long long)", name, ");"))
        }
        for e in f.enums {
            for v in e.entries {
                name := fmt(prefix(f), "_", to_upper(e.name), "_", to_upper(v.name))
                out.push(fmt("    printf(\"", name, " %lld\\n\", (long long)", name, ");"))
            }
        }
    }
    out.push("    return 0;\n}\n")
    join(out[..], "\n")
}

// An AL program that prints the same lines from std.wayland.
priv fn verify_al(all: []Iface) -> str {
    out := vec[str]()
    main := vec[str]()              // the calls of the functions below
    out.push(`use std.wayland
fn message(kind: str, m: *WlMessage) {
    sig := from_cstr(m.signature)
    put(kind, " ", from_cstr(m.name), " ", sig)
    i := 0
    for k, c in sig {
        if is_digit(c) || c == '?' { continue }
        generic := c == 'n' && k >= 2 && sig[k - 1] == 'u' && sig[k - 2] == 's'
        if (c == 'o' || c == 'n') && !generic {
            t := m.types[i]
            put(" ", if t != nil { from_cstr(t.name) } else { "-" })
        }
        i += 1
    }
    putc('\n')
}
fn interface(f: *WlInterface) {
    print("interface", from_cstr(f.name), f.version, f.method_count, f.event_count)
    requests := mkslice[WlMessage](f.methods, i64(f.method_count))
    events := mkslice[WlMessage](f.events, i64(f.event_count))
    for i in 0..requests.len { message("request", &requests[i]) }
    for i in 0..events.len { message("event", &events[i]) }
}`)
    n := 0
    for i in 0..all.len {
        f := &all[i]
        main.push(fmt("    interface(", f.name, "_interface())"))
        names := vec[str]()
        for m in f.requests { names.push(fmt(prefix(f), "_", to_upper(m.name))) }
        for e in f.enums {
            for v in e.entries { names.push(fmt(prefix(f), "_", to_upper(e.name), "_", to_upper(v.name))) }
        }
        if names.is_empty() { continue }
        out.push(fmt("fn c_", i, "() {"))
        for name in names { out.push(fmt("    print(\"", name, "\", i64(", name, "))")) }
        out.push("}")
        n += names.len
    }
    out.push("fn main() {")
    out.extend(main[..])
    for i in 0..all.len {
        f := &all[i]
        if f.requests.len > 0 || f.enums.len > 0 { out.push(fmt("    c_", i, "()")) }
    }
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
    if args().len > 1 && !verify { fail("usage: ./build/alc run tools/gen_wayland.al [-- --verify]") }
    if !file_exists(SELF) { fail(fmt("run it from the root of the repository (there is no ", SELF, " here)")) }
    all := vec[Iface]()
    for path in PROTOCOLS { load(path, &all) }
    text := bindings(all[..])
    save(OUT, text)
    nrequests := 0
    nevents := 0
    nentries := 0
    for f in all {
        nrequests += f.requests.len
        nevents += f.events.len
        for e in f.enums { nentries += e.entries.len }
    }
    print(fmt("wrote ", OUT, ": ", count(text, "\n"), " lines, ", all.len, " interfaces, ", nrequests, " requests, ",
        nevents, " events, ", nentries, " enum values, ", count(text, "\nextern "), " library functions"))
    if !verify { return }

    // The same lines from C (the output of wayland-scanner) and from the new std/wayland.al.
    if !make_dir(SCRATCH) { fail(fmt("cannot create ", SCRATCH, ": ", error_text(io_error()))) }
    headers := vec[str]()
    cc_args := vec_of([]str{"-o", concat(SCRATCH, "/tables_c"), concat(SCRATCH, "/tables.c")})
    for i, path in PROTOCOLS {
        // (wayland-client.h already includes the header of the core protocol; the tables of the
        // scanner's code are compared for it too, not those inside libwayland-client)
        headers.push(fmt("protocol", i, ".h"))
        must_run([]str{"wayland-scanner", "client-header", path, fmt(SCRATCH, "/protocol", i, ".h")})
        must_run([]str{"wayland-scanner", "private-code", path, fmt(SCRATCH, "/protocol", i, ".c")})
        cc_args.push(fmt(SCRATCH, "/protocol", i, ".c"))
    }
    save(concat(SCRATCH, "/tables.c"), verify_c(all[..], headers[..]))
    save(concat(SCRATCH, "/tables.al"), verify_al(all[..]))
    compiled := false
    for cc in []str{"clang", "gcc", "cc"} {
        argv := vec_of([]str{cc})
        argv.extend(cc_args[..])
        status := run(argv[..])
        if status < 0 { continue }              // not installed: try the next one
        if status != 0 { fail(fmt(cc, " does not compile ", SCRATCH, "/tables.c (exit status ", status, ")")) }
        compiled = true
        break
    }
    if !compiled { fail("cannot verify the tables: no C compiler (clang, gcc or cc) is installed") }
    // (ALC_STD_DIR: the compiler has the previous std/wayland.al inside)
    must_run([]str{"env", "ALC_STD_DIR=std", "./build/alc", "build", concat(SCRATCH, "/tables.al"), "-o", concat(SCRATCH, "/tables_al")})
    c := output_of(concat(SCRATCH, "/tables_c"))
    al := output_of(concat(SCRATCH, "/tables_al"))
    mismatches := abs(c.len - al.len)
    for i in 0..min(c.len, al.len) {
        if c[i] == al[i] { continue }
        mismatches += 1
        if mismatches <= 20 { eprint(fmt("tables: C has `", c[i], "`, std.wayland has `", al[i], "`")) }
    }
    if mismatches > 0 { fail(fmt("tables: ", mismatches, " of ", c.len, " lines differ")) }
    print(fmt("tables: no mismatches in ", c.len, " lines"))
}
