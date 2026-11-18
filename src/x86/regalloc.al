// Register allocation for x86-64: the target's part of the iterated register coalescing of
// src/regalloc.al (nodes 0-31 are the machine registers: 0-15 general, 16-31 xmm), and the
// spill code, which uses memory operands where the instruction takes one.

priv gpr_order := [15]i64{0, 1, 2, 6, 7, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15}
priv const XMM_ORDER = [16]i64{16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31}

// Windows: rsi and rdi have to be saved by the function that writes them, as rbx does: they
// come last
fn regalloc_windows() {
    gpr_order = [15]i64{0, 1, 2, 8, 9, 10, 11, 3, 5, 12, 13, 14, 15, 6, 7}
}

// the general-purpose and the xmm registers that a call clobbers, as bit masks
priv const CLOBBER_GPR: u64 = 0xFC7
priv const CLOBBER_XMM: u64 = 0xFFFF0000

struct Alloc {
    used_callee_saved: Vec[i64]
    used_xmm_saved: Vec[i64] // Windows: xmm6-xmm15 that the function writes
    assign: RaAssign         // where each virtual register ended up (src/regalloc.al)
}

// (w: the Work of the thread, whose scratch region holds the graphs of a round)
fn regalloc_allocate(mf: *MFunc, order: []i64, w: *Work) -> Alloc {
    ra := ra_allocate[MFunc, MInst](mf, order, w)
    used_callee_saved := vec[i64]()
    used_xmm_saved := vec[i64]()
    for r in 0..32 {
        if (ra.used >> u64(r)) & 1 != 0 || mf.save_all && mir_callee_saved(r) {
            if mir_callee_saved(r) {
                used_callee_saved.push(r)
            } else if mir_xmm_saved(r) {
                used_xmm_saved.push(r)
            }
        }
    }
    return Alloc{used_callee_saved: used_callee_saved, used_xmm_saved: used_xmm_saved, assign: ra.assign}
}

// ---------- what src/regalloc.al asks of the target ----------
inline fn ra_npre(mf: *MFunc) -> i64 {
    return VREG0
}

inline fn ra_class(mf: *MFunc, r: i64) -> u8 {
    return mf.class(r)
}

inline fn ra_decode(mf: *MFunc, i: *MInst, du: []i64, p: i64) -> i64 {
    return mir_decode(mf, i, du, p)
}

inline fn ra_call_clobber(mf: *MFunc) -> []i64 {
    return CALL_CLOBBER[..]
}

inline fn ra_clobber_mask(mf: *MFunc, cls: u8) -> u64 {
    return if cls == 0 { CLOBBER_GPR } else { CLOBBER_XMM }
}

inline fn ra_order(mf: *MFunc, cls: u8) -> []i64 {
    return if cls == 0 { gpr_order[..] } else { XMM_ORDER[..] }
}

inline fn ra_allocatable(mf: *MFunc, cls: u8, c: i64) -> bool {
    return c != RSP && (if cls == 0 { c < 16 } else { c >= 16 && c < 32 })
}

// (a copy to or from rsp is not a move between values)
inline fn ra_coalescable(mf: *MFunc, d: i64, s: i64) -> bool {
    return d != RSP && s != RSP
}

inline fn ra_map_regs(i: *MInst, table: []i64) {
    mir_map_regs(i, table)
}

inline fn ra_replace_reg(i: *MInst, from: i64, to: i64) {
    mir_replace_reg(i, from, to)
}

inline fn ra_new_vreg(mf: *MFunc, cls: u8) -> i64 {
    return mf.new_vreg(cls)
}

inline fn ra_spill_slot(mf: *MFunc, v: i64) -> i64 {
    return if mf.wide_xmm && mf.class(v) == 1 { mf.new_slot(16, 16) } else { mf.new_slot(8, 8) }
}

// the size of a spill load or store of class cls
priv fn spill_size(mf: *MFunc, cls: u8) -> u8 {
    return if cls == 1 && mf.wide_xmm { 16 } else { 8 }
}

inline fn ra_spill_load(mf: *MFunc, cls: u8, r: i64, slot: i64) -> MInst {
    return minst_new(if cls == 1 { MovSd } else { Mov }, spill_size(mf, cls), R(r), M(mem_slot(slot, 0)))
}

