// AArch64 instruction encodings: one function per instruction form, each returning the 32-bit
// word. Pure functions without dependencies on the rest of the compiler, so that
// tests/arm64/enc.al checks them against known encodings word by word.
//
// Registers are the 5-bit numbers of the encoding: 0-30, and 31, which is sp or the zero
// register depending on the form (the comment of each function says which). sf: 1 for the
// 64-bit form (X registers), 0 for the 32-bit one (W registers).

// condition codes
const A64_EQ = 0
const A64_NE = 1
const A64_HS = 2 // carry set: unsigned >=
const A64_LO = 3 // unsigned <
const A64_MI = 4
const A64_PL = 5
const A64_VS = 6
const A64_VC = 7
const A64_HI = 8 // unsigned >
const A64_LS = 9 // unsigned <=
const A64_GE = 10
const A64_LT = 11
const A64_GT = 12
const A64_LE = 13
const A64_AL = 14

// shift kinds of the shifted-register forms
const A64_LSL = 0
const A64_LSR = 1
const A64_ASR = 2
const A64_ROR = 3

fn a64_invert(cc: i64) -> i64 {
    return cc ^ 1
}

priv fn w(x: i64) -> u32 {
    return u32(x & 0xFFFF_FFFF)
}

priv fn r5(r: i64) -> i64 {
    assert r >= 0 && r < 32, "a64: register number out of range"
    return r
}

// ADD/SUB (immediate): rd, rn may be sp; imm12 0..4095, shifted left by 12 if sh
fn a64_add_imm(sf: i64, sub: bool, setflags: bool, rd: i64, rn: i64, imm12: i64, sh: bool) -> u32 {
    assert imm12 >= 0 && imm12 < 4096, "a64: add immediate out of range"
    op := 0x11000000 | (if sub { 0x40000000 } else { 0 }) | (if setflags { 0x20000000 } else { 0 })
    return w(op | sf << 31 | (if sh { 1 << 22 } else { 0 }) | imm12 << 10 | r5(rn) << 5 | r5(rd))
}

// ADD/SUB (shifted register): 31 is the zero register
fn a64_add_reg(sf: i64, sub: bool, setflags: bool, rd: i64, rn: i64, rm: i64, shift: i64, amount: i64) -> u32 {
    assert shift < 3 && amount >= 0 && amount < 32 + 32 * sf, "a64: bad shift"
    op := 0x0B000000 | (if sub { 0x40000000 } else { 0 }) | (if setflags { 0x20000000 } else { 0 })
    return w(op | sf << 31 | shift << 22 | r5(rm) << 16 | amount << 10 | r5(rn) << 5 | r5(rd))
}

// ADD/SUB (extended register, 64-bit, UXTX #0): rd and rn may be sp, rm is a register
fn a64_add_ext(sub: bool, rd: i64, rn: i64, rm: i64) -> u32 {
    op := if sub { 0xCB200000 } else { 0x8B200000 }
    return w(op | r5(rm) << 16 | 3 << 13 | r5(rn) << 5 | r5(rd))
}

// logical (shifted register): opc 0 AND, 1 ORR, 2 EOR, 3 ANDS; n: the inverted forms (BIC,
// ORN, EON, BICS). 31 is the zero register.
fn a64_logic_reg(sf: i64, opc: i64, n: bool, rd: i64, rn: i64, rm: i64, shift: i64, amount: i64) -> u32 {
    return w(0x0A000000 | sf << 31 | opc << 29 | shift << 22 | (if n { 1 << 21 } else { 0 }) | r5(rm) << 16 | amount << 10 | r5(rn) << 5 | r5(rd))
}

