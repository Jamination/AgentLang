// Machine IR for AArch64 (--target linux-arm64): three-address instructions with virtual
// registers, made by src/arm64/isel.al, coloured by src/arm64/regalloc.al and encoded by
// src/arm64/emit.al.
//
// Registers: 0-30 are x0-x30, A_SP (31) the stack pointer, 32-63 the SIMD and floating-point
// registers v0-v31 (A_V0 + k), A_ZR the zero register (no register of the allocator), and
// A_VREG0 and above the virtual registers. Reserved (never allocated): x16 and x17 (scratch of
// the encoder: large offsets, addresses of globals, atomic loops), x18 (the platform register:
// macOS uses it), x29 (frame pointer: every function with a frame keeps the frame record
// there, so a stack walk follows x29), x30 (link register) and v31 (scratch of the vector
// sequences of the encoder).

const A_SP = 31
const A_V0 = 32
const A_ZR = 64
const A_VREG0 = 65
const A_X16 = 16
const A_X17 = 17
const A_FP = 29
const A_LR = 30
const A_VTMP = 63 // v31

// AAPCS64: arguments in x0-x7 and v0-v7, results in x0-x3 and v0-v3 (as the x86-64 back end:
// up to four of each), the rest of the arguments on the stack in 8-byte words (a vector in
// two words)
const A_NARG = 8
const A_NRET_INT = 4

// x19-x28 are preserved across calls; v8-v15 (their low 64 bits) too, which a function saves
// when it writes them (calls are still taken to clobber every SIMD register)
fn a_callee_saved(r: i64) -> bool {
    return r >= 19 && r <= 28
}

fn a_fp_saved(r: i64) -> bool {
    return r >= A_V0 + 8 && r <= A_V0 + 15
}

// kinds of memory operands (AInst.k of loads and stores)
const AK_NORMAL: u8 = 0 // [n + imm] or [n + (m << sh)]
const AK_SLOT: u8 = 2   // frame slot `id`, + imm
const AK_INARG: u8 = 3  // incoming stack argument word `id` (-1: the saved link register)
const AK_OUTARG: u8 = 4 // outgoing stack argument word `id`