inline fn ra_spill_store(mf: *MFunc, cls: u8, r: i64, slot: i64) -> MInst {
    return minst_new(if cls == 1 { MovSd } else { Mov }, spill_size(mf, cls), M(mem_slot(slot, 0)), R(r))
}

// can operand `b` of this instruction be a memory operand?
priv fn b_can_be_mem(i: *MInst) -> bool {
    match i.a {
        M(_) => return false
        _ => {}
    }
    match i.op {
        Add, Sub, And, Or, Xor, Cmp, Imul, Addsd, Subsd, Mulsd, Divsd, Minsd, Maxsd, Sqrtsd, Cvtf,
            Ucomisd, Cvtsi2sd, Cvttsd2si, Cmov, Imul3, MovSd, Movzx, Movsx => true
        Mov => i.sz == 8 || i.sz == 4
        _ => false
    }
}

// the direct forms that avoid a temporary: the slot of v as a memory operand of a copy, as
// operand b where the instruction takes memory there, as the destination of an immediate
fn ra_spill_direct(mf: *MFunc, i: *MInst, v: i64, slot: i64, is_def: bool, is_use: bool, nt: i64, slot_of: []i64) -> bool {
    cls := mf.class(v)
    mem := M(mem_slot(slot, 0))
    msz := spill_size(mf, cls)
    d, s, is_cp := i.is_copy()
    if is_cp {
        if s == v && d != v && !(d < len(slot_of) && slot_of[d] >= 0) {
            i.b = mem
            i.sz = msz
            return true
        }
        if d == v && s != v && !(s < len(slot_of) && slot_of[s] >= 0) {
            i.a = mem
            i.sz = msz
            return true
        }
    }
    if is_use && !is_def && i.b == R(v) && b_can_be_mem(i) {
        // the only occurrence must be operand b
        if mir_count_reg(i, v) == 1 {
            i.b = mem
            if i.op == MovSd {
                i.sz = msz
            }
            return true
        }
    }
    if i.op == Mov && i.sz == 8 && i.a == R(v) && is_def && !is_use {
        match i.b {
            I(c) if fits_i32(c) => {
                i.a = mem
                return true
            }
            _ => {}
        }
    }
    return false
}

// ---------- after the allocation: spill slots ----------
priv fn spill_slot(o: *Opnd, first_spill: i64) -> i64 {
    match o {
        M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill && m.base == NOREG && m.idx == NOREG && m.disp == 0 => return i64(m.id)
        _ => return -1
    }
}

// the spill slot an operand reads or writes (any part of it), or -1
priv fn spill_slot_any(o: *Opnd, first_spill: i64) -> i64 {
    match o {
        M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill => return i64(m.id)
        _ => return -1
    }
}

// Removes the stores to a spill slot that a later store in the same block overwrites before
// anything reads the slot. A spilled register defined twice in a row (the copy and the
// operation of a two-address instruction: `v = u; v -= x`) is stored after each definition,
// and the store of the first is dead once the reload in between was forwarded. Only the
// spill code touches these slots (their address is never taken), so the instructions that
// name a slot are all its accesses.
priv fn overwritten_stores(mf: *MFunc, order: []i64, first_spill: i64) {
    // killed[s]: the size of a store to s further down the block with no read of s in between
    // (0: none)
    killed := vec_fill(mf.slots.len, 0)
    touched := vec[i64]()
    for b in order {
        insts := &mf.blocks[b].insts
        drop := vec_fill(insts.len, false)
        any := false
        x := insts.len - 1
        while x >= 0 {
            i := &insts[x]
            s := spill_slot(&i.a, first_spill)
            if (i.op == Mov || i.op == MovSd) && s >= 0 {
                if killed[s] >= i64(i.sz) {
                    drop[x] = true
                    any = true
                } else {
                    killed[s] = i64(i.sz)
                    touched.push(s)
                }
                // (the source of a store is a register or an immediate, never a slot)
            } else {
                ra := spill_slot_any(&i.a, first_spill)
                if ra >= 0 {
                    killed[ra] = 0
                }
                rb := spill_slot_any(&i.b, first_spill)
                if rb >= 0 {
                    killed[rb] = 0
                }
            }
            x -= 1
        }
        for t in touched {
            killed[t] = 0
        }
        touched.clear()
        if any {
            n := 0
            for y in 0..insts.len {
                if !drop[y] {
                    if n != y {
                        insts[n] = insts[y]
                    }
                    n += 1
                }
            }
            insts.len = n
        }
    }
}