// The N:immr:imms fields of a logical immediate for the value k of width 32 or 64 bits, or -1
// if k cannot be one (all zeros, all ones, or not a rotated run of ones repeated in elements of
// 2, 4, 8, 16, 32 or 64 bits).
fn a64_bitmask(k: i64, width: i64) -> i64 {
    v := u64(k)
    if width == 32 {
        v = (v & 0xFFFF_FFFF) | (v << 32)
    }
    if v == 0 || v == ~u64(0) {
        return -1
    }
    // the element size: the smallest that repeats
    size: u64 = 64
    while size > 2 {
        h := size / 2
        mask := (u64(1) << h) - 1
        if (v & mask) != ((v >> h) & mask) {
            break
        }
        size = h
    }
    mask := if size == 64 { ~u64(0) } else { (u64(1) << size) - 1 }
    e := v & mask
    // rotate the element right until it is a run of ones starting at bit 0
    ones := i64(popcnt(e))
    rot := 0
    // find a rotation r with ror(e, r) == (1 << ones) - 1
    want := if ones == 64 { ~u64(0) } else { (u64(1) << u64(ones)) - 1 }
    found := false
    for r in 0..i64(size) {
        x := if r == 0 { e } else { ((e >> u64(r)) | (e << (size - u64(r)))) & mask }
        if x == want {
            rot = r
            found = true
            break
        }
    }
    if !found {
        return -1
    }
    // immr: the rotation right that turns the run into the element; imms: size code and ones
    immr := (i64(size) - rot) % i64(size)
    nbit := if size == 64 { 1 } else { 0 }
    imms := match size {
        64 => 0
        32 => 0
        16 => 0x20
        8 => 0x30
        4 => 0x38
        _ => 0x3C
    }
    imms |= ones - 1
    if width == 32 && nbit == 1 {
        return -1
    }
    return nbit << 12 | immr << 6 | (imms & 0x3F)
}

// logical (immediate): opc 0 AND, 1 ORR, 2 EOR, 3 ANDS; nrs from a64_bitmask. rd may be sp
// for AND/ORR/EOR, rn is a register (31: the zero register)
fn a64_logic_imm(sf: i64, opc: i64, rd: i64, rn: i64, nrs: i64) -> u32 {
    assert nrs >= 0, "a64: not a logical immediate"
    return w(0x12000000 | sf << 31 | opc << 29 | nrs << 10 | r5(rn) << 5 | r5(rd))
}

// MOVN (opc 0), MOVZ (2), MOVK (3): imm16 at bit position 16 * hw
fn a64_movw(sf: i64, opc: i64, rd: i64, imm16: i64, hw: i64) -> u32 {
    assert imm16 >= 0 && imm16 < 0x10000 && hw >= 0 && hw < 2 + 2 * sf, "a64: bad move-wide"
    return w(0x12800000 | sf << 31 | opc << 29 | hw << 21 | imm16 << 5 | r5(rd))
}

// bitfield moves: opc 0 SBFM, 1 BFM, 2 UBFM
fn a64_bfm(sf: i64, opc: i64, rd: i64, rn: i64, immr: i64, imms: i64) -> u32 {
    return w(0x13000000 | sf << 31 | opc << 29 | sf << 22 | immr << 16 | imms << 10 | r5(rn) << 5 | r5(rd))
}

fn a64_lsl_imm(sf: i64, rd: i64, rn: i64, s: i64) -> u32 {
    bits := 32 + 32 * sf
    return a64_bfm(sf, 2, rd, rn, (bits - s) % bits, bits - 1 - s)
}

fn a64_lsr_imm(sf: i64, rd: i64, rn: i64, s: i64) -> u32 {
    return a64_bfm(sf, 2, rd, rn, s, 31 + 32 * sf)
}

fn a64_asr_imm(sf: i64, rd: i64, rn: i64, s: i64) -> u32 {
    return a64_bfm(sf, 0, rd, rn, s, 31 + 32 * sf)
}

// EXTR; ROR (immediate) is EXTR rd, rn, rn, #s
fn a64_extr(sf: i64, rd: i64, rn: i64, rm: i64, lsb: i64) -> u32 {
    return w(0x13800000 | sf << 31 | sf << 22 | r5(rm) << 16 | lsb << 10 | r5(rn) << 5 | r5(rd))
}

