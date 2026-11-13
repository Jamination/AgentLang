// Frame layout, final peepholes, x86-64 encoding and branch relaxation.

priv enum RelocKind {
    Abs32Global(i64),
    Abs32Func(i64),
    Rel32Func(i64),
    Abs32FConst(i64), // module float pool index
}

priv struct Reloc {
    off: i64
    kind: RelocKind
    addend: i32
}

struct Code {
    bytes: Vec[u8]
    relocs: Vec[Reloc]
    err: str // a frame too large for 32-bit displacements: the message (the code is unusable)
}

priv struct Frame {
    slot_off: Vec[i32]
    size: i32
    npush: i32
}

priv struct RM {
    is_reg: bool
    reg: u8
    base: i8
    idx: i8
    scale: u8
    disp: i32
    reloc: Opt[RelocKind]
}

priv fn rm_reg(r: i64) -> RM {
    return RM{is_reg: true, reg: u8(r & 15), base: -1, idx: -1, scale: 1, disp: 0, reloc: None}
}

// The code of a function is encoded into one buffer without the jumps; the jumps (and the
// alignment of blocks) are items at positions of that buffer, sized by relaxation and put in
// when the final bytes are assembled.
priv struct Enc {
    out: Vec[u8]
    relocs: Vec[Reloc] // offsets in out
    frame: *Frame
    fpool: []i64 // function-local fconst index -> module pool index
}

// room for one more instruction (at most 15 bytes)
priv inline fn room(self: *Enc) {
    if self.out.len + 16 > len(self.out.buf) {
        self.out.reserve(self.out.len + 16)
    }
}

// one byte (after room)
priv inline fn b1(self: *Enc, x: u8) {
    n := self.out.len
    self.out.buf[n] = x
    self.out.len = n + 1
}

priv fn rm_mem(self: *Enc, m: *Mem) -> RM {
    r := RM{is_reg: false, reg: 0, base: -1, idx: -1, scale: u8(m.scale), disp: i32(m.disp), reloc: None}
    if i64(m.base) != NOREG {
        r.base = i8(m.base)
    }
    if i64(m.idx) != NOREG {
        r.idx = i8(m.idx)
    }
    match m.kind {
        MK_GLOBAL => {
            r.reloc = Some(Abs32Global(i64(m.id)))
        }
        MK_FCONST => {
            r.reloc = Some(Abs32FConst(self.fpool[i64(m.id)]))
        }
        MK_SLOT => {
            r.base = i8(RSP)
            r.disp += self.frame.slot_off[i64(m.id)]
        }
        MK_OUTARG => {
            r.base = i8(RSP)
            r.disp += 8 * i32(m.id)
        }
        MK_INARG => {
            r.base = i8(RSP)
            r.disp += self.frame.size + 8 * self.frame.npush + 8 + 8 * i32(m.id)
        }
        _ => {}
    }
    return r
}

priv fn rm(self: *Enc, o: *Opnd) -> RM {
    match o {
        R(r) => return rm_reg(r)
        M(&m) => return self.rm_mem(m)
        _ => panic(fmt("encoder: operand ", *o, " is not r/m"))
    }
}

// [prefix66] [mandatory prefix] [REX] opcode modrm [sib] [disp]
// (opc: one opcode byte, or 0x0F and a second one as 0x0Fxx)
priv fn op(self: *Enc, p66: bool, pfx: u8, w: bool, opc: i64, reg: u8, rm: *RM, force_rex: bool) {
    if p66 {
        self.b1(0x66)
    }
    if pfx != 0 {
        self.b1(pfx)
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
        self.b1(rex)
    }
    if opc >= 0x100 {
        self.b1(0x0F)
    }
    self.b1(u8(opc & 0xFF))
    regf := (reg & 7) << 3
    if rm.is_reg {
        self.b1(0xC0 | regf | (rm.reg & 7))
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
        self.b1(regf | 4)
        idx: u8 = if rm.idx >= 0 { u8(rm.idx) & 7 } else { 4 }
        self.b1((scale_bits << 6) | (idx << 3) | 5)
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
        self.b1((md << 6) | regf | 4)
        idx: u8 = if rm.idx >= 0 { u8(rm.idx) & 7 } else { 4 }
        self.b1((scale_bits << 6) | (idx << 3) | base)
    } else {
        self.b1((md << 6) | regf | base)
    }
    match dsz {
        1 => self.b1(u8(i8(rm.disp)))
        4 => self.disp32(rm)
        _ => {}
    }
}

// the four bytes of x, least significant first
priv fn put_le32(out: *Vec[u8], x: i32) {
    u := u32(x)
    out.push(u8(u))
    out.push(u8(u >> 8))
    out.push(u8(u >> 16))
    out.push(u8(u >> 24))
}

