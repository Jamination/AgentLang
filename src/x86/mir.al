// Machine IR for x86-64.

const NOREG = 0xFFFFFFFF
const RAX = 0
const RCX = 1
const RDX = 2
const RSP = 4
const RSI = 6
const RDI = 7
const R8 = 8
const R9 = 9
const R10 = 10
priv const R11 = 11
const XMM0 = 16
const VREG0 = 32

INT_ARGS := [6]i64{RDI, RSI, RDX, RCX, R8, R9}
INT_RETS := [4]i64{RAX, RDX, RCX, RSI}
const NUM_FLOAT_ARGS = 8

// rbx, rbp, r12-r15
fn mir_callee_saved(r: i64) -> bool {
    return r == 3 || r == 5 || r == 12 || r == 13 || r == 14 || r == 15
}

priv CALLER_SAVED_GPR := [9]i64{RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11}

// the u128 of the float constant pool
struct Bits128 {
    lo: u64
    hi: u64
}

priv enum MemKind {
    Normal,
    Glob,   // disp is relative to global `id`
    Slot,     // disp is relative to frame slot `id` (base is rsp)
    InArg,    // incoming stack argument `id` (base is rsp)
    OutArg,   // outgoing stack argument `id` (base is rsp)
    FConst,   // float constant pool entry `id`
}

struct Mem {
    base: i64
    idx: i64
    scale: u8
    disp: i32
    kind: MemKind
    id: i64
}

fn mem_new() -> Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: Normal, id: 0}
}

fn mem_slot(id: i64, disp: i32) -> Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: disp, kind: Slot, id: id}
}

enum Opnd {
    None,
    R(i64),
    I(i64),
    M(Mem),
    // absolute address of a symbol: global (id) or function
    GAddr(i64, i64),
    FAddr(i64),
}

fn is_r(o: Opnd) -> bool {
    match o {
        R(_) => true
        _ => false
    }
}

// Opnd equality (`==` does not work on enums with data)
fn eq(a: Opnd, b: Opnd) -> bool {
    match (a, b) {
        (Opnd.None, Opnd.None) => true
        (R(r), R(r2)) => r == r2
        (I(i), I(i2)) => i == i2
        (M(m), M(m2)) => m == m2
        (GAddr(g, d), GAddr(g2, d2)) => g == g2 && d == d2
        (FAddr(f), FAddr(f2)) => f == f2
        _ => false
    }
}

