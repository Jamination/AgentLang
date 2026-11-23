// arm64: frame layout, prologue and epilogue, the encoding of the machine IR (pseudo
// instructions expanded with the scratch registers x16, x17 and v31), branches and the
// relocations the linker (src/elf_arm64.al) resolves.
//
// Frame of a function that has one (it calls, has frame slots, outgoing stack arguments or
// preserved registers to save):
//
//     entry sp + 8k        incoming stack argument word k
//     entry sp - 16        frame record: x29 (the caller's), x30 (the return address); x29
//                          points here, so a stack walk follows the chain of records
//     ... rest bytes ...   saved x19-x28, saved d8-d15, frame slots, outgoing arguments at sp
//     sp = x29 - rest
//
// prologue `stp x29, x30, [sp, #-16]!; mov x29, sp; sub sp, sp, #rest`, then the saves;
// epilogue the loads, `mov sp, x29; ldp x29, x30, [sp], #16; ret`. A function without a frame
// keeps the return address in x30 and leaves sp alone.

// relocation kinds: BL (26-bit word distance), ADRP (page of the target), ADD (its low 12 bits),
// LDR (its low 12 bits / 8)
const AR_CALL26: u8 = 0
const AR_ADRP: u8 = 1
const AR_ADD12: u8 = 2
const AR_LDR64: u8 = 3 // the low 12 bits of the target, scaled by 8, of an 8-byte LDR

// relocation targets
const AT_GLOBAL: u8 = 0
const AT_FUNC: u8 = 1
const AT_FCONST: u8 = 2 // float pool entry (a module pool index after a64_pool_fconsts)
const AT_TLV: u8 = 3    // macOS: the thread-local variable descriptor of the thread block

struct A64Reloc {
    off: i64
    kind: u8
    tgt: u8
    id: i64
    addend: i64
}

struct A64Code {
    bytes: Vec[u8]
    relocs: Vec[A64Reloc]
    err: str
    // (code offset, source location) where the location changes, as Code.lines (x86)
    lines: Vec[i32]
    // the frame for stack traces (src/arm64/backtrace.al): the bytes from sp after the
    // prologue to the saved return address (rest + 8), and where the prologue ends
    ra_off: i64
    prologue_end: i64
}

priv struct Fr {
    has: bool
    rest: i64         // bytes below the frame record
    slot_off: Vec[i64]
    gpr_off: i64      // where the saved x19-x28 start (8 bytes each)
    fpr_off: i64      // where the saved d8-d15 start
}

// a branch to a block, placed after the code is laid out
priv struct Fix {
    at: i64   // word index
    op: AOp   // B, Bcc, Cbz, Cbnz
    cc: i64
    reg: i64
    sf: i64
    tgt: i64  // block
}

priv struct Enc {
    words: Vec[u32]
    relocs: Vec[A64Reloc]
    fixes: Vec[Fix]
    fr: *Fr
    mf: *AFunc
    err: str
}

priv fn put(self: *Enc, x: u32) {
    self.words.push(x)
}

priv fn reloc(self: *Enc, kind: u8, tgt: u8, id: i64, addend: i64) {
    self.relocs.push(A64Reloc{off: 4 * self.words.len, kind: kind, tgt: tgt, id: id, addend: addend})
}

// a machine register's encoding number (v registers: 0-31)
priv fn x(r: i32) -> i64 {
    if r == A_ZR {
        return 31
    }
    assert r >= 0 && r < A_ZR, "arm64 emit: a virtual register after allocation"
    return if r >= A_V0 { i64(r) - A_V0 } else { i64(r) }
}

priv fn sf(sz: u8) -> i64 {
    return if sz == 8 { 1 } else { 0 }
}

