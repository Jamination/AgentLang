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
const R11 = 11
const XMM0 = 16
const VREG0 = 32

var INT_ARGS = [6]i64{RDI, RSI, RDX, RCX, R8, R9}
var INT_RETS = [4]i64{RAX, RDX, RCX, RSI}
const NUM_FLOAT_ARGS = 8

// rbx, rbp, r12-r15
fn mir_callee_saved(r i64) bool {
    return r == 3 || r == 5 || r == 12 || r == 13 || r == 14 || r == 15
}

var CALLER_SAVED_GPR = [9]i64{RAX, RCX, RDX, RSI, RDI, R8, R9, R10, R11}

// the u128 of the float constant pool
struct Bits128 {
    lo u64
    hi u64
}

enum MemKind {
    MemKindNormal,
    MemKindGlobal,   // disp is relative to global `id`
    MemKindSlot,     // disp is relative to frame slot `id` (base is rsp)
    MemKindInArg,    // incoming stack argument `id` (base is rsp)
    MemKindOutArg,   // outgoing stack argument `id` (base is rsp)
    MemKindFConst,   // float constant pool entry `id`
}

struct Mem {
    base i64
    idx i64
    scale u8
    disp i32
    kind MemKind
    id i64
}

fn mem_new() Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: 0, kind: MemKindNormal, id: 0}
}

fn mem_slot(id i64, disp i32) Mem {
    return Mem{base: NOREG, idx: NOREG, scale: 1, disp: disp, kind: MemKindSlot, id: id}
}

enum Opnd {
    OpndNone,
    OpndR(i64),
    OpndI(i64),
    OpndM(Mem),
    // absolute address of a symbol: global (id) or function
    OpndGAddr(i64, i64),
    OpndFAddr(i64),
}

// Opnd equality (PartialEq in the Rust source)
fn eq(a Opnd, b Opnd) bool {
    match a {
        OpndNone => {
            match b {
                OpndNone => return true
                _ => return false
            }
        }
        OpndR(r) => {
            match b {
                OpndR(r2) => return r == r2
                _ => return false
            }
        }
        OpndI(i) => {
            match b {
                OpndI(i2) => return i == i2
                _ => return false
            }
        }
        OpndM(m) => {
            match b {
                OpndM(m2) => return m == m2
                _ => return false
            }
        }
        OpndGAddr(g, d) => {
            match b {
                OpndGAddr(g2, d2) => return g == g2 && d == d2
                _ => return false
            }
        }
        OpndFAddr(f) => {
            match b {
                OpndFAddr(f2) => return f == f2
                _ => return false
            }
        }
    }
}

enum MOp {
    MOpMov,
    MOpMovzx, // sz = source size, 32-bit destination
    MOpMovsx, // sz = source size, sz2 = destination size
    MOpLea,
    MOpAdd,
    MOpSub,
    MOpAnd,
    MOpOr,
    MOpXor,
    MOpCmp,
    MOpTest,
    MOpImul,
    MOpImul3,
    MOpNeg,
    MOpNot,
    MOpShl,
    MOpShr,
    MOpSar,
    MOpRol,
    MOpRor,
    MOpCqo,
    MOpIdiv,
    MOpDiv,
    MOpMul1,
    MOpImul1,
    MOpSetcc,
    MOpCmov,
    MOpJmp,
    MOpJcc,
    MOpCall,
    MOpCallInd,
    MOpRet,
    MOpSyscall,
    MOpUd2,
    MOpMovSd,
    MOpAddsd,
    MOpSubsd,
    MOpMulsd,
    MOpDivsd,
    MOpSqrtsd,
    MOpUcomisd,
    MOpXorpd,
    MOpAndpd,
    // SSE operations above take sz 8 (scalar double), 4 (scalar single) or 16 (packed single)
    MOpMinsd,
    MOpMaxsd,
    MOpCvtf,     // sz 8: single -> double, sz 4: double -> single
    MOpShufps,   // a = dst, b = src, c = immediate
    MOpUnpcklps,
    MOpMovlo, // movss xmm, xmm: replaces lane 0, keeps the rest
    MOpCvtsi2sd,
    MOpCvttsd2si,
    MOpMovqToX, // xmm <- gpr
    MOpMovqToR, // gpr <- xmm
    MOpRepMovsb,
    MOpRepStosb,
    MOpBswap,
    MOpPopcnt,
    MOpTzcnt,
    MOpLzcnt,
    MOpPush,
    MOpPop,
    MOpZero, // xor r32, r32 (clobbers flags)
}

