// Frame layout, final peepholes, x86-64 encoding and branch relaxation.

enum RelocKind {
    RelocKindAbs32Global(i64),
    RelocKindAbs32Func(i64),
    RelocKindRel32Func(i64),
    RelocKindAbs32FConst(i64), // module float pool index
}

struct Reloc {
    off: i64
    kind: RelocKind
    addend: i32
}

struct Code {
    bytes: Vec[u8]
    relocs: Vec[Reloc]
}

struct EmitFrame {
    slot_off: Vec[i32]
    size: i32
    npush: i32
}

struct EmitRM {
    is_reg: bool
    reg: u8
    base: i8
    idx: i8
    scale: u8
    disp: i32
    reloc: Opt[RelocKind]
}

fn emit_rm_reg(r: i64) -> EmitRM {
    return EmitRM{is_reg: true, reg: u8(r & 15), base: -1, idx: -1, scale: 1, disp: 0, reloc: None}
}

struct EmitEnc {
    out: Vec[u8]
    relocs: Vec[Reloc]
    frame: *EmitFrame
    fpool: []i64 // function-local fconst index -> module pool index
}

fn rm_mem(self: *EmitEnc, m: *Mem) -> EmitRM {
    r := EmitRM{is_reg: false, reg: 0, base: -1, idx: -1, scale: u8(m.scale), disp: i32(m.disp), reloc: None}
    if i64(m.base) != NOREG {
        r.base = i8(m.base)
    }
    if i64(m.idx) != NOREG {
        r.idx = i8(m.idx)
    }
    match m.kind {
        MemKindNormal => {}
        MemKindGlobal => {
            r.reloc = Some(RelocKindAbs32Global(i64(m.id)))
        }
        MemKindFConst => {
            r.reloc = Some(RelocKindAbs32FConst(self.fpool[i64(m.id)]))
        }
        MemKindSlot => {
            r.base = i8(RSP)
            r.disp += self.frame.slot_off.at(i64(m.id))
        }
        MemKindOutArg => {
            r.base = i8(RSP)
            r.disp += 8 * i32(m.id)
        }
        MemKindInArg => {
            r.base = i8(RSP)
            r.disp += self.frame.size + 8 * self.frame.npush + 8 + 8 * i32(m.id)
        }
    }
    return r
}

fn rm(self: *EmitEnc, o: Opnd) -> EmitRM {
    match o {
        OpndR(r) => {
            return emit_rm_reg(i64(r))
        }
        OpndM(m) => {
            return self.rm_mem(&m)
        }
        _ => {}
    }
    panic(fmt("encoder: operand ", o, " is not r/m"))
}

// [prefix66] [mandatory prefix] [REX] opcode modrm [sib] [disp]
fn op(self: *EmitEnc, p66: bool, pfx: u8, w: bool, opc: []u8, reg: u8, rm: *EmitRM, force_rex: bool) {
    if p66 {
        self.out.push(0x66)
    }
    if pfx != 0 {
        self.out.push(pfx)
    }
    r_bit := (reg >> 3) & 1
    x_bit: u8 = 0
    b_bit: u8 = 0
    if rm.is_reg {
        b_bit = (rm.reg >> 3) & 1
    } else {
        x_bit = if rm.idx >= 0 { (u8(rm.idx) >> 3) & 1 } else { 0 }
        b_bit = if rm.base >= 0 { (u8(rm.base) >> 3) & 1 } else { 0 }
    }
    rex := 0x40 | (u8(w) << 3) | (r_bit << 2) | (x_bit << 1) | b_bit
    if rex != 0x40 || force_rex {
        self.out.push(rex)
    }
    self.out.extend(opc)
    regf := (reg & 7) << 3
    if rm.is_reg {
        self.out.push(0xC0 | regf | (rm.reg & 7))
        return
    }
    scale_bits: u8 = match rm.scale {
        2 => 1
        4 => 2
        8 => 3
        _ => 0
    }
    has_reloc := is_some(rm.reloc)
    if rm.base < 0 {
        // [disp32] or [idx*scale + disp32]
        self.out.push(regf | 4)
        idx: u8 = if rm.idx >= 0 { u8(rm.idx) & 7 } else { 4 }
        self.out.push((scale_bits << 6) | (idx << 3) | 5)
        self.disp32(rm)
        return
    }
    base := u8(rm.base) & 7
    need_sib := rm.idx >= 0 || base == 4
    md: u8 = 2
    dsz := 4
    if has_reloc {
        md = 2
        dsz = 4
    } else if rm.disp == 0 && base != 5 {
        md = 0
        dsz = 0
    } else if rm.disp >= -128 && rm.disp <= 127 {
        md = 1
        dsz = 1
    } else {
        md = 2
        dsz = 4
    }
    if need_sib {
        self.out.push((md << 6) | regf | 4)
        idx: u8 = if rm.idx >= 0 { u8(rm.idx) & 7 } else { 4 }
        self.out.push((scale_bits << 6) | (idx << 3) | base)
    } else {
        self.out.push((md << 6) | regf | base)
    }
    match dsz {
        1 => self.out.push(u8(i8(rm.disp)))
        4 => self.disp32(rm)
        _ => {}
    }
}

