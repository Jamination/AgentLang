// Machine IR for x86-64.

const NOREG = -1
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

// kinds of memory operands (Mem.kind)
const MK_NORMAL: u8 = 0
const MK_GLOBAL: u8 = 1 // disp is relative to global `id`
const MK_SLOT: u8 = 2   // disp is relative to frame slot `id` (base is rsp)
const MK_INARG: u8 = 3  // incoming stack argument `id` (base is rsp)
const MK_OUTARG: u8 = 4 // outgoing stack argument `id` (base is rsp)
const MK_FCONST: u8 = 5 // float constant pool entry `id`

// 20 bytes: an operand is 32, an instruction 80
struct Mem {
    base: i32 // register or NOREG
    idx: i32  // register or NOREG
    disp: i32
    id: i32
    scale: u8
    kind: u8
}

fn mem_new() -> Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MK_NORMAL, id: 0}
}

fn mem_slot(id: i64, disp: i32) -> Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: disp, kind: MK_SLOT, id: i32(id)}
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

// 80 bytes. Calls, `ret` and `syscall` keep the fixed registers they read (argument and
// result registers) in MFunc.xuses: operand b is I(start) there and sz2 the count.
struct MInst {
    op: MOp
    sz: u8
    sz2: u8
    cc: u8
    tgt: i32 // jump target block, called function, or the immediate third operand (imul3, shufps)
    a: Opnd
    b: Opnd
}

fn minst_new(op: MOp, sz: u8, a: Opnd, b: Opnd) -> MInst {
    return MInst{op: op, sz: sz, sz2: 0, cc: 0, tgt: 0, a: a, b: b}
}

// does the instruction keep a list of fixed registers in MFunc.xuses?
fn has_xuses(op: MOp) -> bool {
    return op == Call || op == CallInd || op == Ret || op == Syscall
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
    xuses: Vec[i64] // the fixed registers read by calls, `ret` and `syscall` (see MInst)
}

