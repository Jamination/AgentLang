// Simple alias analysis: identified objects (allocas, globals, fresh allocations), constant
// offsets, type-based classes.
//
// Fresh allocations. `Fresh(p)` (Op.Fresh, made by __alloc_raw, see the prelude) is the address
// of memory the allocator has just handed out: memory no object that is live at that moment
// occupies. Memory is never handed out again while its object is live (release, reset and a
// Vec's growth give memory back only together with its objects; using an object after that is
// an error of the program, which ALC_CHECK_MEMORY reports), so two objects that are live at
// the same time are disjoint, even when the same address belonged to another object earlier.
// An answer "no alias" between an access q and the accesses p, p' through one pointer value
// (p before q, p' after it, or p moved across q) is used to keep a fact about p's location
// across q. The object of p and p' is live at both of them (else the program is wrong), so it
// is live at q too (an object's life is one interval); the object of q is live at q: they are
// different objects live at the same time, hence disjoint, when
//  - q and p go through two different Fresh values: two distinct allocations (each a single
//    instance wherever the IR compares them: no pass carries a fact across a redefinition of
//    a value it names), or
//  - one goes through a Fresh value and the other through a parameter of the function: the
//    parameter's object was made before the function began, so before the allocation.
// Addresses derived from a base stay inside its object (the rule the Alloca and Global cases
// rely on too); a pointer made from an integer that is no address of a live object (say a
// mark) is not a pointer to any object. A fresh object is neither a stack slot nor a global.

priv enum Base {
    Alloca(i64),
    Global(i64),
    Unknown(i64),
    Fresh(i64),
    // an Unknown address that is a parameter, perhaps plus scaled indices (param_rooted)
    Arg(i64),
}

// (ALC_DISABLE=fresh: Fresh values are not identified objects)
priv fresh_read: bool
priv fresh_on: bool

priv inline fn fresh_enabled() -> bool {
    if !fresh_read {
        fresh_on = opt_enabled("fresh")
        fresh_read = true
    }
    return fresh_on
}

struct Addr {
    base: Base,
    off: Opt[i64],
}

// the offset plus k (None stays None)
priv fn off_add(off: Opt[i64], k: i64) -> Opt[i64] {
    match off {
        Some(o) => Some(o + k)
        None => None
    }
}

// both offsets are known and equal (a tuple match: faster here than `is_some(a) && a == b`)
priv fn off_some_eq(a: Opt[i64], b: Opt[i64]) -> bool {
    match (a, b) {
        (Some(x), Some(y)) => x == y
        _ => false
    }
}

// A parameter that is the address of an aggregate passed by reference (Func.byref_params)
// points to the caller's copy for this call: an object of its own, which only the function
// reaches (through that parameter), like a local alloca. (The pointer only means this while
// it is a Param: inlining replaces it with the caller's argument.)
priv inline fn is_private_param(f: *Func, i: *Inst) -> bool {
    return i.op == Param && i.k < 64 && (f.byref_params >> u64(i.k)) & 1 != 0
}

