// Frame layout, final peepholes, x86-64 encoding and branch relaxation.
use super::mir::*;
use super::regalloc::Alloc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RelocKind {
    Abs32Global(u32),
    Abs32Func(u32),
    Rel32Func(u32),
    Abs32FConst(u32), // module float pool index
}

#[derive(Clone, Copy, Debug)]
pub struct Reloc {
    pub off: u32,
    pub kind: RelocKind,
    pub addend: i32,
}

pub struct Code {
    pub bytes: Vec<u8>,
    pub relocs: Vec<Reloc>,
}

struct Frame {
    slot_off: Vec<i32>,
    size: i32,
    npush: i32,
}

struct RM {
    is_reg: bool,
    reg: u8,
    base: i8,
    idx: i8,
    scale: u8,
    disp: i32,
    reloc: Option<RelocKind>,
}

fn rm_reg(r: Reg) -> RM {
    RM { is_reg: true, reg: (r & 15) as u8, base: -1, idx: -1, scale: 1, disp: 0, reloc: None }
}

struct Enc<'a> {
    out: Vec<u8>,
    relocs: Vec<Reloc>,
    frame: &'a Frame,
    fpool: &'a [u32], // function-local fconst index -> module pool index
}

impl<'a> Enc<'a> {
    fn rm_mem(&self, m: &Mem) -> RM {
        let mut r = RM { is_reg: false, reg: 0, base: -1, idx: -1, scale: m.scale, disp: m.disp, reloc: None };
        if m.base != NOREG {
            r.base = m.base as i8;
        }
        if m.idx != NOREG {
            r.idx = m.idx as i8;
        }
        match m.kind {
            MemKind::Normal => {}
            MemKind::Global => r.reloc = Some(RelocKind::Abs32Global(m.id)),
            MemKind::FConst => r.reloc = Some(RelocKind::Abs32FConst(self.fpool[m.id as usize])),
            MemKind::Slot => {
                r.base = RSP as i8;
                r.disp += self.frame.slot_off[m.id as usize];
            }
            MemKind::OutArg => {
                r.base = RSP as i8;
                r.disp += 8 * m.id as i32;
            }
            MemKind::InArg => {
                r.base = RSP as i8;
                r.disp += self.frame.size + 8 * self.frame.npush + 8 + 8 * m.id as i32;
            }
        }
        r
    }
    fn rm(&self, o: &Opnd) -> RM {
        match o {
            Opnd::R(r) => rm_reg(*r),
            Opnd::M(m) => self.rm_mem(m),
            _ => panic!("encoder: operand {:?} is not r/m", o),
        }
    }
    // [prefix66] [mandatory prefix] [REX] opcode modrm [sib] [disp]
    #[allow(clippy::too_many_arguments)]
    fn op(&mut self, p66: bool, pfx: u8, w: bool, opc: &[u8], reg: u8, rm: &RM, force_rex: bool) {
        if p66 {
            self.out.push(0x66);
        }
        if pfx != 0 {
            self.out.push(pfx);
        }
        let r_bit = (reg >> 3) & 1;
        let (x_bit, b_bit) = if rm.is_reg {
            (0, (rm.reg >> 3) & 1)
        } else {
            (if rm.idx >= 0 { (rm.idx as u8 >> 3) & 1 } else { 0 }, if rm.base >= 0 { (rm.base as u8 >> 3) & 1 } else { 0 })
        };
        let rex = 0x40 | ((w as u8) << 3) | (r_bit << 2) | (x_bit << 1) | b_bit;
        if rex != 0x40 || force_rex {
            self.out.push(rex);
        }
        self.out.extend_from_slice(opc);
        let regf = (reg & 7) << 3;
        if rm.is_reg {
            self.out.push(0xC0 | regf | (rm.reg & 7));
            return;
        }
        let scale_bits = match rm.scale {
            2 => 1u8,
            4 => 2,
            8 => 3,
            _ => 0,
        };
        let has_reloc = rm.reloc.is_some();
        if rm.base < 0 {
            // [disp32] or [idx*scale + disp32]
            self.out.push(regf | 4);
            let idx = if rm.idx >= 0 { rm.idx as u8 & 7 } else { 4 };
            self.out.push((scale_bits << 6) | (idx << 3) | 5);
            self.disp32(rm);
            return;
        }
        let base = rm.base as u8 & 7;
        let need_sib = rm.idx >= 0 || base == 4;
        let (md, dsz) = if has_reloc {
            (2u8, 4)
        } else if rm.disp == 0 && base != 5 {
            (0u8, 0)
        } else if rm.disp >= -128 && rm.disp <= 127 {
            (1u8, 1)
        } else {
            (2u8, 4)
        };
        if need_sib {
            self.out.push((md << 6) | regf | 4);
            let idx = if rm.idx >= 0 { rm.idx as u8 & 7 } else { 4 };
            self.out.push((scale_bits << 6) | (idx << 3) | base);
        } else {
            self.out.push((md << 6) | regf | base);
        }
        match dsz {
            1 => self.out.push(rm.disp as i8 as u8),
            4 => self.disp32(rm),
            _ => {}
        }
    }
    fn disp32(&mut self, rm: &RM) {
        if let Some(k) = rm.reloc {
            self.relocs.push(Reloc { off: self.out.len() as u32, kind: k, addend: rm.disp });
            self.out.extend_from_slice(&0i32.to_le_bytes());
        } else {
            self.out.extend_from_slice(&rm.disp.to_le_bytes());
        }
    }
    fn imm(&mut self, k: i64, n: u8) {
        self.out.extend_from_slice(&k.to_le_bytes()[..n as usize]);
    }
}

