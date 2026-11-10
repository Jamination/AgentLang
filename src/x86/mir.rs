// Machine IR for x86-64.
use std::fmt::Write;

pub type Reg = u32;
pub const NOREG: Reg = u32::MAX;
pub const RAX: Reg = 0;
pub const RCX: Reg = 1;
pub const RDX: Reg = 2;
pub const RSP: Reg = 4;
pub const RSI: Reg = 6;
pub const RDI: Reg = 7;
pub const R8: Reg = 8;
pub const R9: Reg = 9;
pub const R10: Reg = 10;
pub const R11: Reg = 11;
pub const XMM0: Reg = 16;
pub const VREG0: Reg = 32;

pub const INT_ARGS: [Reg; 6] = [RDI, RSI, RDX, RCX, R8, R9];
pub const INT_RETS: [Reg; 4] = [RAX, RDX, RCX, RSI];
pub const NUM_FLOAT_ARGS: usize = 8;
// rbx, rbp, r12-r15
pub fn callee_saved(r: Reg) -> bool {
    matches!(r, 3 | 5 | 12 | 13 | 14 | 15)
}
pub const CALLER_SAVED_GPR: [Reg; 9] = [RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MemKind {
    Normal,
    Global,   // disp is relative to global `id`
    Slot,     // disp is relative to frame slot `id` (base is rsp)
    InArg,    // incoming stack argument `id` (base is rsp)
    OutArg,   // outgoing stack argument `id` (base is rsp)
    FConst,   // float constant pool entry `id`
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Mem {
    pub base: Reg,
    pub idx: Reg,
    pub scale: u8,
    pub disp: i32,
    pub kind: MemKind,
    pub id: u32,
}

impl Mem {
    pub fn new() -> Mem {
        Mem { base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKind::Normal, id: 0 }
    }
    pub fn slot(id: u32, disp: i32) -> Mem {
        Mem { base: NOREG, idx: NOREG, scale: 1, disp, kind: MemKind::Slot, id }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Opnd {
    None,
    R(Reg),
    I(i64),
    M(Mem),
    // absolute address of a symbol: global (id) or function
    GAddr(u32, i32),
    FAddr(u32),
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MOp {
    Mov,
    Movzx, // sz = source size, 32-bit destination
    Movsx, // sz = source size, sz2 = destination size
    Lea,
    Add,
    Sub,
    And,
    Or,
    Xor,
    Cmp,
    Test,
    Imul,
    Imul3,
    Neg,
    Not,
    Shl,
    Shr,
    Sar,
    Rol,
    Ror,
    Cqo,
    Idiv,
    Div,
    Mul1,
    Imul1,
    Setcc,
    Cmov,
    Jmp,
    Jcc,
    Call,
    CallInd,
    Ret,
    Syscall,
    Ud2,
    MovSd,
    Addsd,
    Subsd,
    Mulsd,
    Divsd,
    Sqrtsd,
    Ucomisd,
    Xorpd,
    Andpd,
    Cvtsi2sd,
    Cvttsd2si,
    MovqToX, // xmm <- gpr
    MovqToR, // gpr <- xmm
    RepMovsb,
    RepStosb,
    Bswap,
    Popcnt,
    Tzcnt,
    Lzcnt,
    Push,
    Pop,
    Zero, // xor r32, r32 (clobbers flags)
}

pub mod cc {
    pub const B: u8 = 2;
    pub const AE: u8 = 3;
    pub const E: u8 = 4;
    pub const NE: u8 = 5;
    pub const BE: u8 = 6;
    pub const A: u8 = 7;
    pub const P: u8 = 10;
    pub const NP: u8 = 11;
    pub const L: u8 = 12;
    pub const GE: u8 = 13;
    pub const LE: u8 = 14;
    pub const G: u8 = 15;
}

#[derive(Clone, Debug)]
pub struct MInst {
    pub op: MOp,
    pub sz: u8,
    pub sz2: u8,
    pub cc: u8,
    pub a: Opnd,
    pub b: Opnd,
    pub c: Opnd,
    pub tgt: u32,
    pub uses: Vec<Reg>,
    pub defs: Vec<Reg>,
}

impl MInst {
    pub fn new(op: MOp, sz: u8, a: Opnd, b: Opnd) -> MInst {
        MInst { op, sz, sz2: 0, cc: 0, a, b, c: Opnd::None, tgt: 0, uses: Vec::new(), defs: Vec::new() }
    }
    // a full register-to-register copy that the allocator may coalesce
    pub fn is_copy(&self) -> Option<(Reg, Reg)> {
        match (self.op, self.a, self.b) {
            (MOp::Mov, Opnd::R(d), Opnd::R(s)) if self.sz == 8 => Some((d, s)),
            (MOp::MovSd, Opnd::R(d), Opnd::R(s)) => Some((d, s)),
            _ => None,
        }
    }
}

pub struct MBlock {
    pub insts: Vec<MInst>,
    pub succs: Vec<u32>,
    pub depth: u32,
    pub align: bool,
}

pub struct MFunc {
    pub name: String,
    pub blocks: Vec<MBlock>, // in layout order
    pub vclass: Vec<u8>,     // class of each vreg (index = reg - VREG0): 0 = gpr, 1 = xmm
    pub slots: Vec<(u32, u32)>, // frame slots: (size, align)
    pub out_args: u32,       // number of outgoing stack argument words
    pub fconsts: Vec<u64>,
    pub has_calls: bool,
}

impl MFunc {
    pub fn new_vreg(&mut self, class: u8) -> Reg {
        self.vclass.push(class);
        VREG0 + (self.vclass.len() - 1) as Reg
    }
    pub fn class(&self, r: Reg) -> u8 {
        if r < 16 {
            0
        } else if r < 32 {
            1
        } else {
            self.vclass[(r - VREG0) as usize]
        }
    }
    pub fn new_slot(&mut self, size: u32, align: u32) -> u32 {
        self.slots.push((size, align));
        (self.slots.len() - 1) as u32
    }
}

fn mem_regs(m: &Mem, uses: &mut Vec<Reg>) {
    if m.base != NOREG {
        uses.push(m.base);
    }
    if m.idx != NOREG {
        uses.push(m.idx);
    }
}

fn opnd_uses(o: &Opnd, uses: &mut Vec<Reg>) {
    match o {
        Opnd::R(r) => uses.push(*r),
        Opnd::M(m) => mem_regs(m, uses),
        _ => {}
    }
}

// registers defined and used by an instruction (including implicit ones)
pub fn defs_uses(i: &MInst, defs: &mut Vec<Reg>, uses: &mut Vec<Reg>) {
    defs.clear();
    uses.clear();
    use MOp::*;
    match i.op {
        Mov | Movzx | Movsx | Lea | MovSd | Cvtsi2sd | Cvttsd2si | MovqToX | MovqToR | Setcc | Sqrtsd | Popcnt | Tzcnt | Lzcnt | Imul3 => {
            match &i.a {
                Opnd::R(r) => defs.push(*r),
                Opnd::M(m) => mem_regs(m, uses),
                _ => {}
            }
            opnd_uses(&i.b, uses);
        }
        Zero => {
            if let Opnd::R(r) = i.a {
                defs.push(r);
            }
        }
        Add | Sub | And | Or | Xor | Imul | Addsd | Subsd | Mulsd | Divsd | Xorpd | Andpd | Cmov | Shl | Shr | Sar | Rol | Ror => {
            match &i.a {
                Opnd::R(r) => {
                    defs.push(*r);
                    uses.push(*r);
                }
                Opnd::M(m) => mem_regs(m, uses),
                _ => {}
            }
            opnd_uses(&i.b, uses);
        }
        Neg | Not | Bswap => match &i.a {
            Opnd::R(r) => {
                defs.push(*r);
                uses.push(*r);
            }
            Opnd::M(m) => mem_regs(m, uses),
            _ => {}
        },
        Cmp | Test | Ucomisd => {
            opnd_uses(&i.a, uses);
            opnd_uses(&i.b, uses);
        }
        Cqo => {
            uses.push(RAX);
            defs.push(RDX);
        }
        Idiv | Div => {
            uses.push(RAX);
            uses.push(RDX);
            opnd_uses(&i.a, uses);
            defs.push(RAX);
            defs.push(RDX);
        }
        Mul1 | Imul1 => {
            uses.push(RAX);
            opnd_uses(&i.a, uses);
            defs.push(RAX);
            defs.push(RDX);
        }
        Jmp | Jcc | Ud2 => {}
        Call | CallInd => {
            opnd_uses(&i.a, uses);
            uses.extend(i.uses.iter().copied());
            defs.extend(CALLER_SAVED_GPR.iter().copied());
            for x in 0..16 {
                defs.push(XMM0 + x);
            }
        }
        Ret => {
            uses.extend(i.uses.iter().copied());
        }
        Syscall => {
            uses.extend(i.uses.iter().copied());
            defs.push(RAX);
            defs.push(RCX);
            defs.push(R11);
        }
        RepMovsb => {
            uses.extend([RDI, RSI, RCX]);
            defs.extend([RDI, RSI, RCX]);
        }
        RepStosb => {
            uses.extend([RDI, RAX, RCX]);
            defs.extend([RDI, RCX]);
        }
        Push => opnd_uses(&i.a, uses),
        Pop => {
            if let Opnd::R(r) = i.a {
                defs.push(r);
            }
        }
    }
}

// apply a register mapping to all register operands
pub fn map_regs(i: &mut MInst, f: &mut dyn FnMut(Reg) -> Reg) {
    fn mo(o: &mut Opnd, f: &mut dyn FnMut(Reg) -> Reg) {
        match o {
            Opnd::R(r) => *r = f(*r),
            Opnd::M(m) => {
                if m.base != NOREG {
                    m.base = f(m.base);
                }
                if m.idx != NOREG {
                    m.idx = f(m.idx);
                }
            }
            _ => {}
        }
    }
    mo(&mut i.a, f);
    mo(&mut i.b, f);
    mo(&mut i.c, f);
}

pub fn reg_name(r: Reg, sz: u8) -> String {
    if r == NOREG {
        return "noreg".into();
    }
    if r >= VREG0 {
        return format!("v{}", r - VREG0);
    }
    if r >= 16 {
        return format!("xmm{}", r - 16);
    }
    const N64: [&str; 16] = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"];
    const N32: [&str; 16] = ["eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"];
    const N16: [&str; 16] = ["ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"];
    const N8: [&str; 16] = ["al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"];
    match sz {
        1 => N8[r as usize].into(),
        2 => N16[r as usize].into(),
        4 => N32[r as usize].into(),
        _ => N64[r as usize].into(),
    }
}

fn opnd_str(o: &Opnd, sz: u8) -> String {
    match o {
        Opnd::None => String::new(),
        Opnd::R(r) => reg_name(*r, sz),
        Opnd::I(i) => format!("{}", i),
        Opnd::GAddr(g, d) => format!("&g{}+{}", g, d),
        Opnd::FAddr(f) => format!("&f{}", f),
        Opnd::M(m) => {
            let mut s = String::from("[");
            match m.kind {
                MemKind::Normal => {}
                MemKind::Global => {
                    let _ = write!(s, "g{} ", m.id);
                }
                MemKind::Slot => {
                    let _ = write!(s, "slot{} ", m.id);
                }
                MemKind::InArg => {
                    let _ = write!(s, "inarg{} ", m.id);
                }
                MemKind::OutArg => {
                    let _ = write!(s, "outarg{} ", m.id);
                }
                MemKind::FConst => {
                    let _ = write!(s, "fconst{} ", m.id);
                }
            }
            if m.base != NOREG {
                let _ = write!(s, "{}", reg_name(m.base, 8));
            }
            if m.idx != NOREG {
                let _ = write!(s, "+{}*{}", reg_name(m.idx, 8), m.scale);
            }
            if m.disp != 0 {
                let _ = write!(s, "{:+}", m.disp);
            }
            s.push(']');
            s
        }
    }
}

pub fn print_mfunc(f: &MFunc) -> String {
    let mut s = String::new();
    let _ = writeln!(s, "{}:", f.name);
    for (bi, b) in f.blocks.iter().enumerate() {
        let _ = writeln!(s, ".L{}:  ; depth {} succs {:?}", bi, b.depth, b.succs);
        for i in &b.insts {
            let mut line = format!("    {:?}", i.op).to_lowercase();
            match i.op {
                MOp::Jcc | MOp::Setcc | MOp::Cmov => {
                    let _ = write!(line, "(cc{})", i.cc);
                }
                _ => {}
            }
            let _ = write!(line, "{} ", i.sz);
            let xs = matches!(i.op, MOp::MovSd | MOp::Addsd | MOp::Subsd | MOp::Mulsd | MOp::Divsd | MOp::Sqrtsd | MOp::Ucomisd);
            let _ = xs;
            let a = opnd_str(&i.a, i.sz);
            let b = opnd_str(&i.b, if matches!(i.op, MOp::Shl | MOp::Shr | MOp::Sar | MOp::Rol | MOp::Ror) { 1 } else { i.sz });
            let c = opnd_str(&i.c, i.sz);
            let parts: Vec<String> = [a, b, c].into_iter().filter(|x| !x.is_empty()).collect();
            let _ = write!(line, "{}", parts.join(", "));
            match i.op {
                MOp::Jmp | MOp::Jcc => {
                    let _ = write!(line, ".L{}", i.tgt);
                }
                MOp::Call => {
                    let _ = write!(line, "f{}", i.tgt);
                }
                _ => {}
            }
            let _ = writeln!(s, "{}", line);
        }
    }
    s
}