enum AOp {
    Mov,     // d = n (sz 8: a copy the allocator may coalesce; sz 4: the low 32 bits, zero-extended)
    MovI,    // d = imm
    FMov,    // d = n, all 128 bits (a copy)
    FZero,   // d = 0 (all lanes)
    AddR,    // d = n op (m shifted: k = A64_LSL / LSR / ASR, sh = amount); sz 4 or 8
    SubR,
    AndR,
    OrrR,
    EorR,
    BicR,
    AddI,    // d = n op imm (any imm: the encoder splits or loads it)
    SubI,
    AndI,
    OrrI,
    EorI,
    CmpR,    // flags of n - m
    CmpI,    // flags of n - imm
    TstI,    // flags of n & imm
    Lslv,    // d = n shifted by m (modulo the size)
    Lsrv,
    Asrv,
    Rorv,
    LslI,    // d = n shifted by imm
    LsrI,
    AsrI,
    RorI,
    Mul,     // d = n * m
    Msub,    // d = a - n * m
    Smulh,   // the upper 64 bits of n * m
    Umulh,
    Smull,   // d (64 bits) = n * m (32 bits each)
    Umull,
    Sdiv,
    Udiv,
    Neg,     // d = -n
    Mvn,     // d = ~n
    Sxtb,    // d = sign or zero extension of n; sz: the size of d (4 or 8)
    Sxth,
    Sxtw,
    Uxtb,
    Uxth,
    Csel,    // d = cc ? n : m
    Cset,    // d = cc ? 1 : 0
    Clz,
    Rbit,
    Rev,     // byte reversal of sz bytes
    Ldr,     // d = memory, sz 1 / 2 / 4 / 8 bytes zero-extended (loads of 1 and 2 bytes: to 32 bits)
    Ldrs,    // d = memory, sz 1 / 2 / 4 bytes sign-extended to 64 bits
    Str,     // memory = a (sz bytes)
    FLdr,    // d = memory, sz 4 / 8 / 16
    FStr,    // memory = a
    AdrG,    // d = the address of global id, + imm
    LdrG,    // d = the 8 bytes at global id (an import slot: ADRP + LDR)
    Tlv,     // macOS: x0 (d) = the thread block, from the thread-local variable descriptor (a call of
             // its thunk, which preserves every register but x0, x16, x17 and x30)
    AdrF,    // d = the address of function id
    AdrS,    // d = the address of a memory operand (frame slot, incoming argument)
    FConst,  // d = float constant pool entry id (sz 4 / 8 / 16)
    Mrs,     // d = the thread pointer (TPIDR_EL0)
    B,       // to block id
    Bcc,     // to block id if cc
    Cbz,     // to block id if n == 0 (sz 4 / 8)
    Cbnz,
    Bl,      // call of function id; fixed argument registers in xuses (imm: start, sh: count)
    Blr,     // call of n
    Ret,     // fixed result registers in xuses
    TailB,   // sibling call: the epilogue, then a branch to function id (-1: to x9); xuses as Bl
    Svc,     // system call: x8 and x0-x5 in xuses, result in x0; cc 1: clone of a thread
    Brk,     // trap
    DivTrap, // traps (BRK #1, SIGTRAP) if n is 0: the division fault of x86-64, also unchecked (sz 4 / 8)
    Ldar,    // d = [n], acquire (sz 1 / 2 / 4 / 8)
    Stlr,    // [n] = a, release
    AtSwap,  // d = [n]; [n] = m (a loop of exclusive accesses)
    AtAdd,   // d = [n]; [n] = d + m
    AtCas,   // d = [n]; if d == m (sz bytes): [n] = a
    Dmb,     // full barrier
    Fadd,   // d = n op m; sz 4 (single), 8 (double), 16 (four single lanes)
    Fsub,
    Fmul,
    Fdiv,
    VMin,    // four lanes: d = n < m ? n : m (lane by lane)
    VMax,    // d = n > m ? n : m
    Fsqrt,   // d = op n
    Fneg,
    Fabs,
    Fcmp,    // flags of n vs m (sz 4 / 8)
    Fcsel,   // d = cc ? n : m (sz 4 / 8)
    Fcvt,    // d = n converted; sz: the size of d (4: double -> single, 8: single -> double)
    Scvtf,   // d (float, sz 4 / 8) = n (integer, k: 4 / 8 bytes)
    Fcvtzs,  // d (integer, sz 4 / 8) = n (float, k: 4 / 8 bytes), towards zero
    FmovToV, // d (s or d register, sz 4 / 8) = the bits of n
    FmovToX, // d = the bits of n (sz 4 / 8)
    DupV,    // d.4s = n.s[sh] in every lane
    DupS,    // d = n.s[sh] (the other lanes zero)
    Ins,     // d.s[sh] = n.s[k], the other lanes of d stay (d is read and written)
    Shuf,    // d = the shufps of n and m with the immediate imm: lanes 0, 1 from n, 2, 3 from m
    Cnt,     // d = the number of one bits of n (sz 8: all 64)
    MemCopy, // copies a bytes from m to n, forwards; n, m and a are changed
    MemFill, // fills a bytes at n with the byte m; n and a are changed
}

// 48 bytes
struct AInst {
    op: AOp
    sz: u8
    cc: u8
    sh: u8
    k: u8
    d: i32
    n: i32
    m: i32
    a: i32
    id: i32
    loc: i32 // the source location (Inst.loc) of the IR instruction it was selected for, 0: none
    imm: i64
}

fn ainst(op: AOp, sz: u8, d: i64, n: i64, m: i64) -> AInst {
    return AInst{op: op, sz: sz, d: i32(d), n: i32(n), m: i32(m), a: i32(NOREG)}
}

struct ABlock {
    insts: Vec[AInst]
    succs: Vec[i64]
    depth: i64
}