priv fn decompose(f: *Func, addr: i64) -> Addr {
    v := addr
    off: Opt[i64] = Some(0)
    depth := 0
    loop {
        i := &f.insts[v]
        if i.op == Alloca || is_private_param(f, i) {
            return Addr{base: Base.Alloca(v), off: off}
        }
        if i.op == GAddr {
            return Addr{base: Global(i.k), off: off}
        }
        if i.op == Fresh && fresh_enabled() {
            return Addr{base: Base.Fresh(v), off: off}
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
            match decompose_obj(f, a, depth) {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
            match decompose_obj(f, b, depth) {
                Some(base) => return Addr{base: base, off: None}
                None => {}
            }
        }
        if param_rooted(f, v, 0) {
            return Addr{base: Arg(v), off: off}
        }
        return Addr{base: Unknown(v), off: off}
    }
}

// v is a parameter of the function, or one plus scaled indices (`p + (i << 3)`, `p + i * 24`):
// an address in the object a parameter points to (the scaled terms cannot be the pointer)
priv fn param_rooted(f: *Func, v: i64, depth: i64) -> bool {
    i := &f.insts[v]
    if i.op == Param {
        return true
    }
    if i.op != Add || depth > 8 {
        return false
    }
    a := i.args[0]
    b := i.args[1]
    return param_rooted(f, a, depth + 1) && scaled_index(f, b) || param_rooted(f, b, depth + 1) && scaled_index(f, a)
}

priv fn scaled_index(f: *Func, v: i64) -> bool {
    i := &f.insts[v]
    if i.op == Const {
        return true
    }
    if (i.op == Shl || i.op == Mul) && is_some(f.is_const(i.args[1])) {
        return true
    }
    return false
}

priv fn decompose_obj(f: *Func, v: i64, depth: i64) -> Opt[Base] {
    if depth > 32 {
        return None
    }
    i := &f.insts[v]
    if i.op == Alloca || is_private_param(f, i) {
        return Some(Base.Alloca(v))
    }
    if i.op == GAddr {
        return Some(Global(i.k))
    }
    if i.op == Fresh && fresh_enabled() {
        return Some(Base.Fresh(v))
    }
    if i.op == Add {
        r := decompose_obj(f, i.args[0], depth + 1)
        if is_some(r) {
            return r
        }
        return decompose_obj(f, i.args[1], depth + 1)
    }
    return None
}

// alias_escaped_allocas, remembered for the IR of a change count `gen` (opt_gen(f), for IR not
// changed since the current pass began; -1: not to be remembered), in the Work of the thread
// (f.w: esc_f, esc_gen, esc_last). The result is not to be changed.
fn alias_escaped_cached(f: *Func, gen: i64) -> Vec[bool] {
    w := f.w
    if gen >= 0 && f == w.esc_f && gen == w.esc_gen {
        return w.esc_last
    }
    esc := alias_escaped_allocas(f)
    if gen >= 0 {
        w.esc_f = f
        w.esc_gen = gen
        w.esc_last = esc
    }
    return esc
}

// the remembered result for change count `gen`, if there is one
fn alias_escaped_known(f: *Func, gen: i64) -> (Vec[bool], bool) {
    w := f.w
    if gen >= 0 && f == w.esc_f && gen == w.esc_gen {
        return (w.esc_last, true)
    }
    return (vec[bool](), false)
}

// allocas whose address may be observed by something other than direct loads/stores
fn alias_escaped_allocas(f: *Func) -> Vec[bool] {
    n := f.insts.len
    esc := Vec[bool]{buf: alloc[bool](n), len: n}
    // (the private parameters count as allocas here, see is_private_param)
    any := false
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca || is_private_param(f, &f.insts[v]) {
            any = true
            break
        }
    }
    if !any {
        // nothing is derived from an alloca: nothing escapes
        return esc
    }
    // derived[v] = alloca this pointer value is derived from
    derived := vec_fill(n, i32(NOV))
    for v in f.blocks[0].insts {
        if f.insts[v].op == Alloca || is_private_param(f, &f.insts[v]) {
            derived[v] = v
        }
    }
    rpo := f.rpo()
    changed := true
    while changed {
        changed = false
        for b in rpo {
            for v in f.blocks[b].insts {
                i := &f.insts[v]
                match i.op {
                    Add => {
                        for a in i.args {
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
                    }
                    Load => {}
                    Store => {
                        d := derived[i.args[1]]
                        if d != NOV && !esc[d] {
                            esc[d] = true
                            changed = true
                        }
                    }
                    _ => {
                        for a in i.args {
                            d := derived[a]
                            if d != NOV && !esc[d] {
                                esc[d] = true
                                changed = true
                            }
                        }
                    }
                }
            }
            match f.blocks[b].term {
                Br(c, _, _) => esc_use(&esc, &derived, c, &changed)
                Switch(c, _) => esc_use(&esc, &derived, c, &changed)
                Ret(vs) => {
                    for u in vs {
                        esc_use(&esc, &derived, u, &changed)
                    }
                }
                _ => {}
            }
        }
    }
    return esc
}

// a terminator uses u: the alloca it is derived from escapes
priv inline fn esc_use(esc: *Vec[bool], derived: *Vec[i32], u: i64, changed: *bool) {
    d := derived[u]
    if d != NOV && !esc[d] {
        esc[d] = true
        *changed = true
    }
}

struct MemRef {
    addr: Addr,
    size: i32,
    class: i32, // Inst.aux
    ptr: i32, // the address value itself
}

fn alias_memref(f: *Func, v: i64) -> MemRef {
    i := &f.insts[v]
    return MemRef{addr: decompose(f, i.args[0]), size: i32(i.ty.size()), class: i.aux, ptr: i32(i.args[0])}
}

fn alias_may_alias(a: *MemRef, b: *MemRef, esc: []bool) -> bool {
    match (a.addr.base, b.addr.base) {
        (Alloca(x), Alloca(y)), (Global(x), Global(y)) if x != y => return false
        (Alloca(_), Global(_)), (Global(_), Alloca(_)) => return false
        (Alloca(x), Unknown(_)), (Unknown(_), Alloca(x)) if !esc[x] => return false
        // (see the top of the file)
        (Fresh(x), Fresh(y)) if x != y => return false
        (Fresh(_), Alloca(_)), (Alloca(_), Fresh(_)), (Fresh(_), Global(_)), (Global(_), Fresh(_)) => return false
        (Fresh(_), Arg(_)), (Arg(_), Fresh(_)) => return false
        (Alloca(x), Arg(_)), (Arg(_), Alloca(x)) if !esc[x] => return false
        _ => {}
    }
    if a.ptr == b.ptr && a.ptr != NOV {
        return true
    }
    if a.addr.base == b.addr.base {
        match (a.addr.off, b.addr.off) {
            (Some(oa), Some(ob)) => return oa < ob + i64(b.size) && ob < oa + i64(a.size)
            _ => {}
        }
    }
    return types_may_alias_class(i64(a.class), i64(b.class))
}

fn alias_must_alias(a: *MemRef, b: *MemRef) -> bool {
    if a.size != b.size {
        return false
    }
    return (a.ptr == b.ptr && a.ptr != NOV) || (a.addr.base == b.addr.base && off_some_eq(a.addr.off, b.addr.off))
}
