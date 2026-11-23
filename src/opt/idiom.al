// Loop idioms: a counted loop that only stores one value into consecutive elements becomes a
// MemSet, one that only copies consecutive elements from one place to another a MemCpy (both
// `rep stosb` / `rep movsb` on x86).
//
//     for i in a..b { dst[i] = v }          v loop-invariant, the same in every byte
//     for i in a..b { dst[i] = src[i] }     (any element type)
//
// The loop must be a single block (its checks already hoisted by BCE) whose only effects are
// that store (and that load), counting by 1, with addresses that advance by the element
// size (loop_affine_coef). It is kept as the slow path: the preheader goes to the bulk
// operation only when the loop would run normally (loop_trip_guard), covers at least
// IDIOM_MIN_BYTES (a short loop is faster than starting a string instruction) and, for a copy,
// the two ranges do not overlap (the loop copies element by element in order, which a bulk
// copy of overlapping ranges need not reproduce). The kept loop is marked LOOP_NO_IDIOM (and
// LOOP_NO_UNROLL).

priv const IDIOM_MIN_BYTES = 128

// the byte that a store of v (of `size` bytes) writes everywhere, if all its bytes are equal
priv fn idiom_fill_byte(f: *Func, v: i64, size: i64) -> Opt[i64] {
    i := &f.insts[v]
    if size == 1 && i.ty == I8 {
        return Some(v)
    }
    if i.op != Const && i.op != FConst {
        return None
    }
    if i.ty.is_vec() || size > 8 {
        return None
    }
    k := u64(i.k)
    b := k & 0xFF
    for j in 1..size {
        if (k >> u64(8 * j)) & 0xFF != b {
            return None
        }
    }
    return Some(-1 - i64(b))
}

// turns loop li into a fill or copy if it is one; true if it did
priv fn idiom_try(f: *Func, cfg: *Cfg, loops: *Loops, li: i64, in_loop: []bool, def_block: []i32) -> bool {
    cl := match loop_counted(f, cfg, loops, li, in_loop, def_block) {
        Some(c) => c
        None => return false
    }
    if f.insts[cl.cond].aux & LOOP_NO_IDIOM != 0 || cl.step != 1 || !loop_trip_known(&cl) {
        return false
    }
    if cl.blocks.len != 1 || !loop_single_exit(f, &cl, in_loop) {
        return false
    }
    if loop_used_outside(f, in_loop, def_block).len > 0 {
        return false
    }
    h := cl.header
    st := NOV
    ld := NOV
    for v in f.blocks[h].insts {
        i := &f.insts[v]
        if i.op == Phi {
            if i64(v) != cl.iv {
                return false
            }
        } else if i.op == Store {
            if st != NOV {
                return false
            }
            st = i64(v)
        } else if i.op == Load {
            if ld != NOV {
                return false
            }
            ld = i64(v)
        } else if !i.op.is_pure() {
            return false
        }
    }
    if st == NOV {
        return false
    }
    si := f.insts[st]
    size := si.ty.size()
    if si.ty.is_vec() || size == 0 {
        return false
    }
    addr := si.args[0]
    val := si.args[1]
    match loop_affine_coef(f, &cl, addr, in_loop, def_block) {
        Some(c) => {
            if c != size {
                return false
            }
        }
        None => return false
    }
    // the copy's load: the stored value, read only by the store, from consecutive elements
    laddr := NOV
    fill := -1
    if ld != NOV {
        li2 := &f.insts[ld]
        if val != ld || li2.ty.size() != size {
            return false
        }
        for v in f.blocks[h].insts {
            if i64(v) != st && contains(f.insts[v].args, ld) {
                return false
            }
        }
        if contains(term_args(&f.blocks[h].term), ld) {
            return false
        }
        laddr = li2.args[0]
        match loop_affine_coef(f, &cl, laddr, in_loop, def_block) {
            Some(c) => {
                if c != size {
                    return false
                }
            }
            None => return false
        }
    } else {
        if !loop_invariant(val, in_loop, def_block) {
            return false
        }
        fill = match idiom_fill_byte(f, val, size) {
            Some(x) => x
            None => return false
        }
    }
    // the preheader decides
    pre := cl.pre
    g := loop_trip_guard(f, &cl, pre)
    tc := loop_trip_count(f, &cl, pre)
    if cl.ty != I64 {
        tc = f.push(pre, ZExt, I64, vec_of([]i64{tc}), 0)
    }
    nbytes := if size == 1 { tc } else { f.push(pre, Mul, I64, vec_of([]i64{tc, loop_const(f, pre, I64, size)}), 0) }
    big := f.push(pre, Uge, I8, vec_of([]i64{nbytes, loop_const(f, pre, I64, IDIOM_MIN_BYTES)}), 0)
    ok := f.push(pre, And, I8, vec_of([]i64{g, big}), 0)
    dst := loop_expr_at(f, &cl, pre, addr, cl.start, in_loop, def_block)
    bulk := f.new_block()
    if ld != NOV {
        src := loop_expr_at(f, &cl, pre, laddr, cl.start, in_loop, def_block)
        // the ranges [dst, dst + n) and [src, src + n) are apart
        d1 := f.push(pre, Sub, I64, vec_of([]i64{dst, src}), 0)
        d2 := f.push(pre, Sub, I64, vec_of([]i64{src, dst}), 0)
        a1 := f.push(pre, Uge, I8, vec_of([]i64{d1, nbytes}), 0)
        a2 := f.push(pre, Uge, I8, vec_of([]i64{d2, nbytes}), 0)
        apart := f.push(pre, And, I8, vec_of([]i64{a1, a2}), 0)
        ok = f.push(pre, And, I8, vec_of([]i64{ok, apart}), 0)
        f.push(bulk, MemCpy, Void, vec_of([]i64{dst, src, nbytes}), 0)
    } else {
        byte := if fill >= 0 { fill } else { loop_const(f, pre, I8, -1 - fill) }
        f.push(bulk, MemSet, Void, vec_of([]i64{dst, byte, nbytes}), 0)
    }
    f.blocks[bulk].term = Jmp(cl.exit)
    // the exit's phis: the same inputs from the bulk operation (no value of the loop is used
    // after it)
    for v in f.blocks[cl.exit].insts {
        if f.insts[v].op != Phi {
            break
        }
        x := f.insts[v].phi_input(cl.latch)
        f.im(i64(v)).phi_add(x, bulk)
    }
    np := f.new_block()
    f.blocks[np].term = Jmp(h)
    f.blocks[pre].term = Br(ok, bulk, np)
    f.phi_pred_replace(h, pre, np)
    // (the slow path is short or rare: not unrolled either)
    f.im(cl.cond).aux = f.insts[cl.cond].aux | LOOP_NO_IDIOM | LOOP_NO_UNROLL
    return true
}

// Turns every fill and copy loop into a bulk operation (see above); true if one changed.
fn idiom_run(f: *Func) -> bool {
    return loop_each_innermost(f, idiom_try)
}