const CC_B u8 = 2
const CC_AE u8 = 3
const CC_E u8 = 4
const CC_NE u8 = 5
const CC_BE u8 = 6
const CC_A u8 = 7
const CC_P u8 = 10
const CC_NP u8 = 11
const CC_L u8 = 12
const CC_GE u8 = 13
const CC_LE u8 = 14
const CC_G u8 = 15

struct MInst {
    op MOp
    sz u8
    sz2 u8
    cc u8
    a Opnd
    b Opnd
    c Opnd
    tgt i64
    uses Vec[i64]
    defs Vec[i64]
}

fn minst_new(op MOp, sz u8, a Opnd, b Opnd) MInst {
    return MInst{op: op, sz: sz, sz2: 0, cc: 0, a: a, b: b, c: OpndNone, tgt: 0, uses: vec[i64](), defs: vec[i64]()}
}

// an independent copy (uses and defs are not shared)
fn clone(i *MInst) MInst {
    return MInst{op: i.op, sz: i.sz, sz2: i.sz2, cc: i.cc, a: i.a, b: i.b, c: i.c, tgt: i.tgt, uses: clone(&i.uses), defs: clone(&i.defs)}
}

// a full register-to-register copy that the allocator may coalesce: (dst, src, true)
fn is_copy(self *MInst) (i64, i64, bool) {
    if self.op == MOpMov || self.op == MOpMovSd {
        match self.a {
            OpndR(d) => {
                match self.b {
                    OpndR(s) => {
                        if self.op == MOpMovSd || self.sz == 8 {
                            return (d, s, true)
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }
    return (0, 0, false)
}

struct MBlock {
    insts Vec[MInst]
    succs Vec[i64]
    depth i64
    align bool
}

struct MFunc {
    name str
    blocks Vec[MBlock] // in layout order
    vclass Vec[u8]     // class of each vreg (index = reg - VREG0): 0 = gpr, 1 = xmm
    slots Vec[(i64, i64)] // frame slots: (size, align)
    out_args i64       // number of outgoing stack argument words
    fconsts Vec[Bits128]
    has_calls bool
    wide_xmm bool // some xmm value is a vector: spill slots hold 16 bytes
}

fn new_vreg(self *MFunc, class u8) i64 {
    self.vclass.push(class)
    return VREG0 + (self.vclass.len - 1)
}

fn class(self *MFunc, r i64) u8 {
    if r < 16 {
        return 0
    } else if r < 32 {
        return 1
    } else {
        return self.vclass.buf[r - VREG0]
    }
}

fn new_slot(self *MFunc, size i64, align i64) i64 {
    self.slots.push((size, align))
    return self.slots.len - 1
}

fn mir_mem_regs(m Mem, uses *Vec[i64]) {
    if m.base != NOREG {
        uses.push(m.base)
    }
    if m.idx != NOREG {
        uses.push(m.idx)
    }
}

fn mir_opnd_uses(o Opnd, uses *Vec[i64]) {
    match o {
        OpndR(r) => uses.push(r)
        OpndM(m) => mir_mem_regs(m, uses)
        _ => {}
    }
}

// registers defined and used by an instruction (including implicit ones)
fn mir_defs_uses(i *MInst, defs *Vec[i64], uses *Vec[i64]) {
    defs.clear()
    uses.clear()
    match i.op {
        MOpMov, MOpMovzx, MOpMovsx, MOpLea, MOpMovSd, MOpCvtsi2sd, MOpCvttsd2si, MOpMovqToX, MOpMovqToR, MOpSetcc, MOpSqrtsd, MOpCvtf, MOpPopcnt, MOpTzcnt, MOpLzcnt, MOpImul3 => {
            match i.a {
                OpndR(r) => defs.push(r)
                OpndM(m) => mir_mem_regs(m, uses)
                _ => {}
            }
            mir_opnd_uses(i.b, uses)
        }
        MOpZero => {
            match i.a {
                OpndR(r) => defs.push(r)
                _ => {}
            }
        }
        MOpAdd, MOpSub, MOpAnd, MOpOr, MOpXor, MOpImul, MOpAddsd, MOpSubsd, MOpMulsd, MOpDivsd, MOpMinsd, MOpMaxsd, MOpShufps, MOpUnpcklps, MOpMovlo, MOpXorpd, MOpAndpd, MOpCmov, MOpShl, MOpShr, MOpSar, MOpRol, MOpRor => {
            match i.a {
                OpndR(r) => {
                    defs.push(r)
                    uses.push(r)
                }
                OpndM(m) => mir_mem_regs(m, uses)
                _ => {}
            }
            mir_opnd_uses(i.b, uses)
        }
        MOpNeg, MOpNot, MOpBswap => {
            match i.a {
                OpndR(r) => {
                    defs.push(r)
                    uses.push(r)
                }
                OpndM(m) => mir_mem_regs(m, uses)
                _ => {}
            }
        }
        MOpCmp, MOpTest, MOpUcomisd => {
            mir_opnd_uses(i.a, uses)
            mir_opnd_uses(i.b, uses)
        }
        MOpCqo => {
            uses.push(RAX)
            defs.push(RDX)
        }
        MOpIdiv, MOpDiv => {
            uses.push(RAX)
            uses.push(RDX)
            mir_opnd_uses(i.a, uses)
            defs.push(RAX)
            defs.push(RDX)
        }
        MOpMul1, MOpImul1 => {
            uses.push(RAX)
            mir_opnd_uses(i.a, uses)
            defs.push(RAX)
            defs.push(RDX)
        }
        MOpJmp, MOpJcc, MOpUd2 => {}
        MOpCall, MOpCallInd => {
            mir_opnd_uses(i.a, uses)
            uses.extend(i.uses.items())
            for r in CALLER_SAVED_GPR {
                defs.push(r)
            }
            for x in 0..16 {
                defs.push(XMM0 + x)
            }
        }
        MOpRet => {
            uses.extend(i.uses.items())
        }
        MOpSyscall => {
            uses.extend(i.uses.items())
            defs.push(RAX)
            defs.push(RCX)
            defs.push(R11)
        }
        MOpRepMovsb => {
            uses.push(RDI)
            uses.push(RSI)
            uses.push(RCX)
            defs.push(RDI)
            defs.push(RSI)
            defs.push(RCX)
        }
        MOpRepStosb => {
            uses.push(RDI)
            uses.push(RAX)
            uses.push(RCX)
            defs.push(RDI)
            defs.push(RCX)
        }
        MOpPush => mir_opnd_uses(i.a, uses)
        MOpPop => {
            match i.a {
                OpndR(r) => defs.push(r)
                _ => {}
            }
        }
    }
}

// The Rust `map_regs(i, f)` takes a closure; its callers either apply a lookup table or
// substitute one register, so there is one function for each use.

fn mir_map_regs_lookup(r i64, table []i64) i64 {
    if r < len(table) {
        return table[r]
    }
    return r
}

fn mir_map_regs_mo(o Opnd, table []i64) Opnd {
    match o {
        OpndR(r) => return OpndR(mir_map_regs_lookup(r, table))
        OpndM(m) => {
            mm := m
            if mm.base != NOREG {
                mm.base = mir_map_regs_lookup(mm.base, table)
            }
            if mm.idx != NOREG {
                mm.idx = mir_map_regs_lookup(mm.idx, table)
            }
            return OpndM(mm)
        }
        _ => return o
    }
}

// apply a register mapping to all register operands: register r becomes table[r] when
// r < len(table) and stays unchanged otherwise
fn mir_map_regs(i *MInst, table []i64) {
    i.a = mir_map_regs_mo(i.a, table)
    i.b = mir_map_regs_mo(i.b, table)
    i.c = mir_map_regs_mo(i.c, table)
}

fn mir_replace_reg_mo(o Opnd, from i64, to i64) Opnd {
    match o {
        OpndR(r) => {
            if r == from {
                return OpndR(to)
            }
            return o
        }
        OpndM(m) => {
            mm := m
            if mm.base != NOREG && mm.base == from {
                mm.base = to
            }
            if mm.idx != NOREG && mm.idx == from {
                mm.idx = to
            }
            return OpndM(mm)
        }
        _ => return o
    }
}

// map_regs with `|r| if r == from { to } else { r }`
fn mir_replace_reg(i *MInst, from i64, to i64) {
    i.a = mir_replace_reg_mo(i.a, from, to)
    i.b = mir_replace_reg_mo(i.b, from, to)
    i.c = mir_replace_reg_mo(i.c, from, to)
}

fn mir_count_reg_mo(o Opnd, r i64) i64 {
    match o {
        OpndR(x) => {
            if x == r {
                return 1
            }
            return 0
        }
        OpndM(m) => {
            n := 0
            if m.base != NOREG && m.base == r {
                n += 1
            }
            if m.idx != NOREG && m.idx == r {
                n += 1
            }
            return n
        }
        _ => return 0
    }
}

// number of register operand occurrences of r (the positions map_regs visits)
fn mir_count_reg(i *MInst, r i64) i64 {
    return mir_count_reg_mo(i.a, r) + mir_count_reg_mo(i.b, r) + mir_count_reg_mo(i.c, r)
}

var MIR_N64 = [16]str{"rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}
var MIR_N32 = [16]str{"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi", "r8d", "r9d", "r10d", "r11d", "r12d", "r13d", "r14d", "r15d"}
var MIR_N16 = [16]str{"ax", "cx", "dx", "bx", "sp", "bp", "si", "di", "r8w", "r9w", "r10w", "r11w", "r12w", "r13w", "r14w", "r15w"}
var MIR_N8 = [16]str{"al", "cl", "dl", "bl", "spl", "bpl", "sil", "dil", "r8b", "r9b", "r10b", "r11b", "r12b", "r13b", "r14b", "r15b"}

fn mir_reg_name(r i64, sz u8) str {
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
        1 => return MIR_N8[r]
        2 => return MIR_N16[r]
        4 => return MIR_N32[r]
        _ => return MIR_N64[r]
    }
}

fn mir_opnd_str(o Opnd, sz u8) str {
    match o {
        OpndNone => return ""
        OpndR(r) => return mir_reg_name(r, sz)
        OpndI(i) => return fmt(i)
        OpndGAddr(g, d) => return fmt("&g", g, "+", d)
        OpndFAddr(f) => return fmt("&f", f)
        OpndM(m) => {
            s := "["
            match m.kind {
                MemKindNormal => {}
                MemKindGlobal => {
                    s = fmt(s, "g", m.id, " ")
                }
                MemKindSlot => {
                    s = fmt(s, "slot", m.id, " ")
                }
                MemKindInArg => {
                    s = fmt(s, "inarg", m.id, " ")
                }
                MemKindOutArg => {
                    s = fmt(s, "outarg", m.id, " ")
                }
                MemKindFConst => {
                    s = fmt(s, "fconst", m.id, " ")
                }
            }
            if m.base != NOREG {
                s = concat(s, mir_reg_name(m.base, 8))
            }
            if m.idx != NOREG {
                s = fmt(s, "+", mir_reg_name(m.idx, 8), "*", m.scale)
            }
            if m.disp != 0 {
                // {:+}: always with a sign
                if m.disp > 0 {
                    s = concat(s, "+")
                }
                s = fmt(s, m.disp)
            }
            return concat(s, "]")
        }
    }
}

fn mir_print_mfunc(f *MFunc) str {
    s := vec[str]()
    s.push(fmt(f.name, ":\n"))
    for bi in 0..f.blocks.len {
        b := &f.blocks.buf[bi]
        s.push(fmt(".L", bi, ":  ; depth ", b.depth, " succs ", b.succs.items(), "\n"))
        for ii in 0..b.insts.len {
            i := &b.insts.buf[ii]
            // the variant name without its `MOp` prefix, as `{:?}` prints it
            line := concat("    ", to_lower(fmt(i.op)[3..]))
            match i.op {
                MOpJcc, MOpSetcc, MOpCmov => {
                    line = fmt(line, "(cc", i.cc, ")")
                }
                _ => {}
            }
            line = fmt(line, i.sz, " ")
            a := mir_opnd_str(i.a, i.sz)
            var bsz u8 = i.sz
            if i.op == MOpShl || i.op == MOpShr || i.op == MOpSar || i.op == MOpRol || i.op == MOpRor {
                bsz = 1
            }
            bs := mir_opnd_str(i.b, bsz)
            c := mir_opnd_str(i.c, i.sz)
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
                MOpJmp, MOpJcc => {
                    line = fmt(line, ".L", i.tgt)
                }
                MOpCall => {
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