// data processing, two sources: opcode 2 UDIV, 3 SDIV, 8 LSLV, 9 LSRV, 10 ASRV, 11 RORV
fn a64_dp2(sf: i64, opcode: i64, rd: i64, rn: i64, rm: i64) -> u32 {
    return w(0x1AC00000 | sf << 31 | r5(rm) << 16 | opcode << 10 | r5(rn) << 5 | r5(rd))
}

// data processing, one source: opcode 0 RBIT, 1 REV16, 2 REV (32-bit) / REV32 (64-bit),
// 3 REV (64-bit), 4 CLZ
fn a64_dp1(sf: i64, opcode: i64, rd: i64, rn: i64) -> u32 {
    return w(0x5AC00000 | sf << 31 | opcode << 10 | r5(rn) << 5 | r5(rd))
}

// MADD (sub false) / MSUB: rd = ra +/- rn * rm
fn a64_madd(sf: i64, sub: bool, rd: i64, rn: i64, rm: i64, ra: i64) -> u32 {
    return w(0x1B000000 | sf << 31 | r5(rm) << 16 | (if sub { 1 << 15 } else { 0 }) | r5(ra) << 10 | r5(rn) << 5 | r5(rd))
}

// SMULH (signed) / UMULH: the upper 64 bits of the 128-bit product
fn a64_mulh(signed: bool, rd: i64, rn: i64, rm: i64) -> u32 {
    return w((if signed { 0x9B400000 } else { 0x9BC00000 }) | r5(rm) << 16 | 31 << 10 | r5(rn) << 5 | r5(rd))
}

// SMULL (signed) / UMULL: the 64-bit product of two 32-bit registers
fn a64_mull(signed: bool, rd: i64, rn: i64, rm: i64) -> u32 {
    return w((if signed { 0x9B200000 } else { 0x9BA00000 }) | r5(rm) << 16 | 31 << 10 | r5(rn) << 5 | r5(rd))
}

// conditional select: op 0 CSEL, 1 CSINC, 2 CSINV, 3 CSNEG
fn a64_csel(sf: i64, op: i64, rd: i64, rn: i64, rm: i64, cc: i64) -> u32 {
    base := match op {
        0 => 0x1A800000
        1 => 0x1A800400
        2 => 0x5A800000
        _ => 0x5A800400
    }
    return w(base | sf << 31 | r5(rm) << 16 | cc << 12 | r5(rn) << 5 | r5(rd))
}

// CSET rd, cc
fn a64_cset(sf: i64, rd: i64, cc: i64) -> u32 {
    return a64_csel(sf, 1, rd, 31, 31, a64_invert(cc))
}

// loads and stores, unsigned scaled offset: size 0-3 (1 << size bytes), opc 0 STR, 1 LDR,
// 2 LDRS to 64 bits, 3 LDRS to 32 bits; off a multiple of the size, below 4096 * size. rn may
// be sp.
fn a64_ldst_uimm(size: i64, opc: i64, rt: i64, rn: i64, off: i64) -> u32 {
    scale := 1 << size
    assert off >= 0 && off % scale == 0 && off / scale < 4096, "a64: load/store offset out of range"
    return w(0x39000000 | size << 30 | opc << 22 | (off / scale) << 10 | r5(rn) << 5 | r5(rt))
}

// unscaled signed 9-bit offset (LDUR / STUR forms)
fn a64_ldst_simm9(size: i64, opc: i64, rt: i64, rn: i64, off: i64) -> u32 {
    assert off >= -256 && off < 256, "a64: unscaled offset out of range"
    return w(0x38000000 | size << 30 | opc << 22 | (off & 0x1FF) << 12 | r5(rn) << 5 | r5(rt))
}

