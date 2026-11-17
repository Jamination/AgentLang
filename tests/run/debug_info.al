// alc build -g (debug_info.flags): the program reads its own executable (ELF on Linux, PE on
// Windows) and checks the DWARF that describes it: sections, the compile unit, the
// subprogram of `probe` with its parameters, variables, scopes and types, the line table
// against the lines of this file, the address ranges and the call frame information. A path
// as the first argument reads that file instead (an ELF built by `--target linux -g`).
// Everything printed is the same at -O0 and optimised: `probe` is never inlined and its
// variables have their address taken, so they stay in memory.

struct Pair {
    x: i64
    y: i64
}

enum Shape {
    Dot,
    Box(i64, Pair),
}

noinline fn touch(p: *i64) -> i64 {
    return *p + 1
}

noinline fn tag_of(s: *Shape) -> i64 {
    return match *s {
        Box(n, _) => n
        Dot => 0
    }
}

noinline fn probe(a: i64, s: Shape) -> i64 {
    k := a * 2
    t := touch(&k)
    if t > 0 {
        inner := t + 3
        t += touch(&inner)
    }
    p := Pair{x: k, y: t}
    t += touch(&p.y)
    c := s
    return t + tag_of(&c)
}

// the lines of probe (the declaration and the last line), and of its call in main
const PROBE_FIRST = 30
const PROBE_LAST = 41
const MAIN_CALL = 462

// ---------- reading the file ----------

priv struct Bin {
    b: str
    elf: bool
    secs: Map[str, (i64, i64)] // name -> (file offset, size)
}

priv fn u8at(b: str, o: i64) -> i64 {
    return i64(b[o])
}

priv fn u16at(b: str, o: i64) -> i64 {
    return i64(b[o]) | i64(b[o + 1]) << 8
}

priv fn u32at(b: str, o: i64) -> i64 {
    return u16at(b, o) | u16at(b, o + 2) << 16
}

priv fn u64at(b: str, o: i64) -> i64 {
    return u32at(b, o) | u32at(b, o + 4) << 32
}

priv fn cstr_at(b: str, o: i64) -> str {
    e := o
    while e < len(b) && b[e] != 0 {
        e += 1
    }
    return b[o..e]
}

priv fn open_bin(path: str) -> Bin {
    b, ok := read_file(path)
    if !ok {
        b, ok = read_file(fmt(path, ".exe"))
    }
    assert ok, fmt("cannot read ", path)
    bin := Bin{b: b, elf: len(b) > 4 && b[..4] == "\x7fELF"}
    if bin.elf {
        shoff := u64at(b, 40)
        shnum := u16at(b, 60)
        shstr := u16at(b, 62)
        stro := u64at(b, shoff + 64 * shstr + 24)
        for i in 0..shnum {
            h := shoff + 64 * i
            name := cstr_at(b, stro + u32at(b, h))
            bin.secs.set(name, (u64at(b, h + 24), u64at(b, h + 32)))
        }
    } else {
        assert b[..2] == "MZ"
        pe := u32at(b, 60)
        nsec := u16at(b, pe + 6)
        symtab := u32at(b, pe + 12)
        nsyms := u32at(b, pe + 16)
        opt := u16at(b, pe + 20)
        sh := pe + 24 + opt
        for i in 0..nsec {
            h := sh + 40 * i
            name := cstr_at(b[..h + 8], h)
            if starts_with(name, "/") {
                // a long name: in the COFF string table, after the symbols
                k, _ := parse_i64(name[1..])
                name = cstr_at(b, symtab + 18 * nsyms + k)
            }
            bin.secs.set(name, (u32at(b, h + 20), u32at(b, h + 8)))
        }
    }
    return bin
}

priv fn sec(bin: *Bin, name: str) -> str {
    o, found := bin.secs.get(name)
    assert found, fmt("no section ", name)
    return bin.b[o.0..o.0 + o.1]
}

// ---------- DWARF ----------

priv struct Rd {
    b: str
    p: i64
}

priv fn byte(r: *Rd) -> i64 {
    r.p += 1
    return i64(r.b[r.p - 1])
}

priv fn fixed(r: *Rd, n: i64) -> i64 {
    v := 0
    for i in 0..n {
        v |= i64(r.b[r.p + i]) << (8 * i)
    }
    r.p += n
    return v
}

priv fn uleb(r: *Rd) -> i64 {
    v := 0
    sh := 0
    loop {
        x := byte(r)
        v |= (x & 0x7F) << sh
        sh += 7
        if x & 0x80 == 0 {
            return v
        }
    }
}

