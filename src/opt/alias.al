// Simple alias analysis: identified objects (allocas, globals), constant offsets, type-based classes.

Base :: enum {
    BaseAlloca(i64),
    BaseGlobal(i64),
    BaseUnknown(i64),
}

Addr :: struct {
    base: Base,
    off: Opt[i64],
}

// `==` of two bases (derive(PartialEq))
eq :: (a: Base, b: Base) -> bool {
    match a {
        BaseAlloca(x) => {
            match b {
                BaseAlloca(y) => return x == y
                _ => return false
            }
        }
        BaseGlobal(x) => {
            match b {
                BaseGlobal(y) => return x == y
                _ => return false
            }
        }
        BaseUnknown(x) => {
            match b {
                BaseUnknown(y) => return x == y
                _ => return false
            }
        }
    }
    return false
}

// off.map(|o| o.wrapping_add(k))
alias_off_add :: (off: Opt[i64], k: i64) -> Opt[i64] {
    match off {
        Some(o) => return Some(o + k)
        None => {}
    }
    return None
}

// a.is_some() && a == b
alias_off_some_eq :: (a: Opt[i64], b: Opt[i64]) -> bool {
    match a {
        Some(x) => {
            match b {
                Some(y) => return x == y
                None => return false
            }
        }
        None => {}
    }
    return false
}

alias_decompose :: (f: *Func, addr: i64) -> Addr {
    v := addr
    off: Opt[i64] = Some(0)
    depth := 0
    loop {
        i := &f.insts[v]
        if i.op == OpAlloca {
            return Addr{base: BaseAlloca(v), off: off}
        }
        if i.op == OpGAddr {
            return Addr{base: BaseGlobal(i.k), off: off}
        }
        if i.op == OpAdd && depth < 32 {
            depth += 1
            a := i.args[0]
            b := i.args[1]
            match f.is_const(b) {
                Some(k) => {
                    off = alias_off_add(off, k)
                    v = a
                    continue
                }
                None => {}
            }
            match f.is_const(a) {
                Some(k) => {
                    off = alias_off_add(off, k)
                    v = b
                    continue
                }
                None => {}
            }
            // variable index: look for an identified object on either side
            da := alias_decompose_obj(f, a, depth)
            match da {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
            db := alias_decompose_obj(f, b, depth)
            match db {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
            return Addr{base: BaseUnknown(v), off: off}
        }
        return Addr{base: BaseUnknown(v), off: off}
    }
}

alias_decompose_obj :: (f: *Func, v: i64, depth: i64) -> Opt[Base] {
    if depth > 32 {
        return None
    }
    i := &f.insts[v]
    if i.op == OpAlloca {
        return Some(BaseAlloca(v))
    }
    if i.op == OpGAddr {
        return Some(BaseGlobal(i.k))
    }
    if i.op == OpAdd {
        r := alias_decompose_obj(f, i.args[0], depth + 1)
        match r {
            Some(x) => return r
            None => {}
        }
        return alias_decompose_obj(f, i.args[1], depth + 1)
    }
    return None
}

// allocas whose address may be observed by something other than direct loads/stores
alias_escaped_allocas :: (f: *Func) -> Vec[bool] {
    n := f.insts.len
    esc := vec_fill(n, false)
    // derived[v] = alloca this pointer value is derived from
    derived := vec_fill(n, NOV)
    for v in f.blocks[0].insts.items() {
        if f.insts[v].op == OpAlloca {
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
                if i.op == OpAdd {
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
                } else if i.op == OpLoad {
                } else if i.op == OpStore {
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

MemRef :: struct {
    addr: Addr,
    size: i64,
    class: i64,
    ptr: i64, // the address value itself
}

alias_memref :: (f: *Func, v: i64) -> MemRef {
    i := &f.insts[v]
    return MemRef{addr: alias_decompose(f, i.args[0]), size: i.ty.size(), class: i.aux, ptr: i.args[0]}
}

alias_may_alias :: (a: *MemRef, b: *MemRef, esc: []bool) -> bool {
    match a.addr.base {
        BaseAlloca(x) => {
            match b.addr.base {
                BaseAlloca(y) => {
                    if x != y {
                        return false
                    }
                }
                BaseGlobal(y) => return false
                BaseUnknown(y) => {
                    if !esc[x] {
                        return false
                    }
                }
            }
        }
        BaseGlobal(x) => {
            match b.addr.base {
                BaseAlloca(y) => return false
                BaseGlobal(y) => {
                    if x != y {
                        return false
                    }
                }
                BaseUnknown(y) => {}
            }
        }
        BaseUnknown(u) => {
            match b.addr.base {
                BaseAlloca(x) => {
                    if !esc[x] {
                        return false
                    }
                }
                _ => {}
            }
        }
    }
    if a.ptr == b.ptr && a.ptr != NOV {
        return true
    }
    if eq(a.addr.base, b.addr.base) {
        match a.addr.off {
            Some(oa) => {
                match b.addr.off {
                    Some(ob) => return oa < ob + b.size && ob < oa + a.size
                    None => {}
                }
            }
            None => {}
        }
    }
    return types_may_alias_class(a.class, b.class)
}

alias_must_alias :: (a: *MemRef, b: *MemRef) -> bool {
    if a.size != b.size {
        return false
    }
    return (a.ptr == b.ptr && a.ptr != NOV) || (eq(a.addr.base, b.addr.base) && alias_off_some_eq(a.addr.off, b.addr.off))
}