priv fn disp32(self: *Enc, rm: *RM) {
    match rm.reloc {
        Some(k) => {
            self.relocs.push(Reloc{off: self.out.len, kind: k, addend: rm.disp})
            self.imm(0, 4)
        }
        None => {
            self.imm(i64(rm.disp), 4)
        }
    }
}

// the low n bytes of k, least significant first
priv fn imm(self: *Enc, k: i64, n: i64) {
    u := u64(k)
    for j in 0..n {
        self.b1(u8(u >> u64(8 * j)))
    }
}

// mandatory prefix of an SSE operation by operand size: scalar double, scalar single, packed single
priv fn fp_pfx(sz: u8) -> u8 {
    return match sz {
        4 => 0xF3
        16 => 0
        _ => 0xF2
    }
}

priv fn byte_reg_needs_rex(o: *Opnd) -> bool {
    match o {
        R(r) => return r >= 4 && r < 8
        _ => return false
    }
}

priv fn reg_of(o: *Opnd) -> i64 {
    match o {
        R(r) => return r
        _ => panic(fmt("encoder: expected register, got ", *o))
    }
}

// relocation of a symbol address operand: (kind, addend)
priv fn addr_reloc(o: *Opnd) -> (RelocKind, i32) {
    match o {
        GAddr(g, off) => return (Abs32Global(g), i32(off))
        FAddr(f) => return (Abs32Func(f), 0)
        _ => panic("unreachable")
    }
}