// the four bytes of x, least significant first
fn emit_put_le32(out: *Vec[u8], x: i32) {
    u := u32(x)
    out.push(u8(u))
    out.push(u8(u >> 8))
    out.push(u8(u >> 16))
    out.push(u8(u >> 24))
}

fn disp32(self: *EmitEnc, rm: *EmitRM) {
    match rm.reloc {
        Some(k) => {
            self.relocs.push(Reloc{off: self.out.len, kind: k, addend: rm.disp})
            emit_put_le32(&self.out, 0)
        }
        None => {
            emit_put_le32(&self.out, rm.disp)
        }
    }
}

// the low n bytes of k, least significant first
fn imm(self: *EmitEnc, k: i64, n: i64) {
    u := u64(k)
    for j in 0..n {
        self.out.push(u8(u >> u64(8 * j)))
    }
}

// mandatory prefix of an SSE operation by operand size: scalar double, scalar single, packed single
fn emit_fp_pfx(sz: u8) -> u8 {
    return match sz {
        4 => 0xF3
        16 => 0
        _ => 0xF2
    }
}

fn emit_byte_reg_needs_rex(o: Opnd) -> bool {
    match o {
        OpndR(r) => {
            return i64(r) >= 4 && i64(r) < 8
        }
        _ => {}
    }
    return false
}

fn emit_reg_of(o: Opnd) -> i64 {
    match o {
        OpndR(r) => {
            return i64(r)
        }
        _ => {}
    }
    panic(fmt("encoder: expected register, got ", o))
}

// operand shapes for the `match (&i.a, &i.b)` dispatch of the Rust encoder
const EMIT_K_NONE = 0
const EMIT_K_R = 1
const EMIT_K_I = 2
const EMIT_K_M = 3
const EMIT_K_GADDR = 4
const EMIT_K_FADDR = 5

fn emit_kind(o: Opnd) -> i64 {
    return match o {
        OpndNone => EMIT_K_NONE
        OpndR(r) => EMIT_K_R
        OpndI(k) => EMIT_K_I
        OpndM(m) => EMIT_K_M
        OpndGAddr(g, off) => EMIT_K_GADDR
        OpndFAddr(f) => EMIT_K_FADDR
    }
}

// the immediate of an Opnd::I (only called when the shape is known)
fn emit_imm_of(o: Opnd) -> i64 {
    match o {
        OpndI(k) => {
            return k
        }
        _ => {}
    }
    panic("unreachable")
}

// relocation of a symbol address operand: (kind, addend)
fn emit_addr_reloc(o: Opnd) -> (RelocKind, i32) {
    match o {
        OpndGAddr(g, off) => {
            return (RelocKindAbs32Global(i64(g)), i32(off))
        }
        OpndFAddr(f) => {
            return (RelocKindAbs32Func(i64(f)), 0)
        }
        _ => {}
    }
    panic("unreachable")
}