// register offset: [rn, rm, lsl #size] if scaled, else [rn, rm]
fn a64_ldst_reg(size: i64, opc: i64, rt: i64, rn: i64, rm: i64, scaled: bool) -> u32 {
    return w(0x38200800 | size << 30 | opc << 22 | r5(rm) << 16 | 3 << 13 | (if scaled { 1 << 12 } else { 0 }) | r5(rn) << 5 | r5(rt))
}

// SIMD and floating-point loads and stores: bytes 4 (s), 8 (d) or 16 (q); the same three
// addressing forms
priv fn fp_size_opc(bytes: i64, load: bool) -> (i64, i64) {
    return match bytes {
        4 => (2, if load { 1 } else { 0 })
        8 => (3, if load { 1 } else { 0 })
        _ => (0, if load { 3 } else { 2 })
    }
}

fn a64_fldst_uimm(bytes: i64, load: bool, rt: i64, rn: i64, off: i64) -> u32 {
    size, opc := fp_size_opc(bytes, load)
    assert off >= 0 && off % bytes == 0 && off / bytes < 4096, "a64: load/store offset out of range"
    return w(0x3D000000 | size << 30 | opc << 22 | (off / bytes) << 10 | r5(rn) << 5 | r5(rt))
}

fn a64_fldst_simm9(bytes: i64, load: bool, rt: i64, rn: i64, off: i64) -> u32 {
    size, opc := fp_size_opc(bytes, load)
    assert off >= -256 && off < 256, "a64: unscaled offset out of range"
    return w(0x3C000000 | size << 30 | opc << 22 | (off & 0x1FF) << 12 | r5(rn) << 5 | r5(rt))
}

fn a64_fldst_reg(bytes: i64, load: bool, rt: i64, rn: i64, rm: i64, scaled: bool) -> u32 {
    size, opc := fp_size_opc(bytes, load)
    return w(0x3C200800 | size << 30 | opc << 22 | r5(rm) << 16 | 3 << 13 | (if scaled { 1 << 12 } else { 0 }) | r5(rn) << 5 | r5(rt))
}

// load / store pair of X registers (fp: of D registers): mode 1 post-index, 2 signed offset,
// 3 pre-index; off a multiple of 8 in -512..504
fn a64_ldstp(fp: bool, load: bool, mode: i64, rt: i64, rt2: i64, rn: i64, off: i64) -> u32 {
    assert off % 8 == 0 && off >= -512 && off < 512, "a64: pair offset out of range"
    opc := if fp { 0x6C000000 } else { 0xA8000000 }
    return w(opc | mode << 23 | (if load { 1 << 22 } else { 0 }) | ((off / 8) & 0x7F) << 15 | r5(rt2) << 10 | r5(rn) << 5 | r5(rt))
}

// B / BL: words is the distance in instructions
fn a64_b(link: bool, words: i64) -> u32 {
    assert words >= -(1 << 25) && words < (1 << 25), "a64: branch out of range"
    return w((if link { 0x94000000 } else { 0x14000000 }) | (words & 0x3FFFFFF))
}

fn a64_bcond(cc: i64, words: i64) -> u32 {
    assert words >= -(1 << 18) && words < (1 << 18), "a64: conditional branch out of range"
    return w(0x54000000 | (words & 0x7FFFF) << 5 | cc)
}

// CBZ / CBNZ
fn a64_cbz(sf: i64, nz: bool, rt: i64, words: i64) -> u32 {
    assert words >= -(1 << 18) && words < (1 << 18), "a64: conditional branch out of range"
    return w((if nz { 0x35000000 } else { 0x34000000 }) | sf << 31 | (words & 0x7FFFF) << 5 | r5(rt))
}

// BR (op 0), BLR (1), RET (2)
fn a64_br(op: i64, rn: i64) -> u32 {
    base := match op {
        0 => 0xD61F0000
        1 => 0xD63F0000
        _ => 0xD65F0000
    }
    return w(base | r5(rn) << 5)
}