// After allocation: reuse registers that still hold the value of a spill slot instead of
// reloading it, and drop stores to slots that are never read.
fn ra_spill_forward(mf: *MFunc, order: []i64, first_spill: i64) {
    nb := mf.blocks.len
    npreds := vec_fill(nb, 0)
    the_pred := vec_fill(nb, -1)
    for b in order {
        for s in mf.blocks[b].succs {
            npreds[s] += 1
            the_pred[s] = b
        }
    }
    out_state := vec_fill(nb, Opt[Vec[(i64, i64)]].None)
    du := vec_fill(DU_MAX, 0)
    for oi, b in order {
        st := vec[(i64, i64)]()
        if oi != 0 && npreds[b] == 1 {
            match out_state[the_pred[b]] {
                Some(s) => st = clone(s)
                None => {}
            }
        }
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts[x]
            sa := spill_slot(&i.a, first_spill)
            is_store := (i.op == Mov || i.op == MovSd) && sa >= 0
            // uses of a slot whose value is still in a register
            sb := spill_slot(&i.b, first_spill)
            if sb >= 0 {
                fi := ra_st_slot(&st, sb)
                if fi >= 0 {
                    r := st[fi].1
                    full_reload := ((i.op == Mov && i.sz == 8) || i.op == MovSd) && is_r(i.a)
                    if full_reload && i.a == R(r) {
                        continue
                    }
                    i.b = R(r)
                }
            }
            if (i.op == Cmp || i.op == Test) && sa >= 0 {
                fi := ra_st_slot(&st, sa)
                if fi >= 0 {
                    i.a = R(st[fi].1)
                }
            }
            if st.len > 0 {
                mir_decode(mf, i, du.items(), 0)
                h := du[0]
                for j in 1..1 + (h & 255) {
                    ra_st_drop_reg(&st, du[j])
                }
                if h & (DU_CALL << 16) != 0 {
                    for r in CALL_CLOBBER {
                        ra_st_drop_reg(&st, r)
                    }
                }
            }
            if is_store {
                ra_st_drop_slot(&st, sa)
                match i.b {
                    R(r) => st.push((sa, r))
                    _ => {}
                }
            } else {
                sb2 := spill_slot(&i.b, first_spill)
                match i.a {
                    R(d) if sb2 >= 0 => {
                        if ((i.op == Mov && i.sz == 8) || i.op == MovSd) && ra_st_slot(&st, sb2) < 0 {
                            st.push((sb2, d))
                        }
                    }
                    _ => {
                        d, src, is_cp := i.is_copy()
                        if is_cp {
                            // a register copy of a slot value is another home for it
                            fi := ra_st_reg(&st, src)
                            if fi >= 0 {
                                st.push((st[fi].0, d))
                            }
                        }
                    }
                }
            }
            if n != x {
                insts[n] = insts[x]
            }
            n += 1
        }
        insts.len = n
        out_state[b] = Some(st)
    }
    overwritten_stores(mf, order, first_spill)
    // remove stores to slots that are never read
    reads := vec_fill(mf.slots.len, 0)
    for b in order {
        insts := &mf.blocks[b].insts
        for x in 0..insts.len {
            i := &insts[x]
            is_store := (i.op == Mov || i.op == MovSd) && spill_slot(&i.a, first_spill) >= 0
            match &i.a {
                M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill && !is_store => reads[i64(m.id)] += 1
                _ => {}
            }
            match &i.b {
                M(&m) if m.kind == MK_SLOT && i64(m.id) >= first_spill => reads[i64(m.id)] += 1
                _ => {}
            }
        }
    }
    for b in order {
        // keep the instructions that are not dead stores
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            i := &insts[x]
            keep := true
            if i.op == Mov || i.op == MovSd {
                s := spill_slot(&i.a, first_spill)
                if s >= 0 {
                    keep = reads[s] > 0
                }
            }
            if keep {
                if n != x {
                    insts[n] = insts[x]
                }
                n += 1
            }
        }
        insts.len = n
    }
}