// mandatory prefix of an SSE operation by operand size: scalar double, scalar single, packed single
fn fp_pfx(sz: u8) -> u8 {
    match sz {
        4 => 0xF3,
        16 => 0,
        _ => 0xF2,
    }
}

fn byte_reg_needs_rex(o: &Opnd) -> bool {
    matches!(o, Opnd::R(r) if (4..8).contains(r))
}

fn reg_of(o: &Opnd) -> Reg {
    match o {
        Opnd::R(r) => *r,
        _ => panic!("encoder: expected register, got {:?}", o),
    }
}

fn enc_inst(e: &mut Enc, i: &MInst) {
    use MOp::*;
    let sz = i.sz;
    let w = sz == 8;
    let p66 = sz == 2;
    match i.op {
        Mov => match (&i.a, &i.b) {
            (Opnd::R(d), Opnd::R(s)) => {
                let force = sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b));
                e.op(p66, 0, w, &[if sz == 1 { 0x88 } else { 0x89 }], (*s & 15) as u8, &rm_reg(*d), force);
            }
            (Opnd::R(d), Opnd::I(k)) => {
                let d8 = (*d & 15) as u8;
                if sz == 8 && !(*k >= 0 && *k <= u32::MAX as i64) {
                    if *k >= i32::MIN as i64 && *k <= i32::MAX as i64 {
                        e.op(false, 0, true, &[0xC7], 0, &rm_reg(*d), false);
                        e.imm(*k, 4);
                    } else {
                        e.out.push(0x48 | (d8 >> 3));
                        e.out.push(0xB8 | (d8 & 7));
                        e.imm(*k, 8);
                    }
                } else {
                    if d8 >= 8 {
                        e.out.push(0x41);
                    }
                    e.out.push(0xB8 | (d8 & 7));
                    e.imm(*k, 4);
                }
            }
            (Opnd::R(d), Opnd::GAddr(..)) | (Opnd::R(d), Opnd::FAddr(_)) => {
                let d8 = (*d & 15) as u8;
                if d8 >= 8 {
                    e.out.push(0x41);
                }
                e.out.push(0xB8 | (d8 & 7));
                let (kind, addend) = match i.b {
                    Opnd::GAddr(g, off) => (RelocKind::Abs32Global(g), off),
                    Opnd::FAddr(f) => (RelocKind::Abs32Func(f), 0),
                    _ => unreachable!(),
                };
                e.relocs.push(Reloc { off: e.out.len() as u32, kind, addend });
                e.imm(0, 4);
            }
            (Opnd::R(d), Opnd::M(_)) => {
                let rm = e.rm(&i.b);
                let force = sz == 1 && byte_reg_needs_rex(&i.a);
                e.op(p66, 0, w, &[if sz == 1 { 0x8A } else { 0x8B }], (*d & 15) as u8, &rm, force);
            }
            (Opnd::M(_), Opnd::R(s)) => {
                let rm = e.rm(&i.a);
                let force = sz == 1 && byte_reg_needs_rex(&i.b);
                e.op(p66, 0, w, &[if sz == 1 { 0x88 } else { 0x89 }], (*s & 15) as u8, &rm, force);
            }
            (Opnd::M(_), Opnd::I(k)) => {
                let rm = e.rm(&i.a);
                e.op(p66, 0, w, &[if sz == 1 { 0xC6 } else { 0xC7 }], 0, &rm, false);
                e.imm(*k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 });
            }
            (Opnd::M(_), Opnd::GAddr(..)) | (Opnd::M(_), Opnd::FAddr(_)) => {
                let rm = e.rm(&i.a);
                e.op(false, 0, true, &[0xC7], 0, &rm, false);
                let (kind, addend) = match i.b {
                    Opnd::GAddr(g, off) => (RelocKind::Abs32Global(g), off),
                    Opnd::FAddr(f) => (RelocKind::Abs32Func(f), 0),
                    _ => unreachable!(),
                };
                e.relocs.push(Reloc { off: e.out.len() as u32, kind, addend });
                e.imm(0, 4);
            }
            _ => panic!("encoder: bad mov {:?}", i),
        },
        Movzx => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            match sz {
                1 => e.op(false, 0, false, &[0x0F, 0xB6], (d & 15) as u8, &rm, byte_reg_needs_rex(&i.b)),
                2 => e.op(false, 0, false, &[0x0F, 0xB7], (d & 15) as u8, &rm, false),
                _ => e.op(false, 0, false, &[0x8B], (d & 15) as u8, &rm, false),
            }
        }
        Movsx => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            let w2 = i.sz2 == 8;
            match sz {
                1 => e.op(false, 0, w2, &[0x0F, 0xBE], (d & 15) as u8, &rm, byte_reg_needs_rex(&i.b)),
                2 => e.op(false, 0, w2, &[0x0F, 0xBF], (d & 15) as u8, &rm, false),
                _ => {
                    if w2 {
                        e.op(false, 0, true, &[0x63], (d & 15) as u8, &rm, false)
                    } else {
                        e.op(false, 0, false, &[0x8B], (d & 15) as u8, &rm, false)
                    }
                }
            }
        }
        Lea => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, 0, w, &[0x8D], (d & 15) as u8, &rm, false);
        }
        Add | Sub | And | Or | Xor | Cmp => {
            let n: u8 = match i.op {
                Add => 0,
                Or => 1,
                And => 4,
                Sub => 5,
                Xor => 6,
                _ => 7,
            };
            match (&i.a, &i.b) {
                (_, Opnd::I(k)) => {
                    let rm = e.rm(&i.a);
                    let force = sz == 1 && byte_reg_needs_rex(&i.a);
                    if sz == 1 {
                        e.op(false, 0, false, &[0x80], n, &rm, force);
                        e.imm(*k, 1);
                    } else if *k >= -128 && *k <= 127 {
                        e.op(p66, 0, w, &[0x83], n, &rm, false);
                        e.imm(*k, 1);
                    } else {
                        e.op(p66, 0, w, &[0x81], n, &rm, false);
                        e.imm(*k, if sz == 2 { 2 } else { 4 });
                    }
                }
                (Opnd::R(d), Opnd::M(_)) => {
                    let rm = e.rm(&i.b);
                    let force = sz == 1 && byte_reg_needs_rex(&i.a);
                    e.op(p66, 0, w, &[(n << 3) | if sz == 1 { 2 } else { 3 }], (*d & 15) as u8, &rm, force);
                }
                (_, Opnd::R(s)) => {
                    let rm = e.rm(&i.a);
                    let force = sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b));
                    e.op(p66, 0, w, &[(n << 3) | if sz == 1 { 0 } else { 1 }], (*s & 15) as u8, &rm, force);
                }
                _ => panic!("encoder: bad alu {:?}", i),
            }
        }
        Test => match &i.b {
            Opnd::I(k) => {
                let rm = e.rm(&i.a);
                let force = sz == 1 && byte_reg_needs_rex(&i.a);
                e.op(p66, 0, w, &[if sz == 1 { 0xF6 } else { 0xF7 }], 0, &rm, force);
                e.imm(*k, if sz == 1 { 1 } else if sz == 2 { 2 } else { 4 });
            }
            Opnd::R(s) => {
                let rm = e.rm(&i.a);
                let force = sz == 1 && (byte_reg_needs_rex(&i.a) || byte_reg_needs_rex(&i.b));
                e.op(p66, 0, w, &[if sz == 1 { 0x84 } else { 0x85 }], (*s & 15) as u8, &rm, force);
            }
            _ => panic!("encoder: bad test {:?}", i),
        },
        Imul => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(p66, 0, w, &[0x0F, 0xAF], (d & 15) as u8, &rm, false);
        }
        Imul3 => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            let k = match i.c {
                Opnd::I(k) => k,
                _ => panic!("encoder: imul3 without immediate"),
            };
            if (-128..=127).contains(&k) {
                e.op(false, 0, w, &[0x6B], (d & 15) as u8, &rm, false);
                e.imm(k, 1);
            } else {
                e.op(false, 0, w, &[0x69], (d & 15) as u8, &rm, false);
                e.imm(k, 4);
            }
        }
        Neg | Not | Idiv | Div | Mul1 | Imul1 => {
            let n = match i.op {
                Not => 2,
                Neg => 3,
                Mul1 => 4,
                Imul1 => 5,
                Div => 6,
                _ => 7,
            };
            let rm = e.rm(&i.a);
            let force = sz == 1 && byte_reg_needs_rex(&i.a);
            e.op(p66, 0, w, &[if sz == 1 { 0xF6 } else { 0xF7 }], n, &rm, force);
        }
        Shl | Shr | Sar | Rol | Ror => {
            let n = match i.op {
                Rol => 0,
                Ror => 1,
                Shl => 4,
                Shr => 5,
                _ => 7,
            };
            let rm = e.rm(&i.a);
            let force = sz == 1 && byte_reg_needs_rex(&i.a);
            match &i.b {
                Opnd::I(1) => e.op(p66, 0, w, &[if sz == 1 { 0xD0 } else { 0xD1 }], n, &rm, force),
                Opnd::I(k) => {
                    e.op(p66, 0, w, &[if sz == 1 { 0xC0 } else { 0xC1 }], n, &rm, force);
                    e.imm(*k, 1);
                }
                Opnd::R(_) => e.op(p66, 0, w, &[if sz == 1 { 0xD2 } else { 0xD3 }], n, &rm, force),
                _ => panic!("encoder: bad shift {:?}", i),
            }
        }
        Cqo => {
            if w {
                e.out.push(0x48);
            }
            e.out.push(0x99);
        }
        Setcc => {
            let rm = e.rm(&i.a);
            e.op(false, 0, false, &[0x0F, 0x90 | i.cc], 0, &rm, byte_reg_needs_rex(&i.a));
        }
        Cmov => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, 0, w, &[0x0F, 0x40 | i.cc], (d & 15) as u8, &rm, false);
        }
        Call => {
            e.out.push(0xE8);
            e.relocs.push(Reloc { off: e.out.len() as u32, kind: RelocKind::Rel32Func(i.tgt), addend: 0 });
            e.imm(0, 4);
        }
        CallInd => {
            let rm = e.rm(&i.a);
            e.op(false, 0, false, &[0xFF], 2, &rm, false);
        }
        Ret => e.out.push(0xC3),
        Syscall => e.out.extend_from_slice(&[0x0F, 0x05]),
        Ud2 => e.out.extend_from_slice(&[0x0F, 0x0B]),
        MovSd => {
            // movaps between registers; movsd / movss / movups to and from memory
            let pfx = fp_pfx(sz);
            match (&i.a, &i.b) {
                (Opnd::R(d), Opnd::R(s)) => e.op(false, 0, false, &[0x0F, 0x28], (*d & 15) as u8, &rm_reg(*s), false),
                (Opnd::R(d), Opnd::M(_)) => {
                    let rm = e.rm(&i.b);
                    e.op(false, pfx, false, &[0x0F, 0x10], (*d & 15) as u8, &rm, false);
                }
                (Opnd::M(_), Opnd::R(s)) => {
                    let rm = e.rm(&i.a);
                    e.op(false, pfx, false, &[0x0F, 0x11], (*s & 15) as u8, &rm, false);
                }
                _ => panic!("encoder: bad movsd {:?}", i),
            }
        }
        Addsd | Subsd | Mulsd | Divsd | Sqrtsd | Minsd | Maxsd => {
            let o = match i.op {
                Addsd => 0x58,
                Mulsd => 0x59,
                Subsd => 0x5C,
                Divsd => 0x5E,
                Minsd => 0x5D,
                Maxsd => 0x5F,
                _ => 0x51,
            };
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, fp_pfx(sz), false, &[0x0F, o], (d & 15) as u8, &rm, false);
        }
        Cvtf => {
            // cvtss2sd (sz 8) / cvtsd2ss (sz 4)
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, if sz == 8 { 0xF3 } else { 0xF2 }, false, &[0x0F, 0x5A], (d & 15) as u8, &rm, false);
        }
        Shufps => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, 0, false, &[0x0F, 0xC6], (d & 15) as u8, &rm, false);
            match i.c {
                Opnd::I(k) => e.imm(k, 1),
                _ => panic!("encoder: shufps without immediate"),
            }
        }
        Movlo => {
            let d = reg_of(&i.a);
            e.op(false, 0xF3, false, &[0x0F, 0x10], (d & 15) as u8, &rm_reg(reg_of(&i.b)), false);
        }
        Unpcklps => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, 0, false, &[0x0F, 0x14], (d & 15) as u8, &rm, false);
        }
        Ucomisd | Xorpd | Andpd => {
            let o = match i.op {
                Ucomisd => 0x2E,
                Xorpd => 0x57,
                _ => 0x54,
            };
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(sz == 8, 0, false, &[0x0F, o], (d & 15) as u8, &rm, false);
        }
        Cvtsi2sd => {
            // sz = integer size, sz2 = float size (4: single)
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, if i.sz2 == 4 { 0xF3 } else { 0xF2 }, w, &[0x0F, 0x2A], (d & 15) as u8, &rm, false);
        }
        Cvttsd2si => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, if i.sz2 == 4 { 0xF3 } else { 0xF2 }, w, &[0x0F, 0x2C], (d & 15) as u8, &rm, false);
        }
        MovqToX => {
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(true, 0, w, &[0x0F, 0x6E], (d & 15) as u8, &rm, false);
        }
        MovqToR => {
            let s = reg_of(&i.b);
            let rm = e.rm(&i.a);
            e.op(true, 0, w, &[0x0F, 0x7E], (s & 15) as u8, &rm, false);
        }
        RepMovsb => e.out.extend_from_slice(&[0xF3, 0xA4]),
        RepStosb => e.out.extend_from_slice(&[0xF3, 0xAA]),
        Bswap => {
            let d = (reg_of(&i.a) & 15) as u8;
            let rex = 0x40 | ((w as u8) << 3) | (d >> 3);
            if rex != 0x40 {
                e.out.push(rex);
            }
            e.out.push(0x0F);
            e.out.push(0xC8 | (d & 7));
        }
        Popcnt | Tzcnt | Lzcnt => {
            let o = match i.op {
                Popcnt => 0xB8,
                Tzcnt => 0xBC,
                _ => 0xBD,
            };
            let d = reg_of(&i.a);
            let rm = e.rm(&i.b);
            e.op(false, 0xF3, w, &[0x0F, o], (d & 15) as u8, &rm, false);
        }
        Push | Pop => {
            let r = (reg_of(&i.a) & 15) as u8;
            if r >= 8 {
                e.out.push(0x41);
            }
            e.out.push(if i.op == Push { 0x50 } else { 0x58 } | (r & 7));
        }
        Zero => {
            let r = reg_of(&i.a);
            if r >= 16 {
                e.op(false, 0, false, &[0x0F, 0x57], (r & 15) as u8, &rm_reg(r), false);
            } else {
                e.op(false, 0, false, &[0x31], (r & 15) as u8, &rm_reg(r), false);
            }
        }
        Jmp | Jcc => unreachable!(),
    }
}