fn a64_svc(imm: i64) -> u32 {
    return w(0xD4000001 | imm << 5)
}

fn a64_brk(imm: i64) -> u32 {
    return w(0xD4200000 | imm << 5)
}

const A64_NOP: u32 = 0xD503201F
const A64_DMB_ISH: u32 = 0xD5033BBF

// MRS rt, TPIDR_EL0 / MSR TPIDR_EL0, rt
fn a64_mrs_tpidr(rt: i64) -> u32 {
    return w(0xD53BD040 | r5(rt))
}

fn a64_msr_tpidr(rt: i64) -> u32 {
    return w(0xD51BD040 | r5(rt))
}

// ADRP rd, pages (the distance in 4 KiB pages); ADR rd, bytes
fn a64_adrp(rd: i64, pages: i64) -> u32 {
    assert pages >= -(1 << 20) && pages < (1 << 20), "a64: adrp out of range"
    return w(0x90000000 | (pages & 3) << 29 | ((pages >> 2) & 0x7FFFF) << 5 | r5(rd))
}

fn a64_adr(rd: i64, bytes: i64) -> u32 {
    assert bytes >= -(1 << 20) && bytes < (1 << 20), "a64: adr out of range"
    return w(0x10000000 | (bytes & 3) << 29 | ((bytes >> 2) & 0x7FFFF) << 5 | r5(rd))
}

// exclusive and acquire / release accesses of 1 << size bytes: LDAXR, STLXR (status in rs),
// LDAR, STLR
fn a64_ldaxr(size: i64, rt: i64, rn: i64) -> u32 {
    return w(0x085FFC00 | size << 30 | r5(rn) << 5 | r5(rt))
}

fn a64_stlxr(size: i64, rs: i64, rt: i64, rn: i64) -> u32 {
    return w(0x0800FC00 | size << 30 | r5(rs) << 16 | r5(rn) << 5 | r5(rt))
}

fn a64_ldar(size: i64, rt: i64, rn: i64) -> u32 {
    return w(0x08DFFC00 | size << 30 | r5(rn) << 5 | r5(rt))
}

fn a64_stlr(size: i64, rt: i64, rn: i64) -> u32 {
    return w(0x089FFC00 | size << 30 | r5(rn) << 5 | r5(rt))
}

// ---------- floating point and SIMD ----------
// ftype: 0 single, 1 double

// opcode 0 FMUL, 1 FDIV, 2 FADD, 3 FSUB, 4 FMAX, 5 FMIN
fn a64_fp2(ftype: i64, opcode: i64, rd: i64, rn: i64, rm: i64) -> u32 {
    return w(0x1E200800 | ftype << 22 | r5(rm) << 16 | opcode << 12 | r5(rn) << 5 | r5(rd))
}

// opcode 0 FMOV, 1 FABS, 2 FNEG, 3 FSQRT, 4 FCVT to single, 5 FCVT to double
fn a64_fp1(ftype: i64, opcode: i64, rd: i64, rn: i64) -> u32 {
    return w(0x1E204000 | ftype << 22 | opcode << 15 | r5(rn) << 5 | r5(rd))
}

// FCMP rn, rm
fn a64_fcmp(ftype: i64, rn: i64, rm: i64) -> u32 {
    return w(0x1E202000 | ftype << 22 | r5(rm) << 16 | r5(rn) << 5)
}

fn a64_fcsel(ftype: i64, rd: i64, rn: i64, rm: i64, cc: i64) -> u32 {
    return w(0x1E200C00 | ftype << 22 | r5(rm) << 16 | cc << 12 | r5(rn) << 5 | r5(rd))
}

// FMOV between a general register and a floating-point one: to_fp moves the bits of the
// general register into the s (sf 0) or d (sf 1) register
fn a64_fmov_gen(sf: i64, to_fp: bool, rd: i64, rn: i64) -> u32 {
    base := if sf == 1 { 0x9E660000 } else { 0x1E260000 }
    return w(base | (if to_fp { 1 << 16 } else { 0 }) | r5(rn) << 5 | r5(rd))
}

