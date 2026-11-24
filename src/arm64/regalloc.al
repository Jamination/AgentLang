// Register allocation for arm64: the target's part of the iterated register coalescing of
// src/regalloc.al (nodes 0-63 are the machine registers: x0-x30, sp, v0-v31; A_ZR is never a
// node, the virtual registers start at A_VREG0), and the spill code: loads and stores (the
// instructions take no memory operands).

// the allocatable registers in the order they are tried: the temporaries, then the argument
// registers, then the preserved ones (which cost a save); x16-x18 and x29-x30 are reserved
priv const GPR_ORDER = [26]i64{9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 3, 4, 5, 6, 7, 8, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28}
// v16-v30, v0-v7, then v8-v15 (preserved: saved by the function that writes them); v31 reserved
priv const FPR_ORDER = [31]i64{48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47}

// the general-purpose and the SIMD registers that a call clobbers, as bit masks
priv const CLOBBER_GPR: u64 = 0x3FFFF
priv const CLOBBER_XMM: u64 = 0xFFFF_FFFF_0000_0000

struct AAlloc {
    saved_gpr: Vec[i64] // x19-x28 that the function writes
    saved_fpr: Vec[i64] // v8-v15 that the function writes (their low 64 bits are saved)
    assign: RaAssign    // where each virtual register ended up (src/regalloc.al)
}

// (w: the Work of the thread, whose scratch region holds the graphs of a round)
fn a_regalloc(mf: *AFunc, order: []i64, w: *Work) -> AAlloc {
    ra := ra_allocate[AFunc, AInst](mf, order, w)
    saved_gpr := vec[i64]()
    saved_fpr := vec[i64]()
    for r in 0..A_ZR {
        if (ra.used >> u64(r)) & 1 != 0 || (mf.save_all && a_callee_saved(r)) {
            if a_callee_saved(r) {
                saved_gpr.push(r)
            } else if a_fp_saved(r) {
                saved_fpr.push(r)
            }
        }
    }
    return AAlloc{saved_gpr: saved_gpr, saved_fpr: saved_fpr, assign: ra.assign}
}

// ---------- what src/regalloc.al asks of the target ----------
inline fn ra_npre(mf: *AFunc) -> i64 {
    return A_VREG0
}

inline fn ra_class(mf: *AFunc, r: i64) -> u8 {
    return mf.a_class(r)
}

inline fn ra_decode(mf: *AFunc, i: *AInst, du: []i64, p: i64) -> i64 {
    return a_decode(mf, i, du, p)
}

inline fn ra_call_clobber(mf: *AFunc) -> []i64 {
    return A_CALL_CLOBBER[..]
}

inline fn ra_clobber_mask(mf: *AFunc, cls: u8) -> u64 {
    return if cls == 0 { CLOBBER_GPR } else { CLOBBER_XMM }
}

inline fn ra_order(mf: *AFunc, cls: u8) -> []i64 {
    return if cls == 0 { GPR_ORDER[..] } else { FPR_ORDER[..] }
}

inline fn ra_allocatable(mf: *AFunc, cls: u8, c: i64) -> bool {
    if cls == 0 {
        return c < 16 || (c >= 19 && c <= 28)
    }
    return c >= A_V0 && c < A_VTMP
}

// (a_decode never lists sp or the zero register)
inline fn ra_coalescable(mf: *AFunc, d: i64, s: i64) -> bool {
    return true
}

inline fn ra_map_regs(i: *AInst, table: []i64) {
    a_map_regs(i, table)
}

inline fn ra_replace_reg(i: *AInst, from: i64, to: i64) {
    a_replace_reg(i, from, to)
}

inline fn ra_new_vreg(mf: *AFunc, cls: u8) -> i64 {
    return mf.a_new_vreg(cls)
}

inline fn ra_spill_slot(mf: *AFunc, v: i64) -> i64 {
    return if mf.a_class(v) == 1 { mf.a_new_slot(16, 16) } else { mf.a_new_slot(8, 8) }
}

// a load or store of a whole register (spill code) of slot `slot`
priv fn spill_mem(op: AOp, cls: u8, reg: i64, slot: i64) -> AInst {
    i := ainst(op, if cls == 1 { 16 } else { 8 }, NOREG, NOREG, NOREG)
    if op == Ldr || op == FLdr {
        i.d = i32(reg)
    } else {
        i.a = i32(reg)
    }
    i.k = AK_SLOT
    i.id = i32(slot)
    return i
}