fn sets_flags(op: MOp) -> bool {
    use MOp::*;
    matches!(
        op,
        Add | Sub | And | Or | Xor | Cmp | Test | Imul | Imul3 | Neg | Shl | Shr | Sar | Rol | Ror | Idiv | Div | Mul1 | Imul1 | Ucomisd | Popcnt | Tzcnt | Lzcnt | Zero | Call | CallInd | Syscall | Bswap
    )
}
fn reads_flags(op: MOp) -> bool {
    matches!(op, MOp::Jcc | MOp::Setcc | MOp::Cmov)
}

// post-allocation cleanups that depend on the final layout
fn peephole(mf: &mut MFunc, layout: &mut Vec<u32>) {
    let nb = mf.blocks.len();
    // 1. thread jumps through blocks that only contain `jmp X`
    let mut fwd: Vec<u32> = (0..nb as u32).collect();
    for b in 0..nb {
        let blk = &mf.blocks[b];
        if blk.insts.len() == 1 && blk.insts[0].op == MOp::Jmp && blk.insts[0].tgt != b as u32 {
            fwd[b] = blk.insts[0].tgt;
        }
    }
    let resolve = |mut b: u32, fwd: &Vec<u32>| {
        let mut n = 0;
        while fwd[b as usize] != b && n < 64 {
            b = fwd[b as usize];
            n += 1;
        }
        b
    };
    for b in 0..nb {
        for i in mf.blocks[b].insts.iter_mut() {
            if matches!(i.op, MOp::Jmp | MOp::Jcc) {
                i.tgt = resolve(i.tgt, &fwd);
            }
        }
    }
    // drop blocks that are no longer reachable
    {
        let mut reach = vec![false; nb];
        let mut work = vec![layout[0]];
        reach[layout[0] as usize] = true;
        while let Some(b) = work.pop() {
            for i in &mf.blocks[b as usize].insts {
                if matches!(i.op, MOp::Jmp | MOp::Jcc) && !reach[i.tgt as usize] {
                    reach[i.tgt as usize] = true;
                    work.push(i.tgt);
                }
            }
        }
        layout.retain(|b| reach[*b as usize]);
    }
    // 2. fallthrough and branch inversion
    for (li, &b) in layout.iter().enumerate() {
        let next = layout.get(li + 1).copied().unwrap_or(u32::MAX);
        let insts = &mut mf.blocks[b as usize].insts;
        let n = insts.len();
        if n >= 2 && insts[n - 1].op == MOp::Jmp && insts[n - 2].op == MOp::Jcc {
            let single_jcc = n < 3 || insts[n - 3].op != MOp::Jcc;
            if insts[n - 2].tgt == insts[n - 1].tgt && single_jcc {
                insts.remove(n - 2);
            } else if insts[n - 2].tgt == next && single_jcc {
                let f = insts[n - 1].tgt;
                insts[n - 2].cc ^= 1;
                insts[n - 2].tgt = f;
                insts.pop();
            }
        }
        let n = insts.len();
        if n >= 1 && insts[n - 1].op == MOp::Jmp && insts[n - 1].tgt == next {
            insts.pop();
        }
    }
    // 3. flag-clobbering shorter forms when flags are dead:
    //    mov r, 0 -> xor r, r ; lea r, [r + x] -> add r, x
    for b in 0..nb {
        let n = mf.blocks[b].insts.len();
        for k in 0..n {
            let i = &mf.blocks[b].insts[k];
            let zero = i.op == MOp::Mov && matches!(i.a, Opnd::R(r) if r < 16) && i.b == Opnd::I(0);
            let mut add: Option<Opnd> = None;
            if i.op == MOp::Lea {
                if let (Opnd::R(d), Opnd::M(m)) = (i.a, i.b) {
                    if m.kind == MemKind::Normal {
                        if m.base == d && m.idx == NOREG && m.disp != 0 {
                            add = Some(Opnd::I(m.disp as i64));
                        } else if m.base == d && m.idx != NOREG && m.scale == 1 && m.disp == 0 && m.idx != d {
                            add = Some(Opnd::R(m.idx));
                        } else if m.idx == d && m.scale == 1 && m.disp == 0 && m.base != NOREG && m.base != d {
                            add = Some(Opnd::R(m.base));
                        }
                    }
                }
            }
            if !zero && add.is_none() {
                continue;
            }
            let mut dead = true;
            for j in k + 1..n {
                let o = mf.blocks[b].insts[j].op;
                if reads_flags(o) {
                    dead = false;
                    break;
                }
                if sets_flags(o) {
                    break;
                }
            }
            if !dead {
                continue;
            }
            let a = i.a;
            let sz = i.sz;
            if zero {
                mf.blocks[b].insts[k] = MInst::new(MOp::Zero, 4, a, Opnd::None);
            } else if let Some(src) = add {
                mf.blocks[b].insts[k] = MInst::new(MOp::Add, sz, a, src);
            }
        }
    }
}