enum MOp {
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
    // SSE operations above take sz 8 (scalar double), 4 (scalar single) or 16 (packed single)
    Minsd,
    Maxsd,
    Cvtf,     // sz 8: single -> double, sz 4: double -> single
    Shufps,   // a = dst, b = src, c = immediate
    Unpcklps,
    Movlo, // movss xmm, xmm: replaces lane 0, keeps the rest
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

const CC_B: u8 = 2
const CC_AE: u8 = 3
const CC_E: u8 = 4
const CC_NE: u8 = 5
const CC_BE: u8 = 6
const CC_A: u8 = 7
const CC_P: u8 = 10
const CC_NP: u8 = 11
const CC_L: u8 = 12
const CC_GE: u8 = 13
const CC_LE: u8 = 14
const CC_G: u8 = 15

struct MInst {
    op: MOp
    sz: u8
    sz2: u8
    cc: u8
    a: Opnd
    b: Opnd
    c: Opnd
    tgt: i64
    uses: Vec[i64]
    defs: Vec[i64]
}

fn minst_new(op: MOp, sz: u8, a: Opnd, b: Opnd) -> MInst {
    return MInst{op: op, sz: sz, sz2: 0, cc: 0, a: a, b: b, c: Opnd.None, tgt: 0, uses: vec[i64](), defs: vec[i64]()}
}

// a full register-to-register copy that the allocator may coalesce: (dst, src, true)
fn is_copy(self: *MInst) -> (i64, i64, bool) {
    if self.op == Mov || self.op == MovSd {
        match (&self.a, &self.b) {
            (R(d), R(s)) if self.op == MovSd || self.sz == 8 => return (d, s, true)
            _ => {}
        }
    }
    return (0, 0, false)
}

struct MBlock {
    insts: Vec[MInst]
    succs: Vec[i64]
    depth: i64
    align: bool
}

struct MFunc {
    name: str
    blocks: Vec[MBlock] // in layout order
    vclass: Vec[u8]    // class of each vreg (index = reg - VREG0): 0 = gpr, 1 = xmm
    slots: Vec[(i64, i64)] // frame slots: (size, align)
    out_args: i64      // number of outgoing stack argument words
    fconsts: Vec[Bits128]
    has_calls: bool
    wide_xmm: bool // some xmm value is a vector: spill slots hold 16 bytes
}

fn new_vreg(self: *MFunc, class: u8) -> i64 {
    self.vclass.push(class)
    return VREG0 + (self.vclass.len - 1)
}

fn class(self: *MFunc, r: i64) -> u8 {
    if r < 16 {
        return 0
    } else if r < 32 {
        return 1
    } else {
        return self.vclass[r - VREG0]
    }
}

fn new_slot(self: *MFunc, size: i64, align: i64) -> i64 {
    self.slots.push((size, align))
    return self.slots.len - 1
}

priv fn mem_regs(m: Mem, uses: *Vec[i64]) {
    if m.base != NOREG {
        uses.push(m.base)
    }
    if m.idx != NOREG {
        uses.push(m.idx)
    }
}

priv fn opnd_uses(o: Opnd, uses: *Vec[i64]) {
    match o {
        R(r) => uses.push(r)
        M(m) => mem_regs(m, uses)
        _ => {}
    }
}

// registers defined and used by an instruction (including implicit ones)
fn mir_defs_uses(i: *MInst, defs: *Vec[i64], uses: *Vec[i64]) {
    defs.clear()
    uses.clear()
    match i.op {
        Mov, Movzx, Movsx, Lea, MovSd, Cvtsi2sd, Cvttsd2si, MovqToX, MovqToR, Setcc, Sqrtsd, Cvtf, Popcnt, Tzcnt, Lzcnt, Imul3 => {
            match i.a {
                R(r) => defs.push(r)
                M(m) => mem_regs(m, uses)
                _ => {}
            }
            opnd_uses(i.b, uses)
        }
        Zero => {
            match i.a {
                R(r) => defs.push(r)
                _ => {}
            }
        }
        Add, Sub, And, Or, Xor, Imul, Addsd, Subsd, Mulsd, Divsd, Minsd, Maxsd, Shufps, Unpcklps, Movlo, Xorpd, Andpd, Cmov, Shl, Shr, Sar, Rol, Ror => {
            match i.a {
                R(r) => {
                    defs.push(r)
                    uses.push(r)
                }
                M(m) => mem_regs(m, uses)
                _ => {}
            }
            opnd_uses(i.b, uses)
        }
        Neg, Not, Bswap => {
            match i.a {
                R(r) => {
                    defs.push(r)
                    uses.push(r)
                }
                M(m) => mem_regs(m, uses)
                _ => {}
            }
        }
        Cmp, Test, Ucomisd => {
            opnd_uses(i.a, uses)
            opnd_uses(i.b, uses)
        }
        Cqo => {
            uses.push(RAX)
            defs.push(RDX)
        }
        Idiv, Div => {
            uses.push(RAX)
            uses.push(RDX)
            opnd_uses(i.a, uses)
            defs.push(RAX)
            defs.push(RDX)
        }
        Mul1, Imul1 => {
            uses.push(RAX)
            opnd_uses(i.a, uses)
            defs.push(RAX)
            defs.push(RDX)
        }
        Jmp, Jcc, Ud2 => {}
        Call, CallInd => {
            opnd_uses(i.a, uses)
            uses.extend(i.uses.items())
            for r in CALLER_SAVED_GPR {
                defs.push(r)
            }
            for x in 0..16 {
                defs.push(XMM0 + x)
            }
        }
        Ret => {
            uses.extend(i.uses.items())
        }
        Syscall => {
            uses.extend(i.uses.items())
            defs.push(RAX)
            defs.push(RCX)
            defs.push(R11)
        }
        RepMovsb => {
            uses.push(RDI)
            uses.push(RSI)
            uses.push(RCX)
            defs.push(RDI)
            defs.push(RSI)
            defs.push(RCX)
        }
        RepStosb => {
            uses.push(RDI)
            uses.push(RAX)
            uses.push(RCX)
            defs.push(RDI)
            defs.push(RCX)
        }
        Push => opnd_uses(i.a, uses)
        Pop => {
            match i.a {
                R(r) => defs.push(r)
                _ => {}
            }
        }
    }
}

// Renaming registers: the callers either apply a lookup table or substitute one register;
// there is one function for each use (a nested function cannot capture the table).

priv fn map_regs_lookup(r: i64, table: []i64) -> i64 {
    if r < len(table) {
        return table[r]
    }
    return r
}

priv fn map_regs_mo(o: Opnd, table: []i64) -> Opnd {
    match o {
        R(r) => R(map_regs_lookup(r, table))
        M(&m) => {
            if m.base != NOREG {
                m.base = map_regs_lookup(m.base, table)
            }
            if m.idx != NOREG {
                m.idx = map_regs_lookup(m.idx, table)
            }
            o
        }
        _ => o
    }
}

// apply a register mapping to all register operands: register r becomes table[r] when
// r < len(table) and stays unchanged otherwise
fn mir_map_regs(i: *MInst, table: []i64) {
    i.a = map_regs_mo(i.a, table)
    i.b = map_regs_mo(i.b, table)
    i.c = map_regs_mo(i.c, table)
}

priv fn replace_reg_mo(o: Opnd, from: i64, to: i64) -> Opnd {
    match o {
        R(r) if r == from => R(to)
        M(&m) => {
            if m.base != NOREG && m.base == from {
                m.base = to
            }
            if m.idx != NOREG && m.idx == from {
                m.idx = to
            }
            o
        }
        _ => o
    }
}

// map_regs with `|r| if r == from { to } else { r }`
fn mir_replace_reg(i: *MInst, from: i64, to: i64) {
    i.a = replace_reg_mo(i.a, from, to)
    i.b = replace_reg_mo(i.b, from, to)
    i.c = replace_reg_mo(i.c, from, to)
}

priv fn count_reg_mo(o: Opnd, r: i64) -> i64 {
    match o {
        R(x) if x == r => 1
        M(m) => {
            n := 0
            if m.base != NOREG && m.base == r {
                n += 1
            }
            if m.idx != NOREG && m.idx == r {
                n += 1
            }
            n
        }
        _ => 0
    }
}

// number of register operand occurrences of r (the positions map_regs visits)
fn mir_count_reg(i: *MInst, r: i64) -> i64 {
    return count_reg_mo(i.a, r) + count_reg_mo(i.b, r) + count_reg_mo(i.c, r)
}

priv N64 := [16]str{"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
priv N32 := [16]str{"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"}
priv N16 := [16]str{"ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"}
priv N8 := [16]str{"al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"}

priv fn reg_name(r: i64, sz: u8) -> str {
    if r == NOREG {
        return "noreg"
    }
    if r >= VREG0 {
        return fmt("v", r - VREG0)
    }
    if r >= 16 {
        return fmt("xmm", r - 16)
    }
    match sz {
        1 => N8[r]
        2 => N16[r]
        4 => N32[r]
        _ => N64[r]
    }
}

priv fn opnd_str(o: Opnd, sz: u8) -> str {
    match o {
        Opnd.None => ""
        R(r) => reg_name(r, sz)
        I(i) => fmt(i)
        GAddr(g, d) => fmt("&g", g, "+", d)
        FAddr(f) => fmt("&f", f)
        M(m) => {
            s := "["
            match m.kind {
                Normal => {}
                Glob => {
                    s = fmt(s, "g", m.id, " ")
                }
                Slot => {
                    s = fmt(s, "slot", m.id, " ")
                }
                InArg => {
                    s = fmt(s, "inarg", m.id, " ")
                }
                OutArg => {
                    s = fmt(s, "outarg", m.id, " ")
                }
                FConst => {
                    s = fmt(s, "fconst", m.id, " ")
                }
            }
            if m.base != NOREG {
                s = concat(s, reg_name(m.base, 8))
            }
            if m.idx != NOREG {
                s = fmt(s, "+", reg_name(m.idx, 8), "*", m.scale)
            }
            if m.disp != 0 {
                // {:+}: always with a sign
                if m.disp > 0 {
                    s = concat(s, "+")
                }
                s = fmt(s, m.disp)
            }
            concat(s, "]")
        }
    }
}

fn mir_print_mfunc(f: *MFunc) -> str {
    s := vec[str]()
    s.push(fmt(f.name, ":\n"))
    for bi in 0..f.blocks.len {
        b := &f.blocks[bi]
        s.push(fmt(".L", bi, ":  ; depth ", b.depth, " succs ", b.succs.items(), "\n"))
        for ii in 0..b.insts.len {
            i := &b.insts[ii]
            // the variant name without its `MOp` prefix, as `{:?}` prints it
            line := concat("    ", to_lower(fmt(i.op)[3..]))
            match i.op {
                Jcc, Setcc, Cmov => {
                    line = fmt(line, "(cc", i.cc, ")")
                }
                _ => {}
            }
            line = fmt(line, i.sz, " ")
            a := opnd_str(i.a, i.sz)
            bsz: u8 = i.sz
            if i.op == Shl || i.op == Shr || i.op == Sar || i.op == Rol || i.op == Ror {
                bsz = 1
            }
            bs := opnd_str(i.b, bsz)
            c := opnd_str(i.c, i.sz)
            parts := vec[str]()
            if len(a) != 0 {
                parts.push(a)
            }
            if len(bs) != 0 {
                parts.push(bs)
            }
            if len(c) != 0 {
                parts.push(c)
            }
            line = concat(line, join(parts.items(), ", "))
            match i.op {
                Jmp, Jcc => {
                    line = fmt(line, ".L", i.tgt)
                }
                Call => {
                    line = fmt(line, "f", i.tgt)
                }
                _ => {}
            }
            s.push(line)
            s.push("\n")
        }
    }
    return join(s.items(), "")
}