priv fn sleb(r: *Rd) -> i64 {
    v := 0
    sh := 0
    loop {
        x := byte(r)
        v |= (x & 0x7F) << sh
        sh += 7
        if x & 0x80 == 0 {
            if sh < 64 && x & 0x40 != 0 {
                v |= -1 << sh
            }
            return v
        }
    }
}

priv struct Die {
    off: i64
    tag: i64
    parent: i64 // index of the parent DIE, -1 for the unit
    attrs: Map[i64, i64]  // attribute -> value (strings: index into strs, exprloc: into exprs)
    forms: Map[i64, i64]
}

priv struct Dwarf {
    dies: Vec[Die]
    by_off: Map[i64, i64]
    strs: Vec[str]
    exprs: Vec[str]
}

priv fn parse_info(bin: *Bin) -> Dwarf {
    abbrev := sec(bin, ".debug_abbrev")
    strtab := sec(bin, ".debug_str")
    // code -> (tag, children, [(attr, form)])
    abbrs := map[i64, (i64, bool, Vec[(i64, i64)])]()
    ar := Rd{b: abbrev}
    loop {
        code := uleb(&ar)
        if code == 0 {
            break
        }
        tag := uleb(&ar)
        kids := byte(&ar) == 1
        list := vec[(i64, i64)]()
        loop {
            at := uleb(&ar)
            fm := uleb(&ar)
            if at == 0 && fm == 0 {
                break
            }
            list.push((at, fm))
        }
        abbrs.set(code, (tag, kids, list))
    }
    d := Dwarf{}
    r := Rd{b: sec(bin, ".debug_info")}
    end := fixed(&r, 4) + 4
    assert fixed(&r, 2) == 4, "DWARF version 4"
    assert fixed(&r, 4) == 0
    assert byte(&r) == 8
    stack := vec[i64]()
    while r.p < end {
        off := r.p
        code := uleb(&r)
        if code == 0 {
            stack.pop()
            continue
        }
        a, found := abbrs.get(code)
        assert found, fmt("unknown abbreviation ", code)
        die := Die{off: off, tag: a.0, parent: if stack.is_empty() { -1 } else { stack.last() }}
        for x in a.2 {
            v := match x.1 {
                0x01, 0x07 => fixed(&r, 8)
                0x05 => fixed(&r, 2)
                0x06, 0x13, 0x17 => fixed(&r, 4)
                0x0b => byte(&r)
                0x0d => sleb(&r)
                0x0f => uleb(&r)
                0x19 => 1
                0x0e => {
                    d.strs.push(cstr_at(strtab, fixed(&r, 4)))
                    d.strs.len - 1
                }
                0x18 => {
                    n := uleb(&r)
                    d.exprs.push(r.b[r.p..r.p + n])
                    r.p += n
                    d.exprs.len - 1
                }
                _ => {
                    panic(fmt("unknown form ", x.1))
                    0
                }
            }
            die.attrs.set(x.0, v)
            die.forms.set(x.0, x.1)
        }
        d.by_off.set(off, d.dies.len)
        d.dies.push(die)
        if a.1 {
            stack.push(d.dies.len - 1)
        }
    }
    return d
}

priv fn name_of(d: *Dwarf, k: i64) -> str {
    v, found := d.dies[k].attrs.get(0x03)
    return if found { d.strs[v] } else { "" }
}

priv fn attr(d: *Dwarf, k: i64, a: i64) -> i64 {
    v, found := d.dies[k].attrs.get(a)
    return if found { v } else { -1 }
}

// the DIE a reference attribute of DIE k points to
priv fn ref(d: *Dwarf, k: i64, a: i64) -> i64 {
    o := attr(d, k, a)
    t, found := d.by_off.get(o)
    return if found { t } else { -1 }
}

// a type as text: its name, `*` + the pointee, `[]` + the element of an array
priv fn type_text(d: *Dwarf, k: i64) -> str {
    if k < 0 {
        return "void"
    }
    return match d.dies[k].tag {
        0x0f => fmt("*", type_text(d, ref(d, k, 0x49)))
        0x01 => fmt("[array]", type_text(d, ref(d, k, 0x49)))
        _ => name_of(d, k)
    }
}

// the children of DIE k
priv fn kids(d: *Dwarf, k: i64) -> Vec[i64] {
    out := vec[i64]()
    for i in k + 1..d.dies.len {
        if d.dies[i].parent == k {
            out.push(i)
        }
    }
    return out
}