// rd = k (64-bit, or the low 32 bits when sf is 0)
priv fn movi(self: *Enc, s: i64, rd: i64, k0: i64) {
    k := if s == 1 { k0 } else { k0 & 0xFFFF_FFFF }
    width := 32 + 32 * s
    nh := 2 + 2 * s
    // MOVZ / MOVN of one halfword
    for hw in 0..nh {
        if k & ~(0xFFFF << (16 * hw)) == 0 {
            self.put(a64_movw(s, 2, rd, (k >> (16 * hw)) & 0xFFFF, hw))
            return
        }
        inv := ~k & (if s == 1 { -1 } else { 0xFFFF_FFFF })
        if inv & ~(0xFFFF << (16 * hw)) == 0 {
            self.put(a64_movw(s, 0, rd, (inv >> (16 * hw)) & 0xFFFF, hw))
            return
        }
    }
    nrs := a64_bitmask(k, width)
    if nrs >= 0 {
        self.put(a64_logic_imm(s, 1, rd, 31, nrs))
        return
    }
    // MOVZ (or MOVN when more halfwords are 0xFFFF) and MOVKs for the others
    zeros := 0
    ones := 0
    for hw in 0..nh {
        h := (k >> (16 * hw)) & 0xFFFF
        if h == 0 {
            zeros += 1
        } else if h == 0xFFFF {
            ones += 1
        }
    }
    neg := ones > zeros
    first := true
    for hw in 0..nh {
        h := (k >> (16 * hw)) & 0xFFFF
        if h == (if neg { 0xFFFF } else { 0 }) {
            continue
        }
        if first {
            if neg {
                self.put(a64_movw(s, 0, rd, ~h & 0xFFFF, hw))
            } else {
                self.put(a64_movw(s, 2, rd, h, hw))
            }
            first = false
        } else {
            self.put(a64_movw(s, 3, rd, h, hw))
        }
    }
    if first {
        // (all halfwords 0 or all 0xFFFF: handled above)
        self.put(a64_movw(s, 2, rd, 0, 0))
    }
}

// rd = rn + k (sub: - k); rd and rn may be sp. Uses x16 for an immediate that does not fit.
priv fn addi(self: *Enc, s: i64, sub0: bool, rd: i64, rn: i64, k0: i64) {
    sub := sub0
    k := k0
    if k < 0 && k > -(1 << 62) {
        k = -k
        sub = !sub
    }
    if k < 4096 && k >= 0 {
        if k == 0 && rd == rn {
            return
        }
        self.put(a64_add_imm(s, sub, false, rd, rn, k, false))
        return
    }
    if k >= 0 && k < (1 << 24) {
        self.put(a64_add_imm(s, sub, false, rd, rn, k >> 12, true))
        if k & 0xFFF != 0 {
            self.put(a64_add_imm(s, sub, false, rd, rd, k & 0xFFF, false))
        }
        return
    }
    t := if rn == 16 { 17 } else { 16 }
    self.movi(1, t, k0)
    if rd == 31 || rn == 31 {
        assert s == 1
        self.put(a64_add_ext(sub0, rd, rn, t))
    } else {
        self.put(a64_add_reg(s, sub0, false, rd, rn, t, A64_LSL, 0))
    }
}

// flags of rn - k
priv fn cmpi(self: *Enc, s: i64, rn: i64, k0: i64) {
    k := if s == 1 { k0 } else { i64(i32(k0)) }
    if k >= 0 && k < 4096 {
        self.put(a64_add_imm(s, true, true, 31, rn, k, false))
    } else if k < 0 && k > -4096 {
        self.put(a64_add_imm(s, false, true, 31, rn, -k, false))
    } else {
        self.movi(1, 16, k)
        self.put(a64_add_reg(s, true, true, 31, rn, 16, A64_LSL, 0))
    }
}

// logical operation with an immediate: opc 0 AND, 1 ORR, 2 EOR, 3 ANDS
priv fn logici(self: *Enc, s: i64, opc: i64, rd: i64, rn: i64, k0: i64) {
    width := 32 + 32 * s
    k := if s == 1 { k0 } else { k0 & 0xFFFF_FFFF }
    nrs := a64_bitmask(k, width)
    if nrs >= 0 {
        self.put(a64_logic_imm(s, opc, rd, rn, nrs))
        return
    }
    self.movi(s, 16, k)
    self.put(a64_logic_reg(s, opc, false, rd, rn, 16, A64_LSL, 0))
}

