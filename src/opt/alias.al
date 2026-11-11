// Simple alias analysis: identified objects (allocas, globals), constant offsets, type-based classes.

priv enum Base {
    Alloca(i64),
    Glob(i64),
    Unknown(i64),
}

struct Addr {
    base: Base,
    off: Opt[i64],
}

// `==` of two bases (derive(PartialEq))
priv fn eq(a: Base, b: Base) -> bool {
    match (a, b) {
        (Alloca(x), Alloca(y)), (Glob(x), Glob(y)), (Unknown(x), Unknown(y)) => x == y
        _ => false
    }
}

// off.map(|o| o.wrapping_add(k))
priv fn off_add(off: Opt[i64], k: i64) -> Opt[i64] {
    match off {
        Some(o) => Some(o + k)
        None => None
    }
}

// a.is_some() && a == b
priv fn off_some_eq(a: Opt[i64], b: Opt[i64]) -> bool {
    match (a, b) {
        (Some(x), Some(y)) => x == y
        _ => false
    }
}

priv fn decompose(f: *Func, addr: i64) -> Addr {
    v := addr
    off: Opt[i64] = Some(0)
    depth := 0
    loop {
        i := &f.insts[v]
        if i.op == Alloca {
            return Addr{base: Base.Alloca(v), off: off}
        }
        if i.op == GAddr {
            return Addr{base: Glob(i.k), off: off}
        }
        if i.op == Add && depth < 32 {
            depth += 1
            a := i.args[0]
            b := i.args[1]
            match f.is_const(b) {
                Some(k) => {
                    off = off_add(off, k)
                    v = a
                    continue
                }
                None => {}
            }
            match f.is_const(a) {
                Some(k) => {
                    off = off_add(off, k)
                    v = b
                    continue
                }
                None => {}
            }
            // variable index: look for an identified object on either side
            da := decompose_obj(f, a, depth)
            match da {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
            db := decompose_obj(f, b, depth)
            match db {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
            return Addr{base: Unknown(v), off: off}
        }
        return Addr{base: Unknown(v), off: off}
    }
}

priv fn decompose_obj(f: *Func, v: i64, depth: i64) -> Opt[Base] {
    if depth > 32 {
        return None
    }
    i := &f.insts[v]
    if i.op == Alloca {
        return Some(Base.Alloca(v))
    }
    if i.op == GAddr {
        return Some(Glob(i.k))
    }
    if i.op == Add {
        r := decompose_obj(f, i.args[0], depth + 1)
        match r {
            Some(x) => return r
            None => {}
        }
        return decompose_obj(f, i.args[1], depth + 1)
    }
    return None
}

// allocas whose address may be observed by something other than direct loads/stores
fn alias_escaped_allocas(f: *Func) -> Vec[bool] {
    n := f.insts.len
    esc := vec_fill(n, false)
    // derived[v] = alloca this pointer value is derived from
    derived := vec_fill(n, NOV)
    for v in f.blocks[0].insts.items() {
        if f.insts[v].op == Alloca {
            derived[v] = v
        }
    }
    rpo := f.rpo()
    changed := true
    while changed {
        changed = false
        for b in rpo.items() {
            for v in f.blocks[b].insts.items() {
                i := &f.insts[v]
                if i.op == Add {
                    for a in i.args.items() {
                        d := derived[a]
                        if d != NOV && derived[v] != d {
                            if derived[v] != NOV {
                                // derived from two allocas: treat both as escaped
                                esc[d] = true
                                esc[derived[v]] = true
                            } else {
                                derived[v] = d
                                changed = true
                            }
                        }
                    }
                } else if i.op == Load {
                } else if i.op == Store {
                    d := derived[i.args[1]]
                    if d != NOV && !esc[d] {
                        esc[d] = true
                        changed = true
                    }
                } else {
                    for a in i.args.items() {
                        d := derived[a]
                        if d != NOV && !esc[d] {
                            esc[d] = true
                            changed = true
                        }
                    }
                }
            }
            tu := f.term_uses(b)
            for u in tu.items() {
                d := derived[u]
                if d != NOV && !esc[d] {
                    esc[d] = true
                    changed = true
                }
            }
        }
    }
    return esc
}

struct MemRef {
    addr: Addr,
    size: i64,
    class: i64,
    ptr: i64, // the address value itself
}

fn alias_memref(f: *Func, v: i64) -> MemRef {
    i := &f.insts[v]
    return MemRef{addr: decompose(f, i.args[0]), size: i.ty.size(), class: i.aux, ptr: i.args[0]}
}

fn alias_may_alias(a: *MemRef, b: *MemRef, esc: []bool) -> bool {
    match (a.addr.base, b.addr.base) {
        (Alloca(x), Alloca(y)), (Glob(x), Glob(y)) if x != y => return false
        (Alloca(_), Glob(_)), (Glob(_), Alloca(_)) => return false
        (Alloca(x), Unknown(_)), (Unknown(_), Alloca(x)) if !esc[x] => return false
        _ => {}
    }
    if a.ptr == b.ptr && a.ptr != NOV {
        return true
    }
    if eq(a.addr.base, b.addr.base) {
        match (a.addr.off, b.addr.off) {
            (Some(oa), Some(ob)) => return oa < ob + b.size && ob < oa + a.size
            _ => {}
        }
    }
    return types_may_alias_class(a.class, b.class)
}

fn alias_must_alias(a: *MemRef, b: *MemRef) -> bool {
    if a.size != b.size {
        return false
    }
    return (a.ptr == b.ptr && a.ptr != NOV) || (eq(a.addr.base, b.addr.base) && off_some_eq(a.addr.off, b.addr.off))
}