struct AFunc {
    name: str
    blocks: Vec[ABlock] // indexed by IR block
    vclass: Vec[u8]     // 0 general, 1 SIMD
    slots: Vec[(i64, i64)]
    out_args: i64
    fconsts: Vec[Bits128]
    has_calls: bool
    save_all: bool
    xuses: Vec[i64]
}

fn a_new_vreg(self: *AFunc, class: u8) -> i64 {
    assert self.vclass.len < 0x7FFFFFFF - A_VREG0, "isel: too many virtual registers in a function"
    self.vclass.push(class)
    return A_VREG0 + (self.vclass.len - 1)
}

fn a_class(self: *AFunc, r: i64) -> u8 {
    if r < A_V0 { 0 } else if r < A_ZR { 1 } else if r == A_ZR { 0 } else { self.vclass[r - A_VREG0] }
}

fn a_new_slot(self: *AFunc, size: i64, align: i64) -> i64 {
    assert self.slots.len < 0x7FFFFFFF, "isel: too many frame slots in a function"
    self.slots.push((size, align))
    return self.slots.len - 1
}

// a call, `ret` or `svc` that reads the fixed registers `regs`
fn a_with_uses(self: *AFunc, op: AOp, regs: []i64) -> AInst {
    i := ainst(op, 8, NOREG, NOREG, NOREG)
    i.imm = self.xuses.len
    i.sh = u8(len(regs))
    self.xuses.extend(regs)
    return i
}

fn a_fixed_uses(self: *AFunc, i: *AInst) -> []i64 {
    return self.xuses[i.imm..i.imm + i64(i.sh)]
}

fn a_is_mem(op: AOp) -> bool {
    return op == Ldr || op == Ldrs || op == Str || op == FLdr || op == FStr || op == AdrS
}

// a register-to-register copy that the allocator may coalesce: (dst, src, true)
fn a_is_copy(i: *AInst) -> (i64, i64, bool) {
    if (i.op == Mov && i.sz == 8) || i.op == FMov {
        return (i64(i.d), i64(i.n), true)
    }
    return (0, 0, false)
}

// ---------- registers defined and used ----------
// The same format as mir_decode (src/x86/mir.al): du[p] = nd | nu << 8 | flags << 16, then the
// nd defined and nu used registers. DU_CALL: the instruction also defines A_CALL_CLOBBER;
// DU_COPY: a copy, du[p + 1] its destination and du[p + 2] its source. The zero register and sp
// are never listed.
const A_CALL_CLOBBER = [52]i64{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17,
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63}

priv fn put(du: []i64, q: i64, r: i32) -> i64 {
    if r == NOREG || r == A_ZR || r == A_SP {
        return q
    }
    du[q] = i64(r)
    return q + 1
}

fn a_decode(mf: *AFunc, i: *AInst, du: []i64, p: i64) -> i64 {
    q := p + 1
    flags := 0
    nd := 0
    match i.op {
        Str, FStr, Stlr => {}
        CmpR, CmpI, TstI, Fcmp, B, Bcc, Cbz, Cbnz, Bl, Blr, Ret, TailB, Svc, Brk, DivTrap, Dmb, MemCopy, MemFill => {}
        _ => {
            q2 := put(du, q, i.d)
            nd = q2 - q
            q = q2
        }
    }
    match i.op {
        Bl, Blr => {
            flags = DU_CALL
            q = put(du, q, i.n)
            q += copy(du[q..], mf.a_fixed_uses(i))
        }
        Ret, TailB => q += copy(du[q..], mf.a_fixed_uses(i))
        Svc => {
            // x0 is the result (and the first argument)
            du[q] = 0
            q += 1
            nd = 1
            q += copy(du[q..], mf.a_fixed_uses(i))
        }
        Ins => {
            q = put(du, q, i.d)
            q = put(du, q, i.n)
        }
        AtSwap, AtAdd, AtCas => {
            // the loop writes d before it reads n, m and a for the last time: they are listed
            // as defined too (with their own value), so that d gets a register of its own
            q = put(du, q, i.n)
            q = put(du, q, i.m)
            q = put(du, q, i.a)
            nd = q - p - 1
            q = put(du, q, i.n)
            q = put(du, q, i.m)
            q = put(du, q, i.a)
        }
        MemCopy, MemFill => {
            // (the registers the loop changes are defined and used)
            q = put(du, q, i.n)
            if i.op == MemCopy {
                q = put(du, q, i.m)
            }
            q = put(du, q, i.a)
            nd = q - p - 1
            q = put(du, q, i.n)
            q = put(du, q, i.m)
            q = put(du, q, i.a)
        }
        _ => {
            if (i.op == Mov && i.sz == 8 && i.n != A_ZR && i.d != A_SP && i.n != A_SP) || i.op == FMov {
                flags = DU_COPY
            }
            q = put(du, q, i.n)
            q = put(du, q, i.m)
            q = put(du, q, i.a)
        }
    }
    du[p] = nd | ((q - p - 1 - nd) << 8) | (flags << 16)
    return q
}