// ---------- the line table ----------

priv struct Row {
    addr: i64
    file: str
    line: i64
    end: bool
}

priv fn parse_lines(bin: *Bin) -> Vec[Row] {
    r := Rd{b: sec(bin, ".debug_line")}
    end := fixed(&r, 4) + 4
    assert fixed(&r, 2) == 4
    hlen := fixed(&r, 4)
    prog := r.p + hlen
    min_inst := byte(&r)
    byte(&r)
    byte(&r)
    line_base := byte(&r)
    if line_base >= 128 {
        line_base -= 256
    }
    line_range := byte(&r)
    opcode_base := byte(&r)
    r.p += opcode_base - 1
    while byte(&r) != 0 {
        r.p -= 1
        cstr_at(r.b, r.p)
        r.p += len(cstr_at(r.b, r.p)) + 1
    }
    files := vec_of([]str{"?"})
    loop {
        n := cstr_at(r.b, r.p)
        r.p += len(n) + 1
        if len(n) == 0 {
            break
        }
        files.push(n)
        uleb(&r)
        uleb(&r)
        uleb(&r)
    }
    assert r.p == prog, "line table header length"
    rows := vec[Row]()
    addr := 0
    file := 1
    line := 1
    while r.p < end {
        op := byte(&r)
        if op >= opcode_base {
            a := op - opcode_base
            addr += min_inst * (a / line_range)
            line += line_base + a % line_range
            rows.push(Row{addr: addr, file: files[file], line: line})
            continue
        }
        match op {
            0 => {
                n := uleb(&r)
                sub := byte(&r)
                if sub == 1 {
                    rows.push(Row{addr: addr, file: files[file], line: line, end: true})
                    addr = 0
                    file = 1
                    line = 1
                } else if sub == 2 {
                    addr = fixed(&r, 8)
                } else {
                    r.p += n - 1
                }
            }
            1 => rows.push(Row{addr: addr, file: files[file], line: line})
            2 => addr += min_inst * uleb(&r)
            3 => line += sleb(&r)
            4 => file = uleb(&r)
            5 => uleb(&r)
            8 => addr += min_inst * ((255 - opcode_base) / line_range)
            9 => addr += fixed(&r, 2)
            _ => {}
        }
    }
    return rows
}

// ---------- call frame information ----------

// The CFA rule at address `at` in the FDE that covers it: (register, offset), (-1, 0) for an
// expression, (-2, 0) if no FDE covers `at`.
priv fn cfa_at(bin: *Bin, at: i64) -> (i64, i64) {
    f := sec(bin, ".debug_frame")
    // the CIE's initial rule
    r := Rd{b: f}
    p := 0
    while p < len(f) {
        r.p = p
        n := fixed(&r, 4)
        id := fixed(&r, 4)
        next := p + 4 + n
        if id != 0xFFFFFFFF {
            lo := fixed(&r, 8)
            size := fixed(&r, 8)
            if at >= lo && at < lo + size {
                reg := 7
                off := 8
                saved := vec[(i64, i64)]()
                pc := lo
                while r.p < next {
                    op := byte(&r)
                    hi := op & 0xC0
                    adv := -1
                    if hi == 0x40 {
                        adv = op & 0x3F
                    } else if hi == 0x80 {
                        uleb(&r)
                    } else if hi == 0 {
                        match op {
                            0x02 => adv = byte(&r)
                            0x03 => adv = fixed(&r, 2)
                            0x04 => adv = fixed(&r, 4)
                            0x0a => saved.push((reg, off))
                            0x0b => {
                                reg, off = saved.pop()
                            }
                            0x0c => {
                                reg = uleb(&r)
                                off = uleb(&r)
                            }
                            0x0e => off = uleb(&r)
                            0x0f => {
                                reg = -1
                                r.p += uleb(&r)
                            }
                            0x07 => uleb(&r)
                            _ => {}
                        }
                    }
                    // (the rules hold from pc on: an advance past `at` ends the search)
                    if adv >= 0 {
                        if pc + adv > at {
                            break
                        }
                        pc += adv
                    }
                }
                return (reg, off)
            }
        }
        p = next
    }
    return (-2, 0)
}

// ---------- the checks ----------