priv fn enc_inst(e: *Enc, i: *MInst) {
    e.room()
    sz := u8(i.sz)
    w := sz == 8
    p66 := sz == 2
    match i.op {
        Mov => match (&i.a, &i.b) {
            (R(d), R(s)) => {
                force := sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b))
                rm := rm_reg(d)
                e.op(p66, 0, w, if sz == 1 { 0x88 } else { 0x89 }, u8(s & 15), &rm, force)
            }
            (R(d), I(k)) => {
                d8 := u8(d & 15)
                if sz == 8 && !(k >= 0 && k <= 0xFFFFFFFF) {
                    if k >= -2147483648 && k <= 2147483647 {
                        rm := rm_reg(d)
                        e.op(false, 0, true, 0xC7, 0, &rm, false)
                        e.imm(k, 4)
                    } else {
                        e.b1(0x48 | (d8 >> 3))
                        e.b1(0xB8 | (d8 & 7))
                        e.imm(k, 8)
                    }
                } else {
                    if d8 >= 8 {
                        e.b1(0x41)
                    }
                    e.b1(0xB8 | (d8 & 7))
                    e.imm(k, 4)
                }
            }
            (R(d), GAddr(_, _)), (R(d), FAddr(_)) => {
                d8 := u8(d & 15)
                if d8 >= 8 {
                    e.b1(0x41)
                }
                e.b1(0xB8 | (d8 & 7))
                kind, addend := addr_reloc(&i.b)
                e.relocs.push(Reloc{off: e.out.len, kind: kind, addend: addend})
                e.imm(0, 4)
            }
            (R(d), M(_)) => {
                rm := e.rm(&i.b)
                force := sz == 1 && byte_reg_needs_rex(&i.a)
                e.op(p66, 0, w, if sz == 1 { 0x8A } else { 0x8B }, u8(d & 15), &rm, force)
            }
            (M(_), R(s)) => {
                rm := e.rm(&i.a)
                force := sz == 1 && byte_reg_needs_rex(&i.b)
                e.op(p66, 0, w, if sz == 1 { 0x88 } else { 0x89 }, u8(s & 15), &rm, force)
            }
            (M(_), I(k)) => {
                rm := e.rm(&i.a)
                e.op(p66, 0, w, if sz == 1 { 0xC6 } else { 0xC7 }, 0, &rm, false)
                e.imm(k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 })
            }
            (M(_), GAddr(_, _)), (M(_), FAddr(_)) => {
                rm := e.rm(&i.a)
                e.op(false, 0, true, 0xC7, 0, &rm, false)
                kind, addend := addr_reloc(&i.b)
                e.relocs.push(Reloc{off: e.out.len, kind: kind, addend: addend})
                e.imm(0, 4)
            }
            _ => panic(fmt("encoder: bad mov ", *i))
        }
        Movzx => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            match sz {
                1 => e.op(false, 0, false, 0x0FB6, u8(d & 15), &rm, byte_reg_needs_rex(&i.b))
                2 => e.op(false, 0, false, 0x0FB7, u8(d & 15), &rm, false)
                _ => e.op(false, 0, false, 0x8B, u8(d & 15), &rm, false)
            }
        }
        Movsx => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            w2 := u8(i.sz2) == 8
            match sz {
                1 => e.op(false, 0, w2, 0x0FBE, u8(d & 15), &rm, byte_reg_needs_rex(&i.b))
                2 => e.op(false, 0, w2, 0x0FBF, u8(d & 15), &rm, false)
                _ => {
                    if w2 {
                        e.op(false, 0, true, 0x63, u8(d & 15), &rm, false)
                    } else {
                        e.op(false, 0, false, 0x8B, u8(d & 15), &rm, false)
                    }
                }
            }
        }
        Lea => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, 0, w, 0x8D, u8(d & 15), &rm, false)
        }
        Add, Sub, And, Or, Xor, Cmp => {
            n: u8 = match i.op {
                Add => 0
                Or => 1
                And => 4
                Sub => 5
                Xor => 6
                _ => 7
            }
            match (&i.a, &i.b) {
                (_, I(k)) => {
                    rm := e.rm(&i.a)
                    force := sz == 1 && byte_reg_needs_rex(&i.a)
                    if sz == 1 {
                        e.op(false, 0, false, 0x80, n, &rm, force)
                        e.imm(k, 1)
                    } else if k >= -128 && k <= 127 {
                        e.op(p66, 0, w, 0x83, n, &rm, false)
                        e.imm(k, 1)
                    } else {
                        e.op(p66, 0, w, 0x81, n, &rm, false)
                        e.imm(k, if sz == 2 { 2 } else { 4 })
                    }
                }
                (R(d), M(_)) => {
                    rm := e.rm(&i.b)
                    force := sz == 1 && byte_reg_needs_rex(&i.a)
                    lo: u8 = if sz == 1 { 2 } else { 3 }
                    e.op(p66, 0, w, i64((n << 3) | lo), u8(d & 15), &rm, force)
                }
                (_, R(s)) => {
                    rm := e.rm(&i.a)
                    force := sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b))
                    lo: u8 = if sz == 1 { 0 } else { 1 }
                    e.op(p66, 0, w, i64((n << 3) | lo), u8(s & 15), &rm, force)
                }
                _ => panic(fmt("encoder: bad alu ", *i))
            }
        }
        Test => match &i.b {
            I(k) => {
                rm := e.rm(&i.a)
                force := sz == 1 && byte_reg_needs_rex(&i.a)
                e.op(p66, 0, w, if sz == 1 { 0xF6 } else { 0xF7 }, 0, &rm, force)
                e.imm(k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 })
            }
            R(s) => {
                rm := e.rm(&i.a)
                force := sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b))
                e.op(p66, 0, w, if sz == 1 { 0x84 } else { 0x85 }, u8(s & 15), &rm, force)
            }
            _ => panic(fmt("encoder: bad test ", *i))
        }
        Imul => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(p66, 0, w, 0x0FAF, u8(d & 15), &rm, false)
        }
        Imul3 => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            k := i64(i.tgt)
            if k >= -128 && k <= 127 {
                e.op(false, 0, w, 0x6B, u8(d & 15), &rm, false)
                e.imm(k, 1)
            } else {
                e.op(false, 0, w, 0x69, u8(d & 15), &rm, false)
                e.imm(k, 4)
            }
        }
        Neg, Not, Idiv, Div, Mul1, Imul1 => {
            n: u8 = match i.op {
                Not => 2
                Neg => 3
                Mul1 => 4
                Imul1 => 5
                Div => 6
                _ => 7
            }
            rm := e.rm(&i.a)
            force := sz == 1 && byte_reg_needs_rex(&i.a)
            e.op(p66, 0, w, if sz == 1 { 0xF6 } else { 0xF7 }, n, &rm, force)
        }
        Shl, Shr, Sar, Rol, Ror => {
            n: u8 = match i.op {
                Rol => 0
                Ror => 1
                Shl => 4
                Shr => 5
                _ => 7
            }
            rm := e.rm(&i.a)
            force := sz == 1 && byte_reg_needs_rex(&i.a)
            match &i.b {
                I(1) => e.op(p66, 0, w, if sz == 1 { 0xD0 } else { 0xD1 }, n, &rm, force)
                I(k) => {
                    e.op(p66, 0, w, if sz == 1 { 0xC0 } else { 0xC1 }, n, &rm, force)
                    e.imm(k, 1)
                }
                R(_) => e.op(p66, 0, w, if sz == 1 { 0xD2 } else { 0xD3 }, n, &rm, force)
                _ => panic(fmt("encoder: bad shift ", *i))
            }
        }
        Cqo => {
            if w {
                e.b1(0x48)
            }
            e.b1(0x99)
        }
        Setcc => {
            rm := e.rm(&i.a)
            e.op(false, 0, false, 0x0F90 | i64(i.cc), 0, &rm, byte_reg_needs_rex(&i.a))
        }
        Cmov => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, 0, w, 0x0F40 | i64(i.cc), u8(d & 15), &rm, false)
        }
        Call => {
            e.b1(0xE8)
            e.relocs.push(Reloc{off: e.out.len, kind: Rel32Func(i64(i.tgt)), addend: 0})
            e.imm(0, 4)
        }
        CallInd => {
            rm := e.rm(&i.a)
            e.op(false, 0, false, 0xFF, 2, &rm, false)
        }
        Ret => e.b1(0xC3)
        Syscall => {
            e.b1(0x0F)
            e.b1(0x05)
        }
        Ud2 => {
            e.b1(0x0F)
            e.b1(0x0B)
        }
        MovSd => {
            // movaps between registers; movsd / movss / movups to and from memory
            pfx := fp_pfx(sz)
            match (&i.a, &i.b) {
                (R(d), R(s)) => {
                    rm := rm_reg(s)
                    e.op(false, 0, false, 0x0F28, u8(d & 15), &rm, false)
                }
                (R(d), M(_)) => {
                    rm := e.rm(&i.b)
                    e.op(false, pfx, false, 0x0F10, u8(d & 15), &rm, false)
                }
                (M(_), R(s)) => {
                    rm := e.rm(&i.a)
                    e.op(false, pfx, false, 0x0F11, u8(s & 15), &rm, false)
                }
                _ => panic(fmt("encoder: bad movsd ", *i))
            }
        }
        Addsd, Subsd, Mulsd, Divsd, Sqrtsd, Minsd, Maxsd => {
            o: i64 = match i.op {
                Addsd => 0x0F58
                Mulsd => 0x0F59
                Subsd => 0x0F5C
                Divsd => 0x0F5E
                Minsd => 0x0F5D
                Maxsd => 0x0F5F
                _ => 0x0F51
            }
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, fp_pfx(sz), false, o, u8(d & 15), &rm, false)
        }
        Cvtf => {
            // cvtss2sd (sz 8) / cvtsd2ss (sz 4)
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, if sz == 8 { 0xF3 } else { 0xF2 }, false, 0x0F5A, u8(d & 15), &rm, false)
        }
        Shufps => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, 0, false, 0x0FC6, u8(d & 15), &rm, false)
            e.imm(i64(i.tgt), 1)
        }
        Movlo => {
            d := reg_of(&i.a)
            rm := rm_reg(reg_of(&i.b))
            e.op(false, 0xF3, false, 0x0F10, u8(d & 15), &rm, false)
        }
        Unpcklps => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, 0, false, 0x0F14, u8(d & 15), &rm, false)
        }
        Ucomisd, Xorpd, Andpd => {
            o: i64 = match i.op {
                Ucomisd => 0x0F2E
                Xorpd => 0x0F57
                _ => 0x0F54
            }
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(sz == 8, 0, false, o, u8(d & 15), &rm, false)
        }
        Cvtsi2sd => {
            // sz = integer size, sz2 = float size (4: single)
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, if u8(i.sz2) == 4 { 0xF3 } else { 0xF2 }, w, 0x0F2A, u8(d & 15), &rm, false)
        }
        Cvttsd2si => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, if u8(i.sz2) == 4 { 0xF3 } else { 0xF2 }, w, 0x0F2C, u8(d & 15), &rm, false)
        }
        MovqToX => {
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(true, 0, w, 0x0F6E, u8(d & 15), &rm, false)
        }
        MovqToR => {
            s := reg_of(&i.b)
            rm := e.rm(&i.a)
            e.op(true, 0, w, 0x0F7E, u8(s & 15), &rm, false)
        }
        RepMovsb => {
            e.b1(0xF3)
            e.b1(0xA4)
        }
        RepStosb => {
            e.b1(0xF3)
            e.b1(0xAA)
        }
        Bswap => {
            d := u8(reg_of(&i.a) & 15)
            rex := 0x40 | (u8(w) << 3) | (d >> 3)
            if rex != 0x40 {
                e.b1(rex)
            }
            e.b1(0x0F)
            e.b1(0xC8 | (d & 7))
        }
        Popcnt, Tzcnt, Lzcnt => {
            o: i64 = match i.op {
                Popcnt => 0x0FB8
                Tzcnt => 0x0FBC
                _ => 0x0FBD
            }
            d := reg_of(&i.a)
            rm := e.rm(&i.b)
            e.op(false, 0xF3, w, o, u8(d & 15), &rm, false)
        }
        Push, Pop => {
            r := u8(reg_of(&i.a) & 15)
            if r >= 8 {
                e.b1(0x41)
            }
            base: u8 = if i.op == Push { 0x50 } else { 0x58 }
            e.b1(base | (r & 7))
        }
        Zero => {
            r := reg_of(&i.a)
            rm := rm_reg(r)
            if r >= 16 {
                e.op(false, 0, false, 0x0F57, u8(r & 15), &rm, false)
            } else {
                e.op(false, 0, false, 0x31, u8(r & 15), &rm, false)
            }
        }
        Jmp, Jcc => panic("unreachable")
    }
}