inline fn ra_spill_load(mf: *AFunc, cls: u8, r: i64, slot: i64) -> AInst {
    return spill_mem(if cls == 1 { FLdr } else { Ldr }, cls, r, slot)
}

inline fn ra_spill_store(mf: *AFunc, cls: u8, r: i64, slot: i64) -> AInst {
    return spill_mem(if cls == 1 { FStr } else { Str }, cls, r, slot)
}

// i, the one definition of v, may be repeated before each use instead of a spill (src/
// regalloc.al, "rematerialization"): a constant or the address of a global or function
inline fn ra_remat(mf: *AFunc, i: *AInst, v: i64) -> bool {
    return (i.op == MovI || i.op == AdrG || i.op == AdrF) && i64(i.d) == v
}

// a copy with one spilled side (the only spilled register it touches) becomes the load or
// the store itself
fn ra_spill_direct(mf: *AFunc, i: *AInst, v: i64, slot: i64, is_def: bool, is_use: bool, nt: i64, slot_of: []i64) -> bool {
    if nt != 1 {
        return false
    }
    d, s, is_cp := a_is_copy(i)
    if !is_cp {
        return false
    }
    cls := mf.a_class(d)
    if slot_of[s] >= 0 {
        *i = spill_mem(if cls == 1 { FLdr } else { Ldr }, cls, d, slot_of[s])
    } else {
        *i = spill_mem(if cls == 1 { FStr } else { Str }, cls, s, slot_of[d])
    }
    return true
}

// ---------- after the allocation: spill slots ----------
// a spill load (register d) or store (register a) of slot >= first_spill: the slot, or -1
priv fn spill_load(i: *AInst, first_spill: i64) -> i64 {
    if ((i.op == Ldr && i.sz == 8) || (i.op == FLdr && i.sz == 16)) && i.k == AK_SLOT && i64(i.id) >= first_spill && i.imm == 0 {
        return i64(i.id)
    }
    return -1
}

priv fn spill_store(i: *AInst, first_spill: i64) -> i64 {
    if ((i.op == Str && i.sz == 8) || (i.op == FStr && i.sz == 16)) && i.k == AK_SLOT && i64(i.id) >= first_spill && i.imm == 0 {
        return i64(i.id)
    }
    return -1
}

// After allocation: a reload of a spill slot whose value is still in a register becomes a
// copy (or nothing), and stores to slots that are never read go away. The state (slot,
// register) follows a block into its successor when that has no other predecessor.
fn ra_spill_forward(mf: *AFunc, order: []i64, first_spill: i64) {
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
            sl := spill_load(i, first_spill)
            if sl >= 0 {
                fi := ra_st_slot(&st, sl)
                if fi >= 0 {
                    r := st[fi].1
                    if r == i64(i.d) {
                        continue
                    }
                    *i = ainst(if i.op == FLdr { FMov } else { Mov }, 8, i64(i.d), r, NOREG)
                }
            }
            if st.len > 0 {
                a_decode(mf, i, du.items(), 0)
                h := du[0]
                for j in 1..1 + (h & 255) {
                    ra_st_drop_reg(&st, du[j])
                }
                if h & (DU_CALL << 16) != 0 {
                    for r in A_CALL_CLOBBER {
                        ra_st_drop_reg(&st, r)
                    }
                }
            }
            ss := spill_store(i, first_spill)
            if ss >= 0 {
                ra_st_drop_slot(&st, ss)
                st.push((ss, i64(i.a)))
            } else {
                sl2 := spill_load(i, first_spill)
                if sl2 >= 0 {
                    if ra_st_slot(&st, sl2) < 0 {
                        st.push((sl2, i64(i.d)))
                    }
                } else {
                    d, src, is_cp := a_is_copy(i)
                    if is_cp {
                        fi := ra_st_reg(&st, src)
                        if fi >= 0 {
                            st.push((st[fi].0, d))
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
    // remove stores to slots that are never read
    reads := vec_fill(mf.slots.len, 0)
    for b in order {
        for i in mf.blocks[b].insts {
            sl := spill_load(&i, first_spill)
            if sl >= 0 {
                reads[sl] += 1
            }
        }
    }
    for b in order {
        insts := &mf.blocks[b].insts
        n := 0
        for x in 0..insts.len {
            ss := spill_store(&insts[x], first_spill)
            if ss >= 0 && reads[ss] == 0 {
                continue
            }
            if n != x {
                insts[n] = insts[x]
            }
            n += 1
        }
        insts.len = n
    }
}