// the base register and offset of a memory operand (frame slots and arguments are sp-relative)
priv fn mem_base(self: *Enc, i: *AInst) -> (i64, i64) {
    f := self.fr
    match i.k {
        AK_SLOT => return (31, f.slot_off[i.id] + i.imm)
        // (a function without a frame leaves sp at the entry value: the arguments start there)
        AK_INARG => return (31, (if f.has { f.rest + 16 } else { 0 }) + 8 * i64(i.id) + i.imm)
        AK_OUTARG => return (31, 8 * i64(i.id) + i.imm)
        _ => return (x(i.n), i.imm)
    }
}

priv fn log2(n: i64) -> i64 {
    return i64(ctz(u64(n)))
}

// a load or store of `bytes` bytes of register rt at the memory operand of i; fp: a SIMD
// register; opc for the integer forms (0 STR, 1 LDR, 2 LDRS to 64 bits)
priv fn ldst(self: *Enc, i: *AInst, fp: bool, load: bool, opc: i64, bytes: i64, rt: i64) {
    base, off := self.mem_base(i)
    if i.k == AK_NORMAL && i.m != NOREG {
        idx := x(i.m)
        sh := i64(i.sh)
        if off == 0 && (sh == 0 || sh == log2(bytes)) {
            if fp {
                self.put(a64_fldst_reg(bytes, load, rt, base, idx, sh != 0))
            } else {
                self.put(a64_ldst_reg(log2(bytes), opc, rt, base, idx, sh != 0))
            }
            return
        }
        // x16 = base + (idx << sh), then the offset
        self.put(a64_add_reg(1, false, false, 16, base, idx, A64_LSL, sh))
        base = 16
    }
    if off >= 0 && off % bytes == 0 && off / bytes < 4096 {
        if fp {
            self.put(a64_fldst_uimm(bytes, load, rt, base, off))
        } else {
            self.put(a64_ldst_uimm(log2(bytes), opc, rt, base, off))
        }
        return
    }
    if off >= -256 && off < 256 {
        if fp {
            self.put(a64_fldst_simm9(bytes, load, rt, base, off))
        } else {
            self.put(a64_ldst_simm9(log2(bytes), opc, rt, base, off))
        }
        return
    }
    if base == 16 {
        self.addi(1, false, 16, 16, off)
    } else {
        self.movi(1, 16, off)
        if fp {
            self.put(a64_fldst_reg(bytes, load, rt, base, 16, false))
        } else {
            self.put(a64_ldst_reg(log2(bytes), opc, rt, base, 16, false))
        }
        return
    }
    if fp {
        self.put(a64_fldst_uimm(bytes, load, rt, 16, 0))
    } else {
        self.put(a64_ldst_uimm(log2(bytes), opc, rt, 16, 0))
    }
}

// rd = the address of a global (tgt AT_GLOBAL), function or pool entry: ADRP and ADD
priv fn adr(self: *Enc, rd: i64, tgt: u8, id: i64, addend: i64) {
    self.reloc(AR_ADRP, tgt, id, addend)
    self.put(a64_adrp(rd, 0))
    self.reloc(AR_ADD12, tgt, id, addend)
    self.put(a64_add_imm(1, false, false, rd, rd, 0, false))
}

priv fn branch(self: *Enc, op: AOp, cc: i64, reg: i64, s: i64, tgt: i64) {
    self.fixes.push(Fix{at: self.words.len, op: op, cc: cc, reg: reg, sf: s, tgt: tgt})
    self.put(0)
}

priv fn ftype(sz: u8) -> i64 {
    return if sz == 8 { 1 } else { 0 }
}

priv fn epilogue(self: *Enc, alloc: *AAlloc) {
    f := self.fr
    if !f.has {
        return
    }
    for k, r in alloc.saved_gpr {
        self.ldst_sp(true, false, f.gpr_off + 8 * k, r)
    }
    for k, r in alloc.saved_fpr {
        self.ldst_sp(true, true, f.fpr_off + 8 * k, r - A_V0)
    }
    self.put(a64_add_imm(1, false, false, 31, 29, 0, false)) // mov sp, x29
    self.put(a64_ldstp(false, true, 1, 29, 30, 31, 16))      // ldp x29, x30, [sp], #16
}

// a load or store of an 8-byte register (fp: a d register) at sp + off
priv fn ldst_sp(self: *Enc, load: bool, fp: bool, off: i64, r: i64) {
    i := ainst(Ldr, 8, NOREG, NOREG, NOREG)
    i.k = AK_OUTARG
    i.imm = off
    self.ldst(&i, fp, load, if load { 1 } else { 0 }, 8, r)
}