fn emit_enc_inst(e: *EmitEnc, i: *MInst) {
    sz := u8(i.sz)
    w := sz == 8
    p66 := sz == 2
    ka := emit_kind(i.a)
    kb := emit_kind(i.b)
    match i.op {
        MOpMov => {
            if ka == EMIT_K_R && kb == EMIT_K_R {
                d := emit_reg_of(i.a)
                s := emit_reg_of(i.b)
                force := sz == 1 && (emit_byte_reg_needs_rex(i.a) || emit_byte_reg_needs_rex(i.b))
                rm := emit_rm_reg(d)
                e.op(p66, 0, w, []u8{if sz == 1 { 0x88 } else { 0x89 }}, u8(s & 15), &rm, force)
            } else if ka == EMIT_K_R && kb == EMIT_K_I {
                d := emit_reg_of(i.a)
                k := emit_imm_of(i.b)
                d8 := u8(d & 15)
                if sz == 8 && !(k >= 0 && k <= 0xFFFFFFFF) {
                    if k >= -2147483648 && k <= 2147483647 {
                        rm := emit_rm_reg(d)
                        e.op(false, 0, true, []u8{0xC7}, 0, &rm, false)
                        e.imm(k, 4)
                    } else {
                        e.out.push(0x48 | (d8 >> 3))
                        e.out.push(0xB8 | (d8 & 7))
                        e.imm(k, 8)
                    }
                } else {
                    if d8 >= 8 {
                        e.out.push(0x41)
                    }
                    e.out.push(0xB8 | (d8 & 7))
                    e.imm(k, 4)
                }
            } else if ka == EMIT_K_R && (kb == EMIT_K_GADDR || kb == EMIT_K_FADDR) {
                d := emit_reg_of(i.a)
                d8 := u8(d & 15)
                if d8 >= 8 {
                    e.out.push(0x41)
                }
                e.out.push(0xB8 | (d8 & 7))
                kind, addend := emit_addr_reloc(i.b)
                e.relocs.push(Reloc{off: e.out.len, kind: kind, addend: addend})
                e.imm(0, 4)
            } else if ka == EMIT_K_R && kb == EMIT_K_M {
                d := emit_reg_of(i.a)
                rm := e.rm(i.b)
                force := sz == 1 && emit_byte_reg_needs_rex(i.a)
                e.op(p66, 0, w, []u8{if sz == 1 { 0x8A } else { 0x8B }}, u8(d & 15), &rm, force)
            } else if ka == EMIT_K_M && kb == EMIT_K_R {
                s := emit_reg_of(i.b)
                rm := e.rm(i.a)
                force := sz == 1 && emit_byte_reg_needs_rex(i.b)
                e.op(p66, 0, w, []u8{if sz == 1 { 0x88 } else { 0x89 }}, u8(s & 15), &rm, force)
            } else if ka == EMIT_K_M && kb == EMIT_K_I {
                k := emit_imm_of(i.b)
                rm := e.rm(i.a)
                e.op(p66, 0, w, []u8{if sz == 1 { 0xC6 } else { 0xC7 }}, 0, &rm, false)
                e.imm(k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 })
            } else if ka == EMIT_K_M && (kb == EMIT_K_GADDR || kb == EMIT_K_FADDR) {
                rm := e.rm(i.a)
                e.op(false, 0, true, []u8{0xC7}, 0, &rm, false)
                kind, addend := emit_addr_reloc(i.b)
                e.relocs.push(Reloc{off: e.out.len, kind: kind, addend: addend})
                e.imm(0, 4)
            } else {
                panic(fmt("encoder: bad mov ", *i))
            }
        }
        MOpMovzx => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            match sz {
                1 => e.op(false, 0, false, []u8{0x0F, 0xB6}, u8(d & 15), &rm, emit_byte_reg_needs_rex(i.b))
                2 => e.op(false, 0, false, []u8{0x0F, 0xB7}, u8(d & 15), &rm, false)
                _ => e.op(false, 0, false, []u8{0x8B}, u8(d & 15), &rm, false)
            }
        }
        MOpMovsx => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            w2 := u8(i.sz2) == 8
            match sz {
                1 => e.op(false, 0, w2, []u8{0x0F, 0xBE}, u8(d & 15), &rm, emit_byte_reg_needs_rex(i.b))
                2 => e.op(false, 0, w2, []u8{0x0F, 0xBF}, u8(d & 15), &rm, false)
                _ => {
                    if w2 {
                        e.op(false, 0, true, []u8{0x63}, u8(d & 15), &rm, false)
                    } else {
                        e.op(false, 0, false, []u8{0x8B}, u8(d & 15), &rm, false)
                    }
                }
            }
        }
        MOpLea => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, 0, w, []u8{0x8D}, u8(d & 15), &rm, false)
        }
        MOpAdd, MOpSub, MOpAnd, MOpOr, MOpXor, MOpCmp => {
            n: u8 = match i.op {
                MOpAdd => 0
                MOpOr => 1
                MOpAnd => 4
                MOpSub => 5
                MOpXor => 6
                _ => 7
            }
            if kb == EMIT_K_I {
                k := emit_imm_of(i.b)
                rm := e.rm(i.a)
                force := sz == 1 && emit_byte_reg_needs_rex(i.a)
                if sz == 1 {
                    e.op(false, 0, false, []u8{0x80}, n, &rm, force)
                    e.imm(k, 1)
                } else if k >= -128 && k <= 127 {
                    e.op(p66, 0, w, []u8{0x83}, n, &rm, false)
                    e.imm(k, 1)
                } else {
                    e.op(p66, 0, w, []u8{0x81}, n, &rm, false)
                    e.imm(k, if sz == 2 { 2 } else { 4 })
                }
            } else if ka == EMIT_K_R && kb == EMIT_K_M {
                d := emit_reg_of(i.a)
                rm := e.rm(i.b)
                force := sz == 1 && emit_byte_reg_needs_rex(i.a)
                lo: u8 = if sz == 1 { 2 } else { 3 }
                e.op(p66, 0, w, []u8{(n << 3) | lo}, u8(d & 15), &rm, force)
            } else if kb == EMIT_K_R {
                s := emit_reg_of(i.b)
                rm := e.rm(i.a)
                force := sz == 1 && (emit_byte_reg_needs_rex(i.a) || emit_byte_reg_needs_rex(i.b))
                lo: u8 = if sz == 1 { 0 } else { 1 }
                e.op(p66, 0, w, []u8{(n << 3) | lo}, u8(s & 15), &rm, force)
            } else {
                panic(fmt("encoder: bad alu ", *i))
            }
        }
        MOpTest => {
            if kb == EMIT_K_I {
                k := emit_imm_of(i.b)
                rm := e.rm(i.a)
                force := sz == 1 && emit_byte_reg_needs_rex(i.a)
                e.op(p66, 0, w, []u8{if sz == 1 { 0xF6 } else { 0xF7 }}, 0, &rm, force)
                e.imm(k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 })
            } else if kb == EMIT_K_R {
                s := emit_reg_of(i.b)
                rm := e.rm(i.a)
                force := sz == 1 && (emit_byte_reg_needs_rex(i.a) || emit_byte_reg_needs_rex(i.b))
                e.op(p66, 0, w, []u8{if sz == 1 { 0x84 } else { 0x85 }}, u8(s & 15), &rm, force)
            } else {
                panic(fmt("encoder: bad test ", *i))
            }
        }
        MOpImul => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(p66, 0, w, []u8{0x0F, 0xAF}, u8(d & 15), &rm, false)
        }
        MOpImul3 => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            if emit_kind(i.c) != EMIT_K_I {
                panic("encoder: imul3 without immediate")
            }
            k := emit_imm_of(i.c)
            if k >= -128 && k <= 127 {
                e.op(false, 0, w, []u8{0x6B}, u8(d & 15), &rm, false)
                e.imm(k, 1)
            } else {
                e.op(false, 0, w, []u8{0x69}, u8(d & 15), &rm, false)
                e.imm(k, 4)
            }
        }
        MOpNeg, MOpNot, MOpIdiv, MOpDiv, MOpMul1, MOpImul1 => {
            n: u8 = match i.op {
                MOpNot => 2
                MOpNeg => 3
                MOpMul1 => 4
                MOpImul1 => 5
                MOpDiv => 6
                _ => 7
            }
            rm := e.rm(i.a)
            force := sz == 1 && emit_byte_reg_needs_rex(i.a)
            e.op(p66, 0, w, []u8{if sz == 1 { 0xF6 } else { 0xF7 }}, n, &rm, force)
        }
        MOpShl, MOpShr, MOpSar, MOpRol, MOpRor => {
            n: u8 = match i.op {
                MOpRol => 0
                MOpRor => 1
                MOpShl => 4
                MOpShr => 5
                _ => 7
            }
            rm := e.rm(i.a)
            force := sz == 1 && emit_byte_reg_needs_rex(i.a)
            if kb == EMIT_K_I {
                k := emit_imm_of(i.b)
                if k == 1 {
                    e.op(p66, 0, w, []u8{if sz == 1 { 0xD0 } else { 0xD1 }}, n, &rm, force)
                } else {
                    e.op(p66, 0, w, []u8{if sz == 1 { 0xC0 } else { 0xC1 }}, n, &rm, force)
                    e.imm(k, 1)
                }
            } else if kb == EMIT_K_R {
                e.op(p66, 0, w, []u8{if sz == 1 { 0xD2 } else { 0xD3 }}, n, &rm, force)
            } else {
                panic(fmt("encoder: bad shift ", *i))
            }
        }
        MOpCqo => {
            if w {
                e.out.push(0x48)
            }
            e.out.push(0x99)
        }
        MOpSetcc => {
            rm := e.rm(i.a)
            e.op(false, 0, false, []u8{0x0F, 0x90 | u8(i.cc)}, 0, &rm, emit_byte_reg_needs_rex(i.a))
        }
        MOpCmov => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, 0, w, []u8{0x0F, 0x40 | u8(i.cc)}, u8(d & 15), &rm, false)
        }
        MOpCall => {
            e.out.push(0xE8)
            e.relocs.push(Reloc{off: e.out.len, kind: RelocKindRel32Func(i64(i.tgt)), addend: 0})
            e.imm(0, 4)
        }
        MOpCallInd => {
            rm := e.rm(i.a)
            e.op(false, 0, false, []u8{0xFF}, 2, &rm, false)
        }
        MOpRet => e.out.push(0xC3)
        MOpSyscall => e.out.extend([]u8{0x0F, 0x05})
        MOpUd2 => e.out.extend([]u8{0x0F, 0x0B})
        MOpMovSd => {
            // movaps between registers; movsd / movss / movups to and from memory
            pfx := emit_fp_pfx(sz)
            if ka == EMIT_K_R && kb == EMIT_K_R {
                d := emit_reg_of(i.a)
                rm := emit_rm_reg(emit_reg_of(i.b))
                e.op(false, 0, false, []u8{0x0F, 0x28}, u8(d & 15), &rm, false)
            } else if ka == EMIT_K_R && kb == EMIT_K_M {
                d := emit_reg_of(i.a)
                rm := e.rm(i.b)
                e.op(false, pfx, false, []u8{0x0F, 0x10}, u8(d & 15), &rm, false)
            } else if ka == EMIT_K_M && kb == EMIT_K_R {
                s := emit_reg_of(i.b)
                rm := e.rm(i.a)
                e.op(false, pfx, false, []u8{0x0F, 0x11}, u8(s & 15), &rm, false)
            } else {
                panic(fmt("encoder: bad movsd ", *i))
            }
        }
        MOpAddsd, MOpSubsd, MOpMulsd, MOpDivsd, MOpSqrtsd, MOpMinsd, MOpMaxsd => {
            o: u8 = match i.op {
                MOpAddsd => 0x58
                MOpMulsd => 0x59
                MOpSubsd => 0x5C
                MOpDivsd => 0x5E
                MOpMinsd => 0x5D
                MOpMaxsd => 0x5F
                _ => 0x51
            }
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, emit_fp_pfx(sz), false, []u8{0x0F, o}, u8(d & 15), &rm, false)
        }
        MOpCvtf => {
            // cvtss2sd (sz 8) / cvtsd2ss (sz 4)
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, if sz == 8 { 0xF3 } else { 0xF2 }, false, []u8{0x0F, 0x5A}, u8(d & 15), &rm, false)
        }
        MOpShufps => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, 0, false, []u8{0x0F, 0xC6}, u8(d & 15), &rm, false)
            if emit_kind(i.c) != EMIT_K_I {
                panic("encoder: shufps without immediate")
            }
            e.imm(emit_imm_of(i.c), 1)
        }
        MOpMovlo => {
            d := emit_reg_of(i.a)
            rm := emit_rm_reg(emit_reg_of(i.b))
            e.op(false, 0xF3, false, []u8{0x0F, 0x10}, u8(d & 15), &rm, false)
        }
        MOpUnpcklps => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, 0, false, []u8{0x0F, 0x14}, u8(d & 15), &rm, false)
        }
        MOpUcomisd, MOpXorpd, MOpAndpd => {
            o: u8 = match i.op {
                MOpUcomisd => 0x2E
                MOpXorpd => 0x57
                _ => 0x54
            }
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(sz == 8, 0, false, []u8{0x0F, o}, u8(d & 15), &rm, false)
        }
        MOpCvtsi2sd => {
            // sz = integer size, sz2 = float size (4: single)
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, if u8(i.sz2) == 4 { 0xF3 } else { 0xF2 }, w, []u8{0x0F, 0x2A}, u8(d & 15), &rm, false)
        }
        MOpCvttsd2si => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, if u8(i.sz2) == 4 { 0xF3 } else { 0xF2 }, w, []u8{0x0F, 0x2C}, u8(d & 15), &rm, false)
        }
        MOpMovqToX => {
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(true, 0, w, []u8{0x0F, 0x6E}, u8(d & 15), &rm, false)
        }
        MOpMovqToR => {
            s := emit_reg_of(i.b)
            rm := e.rm(i.a)
            e.op(true, 0, w, []u8{0x0F, 0x7E}, u8(s & 15), &rm, false)
        }
        MOpRepMovsb => e.out.extend([]u8{0xF3, 0xA4})
        MOpRepStosb => e.out.extend([]u8{0xF3, 0xAA})
        MOpBswap => {
            d := u8(emit_reg_of(i.a) & 15)
            rex := 0x40 | (u8(w) << 3) | (d >> 3)
            if rex != 0x40 {
                e.out.push(rex)
            }
            e.out.push(0x0F)
            e.out.push(0xC8 | (d & 7))
        }
        MOpPopcnt, MOpTzcnt, MOpLzcnt => {
            o: u8 = match i.op {
                MOpPopcnt => 0xB8
                MOpTzcnt => 0xBC
                _ => 0xBD
            }
            d := emit_reg_of(i.a)
            rm := e.rm(i.b)
            e.op(false, 0xF3, w, []u8{0x0F, o}, u8(d & 15), &rm, false)
        }
        MOpPush, MOpPop => {
            r := u8(emit_reg_of(i.a) & 15)
            if r >= 8 {
                e.out.push(0x41)
            }
            base: u8 = if i.op == MOpPush { 0x50 } else { 0x58 }
            e.out.push(base | (r & 7))
        }
        MOpZero => {
            r := emit_reg_of(i.a)
            rm := emit_rm_reg(r)
            if r >= 16 {
                e.op(false, 0, false, []u8{0x0F, 0x57}, u8(r & 15), &rm, false)
            } else {
                e.op(false, 0, false, []u8{0x31}, u8(r & 15), &rm, false)
            }
        }
        MOpJmp, MOpJcc => panic("unreachable")
    }
}