// renames the registers of i: r becomes table[r] for a virtual register (r < len(table))
fn a_map_regs(i: *AInst, table: []i64) {
    fn one(r: *i32, table: []i64) {
        if *r >= A_VREG0 && i64(*r) < len(table) {
            *r = i32(table[*r])
        }
    }
    one(&i.d, table)
    one(&i.n, table)
    one(&i.m, table)
    one(&i.a, table)
}

fn a_replace_reg(i: *AInst, from: i64, to: i64) {
    if i64(i.d) == from {
        i.d = i32(to)
    }
    if i64(i.n) == from {
        i.n = i32(to)
    }
    if i64(i.m) == from {
        i.m = i32(to)
    }
    if i64(i.a) == from {
        i.a = i32(to)
    }
}

// ---------- printing (--emit-asm, ALC_DEBUG=mir) ----------
priv fn rn(r: i32, sz: u8) -> str {
    if r == NOREG {
        return "_"
    }
    if r == A_ZR {
        return if sz == 8 { "xzr" } else { "wzr" }
    }
    if r == A_SP {
        return "sp"
    }
    if r >= A_VREG0 {
        return fmt("v", r - A_VREG0)
    }
    if r >= A_V0 {
        return fmt("q", r - A_V0)
    }
    return fmt(if sz == 8 { "x" } else { "w" }, r)
}

fn a_print(f: *AFunc, order: []i64) -> str {
    s := vec[str]()
    s.push(fmt(f.name, ":\n"))
    for b in order {
        blk := &f.blocks[b]
        s.push(fmt(".L", b, ":  ; depth ", blk.depth, " succs ", blk.succs.items(), "\n"))
        for i in blk.insts {
            line := fmt("    ", to_lower(fmt(i.op)))
            if i.sz != 0 {
                line = fmt(line, ".", i.sz)
            }
            parts := vec[str]()
            sz := if i.sz == 8 { u8(8) } else { u8(4) }
            for r in [4]i32{i.d, i.n, i.m, i.a} {
                if r != NOREG {
                    parts.push(rn(r, sz))
                }
            }
            if i.imm != 0 || i.op == MovI || i.op == AddI || i.op == SubI || i.op == CmpI {
                parts.push(fmt("#", i.imm))
            }
            match i.op {
                B, Bcc, Cbz, Cbnz => parts.push(fmt(".L", i.id))
                Bl => parts.push(fmt("f", i.id))
                TailB => parts.push(if i.id >= 0 { fmt("f", i.id) } else { "x9" })
                AdrG, LdrG => parts.push(fmt("g", i.id))
                AdrF => parts.push(fmt("f", i.id))
                FConst => parts.push(fmt("c", i.id))
                _ => {}
            }
            if a_is_mem(i.op) && i.k != AK_NORMAL {
                parts.push(fmt("[k", i.k, " ", i.id, "]"))
            }
            if i.op == Bcc || i.op == Csel || i.op == Cset || i.op == Fcsel {
                parts.push(fmt("cc", i.cc))
            }
            s.push(fmt(line, " ", join(parts.items(), ", "), "\n"))
        }
    }
    return join(s.items(), "")
}