priv fn enc_inst(self: *Enc, i: *AInst, alloc: *AAlloc) {
    s := sf(i.sz)
    match i.op {
        Mov => {
            d := x(i.d)
            n := x(i.n)
            if d == n && i.sz == 8 {
                return
            }
            if i.d == A_SP || i.n == A_SP {
                self.put(a64_add_imm(1, false, false, d, n, 0, false))
            } else {
                self.put(a64_logic_reg(s, 1, false, d, 31, n, A64_LSL, 0))
            }
        }
        MovI => self.movi(s, x(i.d), i.imm)
        FMov => {
            if i.d != i.n {
                self.put(a64_vorr(x(i.d), x(i.n), x(i.n)))
            }
        }
        FZero => self.put(a64_movi_zero(x(i.d)))
        AddR, SubR => self.put(a64_add_reg(s, i.op == SubR, false, x(i.d), x(i.n), x(i.m), i64(i.k), i64(i.sh)))
        AndR, OrrR, EorR, BicR => {
            opc := match i.op {
                AndR, BicR => 0
                OrrR => 1
                _ => 2
            }
            self.put(a64_logic_reg(s, opc, i.op == BicR, x(i.d), x(i.n), x(i.m), i64(i.k), i64(i.sh)))
        }
        AddI, SubI => self.addi(s, i.op == SubI, x(i.d), x(i.n), i.imm)
        AndI => self.logici(s, 0, x(i.d), x(i.n), i.imm)
        OrrI => self.logici(s, 1, x(i.d), x(i.n), i.imm)
        EorI => self.logici(s, 2, x(i.d), x(i.n), i.imm)
        TstI => self.logici(s, 3, 31, x(i.n), i.imm)
        CmpR => self.put(a64_add_reg(s, true, true, 31, x(i.n), x(i.m), A64_LSL, 0))
        CmpI => self.cmpi(s, x(i.n), i.imm)
        Lslv => self.put(a64_dp2(s, 8, x(i.d), x(i.n), x(i.m)))
        Lsrv => self.put(a64_dp2(s, 9, x(i.d), x(i.n), x(i.m)))
        Asrv => self.put(a64_dp2(s, 10, x(i.d), x(i.n), x(i.m)))
        Rorv => self.put(a64_dp2(s, 11, x(i.d), x(i.n), x(i.m)))
        LslI => self.put(a64_lsl_imm(s, x(i.d), x(i.n), i.imm))
        LsrI => self.put(a64_lsr_imm(s, x(i.d), x(i.n), i.imm))
        AsrI => self.put(a64_asr_imm(s, x(i.d), x(i.n), i.imm))
        RorI => self.put(a64_extr(s, x(i.d), x(i.n), x(i.n), i.imm))
        Mul => self.put(a64_madd(s, false, x(i.d), x(i.n), x(i.m), 31))
        Msub => self.put(a64_madd(s, true, x(i.d), x(i.n), x(i.m), x(i.a)))
        Smulh, Umulh => self.put(a64_mulh(i.op == Smulh, x(i.d), x(i.n), x(i.m)))
        Smull, Umull => self.put(a64_mull(i.op == Smull, x(i.d), x(i.n), x(i.m)))
        Sdiv => self.put(a64_dp2(s, 3, x(i.d), x(i.n), x(i.m)))
        Udiv => self.put(a64_dp2(s, 2, x(i.d), x(i.n), x(i.m)))
        Neg => self.put(a64_add_reg(s, true, false, x(i.d), 31, x(i.n), A64_LSL, 0))
        Mvn => self.put(a64_logic_reg(s, 1, true, x(i.d), 31, x(i.n), A64_LSL, 0))
        Sxtb => self.put(a64_bfm(s, 0, x(i.d), x(i.n), 0, 7))
        Sxth => self.put(a64_bfm(s, 0, x(i.d), x(i.n), 0, 15))
        Sxtw => self.put(a64_bfm(1, 0, x(i.d), x(i.n), 0, 31))
        Uxtb => self.put(a64_bfm(0, 2, x(i.d), x(i.n), 0, 7))
        Uxth => self.put(a64_bfm(0, 2, x(i.d), x(i.n), 0, 15))
        Csel => self.put(a64_csel(s, 0, x(i.d), x(i.n), x(i.m), i64(i.cc)))
        Cset => self.put(a64_cset(0, x(i.d), i64(i.cc)))
        Clz => self.put(a64_dp1(s, 4, x(i.d), x(i.n)))
        Rbit => self.put(a64_dp1(s, 0, x(i.d), x(i.n)))
        Rev => self.put(a64_dp1(s, if s == 1 { 3 } else { 2 }, x(i.d), x(i.n)))
        Ldr => self.ldst(i, false, true, 1, i64(i.sz), x(i.d))
        Ldrs => self.ldst(i, false, true, 2, i64(i.sz), x(i.d))
        Str => self.ldst(i, false, false, 0, i64(i.sz), x(i.a))
        FLdr => self.ldst(i, true, true, 0, i64(i.sz), x(i.d))
        FStr => self.ldst(i, true, false, 0, i64(i.sz), x(i.a))
        AdrS => {
            base, off := self.mem_base(i)
            self.addi(1, false, x(i.d), base, off)
        }
        AdrG => self.adr(x(i.d), AT_GLOBAL, i64(i.id), i.imm)
        Tlv => {
            // adrp x0, desc; add x0, x0, :lo12:desc; ldr x16, [x0]; blr x16 (as clang does)
            self.adr(0, AT_TLV, 0, 0)
            self.put(a64_ldst_uimm(3, 1, 16, 0, 0))
            self.put(a64_br(1, 16))
        }
        LdrG => {
            self.reloc(AR_ADRP, AT_GLOBAL, i64(i.id), 0)
            self.put(a64_adrp(x(i.d), 0))
            self.reloc(AR_LDR64, AT_GLOBAL, i64(i.id), 0)
            self.put(a64_ldst_uimm(3, 1, x(i.d), x(i.d), 0))
        }
        AdrF => self.adr(x(i.d), AT_FUNC, i64(i.id), 0)
        FConst => {
            self.adr(16, AT_FCONST, i64(i.id), 0)
            self.put(a64_fldst_uimm(i64(i.sz), true, x(i.d), 16, 0))
        }
        Mrs => self.put(a64_mrs_tpidr(x(i.d)))
        B => self.branch(B, 0, 0, 0, i64(i.id))
        Bcc => self.branch(Bcc, i64(i.cc), 0, 0, i64(i.id))
        Cbz, Cbnz => self.branch(i.op, 0, x(i.n), s, i64(i.id))
        Bl => {
            self.reloc(AR_CALL26, AT_FUNC, i64(i.id), 0)
            self.put(a64_b(true, 0))
        }
        Blr => self.put(a64_br(1, x(i.n)))
        Ret => {
            self.epilogue(alloc)
            self.put(a64_br(2, 30))
        }
        TailB => {
            self.epilogue(alloc)
            if i.id >= 0 {
                self.reloc(AR_CALL26, AT_FUNC, i64(i.id), 0)
                self.put(a64_b(false, 0))
            } else {
                self.put(a64_br(0, 9))
            }
        }
        Svc => {
            self.put(a64_svc(0))
            if i.cc == 1 {
                // the child of a clone (x0 0): its argument and function from its new stack
                self.put(a64_cbz(1, true, 0, 4))
                self.put(a64_ldstp(false, true, 1, 0, 1, 31, 16))
                self.put(a64_br(1, 1))
                self.put(a64_brk(0))
            }
        }
        Brk => self.put(a64_brk(0))
        DivTrap => {
            self.put(a64_cbz(s, true, x(i.n), 2))
            self.put(a64_brk(1))
        }
        Ldar => self.put(a64_ldar(log2(i64(i.sz)), x(i.d), x(i.n)))
        Stlr => self.put(a64_stlr(log2(i64(i.sz)), x(i.a), x(i.n)))
        AtSwap, AtAdd => {
            z := log2(i64(i.sz))
            self.put(a64_ldaxr(z, x(i.d), x(i.n)))
            v := x(i.m)
            if i.op == AtAdd {
                self.put(a64_add_reg(1, false, false, 17, x(i.d), v, A64_LSL, 0))
                v = 17
            }
            self.put(a64_stlxr(z, 16, v, x(i.n)))
            self.put(a64_cbz(0, true, 16, if i.op == AtAdd { -3 } else { -2 }))
        }
        AtCas => {
            z := log2(i64(i.sz))
            self.put(a64_ldaxr(z, x(i.d), x(i.n)))
            // compare the sz bytes (the expected value's upper bits are undefined below 4)
            e := x(i.m)
            if i.sz < 4 {
                self.put(a64_bfm(0, 2, 17, e, 0, if i.sz == 1 { 7 } else { 15 }))
                e = 17
            } else {
                self.put(a64_logic_reg(sf(i.sz), 1, false, 17, 31, e, A64_LSL, 0))
                e = 17
            }
            self.put(a64_add_reg(if i.sz == 8 { 1 } else { 0 }, true, true, 31, x(i.d), e, A64_LSL, 0))
            self.put(a64_bcond(A64_NE, 3))
            self.put(a64_stlxr(z, 16, x(i.a), x(i.n)))
            self.put(a64_cbz(0, true, 16, -5))
        }
        Dmb => self.put(A64_DMB_ISH)
        Fadd, Fsub, Fmul, Fdiv => {
            if i.sz == 16 {
                op := match i.op {
                    Fadd => 0
                    Fsub => 1
                    Fmul => 2
                    _ => 3
                }
                self.put(a64_vfp2(op, x(i.d), x(i.n), x(i.m)))
            } else {
                opc := match i.op {
                    Fmul => 0
                    Fdiv => 1
                    Fadd => 2
                    _ => 3
                }
                self.put(a64_fp2(ftype(i.sz), opc, x(i.d), x(i.n), x(i.m)))
            }
        }
        VMin, VMax => {
            // mask = n < m (min) or n > m (max), then the lanes of n where it is set, of m
            // elsewhere
            if i.op == VMin {
                self.put(a64_vfp2(6, 31, x(i.m), x(i.n)))
            } else {
                self.put(a64_vfp2(6, 31, x(i.n), x(i.m)))
            }
            self.put(a64_bsl(31, x(i.n), x(i.m)))
            self.put(a64_vorr(x(i.d), 31, 31))
        }
        Fsqrt, Fneg, Fabs => {
            k := if i.op == Fabs { 0 } else if i.op == Fneg { 1 } else { 2 }
            if i.sz == 16 {
                self.put(a64_vfp1(k, x(i.d), x(i.n)))
            } else {
                self.put(a64_fp1(ftype(i.sz), k + 1, x(i.d), x(i.n)))
            }
        }
        Fcmp => self.put(a64_fcmp(ftype(i.sz), x(i.n), x(i.m)))
        Fcsel => self.put(a64_fcsel(ftype(i.sz), x(i.d), x(i.n), x(i.m), i64(i.cc)))
        Fcvt => {
            if i.sz == 8 {
                self.put(a64_fp1(0, 5, x(i.d), x(i.n)))
            } else {
                self.put(a64_fp1(1, 4, x(i.d), x(i.n)))
            }
        }
        Scvtf => self.put(a64_scvtf(if i.k == 8 { 1 } else { 0 }, ftype(i.sz), x(i.d), x(i.n)))
        Fcvtzs => {
            // the x86-64 result (cvttsd2si, which the constant folder follows too): NaN and
            // values out of range give the "integer indefinite" 0x8000..., where FCVTZS
            // saturates and gives 0 for NaN. The conversion is done in 64 bits, then checked.
            d := x(i.d)
            n := x(i.n)
            ft := if i.k == 8 { 1 } else { 0 }
            self.put(a64_fcvtzs(1, ft, d, n))
            self.put(a64_fcmp(ft, n, n)) // V: unordered (NaN)
            if i.sz == 8 {
                self.put(a64_movw(1, 2, 16, 0x8000, 3)) // x16 = 0x8000000000000000
                self.put(a64_csel(1, 0, d, 16, d, A64_VS))
                self.put(a64_add_imm(1, true, false, 17, 16, 1, false)) // x17 = 0x7FFF...F
                self.put(a64_add_reg(1, true, true, 31, d, 17, A64_LSL, 0))
                self.put(a64_csel(1, 0, d, 16, d, A64_EQ)) // saturated above
            } else {
                self.put(a64_movw(1, 2, 16, 0x8000, 1)) // x16 = 0x80000000
                self.put(a64_csel(1, 0, d, 16, d, A64_VS))
                self.put(a64_bfm(1, 0, 17, d, 0, 31)) // x17 = sxtw(w d)
                self.put(a64_add_reg(1, true, true, 31, 17, d, A64_LSL, 0))
                self.put(a64_csel(1, 0, d, 16, d, A64_NE)) // not a 32-bit value
            }
        }
        FmovToV => self.put(a64_fmov_gen(s, true, x(i.d), x(i.n)))
        FmovToX => self.put(a64_fmov_gen(s, false, x(i.d), x(i.n)))
        DupV => self.put(a64_dup4s(x(i.d), x(i.n), i64(i.sh)))
        DupS => self.put(a64_dups(x(i.d), x(i.n), i64(i.sh)))
        Ins => self.put(a64_ins_s(x(i.d), i64(i.sh), x(i.n), i64(i.k)))
        Shuf => {
            // lanes 0, 1 from n and 2, 3 from m, chosen by two bits each, assembled in v31
            // (lane 0 by a DUP, which writes all of v31)
            self.put(a64_dup4s(31, x(i.n), i.imm & 3))
            for lane in 1..4 {
                src := if lane < 2 { x(i.n) } else { x(i.m) }
                self.put(a64_ins_s(31, lane, src, (i.imm >> (2 * lane)) & 3))
            }
            self.put(a64_vorr(x(i.d), 31, 31))
        }
        Cnt => {
            self.put(a64_fmov_gen(1, true, 31, x(i.n)))
            self.put(a64_cnt8b(31, 31))
            self.put(a64_addv8b(31, 31))
            self.put(a64_fmov_gen(0, false, x(i.d), 31))
        }
        MemCopy, MemFill => {
            d := x(i.n)
            n := x(i.a)
            v := x(i.m)
            if i.op == MemFill {
                // x17 = the byte in all eight bytes
                self.put(a64_bfm(0, 2, 17, v, 0, 7))
                self.put(a64_logic_reg(1, 1, false, 17, 17, 17, A64_LSL, 8))
                self.put(a64_logic_reg(1, 1, false, 17, 17, 17, A64_LSL, 16))
                self.put(a64_logic_reg(1, 1, false, 17, 17, 17, A64_LSL, 32))
            }
            // words: while n >= 8
            self.put(a64_add_imm(1, true, true, 31, n, 8, false)) // cmp n, #8
            self.put(a64_bcond(A64_LO, if i.op == MemCopy { 5 } else { 4 }))
            if i.op == MemCopy {
                self.put(a64_ldst_post(3, 1, 16, v, 8))
                self.put(a64_ldst_post(3, 0, 16, d, 8))
            } else {
                self.put(a64_ldst_post(3, 0, 17, d, 8))
            }
            self.put(a64_add_imm(1, true, false, n, n, 8, false))
            self.put(a64_b(false, -(4 + (if i.op == MemCopy { 1 } else { 0 }))))
            // bytes: while n != 0
            self.put(a64_cbz(1, false, n, 4 + (if i.op == MemCopy { 1 } else { 0 })))
            if i.op == MemCopy {
                self.put(a64_ldst_post(0, 1, 16, v, 1))
                self.put(a64_ldst_post(0, 0, 16, d, 1))
            } else {
                self.put(a64_ldst_post(0, 0, 17, d, 1))
            }
            self.put(a64_add_imm(1, true, false, n, n, 1, false))
            self.put(a64_b(false, -(3 + (if i.op == MemCopy { 1 } else { 0 }))))
        }
    }
}