enum Item {
    Bytes(Vec<u8>, Vec<Reloc>),
    Jump { cc: Option<u8>, tgt: u32, long: bool },
    Align(u32),
}

pub fn emit(mf: &mut MFunc, alloc: &Alloc, layout: &[u32], fpool: &[u32]) -> Code {
    // frame layout
    let mut off = 8 * mf.out_args as i32;
    let mut slot_off = Vec::with_capacity(mf.slots.len());
    for &(size, align) in &mf.slots {
        let a = align.clamp(1, 16) as i32;
        off = (off + a - 1) / a * a;
        slot_off.push(off);
        off += size as i32;
    }
    let npush = alloc.used_callee_saved.len() as i32;
    let mut size = (off + 15) / 16 * 16;
    if (8 + 8 * npush + size) % 16 != 0 {
        size += 8;
    }
    if !mf.has_calls && off == 0 {
        size = 0;
    }
    let frame = Frame { slot_off, size, npush };
    // prologue / epilogue
    let mut pro: Vec<MInst> = Vec::new();
    for &r in &alloc.used_callee_saved {
        pro.push(MInst::new(MOp::Push, 8, Opnd::R(r), Opnd::None));
    }
    if size > 0 {
        pro.push(MInst::new(MOp::Sub, 8, Opnd::R(RSP), Opnd::I(size as i64)));
    }
    let mut layout: Vec<u32> = layout.to_vec();
    let entry = layout[0] as usize;
    let mut body = std::mem::take(&mut mf.blocks[entry].insts);
    pro.append(&mut body);
    mf.blocks[entry].insts = pro;
    for &b in layout.iter() {
        let insts = std::mem::take(&mut mf.blocks[b as usize].insts);
        let mut out = Vec::with_capacity(insts.len() + 4);
        for i in insts {
            if i.op == MOp::Ret {
                if size > 0 {
                    out.push(MInst::new(MOp::Add, 8, Opnd::R(RSP), Opnd::I(size as i64)));
                }
                for &r in alloc.used_callee_saved.iter().rev() {
                    out.push(MInst::new(MOp::Pop, 8, Opnd::R(r), Opnd::None));
                }
            }
            out.push(i);
        }
        mf.blocks[b as usize].insts = out;
    }
    peephole(mf, &mut layout);
    // encode
    let mut items: Vec<Item> = Vec::new();
    let mut block_item: Vec<usize> = vec![usize::MAX; mf.blocks.len()];
    for &b in layout.iter() {
        if mf.blocks[b as usize].align {
            items.push(Item::Align(16));
        }
        block_item[b as usize] = items.len();
        let mut enc = Enc { out: Vec::new(), relocs: Vec::new(), frame: &frame, fpool };
        for i in &mf.blocks[b as usize].insts {
            match i.op {
                MOp::Jmp | MOp::Jcc => {
                    if !enc.out.is_empty() {
                        items.push(Item::Bytes(std::mem::take(&mut enc.out), std::mem::take(&mut enc.relocs)));
                    }
                    items.push(Item::Jump { cc: if i.op == MOp::Jcc { Some(i.cc) } else { None }, tgt: i.tgt, long: false });
                }
                _ => enc_inst(&mut enc, i),
            }
        }
        if !enc.out.is_empty() {
            items.push(Item::Bytes(enc.out, enc.relocs));
        }
    }
    // relaxation
    let mut offs: Vec<u32> = vec![0; items.len() + 1];
    loop {
        let mut o = 0u32;
        for (k, it) in items.iter().enumerate() {
            offs[k] = o;
            o += match it {
                Item::Bytes(b, _) => b.len() as u32,
                Item::Jump { cc, long, .. } => match (cc.is_some(), *long) {
                    (_, false) => 2,
                    (false, true) => 5,
                    (true, true) => 6,
                },
                Item::Align(a) => align_pad(o, *a),
            };
        }
        offs[items.len()] = o;
        let mut changed = false;
        for k in 0..items.len() {
            if let Item::Jump { tgt, long, .. } = &mut items[k] {
                if !*long {
                    let t = offs[block_item[*tgt as usize]] as i64;
                    let d = t - (offs[k] as i64 + 2);
                    if !(-128..=127).contains(&d) {
                        *long = true;
                        changed = true;
                    }
                }
            }
        }
        if !changed {
            break;
        }
    }
    let mut bytes: Vec<u8> = Vec::with_capacity(offs[items.len()] as usize);
    let mut relocs: Vec<Reloc> = Vec::new();
    for (k, it) in items.iter().enumerate() {
        debug_assert_eq!(bytes.len() as u32, offs[k]);
        match it {
            Item::Bytes(b, r) => {
                for rr in r {
                    relocs.push(Reloc { off: rr.off + bytes.len() as u32, kind: rr.kind, addend: rr.addend });
                }
                bytes.extend_from_slice(b);
            }
            Item::Jump { cc, tgt, long } => {
                let t = offs[block_item[*tgt as usize]] as i64;
                if *long {
                    match cc {
                        Some(c) => {
                            bytes.push(0x0F);
                            bytes.push(0x80 | c);
                            let d = t - (offs[k] as i64 + 6);
                            bytes.extend_from_slice(&(d as i32).to_le_bytes());
                        }
                        None => {
                            bytes.push(0xE9);
                            let d = t - (offs[k] as i64 + 5);
                            bytes.extend_from_slice(&(d as i32).to_le_bytes());
                        }
                    }
                } else {
                    let d = t - (offs[k] as i64 + 2);
                    bytes.push(match cc {
                        Some(c) => 0x70 | c,
                        None => 0xEB,
                    });
                    bytes.push(d as i8 as u8);
                }
            }
            Item::Align(a) => {
                let pad = align_pad(bytes.len() as u32, *a);
                nops(&mut bytes, pad);
            }
        }
    }
    Code { bytes, relocs }
}

// padding in front of an aligned block; long paddings are not worth executing
fn align_pad(o: u32, a: u32) -> u32 {
    let p = (a - o % a) % a;
    if p > 10 {
        0
    } else {
        p
    }
}

pub fn nops(out: &mut Vec<u8>, mut n: u32) {
    const SEQ: [&[u8]; 9] = [
        &[0x90],
        &[0x66, 0x90],
        &[0x0F, 0x1F, 0x00],
        &[0x0F, 0x1F, 0x40, 0x00],
        &[0x0F, 0x1F, 0x44, 0x00, 0x00],
        &[0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00],
        &[0x0F, 0x1F, 0x80, 0x00, 0x00, 0x00, 0x00],
        &[0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00],
        &[0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00],
    ];
    while n > 0 {
        let k = n.min(9);
        out.extend_from_slice(SEQ[k as usize - 1]);
        n -= k;
    }
}