priv fn sets_flags(op: MOp) -> bool {
    return op == Add || op == Sub || op == And || op == Or || op == Xor || op == Cmp || op == Test ||
        op == Imul || op == Imul3 || op == Neg || op == Shl || op == Shr || op == Sar || op == Rol ||
        op == Ror || op == Idiv || op == Div || op == Mul1 || op == Imul1 || op == Ucomisd ||
        op == Popcnt || op == Tzcnt || op == Lzcnt || op == Zero || op == Call || op == CallInd ||
        op == Syscall || op == Bswap
}

priv fn reads_flags(op: MOp) -> bool {
    return op == Jcc || op == Setcc || op == Cmov
}

priv fn peephole_resolve(b0: i64, fwd: *Vec[i64]) -> i64 {
    b := b0
    n := 0
    while fwd[b] != b && n < 64 {
        b = fwd[b]
        n += 1
    }
    return b
}

// the `add` replacement of step 3 of the peephole for a `lea`, if there is one
priv fn peephole_lea_add(i: *MInst) -> Opt[Opnd] {
    add: Opt[Opnd] = None
    if i.op == Lea {
        match (&i.a, &i.b) {
            (R(d), M(m)) if m.kind == MK_NORMAL => {
                base := i64(m.base)
                idx := i64(m.idx)
                if base == d && idx == NOREG && i32(m.disp) != 0 {
                    add = Some(I(i64(m.disp)))
                } else if base == d && idx != NOREG && u8(m.scale) == 1 && i32(m.disp) == 0 && idx != d {
                    add = Some(R(idx))
                } else if idx == d && u8(m.scale) == 1 && i32(m.disp) == 0 && base != NOREG && base != d {
                    add = Some(R(base))
                }
            }
            _ => {}
        }
    }
    return add
}