// the frame of a function (see the top)
priv fn frame(mf: *AFunc, alloc: *AAlloc) -> Fr {
    off := 8 * mf.out_args
    slot_off := vec[i64]()
    for sl in mf.slots {
        off = align_up(off, min(max(sl.1, 1), 16))
        slot_off.push(off)
        off += sl.0
    }
    fpr_off := align_up(off, 8)
    off = fpr_off + 8 * alloc.saved_fpr.len
    gpr_off := off
    off += 8 * alloc.saved_gpr.len
    rest := align_up(off, 16)
    // (every function keeps a frame record: the stack walk of a panic follows x29 and finds
    // the return address at a fixed place in each frame)
    has := true
    return Fr{has: has, rest: rest, slot_off: slot_off, gpr_off: gpr_off, fpr_off: fpr_off}
}

fn a_emit(mf: *AFunc, alloc: *AAlloc, layout: []i64) -> A64Code {
    fr := frame(mf, alloc)
    e := Enc{fr: &fr, mf: mf}
    err := ""
    if fr.rest > 0x7FFF_0000 {
        err = fmt("function `", mf.name, "` needs a stack frame of ", fr.rest,
            " bytes; at most 2 GiB are possible (allocate large arrays with alloc[T](n))")
        fr.rest = 0
    }
    // prologue (prologue_end: after the allocation; the saves below it may fault, on a stack
    // that overflows, with the frame complete)
    prologue_end := 0
    if fr.has {
        e.put(a64_ldstp(false, false, 3, 29, 30, 31, -16)) // stp x29, x30, [sp, #-16]!
        e.put(a64_add_imm(1, false, false, 29, 31, 0, false)) // mov x29, sp
        if fr.rest > 0 {
            e.addi(1, true, 31, 31, fr.rest)
        }
        prologue_end = 4 * e.words.len
        for k, r in alloc.saved_gpr {
            e.ldst_sp(false, false, fr.gpr_off + 8 * k, r)
        }
        for k, r in alloc.saved_fpr {
            e.ldst_sp(false, true, fr.fpr_off + 8 * k, r - A_V0)
        }
    }
    bpos := vec_fill(mf.blocks.len, -1) // the word where each block starts
    lines := vec[i32]()
    last_loc: i32 = 0
    for li, b in layout {
        bpos[b] = e.words.len
        insts := &mf.blocks[b].insts
        next := if li + 1 < len(layout) { layout[li + 1] } else { -1 }
        for xi in 0..insts.len {
            i := &insts[xi]
            if i.loc != 0 && i.loc != last_loc && i.op != B && i.op != Bcc {
                lines.push(if lines.len == 0 { 0 } else { i32(4 * e.words.len) })
                lines.push(i.loc)
                last_loc = i.loc
            }
            // a jump to the next block is left out; `b.cc next; b t` becomes `b.!cc t`
            if i.op == B && i64(i.id) == next && xi == insts.len - 1 {
                continue
            }
            if i.op == Bcc && i64(i.id) == next && xi + 2 == insts.len && insts[xi + 1].op == B {
                inv := ainst(Bcc, 0, NOREG, NOREG, NOREG)
                inv.cc = u8(a64_invert(i64(i.cc)))
                inv.id = insts[xi + 1].id
                e.enc_inst(&inv, alloc)
                break
            }
            e.enc_inst(i, alloc)
        }
    }
    for f in e.fixes {
        t := bpos[f.tgt]
        assert t >= 0, "arm64 emit: a branch to a block that is not laid out"
        d := t - f.at
        word := match f.op {
            B => a64_b(false, d)
            Bcc => {
                if d < -(1 << 18) || d >= (1 << 18) {
                    if len(err) == 0 {
                        err = fmt("function `", mf.name, "` is too large for the conditional branches of arm64 (1 MiB)")
                    }
                    d = 0
                }
                a64_bcond(f.cc, d)
            }
            Cbnz => a64_cbz(f.sf, true, f.reg, d)
            _ => a64_cbz(f.sf, false, f.reg, d)
        }
        e.words[f.at] = word
    }
    bytes := vec[u8]()
    bytes.reserve(4 * e.words.len)
    for wd in e.words {
        put32(&bytes, i64(wd))
    }
    return A64Code{bytes: bytes, relocs: e.relocs, err: err, lines: lines, ra_off: fr.rest + 8, prologue_end: prologue_end}
}

// float constant relocations: from indices into the function's list to the module pool
fn a64_pool_fconsts(code: *A64Code, local: []i64) {
    for j in 0..code.relocs.len {
        if code.relocs[j].tgt == AT_FCONST {
            code.relocs[j].id = local[code.relocs[j].id]
        }
    }
}