fn new_vreg(self: *MFunc, class: u8) -> i64 {
    // registers are kept in i32 fields and tables (Mem, isel, regalloc)
    assert self.vclass.len < 0x7FFFFFFF - VREG0, "isel: too many virtual registers in a function"
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

// a call, `ret` or `syscall` that reads the fixed registers `regs`
fn mir_with_uses(self: *MFunc, op: MOp, sz: u8, a: Opnd, regs: []i64) -> MInst {
    i := minst_new(op, sz, a, I(self.xuses.len))
    i.sz2 = u8(len(regs))
    self.xuses.extend(regs)
    return i
}

// the fixed registers read by a call, `ret` or `syscall`
fn mir_xuses(self: *MFunc, i: *MInst) -> []i64 {
    match i.b {
        I(k) => return self.xuses[k..k + i64(i.sz2)]
        _ => return nil
    }
}

// ---------- registers defined and used by an instruction ----------
// mir_decode writes the registers that instruction `i` defines and uses (including implicit
// ones) to du[p..]: du[p] = nd | nu << 8 | flags << 16, then nd defs and nu uses. With
// DU_CALL the instruction also defines the CALL_CLOBBER registers (after the nd listed
// ones); with DU_COPY it is a copy (is_copy) and du[p + 1] / du[p + 2] are its dst / src.
// The caller makes room for DU_MAX entries. Returns the position after the entry.
const DU_CALL = 1
const DU_COPY = 2
const DU_MAX = 24

CALL_CLOBBER := [25]i64{RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31}

priv fn du_mem(m: *Mem, du: []i64, q0: i64) -> i64 {
    q := q0
    if m.base != NOREG {
        du[q] = i64(m.base)
        q += 1
    }
    if m.idx != NOREG {
        du[q] = i64(m.idx)
        q += 1
    }
    return q
}

priv fn du_opnd(o: *Opnd, du: []i64, q: i64) -> i64 {
    match o {
        R(r) => {
            du[q] = r
            return q + 1
        }
        M(&m) => return du_mem(m, du, q)
        _ => return q
    }
}

fn mir_decode(mf: *MFunc, i: *MInst, du: []i64, p: i64) -> i64 {
    nd := 0
    q := p + 1
    flags := 0
    match i.op {
        Mov, Movzx, Movsx, Lea, MovSd, Cvtsi2sd, Cvttsd2si, MovqToX, MovqToR, Setcc, Sqrtsd, Cvtf, Popcnt, Tzcnt, Lzcnt, Imul3 => {
            match &i.a {
                R(r) => {
                    du[q] = r
                    q += 1
                    nd = 1
                    match &i.b {
                        R(s) => {
                            du[q] = s
                            q += 1
                            if i.op == MovSd || (i.op == Mov && i.sz == 8) {
                                flags = DU_COPY
                            }
                        }
                        M(&m) => q = du_mem(m, du, q)
                        _ => {}
                    }
                }
                M(&m) => {
                    q = du_mem(m, du, q)
                    q = du_opnd(&i.b, du, q)
                }
                _ => q = du_opnd(&i.b, du, q)
            }
        }
        Zero => {
            match &i.a {
                R(r) => {
                    du[q] = r
                    q += 1
                    nd = 1
                }
                _ => {}
            }
        }
        Add, Sub, And, Or, Xor, Imul, Addsd, Subsd, Mulsd, Divsd, Minsd, Maxsd, Shufps, Unpcklps, Movlo, Xorpd, Andpd, Cmov, Shl, Shr, Sar, Rol, Ror => {
            match &i.a {
                R(r) => {
                    du[q] = r
                    du[q + 1] = r
                    q += 2
                    nd = 1
                }
                M(&m) => q = du_mem(m, du, q)
                _ => {}
            }
            q = du_opnd(&i.b, du, q)
        }
        Neg, Not, Bswap => {
            match &i.a {
                R(r) => {
                    du[q] = r
                    du[q + 1] = r
                    q += 2
                    nd = 1
                }
                M(&m) => q = du_mem(m, du, q)
                _ => {}
            }
        }
        Cmp, Test, Ucomisd => {
            q = du_opnd(&i.a, du, q)
            q = du_opnd(&i.b, du, q)
        }
        Cqo => {
            du[q] = RDX
            du[q + 1] = RAX
            q += 2
            nd = 1
        }
        Idiv, Div => {
            du[q] = RAX
            du[q + 1] = RDX
            du[q + 2] = RAX
            du[q + 3] = RDX
            q = du_opnd(&i.a, du, q + 4)
            nd = 2
        }
        Mul1, Imul1 => {
            du[q] = RAX
            du[q + 1] = RDX
            du[q + 2] = RAX
            q = du_opnd(&i.a, du, q + 3)
            nd = 2
        }
        Jmp, Jcc, Ud2 => {}
        Call, CallInd => {
            flags = DU_CALL
            q = du_opnd(&i.a, du, q)
            for r in mf.mir_xuses(i) {
                du[q] = r
                q += 1
            }
        }
        Ret => {
            for r in mf.mir_xuses(i) {
                du[q] = r
                q += 1
            }
        }
        Syscall => {
            du[q] = RAX
            du[q + 1] = RCX
            du[q + 2] = R11
            q += 3
            nd = 3
            for r in mf.mir_xuses(i) {
                du[q] = r
                q += 1
            }
        }
        RepMovsb => {
            du[q] = RDI
            du[q + 1] = RSI
            du[q + 2] = RCX
            du[q + 3] = RDI
            du[q + 4] = RSI
            du[q + 5] = RCX
            q += 6
            nd = 3
        }
        RepStosb => {
            du[q] = RDI
            du[q + 1] = RCX
            du[q + 2] = RDI
            du[q + 3] = RAX
            du[q + 4] = RCX
            q += 5
            nd = 2
        }
        Push => q = du_opnd(&i.a, du, q)
        Pop => {
            match &i.a {
                R(r) => {
                    du[q] = r
                    q += 1
                    nd = 1
                }
                _ => {}
            }
        }
    }
    du[p] = nd | ((q - p - 1 - nd) << 8) | (flags << 16)
    return q
}

// Renaming registers: the callers either apply a lookup table or substitute one register;
// there is one function for each use (a nested function cannot capture the table).

priv fn map_regs_lookup(r: i64, table: []i64) -> i64 {
    if r < len(table) {
        return table[r]
    }
    return r
}

priv fn map_regs_mo(o: *Opnd, table: []i64) {
    match o {
        R(&r) => *r = map_regs_lookup(*r, table)
        M(&m) => {
            if m.base != NOREG {
                m.base = i32(map_regs_lookup(i64(m.base), table))
            }
            if m.idx != NOREG {
                m.idx = i32(map_regs_lookup(i64(m.idx), table))
            }
        }
        _ => {}
    }
}

// apply a register mapping to all register operands: register r becomes table[r] when
// r < len(table) and stays unchanged otherwise
fn mir_map_regs(i: *MInst, table: []i64) {
    map_regs_mo(&i.a, table)
    map_regs_mo(&i.b, table)
}

priv fn replace_reg_mo(o: *Opnd, from: i64, to: i64) {
    match o {
        R(&r) => {
            if *r == from {
                *r = to
            }
        }
        M(&m) => {
            if m.base != NOREG && i64(m.base) == from {
                m.base = i32(to)
            }
            if m.idx != NOREG && i64(m.idx) == from {
                m.idx = i32(to)
            }
        }
        _ => {}
    }
}

// map_regs with `|r| if r == from { to } else { r }`
fn mir_replace_reg(i: *MInst, from: i64, to: i64) {
    replace_reg_mo(&i.a, from, to)
    replace_reg_mo(&i.b, from, to)
}

priv fn count_reg_mo(o: *Opnd, r: i64) -> i64 {
    match o {
        R(x) if x == r => return 1
        M(&m) => {
            n := 0
            if m.base != NOREG && i64(m.base) == r {
                n += 1
            }
            if m.idx != NOREG && i64(m.idx) == r {
                n += 1
            }
            return n
        }
        _ => return 0
    }
}

// number of register operand occurrences of r (the positions map_regs visits)
fn mir_count_reg(i: *MInst, r: i64) -> i64 {
    return count_reg_mo(&i.a, r) + count_reg_mo(&i.b, r)
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
                MK_GLOBAL => {
                    s = fmt(s, "g", m.id, " ")
                }
                MK_SLOT => {
                    s = fmt(s, "slot", m.id, " ")
                }
                MK_INARG => {
                    s = fmt(s, "inarg", m.id, " ")
                }
                MK_OUTARG => {
                    s = fmt(s, "outarg", m.id, " ")
                }
                MK_FCONST => {
                    s = fmt(s, "fconst", m.id, " ")
                }
                _ => {}
            }
            if m.base != NOREG {
                s = concat(s, reg_name(i64(m.base), 8))
            }
            if m.idx != NOREG {
                s = fmt(s, "+", reg_name(i64(m.idx), 8), "*", m.scale)
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
            line := concat("    ", to_lower(fmt(i.op)))
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
            bs := if has_xuses(i.op) { "" } else { opnd_str(i.b, bsz) }
            c := if i.op == Imul3 || i.op == Shufps { fmt(i.tgt) } else { "" }
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