// Post-allocation cleanups that depend on the final layout. The prologue and the epilogues
// are not in the instruction lists yet (emit_emit adds them while encoding); `pro` tells
// whether the entry block will start with a prologue. (Their instructions never take part in
// these rewrites, and an epilogue before a `ret` decides nothing in step 3: either way the
// flags are dead at the end of the block.)
priv fn peephole(mf: *MFunc, layout: *Vec[i64], pro: bool) {
    nb := mf.blocks.len
    entry := layout[0]
    // 1. thread jumps through blocks that only contain `jmp X`
    fwd := vec_fill(nb, 0)
    for b in 0..nb {
        fwd[b] = b
        blk := &mf.blocks[b]
        if blk.insts.len == 1 && blk.insts[0].op == Jmp && i64(blk.insts[0].tgt) != b && !(pro && b == entry) {
            fwd[b] = i64(blk.insts[0].tgt)
        }
    }
    // (jumps are only at the end of a block: isel puts them last and nothing is ever inserted
    // after an instruction without definitions)
    for b in 0..nb {
        insts := &mf.blocks[b].insts
        x := insts.len - 1
        while x >= 0 && (insts[x].op == Jmp || insts[x].op == Jcc) {
            insts[x].tgt = i32(peephole_resolve(i64(insts[x].tgt), &fwd))
            x -= 1
        }
    }
    // drop blocks that are no longer reachable
    {
        reach := vec_fill(nb, false)
        work := vec_of([]i64{entry})
        reach[entry] = true
        while work.len > 0 {
            b := work.pop()
            insts := &mf.blocks[b].insts
            x := insts.len - 1
            while x >= 0 && (insts[x].op == Jmp || insts[x].op == Jcc) {
                t := i64(insts[x].tgt)
                if !reach[t] {
                    reach[t] = true
                    work.push(t)
                }
                x -= 1
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
    // 2. fallthrough and branch inversion (the prologue is never a `jcc`: with it, a block
    // ending in `jcc; jmp` has a single jcc exactly when it has one without it)
    for li in 0..layout.len {
        b := layout[li]
        next := if li + 1 < layout.len { layout[li + 1] } else { -1 }
        insts := &mf.blocks[b].insts
        n := insts.len
        if n >= 2 && insts[n - 1].op == Jmp && insts[n - 2].op == Jcc {
            single_jcc := n < 3 || insts[n - 3].op != Jcc
            if i64(insts[n - 2].tgt) == i64(insts[n - 1].tgt) && single_jcc {
                insts[n - 2] = insts[n - 1]
                insts.len = n - 1
            } else if i64(insts[n - 2].tgt) == next && single_jcc {
                f := insts[n - 1].tgt
                insts[n - 2].cc ^= 1
                insts[n - 2].tgt = f
                insts.len = n - 1
            }
        }
        n2 := insts.len
        if n2 >= 1 && insts[n2 - 1].op == Jmp && i64(insts[n2 - 1].tgt) == next {
            insts.len = n2 - 1
        }
    }
    // 3. flag-clobbering shorter forms when flags are dead:
    //    mov r, 0 -> xor r, r ; lea r, [r + x] -> add r, x
    for b in 0..nb {
        insts := &mf.blocks[b].insts
        n := insts.len
        next_inst: for k in 0..n {
            i := &insts[k]
            if i.op != Mov && i.op != Lea {
                continue
            }
            a_low_reg := match &i.a {
                R(r) => r < 16
                _ => false
            }
            zero := i.op == Mov && a_low_reg && i.b == I(0)
            add := peephole_lea_add(i)
            if !zero && !is_some(add) {
                continue
            }
            // the flags must be dead after the instruction
            for j in k + 1..n {
                o := insts[j].op
                if reads_flags(o) {
                    continue next_inst
                }
                if sets_flags(o) {
                    break
                }
            }
            a := i.a
            sz := i.sz
            if zero {
                insts[k] = minst_new(Zero, 4, a, Opnd.None)
            } else {
                match add {
                    Some(src) => {
                        insts[k] = minst_new(Add, sz, a, src)
                    }
                    None => {}
                }
            }
        }
    }
}

// a jump or the alignment of a block, at position `pos` of the encoded buffer
priv struct Item {
    pos: i64
    tgt: i64 // jump target block, or -1: alignment to 16
    cc: i64  // condition code, or -1: unconditional
    long: bool
}

// size of item k at offset o
priv fn item_size(it: *Item, o: i64) -> i64 {
    if it.tgt < 0 {
        return align_pad(o, 16)
    }
    if !it.long {
        return 2
    }
    return if it.cc < 0 { 5 } else { 6 }
}

// Windows: `sub rsp, size` for a frame of a page or more, touching every page on the way down
// (the stack grows through a guard page one page at a time): r11 counts the pages
//     mov r11d, size / 4096
//  l: sub rsp, 4096 ; test [rsp], rsp ; dec r11 ; jnz l
//     sub rsp, size % 4096 ; test [rsp], rsp
// (r11 is no argument register and is free at the entry)
priv fn stack_probe(e: *Enc, size: i32) {
    e.room()
    for x in []u8{0x41, 0xBB} {
        e.b1(x)
    }
    e.imm(i64(size / 4096), 4)
    e.room()
    for x in []u8{0x48, 0x81, 0xEC, 0x00, 0x10, 0x00, 0x00, 0x48, 0x85, 0x24, 0x24, 0x49, 0xFF, 0xCB, 0x75, 0xF0} {
        e.b1(x)
    }
    rest := size % 4096
    if rest > 0 {
        si := minst_new(Sub, 8, R(RSP), I(i64(rest)))
        enc_inst(e, &si)
        e.room()
        for x in []u8{0x48, 0x85, 0x24, 0x24} {
            e.b1(x)
        }
    }
}

fn emit_emit(mf: *MFunc, alloc: *Alloc, layout0: []i64, fpool: []i64) -> Code {
    // frame layout (computed in i64: a frame over 2 GiB cannot be addressed and is an error)
    off := 8 * mf.out_args
    slot_off := vec[i32]()
    slot_off.reserve(mf.slots.len)
    for sl in mf.slots {
        a := min(max(sl.1, 1), 16)
        off = (off + a - 1) / a * a
        slot_off.push(i32(off))
        off += sl.0
    }
    // Windows: the xmm registers to preserve, 16 bytes each above the slots
    xmm_off := (off + 15) / 16 * 16
    if alloc.used_xmm_saved.len > 0 {
        off = xmm_off + 16 * alloc.used_xmm_saved.len
    }
    npush := i32(alloc.used_callee_saved.len)
    size64 := (off + 15) / 16 * 16
    if (8 + 8 * i64(npush) + size64) % 16 != 0 {
        size64 += 8
    }
    if !mf.has_calls && off == 0 {
        size64 = 0
    }
    err := ""
    if size64 > 0x7FFF_0000 {
        err = fmt("function `", mf.name, "` needs a stack frame of ", size64,
            " bytes; at most 2 GiB are possible (allocate large arrays with alloc[T](n))")
        size64 = 0
    }
    size := i32(size64)
    frame := Frame{slot_off: slot_off, size: size, npush: npush}
    layout := vec_of(layout0)
    entry := layout[0]
    peephole(mf, &layout, npush > 0 || size > 0)
    // encode
    total := 0
    for b in layout {
        total += mf.blocks[b].insts.len
    }
    enc := Enc{out: vec[u8](), relocs: vec[Reloc](), frame: &frame, fpool: fpool}
    enc.out.reserve(4 * total + 64)
    items := vec[Item]()
    bpos := vec_fill(mf.blocks.len, 0)  // where each block starts in enc.out
    bitem := vec_fill(mf.blocks.len, 0) // the items before it
    for b in layout {
        if mf.blocks[b].align {
            items.push(Item{pos: enc.out.len, tgt: -1, cc: -1, long: false})
        }
        bpos[b] = enc.out.len
        bitem[b] = items.len
        if b == entry {
            // prologue
            for r in alloc.used_callee_saved {
                pi := minst_new(Push, 8, R(r), Opnd.None)
                enc_inst(&enc, &pi)
            }
            if size >= 4096 && target_os == TargetWindows {
                stack_probe(&enc, size)
            } else if size > 0 {
                si := minst_new(Sub, 8, R(RSP), I(i64(size)))
                enc_inst(&enc, &si)
            }
            for k, r in alloc.used_xmm_saved {
                m := mem_new()
                m.base = i32(RSP)
                m.disp = i32(xmm_off + 16 * k)
                si := minst_new(MovSd, 16, M(m), R(r))
                enc_inst(&enc, &si)
            }
        }
        insts := &mf.blocks[b].insts
        for x in 0..insts.len {
            i := &insts[x]
            if i.op == Jmp || i.op == Jcc {
                items.push(Item{pos: enc.out.len, tgt: i64(i.tgt), cc: if i.op == Jcc { i64(i.cc) } else { -1 }, long: false})
                continue
            }
            if i.op == Ret {
                // epilogue
                for k, r in alloc.used_xmm_saved {
                    m := mem_new()
                    m.base = i32(RSP)
                    m.disp = i32(xmm_off + 16 * k)
                    li := minst_new(MovSd, 16, R(r), M(m))
                    enc_inst(&enc, &li)
                }
                if size > 0 {
                    ai := minst_new(Add, 8, R(RSP), I(i64(size)))
                    enc_inst(&enc, &ai)
                }
                for y in alloc.used_callee_saved.len - 1..=0 by -1 {
                    pi := minst_new(Pop, 8, R(alloc.used_callee_saved[y]), Opnd.None)
                    enc_inst(&enc, &pi)
                }
            }
            if i.op == Syscall && target_os == TargetWindows && len(err) == 0 {
                err = fmt("function `", mf.name, "` makes a Linux system call (`syscall`), which a Windows executable cannot make")
            }
            enc_inst(&enc, i)
        }
    }
    // relaxation: pre[k] = the bytes the items before item k add
    ni := items.len
    pre := vec_fill(ni + 1, 0)
    loop {
        add := 0
        for k in 0..ni {
            pre[k] = add
            add += item_size(&items[k], items[k].pos + add)
        }
        pre[ni] = add
        changed := false
        for k in 0..ni {
            it := &items[k]
            if it.tgt >= 0 && !it.long {
                t := bpos[it.tgt] + pre[bitem[it.tgt]]
                d := t - (it.pos + pre[k] + 2)
                if !(d >= -128 && d <= 127) {
                    it.long = true
                    changed = true
                }
            }
        }
        if !changed {
            break
        }
    }
    bytes := vec[u8]()
    bytes.reserve(enc.out.len + pre[ni])
    relocs := vec[Reloc]()
    relocs.reserve(enc.relocs.len)
    src := enc.out.items()
    p := 0  // copied from src up to here
    ri := 0 // relocations up to here are placed
    for k in 0..=ni {
        q := if k < ni { items[k].pos } else { src.len }
        // (a relocation is inside an instruction: never at the position of an item)
        while ri < enc.relocs.len && enc.relocs[ri].off < q {
            rr := enc.relocs[ri]
            relocs.push(Reloc{off: rr.off + pre[k], kind: rr.kind, addend: rr.addend})
            ri += 1
        }
        bytes.extend(src[p..q])
        p = q
        if k == ni {
            break
        }
        it := &items[k]
        o := bytes.len
        if it.tgt < 0 {
            nops(&bytes, align_pad(o, 16))
            continue
        }
        t := bpos[it.tgt] + pre[bitem[it.tgt]]
        if it.long {
            if it.cc >= 0 {
                bytes.push(0x0F)
                bytes.push(0x80 | u8(it.cc))
                put_le32(&bytes, i32(t - (o + 6)))
            } else {
                bytes.push(0xE9)
                put_le32(&bytes, i32(t - (o + 5)))
            }
        } else {
            d := t - (o + 2)
            bytes.push(if it.cc >= 0 { 0x70 | u8(it.cc) } else { 0xEB })
            bytes.push(u8(i8(d)))
        }
    }
    return Code{bytes: bytes, relocs: relocs, err: err}
}

// rewrites the float constant relocations of code from indices into the function's own list
// to indices into the module pool (local[i])
fn emit_pool_fconsts(code: *Code, local: []i64) {
    for j in 0..code.relocs.len {
        match code.relocs[j].kind {
            Abs32FConst(k) => code.relocs[j].kind = Abs32FConst(local[k])
            _ => {}
        }
    }
}

// ---------- code in a shared mapping (the parallel back end) ----------
// At byte offset q (8-aligned) of the mapping at base: the counts of bytes, relocations, float
// constants and error bytes, then the bytes (padded to 8), each relocation as 4 words
// (offset, kind, payload, addend), each constant as 2 words, the error text (padded).

priv fn pad8(n: i64) -> i64 {
    return (n + 7) / 8 * 8
}

fn emit_code_size(code: *Code, fc: *Vec[Bits128]) -> i64 {
    return 32 + pad8(code.bytes.len) + 32 * code.relocs.len + 16 * fc.len + pad8(len(code.err))
}

// writes code at q; returns the offset after it
fn emit_put_code(code: *Code, fc: *Vec[Bits128], base: i64, q0: i64) -> i64 {
    h := cast[*i64](base + q0)
    h[0] = code.bytes.len
    h[1] = code.relocs.len
    h[2] = fc.len
    h[3] = len(code.err)
    q := q0 + 32
    if code.bytes.len > 0 {
        memcopy(cast[*u8](base + q), ptr(code.bytes.buf), code.bytes.len)
    }
    q += pad8(code.bytes.len)
    for r in code.relocs {
        w := cast[*i64](base + q)
        w[0] = r.off
        match r.kind {
            Abs32Global(x) => {
                w[1] = 0
                w[2] = x
            }
            Abs32Func(x) => {
                w[1] = 1
                w[2] = x
            }
            Rel32Func(x) => {
                w[1] = 2
                w[2] = x
            }
            Abs32FConst(x) => {
                w[1] = 3
                w[2] = x
            }
        }
        w[3] = i64(r.addend)
        q += 32
    }
    for b in *fc {
        w := cast[*i64](base + q)
        w[0] = i64(b.lo)
        w[1] = i64(b.hi)
        q += 16
    }
    if len(code.err) > 0 {
        memcopy(cast[*u8](base + q), ptr(code.err), len(code.err))
    }
    return q + pad8(len(code.err))
}

// reads the code at q (into the current arena): (code, float constants, offset after it)
fn emit_get_code(base: i64, q0: i64) -> (Code, Vec[Bits128], i64) {
    h := cast[*i64](base + q0)
    nb := h[0]
    nr := h[1]
    nf := h[2]
    ne := h[3]
    q := q0 + 32
    bytes := vec_of(mkslice[u8](cast[*u8](base + q), nb))
    q += pad8(nb)
    relocs := vec[Reloc]()
    relocs.reserve(nr)
    for k in 0..nr {
        w := cast[*i64](base + q)
        kind := match w[1] {
            0 => Abs32Global(w[2])
            1 => Abs32Func(w[2])
            2 => Rel32Func(w[2])
            _ => Abs32FConst(w[2])
        }
        relocs.push(Reloc{off: w[0], kind: kind, addend: i32(w[3])})
        q += 32
    }
    fc := vec[Bits128]()
    fc.reserve(nf)
    for k in 0..nf {
        w := cast[*i64](base + q)
        fc.push(Bits128{lo: u64(w[0]), hi: u64(w[1])})
        q += 16
    }
    err := clone(mkslice[u8](cast[*u8](base + q), ne))
    q += pad8(ne)
    return (Code{bytes: bytes, relocs: relocs, err: err}, fc, q)
}

// padding in front of an aligned block; long paddings are not worth executing
priv fn align_pad(o: i64, a: i64) -> i64 {
    p := (a - o % a) % a
    if p > 10 {
        return 0
    }
    return p
}

priv fn nops_seq(k: i64) -> []u8 {
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

priv fn nops(out: *Vec[u8], n0: i64) {
    n := n0
    while n > 0 {
        k := min(n, 9)
        out.extend(nops_seq(k))
        n -= k
    }
}