// SCVTF fd, rn (sf: the integer is 64-bit)
fn a64_scvtf(sf: i64, ftype: i64, rd: i64, rn: i64) -> u32 {
    return w(0x1E220000 | sf << 31 | ftype << 22 | r5(rn) << 5 | r5(rd))
}

// FCVTZS rd, fn
fn a64_fcvtzs(sf: i64, ftype: i64, rd: i64, rn: i64) -> u32 {
    return w(0x1E380000 | sf << 31 | ftype << 22 | r5(rn) << 5 | r5(rd))
}

// vector operations on four single lanes (.4s): op 0 FADD, 1 FSUB, 2 FMUL, 3 FDIV, 4 FMAX,
// 5 FMIN, 6 FCMGT (rd = rn > rm, lane masks)
fn a64_vfp2(op: i64, rd: i64, rn: i64, rm: i64) -> u32 {
    base := match op {
        0 => 0x4E20D400
        1 => 0x4EA0D400
        2 => 0x6E20DC00
        3 => 0x6E20FC00
        4 => 0x4E20F400
        5 => 0x4EA0F400
        _ => 0x6EA0E400
    }
    return w(base | r5(rm) << 16 | r5(rn) << 5 | r5(rd))
}

// .4s: op 0 FABS, 1 FNEG, 2 FSQRT
fn a64_vfp1(op: i64, rd: i64, rn: i64) -> u32 {
    base := match op {
        0 => 0x4EA0F800
        1 => 0x6EA0F800
        _ => 0x6EA1F800
    }
    return w(base | r5(rn) << 5 | r5(rd))
}

// ORR vd.16b, vn.16b, vm.16b (MOV vd.16b, vn.16b with rm = rn)
fn a64_vorr(rd: i64, rn: i64, rm: i64) -> u32 {
    return w(0x4EA01C00 | r5(rm) << 16 | r5(rn) << 5 | r5(rd))
}

// BSL vd.16b, vn.16b, vm.16b: rd = (rd & rn) | (~rd & rm)
fn a64_bsl(rd: i64, rn: i64, rm: i64) -> u32 {
    return w(0x6E601C00 | r5(rm) << 16 | r5(rn) << 5 | r5(rd))
}

// DUP vd.4s, vn.s[lane]
fn a64_dup4s(rd: i64, rn: i64, lane: i64) -> u32 {
    return w(0x4E000400 | (lane << 3 | 4) << 16 | r5(rn) << 5 | r5(rd))
}

// DUP sd, vn.s[lane] (MOV sd, vn.s[lane]): lane into a scalar, the rest of vd zeroed
fn a64_dups(rd: i64, rn: i64, lane: i64) -> u32 {
    return w(0x5E000400 | (lane << 3 | 4) << 16 | r5(rn) << 5 | r5(rd))
}

// INS vd.s[i], vn.s[j] (MOV vd.s[i], vn.s[j]): the other lanes of vd stay
fn a64_ins_s(rd: i64, i: i64, rn: i64, j: i64) -> u32 {
    return w(0x6E000400 | (i << 3 | 4) << 16 | (j << 2) << 11 | r5(rn) << 5 | r5(rd))
}

// MOVI vd.2d, #0
fn a64_movi_zero(rd: i64) -> u32 {
    return w(0x6F00E400 | r5(rd))
}

// CNT vd.8b, vn.8b; ADDV bd, vn.8b
fn a64_cnt8b(rd: i64, rn: i64) -> u32 {
    return w(0x0E205800 | r5(rn) << 5 | r5(rd))
}

fn a64_addv8b(rd: i64, rn: i64) -> u32 {
    return w(0x0E31B800 | r5(rn) << 5 | r5(rd))
}