fn main() {
    probe(1, Shape.Box(2, Pair{3, 4}))
    path := if args().len > 1 && args()[1] != "a1" { args()[1] } else { args()[0] }
    bin := open_bin(path)
    for s in []str{".debug_abbrev", ".debug_info", ".debug_line", ".debug_str", ".debug_aranges", ".debug_frame"} {
        _, found := bin.secs.get(s)
        print(s, found)
    }
    d := parse_info(&bin)
    cu := 0
    print("unit:", d.dies[cu].tag == 0x11, attr(&d, cu, 0x13) == 0x0c, starts_with(d.strs[attr(&d, cu, 0x25)], "alc"))
    lo := attr(&d, cu, 0x11)
    size := attr(&d, cu, 0x12)
    // the subprogram of probe
    pk := -1
    for i, die in d.dies {
        if die.tag == 0x2e && name_of(&d, i) == "probe" {
            pk = i
        }
    }
    assert pk >= 0, "no subprogram probe"
    plo := attr(&d, pk, 0x11)
    phi := plo + attr(&d, pk, 0x12)
    print("probe: line", attr(&d, pk, 0x3b), "returns", type_text(&d, ref(&d, pk, 0x49)), "inside the unit", plo >= lo && phi <= lo + size)
    // the variables whose address is taken (in memory at every optimisation level): the scope
    // of `inner` (a block of its own inside k's), the others in the scope of their line
    fn walk(d: *Dwarf, k: i64, depth: i64, out: *Vec[(str, i64)]) {
        for c in kids(d, k) {
            tag := d.dies[c].tag
            n := name_of(d, c)
            if (tag == 0x05 || tag == 0x34) && (n == "k" || n == "inner" || n == "p" || n == "c") {
                e := d.exprs[attr(d, c, 0x02)]
                loc := if len(e) >= 2 && e[0] == 0x91 { "fbreg" } else { "?" }
                print(fmt("  var ", n, ": ", type_text(d, ref(d, c, 0x49)), " line ", attr(d, c, 0x3b), " (", loc, ")"))
                out.push((n, depth))
            } else if tag == 0x0b {
                walk(d, c, depth + 1, out)
            }
        }
    }
    depths := vec[(str, i64)]()
    walk(&d, pk, 0, &depths)
    dk := 0
    for x in depths {
        if x.0 == "k" {
            dk = x.1
        }
    }
    for x in depths {
        if x.0 == "inner" {
            print("  inner in a block inside k's:", x.1 > dk && dk > 0)
        }
    }
    // the types: Pair, Shape (a variant part with two variants)
    for want in []str{"Pair", "Shape"} {
        i := -1
        for j, die in d.dies {
            if die.tag == 0x13 && name_of(&d, j) == want {
                i = j
            }
        }
        if i < 0 {
            print("type", want, "missing")
            continue
        }
        n := want
        {
            parts := vec[str]()
            for c in kids(&d, i) {
                if d.dies[c].tag == 0x0d {
                    parts.push(fmt(name_of(&d, c), "@", attr(&d, c, 0x38)))
                } else if d.dies[c].tag == 0x33 {
                    parts.push(fmt("variants ", kids(&d, c).len))
                }
            }
            print("type", n, "size", attr(&d, i, 0x0b), join(parts.items(), " "))
        }
    }
    // the line table: probe's rows are lines of probe, the first at its start
    rows := parse_lines(&bin)
    lines := vec[i64]()
    first_at_start := false
    for r in rows {
        if r.addr >= plo && r.addr < phi && !r.end && ends_with(r.file, "debug_info.al") {
            lines.push(r.line)
            first_at_start = first_at_start || r.addr == plo
        }
    }
    within := !lines.is_empty()
    for l in lines {
        within = within && l >= PROBE_FIRST && l <= PROBE_LAST
    }
    has_call := false
    for r in rows {
        has_call = has_call || r.line == MAIN_CALL && ends_with(r.file, "debug_info.al")
    }
    print("probe lines: within its source", within, "from its start", first_at_start, "the call in main", has_call)
    // aranges: one range, the unit's
    ar := Rd{b: sec(&bin, ".debug_aranges")}
    ar.p = 16
    print("aranges:", fixed(&ar, 8) == lo, fixed(&ar, 8) == size)
    // frames: the CFA is rsp + 8 at the entry and one rule (rsp + n) at every row of the body
    e := cfa_at(&bin, plo)
    body := vec[(i64, i64)]()
    for r in rows {
        if r.addr > plo && r.addr < phi && !r.end {
            body.push(cfa_at(&bin, r.addr))
        }
    }
    same := !body.is_empty()
    for b in body {
        same = same && b == body[0] && b.0 == 7 && b.1 >= 8
    }
    print("frame: entry rsp+8", e == (7, 8), "body one rule", same)
}