fn emit_sets_flags(op: MOp) -> bool {
    return op == MOpAdd || op == MOpSub || op == MOpAnd || op == MOpOr || op == MOpXor || op == MOpCmp || op == MOpTest ||
        op == MOpImul || op == MOpImul3 || op == MOpNeg || op == MOpShl || op == MOpShr || op == MOpSar || op == MOpRol ||
        op == MOpRor || op == MOpIdiv || op == MOpDiv || op == MOpMul1 || op == MOpImul1 || op == MOpUcomisd ||
        op == MOpPopcnt || op == MOpTzcnt || op == MOpLzcnt || op == MOpZero || op == MOpCall || op == MOpCallInd ||
        op == MOpSyscall || op == MOpBswap
}

fn emit_reads_flags(op: MOp) -> bool {
    return op == MOpJcc || op == MOpSetcc || op == MOpCmov
}

fn emit_peephole_resolve(b0: i64, fwd: *Vec[i64]) -> i64 {
    b := b0
    n := 0
    while fwd[b] != b && n < 64 {
        b = fwd[b]
        n += 1
    }
    return b
}

// the `add` replacement of step 3 of the peephole for a `lea`, if there is one
fn emit_peephole_lea_add(i: *MInst) -> Opt[Opnd] {
    add: Opt[Opnd] = None
    if i.op == MOpLea {
        match i.a {
            OpndR(d0) => {
                d := i64(d0)
                match i.b {
                    OpndM(m) => {
                        if m.kind == MemKindNormal {
                            base := i64(m.base)
                            idx := i64(m.idx)
                            if base == d && idx == NOREG && i32(m.disp) != 0 {
                                add = Some(OpndI(i64(m.disp)))
                            } else if base == d && idx != NOREG && u8(m.scale) == 1 && i32(m.disp) == 0 && idx != d {
                                add = Some(OpndR(m.idx))
                            } else if idx == d && u8(m.scale) == 1 && i32(m.disp) == 0 && base != NOREG && base != d {
                                add = Some(OpndR(m.base))
                            }
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    return add
}

// post-allocation cleanups that depend on the final layout
fn emit_peephole(mf: *MFunc, layout: *Vec[i64]) {
    nb := mf.blocks.len
    // 1. thread jumps through blocks that only contain `jmp X`
    fwd := vec[i64]()
    for b in 0..nb {
        fwd.push(b)
    }
    for b in 0..nb {
        blk := &mf.blocks[b]
        if blk.insts.len == 1 && blk.insts[0].op == MOpJmp && i64(blk.insts[0].tgt) != b {
            fwd[b] = i64(blk.insts[0].tgt)
        }
    }
    for b in 0..nb {
        for x in 0..mf.blocks[b].insts.len {
            i := &mf.blocks[b].insts[x]
            if i.op == MOpJmp || i.op == MOpJcc {
                i.tgt = emit_peephole_resolve(i64(i.tgt), &fwd)
            }
        }
    }
    // drop blocks that are no longer reachable
    {
        reach := vec_fill(nb, false)
        work := vec_of([]i64{layout[0]})
        reach[layout[0]] = true
        while work.len > 0 {
            b := work.pop()
            for x in 0..mf.blocks[b].insts.len {
                i := &mf.blocks[b].insts[x]
                if (i.op == MOpJmp || i.op == MOpJcc) && !reach[i64(i.tgt)] {
                    reach[i64(i.tgt)] = true
                    work.push(i64(i.tgt))
                }
            }
        }
        // layout.retain(|b| reach[b])
        n := 0
        for x in 0..layout.len {
            if reach[layout[x]] {
                layout[n] = layout[x]
                n += 1
            }
        }
        layout.len = n
    }
    // 2. fallthrough and branch inversion
    for li in 0..layout.len {
        b := layout[li]
        next := if li + 1 < layout.len { layout[li + 1] } else { 0xFFFFFFFF }
        insts := &mf.blocks[b].insts
        n := insts.len
        if n >= 2 && insts[n - 1].op == MOpJmp && insts[n - 2].op == MOpJcc {
            single_jcc := n < 3 || insts[n - 3].op != MOpJcc
            if i64(insts[n - 2].tgt) == i64(insts[n - 1].tgt) && single_jcc {
                insts.remove(n - 2)
            } else if i64(insts[n - 2].tgt) == next && single_jcc {
                f := insts[n - 1].tgt
                insts[n - 2].cc ^= 1
                insts[n - 2].tgt = f
                insts.pop()
            }
        }
        n2 := insts.len
        if n2 >= 1 && insts[n2 - 1].op == MOpJmp && i64(insts[n2 - 1].tgt) == next {
            insts.pop()
        }
    }
    // 3. flag-clobbering shorter forms when flags are dead:
    //    mov r, 0 -> xor r, r ; lea r, [r + x] -> add r, x
    for b in 0..nb {
        n := mf.blocks[b].insts.len
        for k in 0..n {
            i := &mf.blocks[b].insts[k]
            a_low_reg := match i.a {
                OpndR(r) => i64(r) < 16
                _ => false
            }
            zero := i.op == MOpMov && a_low_reg && eq(i.b, OpndI(0))
            add := emit_peephole_lea_add(i)
            if !zero && !is_some(add) {
                continue
            }
            dead := true
            for j in k + 1..n {
                o := mf.blocks[b].insts[j].op
                if emit_reads_flags(o) {
                    dead = false
                    break
                }
                if emit_sets_flags(o) {
                    break
                }
            }
            if !dead {
                continue
            }
            a := i.a
            sz := i.sz
            if zero {
                mf.blocks[b].insts[k] = minst_new(MOpZero, 4, a, OpndNone)
            } else {
                match add {
                    Some(src) => {
                        mf.blocks[b].insts[k] = minst_new(MOpAdd, sz, a, src)
                    }
                    None => {}
                }
            }
        }
    }
}

enum EmitItem {
    EmitItemBytes(Vec[u8], Vec[Reloc]),
    EmitItemJump(Opt[u8], i64, bool), // cc, tgt, long
    EmitItemAlign(i64),
}

fn emit_emit(mf: *MFunc, alloc: *Alloc, layout0: []i64, fpool: []i64) -> Code {
    // frame layout
    off: i32 = 8 * i32(mf.out_args)
    slot_off := vec[i32]()
    for sl in mf.slots.items() {
        a := i32(min(max(i64(sl.1), 1), 16))
        off = (off + a - 1) / a * a
        slot_off.push(off)
        off += i32(sl.0)
    }
    npush := i32(alloc.used_callee_saved.len)
    size := (off + 15) / 16 * 16
    if (8 + 8 * npush + size) % 16 != 0 {
        size += 8
    }
    if !mf.has_calls && off == 0 {
        size = 0
    }
    frame := EmitFrame{slot_off: slot_off, size: size, npush: npush}
    // prologue / epilogue
    pro := vec[MInst]()
    for r in alloc.used_callee_saved.items() {
        pro.push(minst_new(MOpPush, 8, OpndR(r), OpndNone))
    }
    if size > 0 {
        pro.push(minst_new(MOpSub, 8, OpndR(RSP), OpndI(i64(size))))
    }
    layout := vec_of(layout0)
    entry := layout[0]
    body := mf.blocks[entry].insts
    mf.blocks[entry].insts = vec[MInst]()
    pro.extend(body.items())
    mf.blocks[entry].insts = pro
    for b in layout.items() {
        insts := mf.blocks[b].insts
        mf.blocks[b].insts = vec[MInst]()
        out := vec[MInst]()
        for x in 0..insts.len {
            i := insts[x]
            if i.op == MOpRet {
                if size > 0 {
                    out.push(minst_new(MOpAdd, 8, OpndR(RSP), OpndI(i64(size))))
                }
                for y in alloc.used_callee_saved.len - 1..=0 by -1 {
                    out.push(minst_new(MOpPop, 8, OpndR(alloc.used_callee_saved[y]), OpndNone))
                }
            }
            out.push(i)
        }
        mf.blocks[b].insts = out
    }
    emit_peephole(mf, &layout)
    // encode
    items := vec[EmitItem]()
    block_item := vec_fill(mf.blocks.len, -1)
    for b in layout.items() {
        if mf.blocks[b].align {
            items.push(EmitItemAlign(16))
        }
        block_item[b] = items.len
        enc := EmitEnc{out: vec[u8](), relocs: vec[Reloc](), frame: &frame, fpool: fpool}
        for x in 0..mf.blocks[b].insts.len {
            i := &mf.blocks[b].insts[x]
            if i.op == MOpJmp || i.op == MOpJcc {
                if !enc.out.is_empty() {
                    items.push(EmitItemBytes(enc.out, enc.relocs))
                    enc.out = vec[u8]()
                    enc.relocs = vec[Reloc]()
                }
                cc: Opt[u8] = None
                if i.op == MOpJcc {
                    cc = Some(u8(i.cc))
                }
                items.push(EmitItemJump(cc, i64(i.tgt), false))
            } else {
                emit_enc_inst(&enc, i)
            }
        }
        if !enc.out.is_empty() {
            items.push(EmitItemBytes(enc.out, enc.relocs))
        }
    }
    // relaxation
    offs := vec_fill(items.len + 1, 0)
    loop {
        o := 0
        for k in 0..items.len {
            offs[k] = o
            o += match items[k] {
                EmitItemBytes(b, r) => b.len
                EmitItemJump(cc, tgt, long) => {
                    if !long {
                        2
                    } else if !is_some(cc) {
                        5
                    } else {
                        6
                    }
                }
                EmitItemAlign(a) => emit_align_pad(o, a)
            }
        }
        offs[items.len] = o
        changed := false
        for k in 0..items.len {
            match items[k] {
                EmitItemJump(cc, tgt, long) => {
                    if !long {
                        t := offs[block_item[tgt]]
                        d := t - (offs[k] + 2)
                        if !(d >= -128 && d <= 127) {
                            items[k] = EmitItemJump(cc, tgt, true)
                            changed = true
                        }
                    }
                }
                _ => {}
            }
        }
        if !changed {
            break
        }
    }
    bytes := vec[u8]()
    relocs := vec[Reloc]()
    for k in 0..items.len {
        assert bytes.len == offs[k]
        match items[k] {
            EmitItemBytes(b, r) => {
                for rr in r.items() {
                    relocs.push(Reloc{off: rr.off + bytes.len, kind: rr.kind, addend: rr.addend})
                }
                bytes.extend(b.items())
            }
            EmitItemJump(cc, tgt, long) => {
                t := offs[block_item[tgt]]
                if long {
                    match cc {
                        Some(c) => {
                            bytes.push(0x0F)
                            bytes.push(0x80 | c)
                            d := t - (offs[k] + 6)
                            emit_put_le32(&bytes, i32(d))
                        }
                        None => {
                            bytes.push(0xE9)
                            d := t - (offs[k] + 5)
                            emit_put_le32(&bytes, i32(d))
                        }
                    }
                } else {
                    d := t - (offs[k] + 2)
                    opc: u8 = match cc {
                        Some(c) => 0x70 | c
                        None => 0xEB
                    }
                    bytes.push(opc)
                    bytes.push(u8(i8(d)))
                }
            }
            EmitItemAlign(a) => {
                pad := emit_align_pad(bytes.len, a)
                emit_nops(&bytes, pad)
            }
        }
    }
    return Code{bytes: bytes, relocs: relocs}
}

// padding in front of an aligned block; long paddings are not worth executing
fn emit_align_pad(o: i64, a: i64) -> i64 {
    p := (a - o % a) % a
    if p > 10 {
        return 0
    }
    return p
}

fn emit_nops_seq(k: i64) -> []u8 {
    return match k {
        1 => []u8{0x90}
        2 => []u8{0x66, 0x90}
        3 => []u8{0x0F, 0x1F, 0x00}
        4 => []u8{0x0F, 0x1F, 0x40, 0x00}
        5 => []u8{0x0F, 0x1F, 0x44, 0x00, 0x00}
        6 => []u8{0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00}
        7 => []u8{0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00}
        8 => []u8{0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00}
        _ => []u8{0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00}
    }
}

fn emit_nops(out: *Vec[u8], n0: i64) {
    n := n0
    while n > 0 {
        k := min(n, 9)
        out.extend(emit_nops_seq(k))
        n -= k
    }
}
