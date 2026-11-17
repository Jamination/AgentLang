// The AArch64 encoder of the arm64 back end (src/arm64/enc.al) against known encodings: each
// row is an instruction as a disassembler (GNU objdump, llvm-objdump) prints it and the word it
// prints for it. No machine here runs arm64 code, so this table is what checks the encoder
// instruction by instruction.
use "../../src/arm64/enc.al"

struct Row {
    text: str
    want: u32
    got: u32
}

fn check(rows: []Row) -> bool {
    ok := true
    for r in rows {
        if r.got != r.want {
            print(fmt("  ", r.text, ": got ", hex(u64(r.got), 8), ", expected ", hex(u64(r.want), 8)))
            ok = false
        }
    }
    return ok
}

const SP = 31
const ZR = 31

test "arm64 integer arithmetic" {
    assert check([]Row{
        Row{"add x0, x0, #1", 0x91000400, a64_add_imm(1, false, false, 0, 0, 1, false)},
        Row{"add x0, x1, #4095", 0x913ffc20, a64_add_imm(1, false, false, 0, 1, 4095, false)},
        Row{"add x0, x1, #1, lsl #12", 0x91400420, a64_add_imm(1, false, false, 0, 1, 1, true)},
        Row{"mov x29, sp", 0x910003fd, a64_add_imm(1, false, false, 29, SP, 0, false)},
        Row{"sub sp, sp, #16", 0xd10043ff, a64_add_imm(1, true, false, SP, SP, 16, false)},
        Row{"cmp x1, #0", 0xf100003f, a64_add_imm(1, true, true, ZR, 1, 0, false)},
        Row{"cmp x0, x1", 0xeb01001f, a64_add_reg(1, true, true, ZR, 0, 1, A64_LSL, 0)},
        Row{"cmp w0, w1", 0x6b01001f, a64_add_reg(0, true, true, ZR, 0, 1, A64_LSL, 0)},
        Row{"add x0, x1, x2", 0x8b020020, a64_add_reg(1, false, false, 0, 1, 2, A64_LSL, 0)},
        Row{"add x0, x1, x2, lsl #3", 0x8b020c20, a64_add_reg(1, false, false, 0, 1, 2, A64_LSL, 3)},
        Row{"sub x0, x1, x2", 0xcb020020, a64_add_reg(1, true, false, 0, 1, 2, A64_LSL, 0)},
        Row{"neg x0, x1", 0xcb0103e0, a64_add_reg(1, true, false, 0, ZR, 1, A64_LSL, 0)},
        Row{"add x0, sp, x16", 0x8b3063e0, a64_add_ext(false, 0, SP, 16)},
        Row{"mul x0, x1, x2", 0x9b027c20, a64_madd(1, false, 0, 1, 2, ZR)},
        Row{"madd x0, x1, x2, x3", 0x9b020c20, a64_madd(1, false, 0, 1, 2, 3)},
        Row{"msub x0, x1, x2, x3", 0x9b028c20, a64_madd(1, true, 0, 1, 2, 3)},
        Row{"sdiv x0, x1, x2", 0x9ac20c20, a64_dp2(1, 3, 0, 1, 2)},
        Row{"udiv x0, x1, x2", 0x9ac20820, a64_dp2(1, 2, 0, 1, 2)},
        Row{"sdiv w0, w1, w2", 0x1ac20c20, a64_dp2(0, 3, 0, 1, 2)},
        Row{"lsl x0, x1, x2", 0x9ac22020, a64_dp2(1, 8, 0, 1, 2)},
        Row{"lsr x0, x1, x2", 0x9ac22420, a64_dp2(1, 9, 0, 1, 2)},
        Row{"asr x0, x1, x2", 0x9ac22820, a64_dp2(1, 10, 0, 1, 2)},
        Row{"ror x0, x1, x2", 0x9ac22c20, a64_dp2(1, 11, 0, 1, 2)},
        Row{"smulh x0, x1, x2", 0x9b427c20, a64_mulh(true, 0, 1, 2)},
        Row{"umulh x0, x1, x2", 0x9bc27c20, a64_mulh(false, 0, 1, 2)},
        Row{"smull x0, w1, w2", 0x9b227c20, a64_mull(true, 0, 1, 2)},
        Row{"umull x0, w1, w2", 0x9ba27c20, a64_mull(false, 0, 1, 2)},
        Row{"clz x0, x1", 0xdac01020, a64_dp1(1, 4, 0, 1)},
        Row{"rbit x0, x1", 0xdac00020, a64_dp1(1, 0, 0, 1)},
        Row{"rev x0, x1", 0xdac00c20, a64_dp1(1, 3, 0, 1)},
        Row{"rev w0, w1", 0x5ac00820, a64_dp1(0, 2, 0, 1)},
        Row{"rev16 w0, w1", 0x5ac00420, a64_dp1(0, 1, 0, 1)},
        Row{"csel x0, x1, x2, eq", 0x9a820020, a64_csel(1, 0, 0, 1, 2, A64_EQ)},
        Row{"cset w0, eq", 0x1a9f17e0, a64_cset(0, 0, A64_EQ)},
        Row{"cset x0, lt", 0x9a9fa7e0, a64_cset(1, 0, A64_LT)},
    })
}

test "arm64 logical, moves and bitfields" {
    assert check([]Row{
        Row{"mov x0, x1", 0xaa0103e0, a64_logic_reg(1, 1, false, 0, ZR, 1, A64_LSL, 0)},
        Row{"mov w0, w1", 0x2a0103e0, a64_logic_reg(0, 1, false, 0, ZR, 1, A64_LSL, 0)},
        Row{"and x0, x1, x2", 0x8a020020, a64_logic_reg(1, 0, false, 0, 1, 2, A64_LSL, 0)},
        Row{"orr x0, x1, x2", 0xaa020020, a64_logic_reg(1, 1, false, 0, 1, 2, A64_LSL, 0)},
        Row{"eor x0, x1, x2", 0xca020020, a64_logic_reg(1, 2, false, 0, 1, 2, A64_LSL, 0)},
        Row{"mvn x0, x1", 0xaa2103e0, a64_logic_reg(1, 1, true, 0, ZR, 1, A64_LSL, 0)},
        Row{"tst x0, x1", 0xea01001f, a64_logic_reg(1, 3, false, ZR, 0, 1, A64_LSL, 0)},
        Row{"and x0, x1, #0xff", 0x92401c20, a64_logic_imm(1, 0, 0, 1, a64_bitmask(0xff, 64))},
        Row{"and w0, w1, #0xff", 0x12001c20, a64_logic_imm(0, 0, 0, 1, a64_bitmask(0xff, 32))},
        Row{"mov x0, #0x5555555555555555", 0xb200f3e0, a64_logic_imm(1, 1, 0, ZR, a64_bitmask(0x5555555555555555, 64))},
        Row{"and x0, x1, #0xfffffffffffffff0", 0x927cec20, a64_logic_imm(1, 0, 0, 1, a64_bitmask(-16, 64))},
        Row{"mov x0, #0", 0xd2800000, a64_movw(1, 2, 0, 0, 0)},
        Row{"mov w0, #1", 0x52800020, a64_movw(0, 2, 0, 1, 0)},
        Row{"movk x0, #0x1234, lsl #16", 0xf2a24680, a64_movw(1, 3, 0, 0x1234, 1)},
        Row{"mov x0, #-1", 0x92800000, a64_movw(1, 0, 0, 0, 0)},
        Row{"lsl x0, x1, #3", 0xd37df020, a64_lsl_imm(1, 0, 1, 3)},
        Row{"lsr x0, x1, #3", 0xd343fc20, a64_lsr_imm(1, 0, 1, 3)},
        Row{"asr x0, x1, #3", 0x9343fc20, a64_asr_imm(1, 0, 1, 3)},
        Row{"lsl w0, w1, #3", 0x531d7020, a64_lsl_imm(0, 0, 1, 3)},
        Row{"lsr w0, w1, #3", 0x53037c20, a64_lsr_imm(0, 0, 1, 3)},
        Row{"sxtb x0, w1", 0x93401c20, a64_bfm(1, 0, 0, 1, 0, 7)},
        Row{"sxth x0, w1", 0x93403c20, a64_bfm(1, 0, 0, 1, 0, 15)},
        Row{"sxtw x0, w1", 0x93407c20, a64_bfm(1, 0, 0, 1, 0, 31)},
        Row{"uxtb w0, w1", 0x53001c20, a64_bfm(0, 2, 0, 1, 0, 7)},
        Row{"uxth w0, w1", 0x53003c20, a64_bfm(0, 2, 0, 1, 0, 15)},
        Row{"ror x0, x1, #3", 0x93c10c20, a64_extr(1, 0, 1, 1, 3)},
    })
    // values that are not logical immediates
    assert a64_bitmask(0, 64) == -1 && a64_bitmask(-1, 64) == -1 && a64_bitmask(0x1234, 64) == -1
    assert a64_bitmask(0xFFFF_FFFF, 32) == -1 && a64_bitmask(5, 64) == -1
}

test "arm64 loads, stores and branches" {
    assert check([]Row{
        Row{"ldr x0, [x1]", 0xf9400020, a64_ldst_uimm(3, 1, 0, 1, 0)},
        Row{"ldr x0, [x1, #8]", 0xf9400420, a64_ldst_uimm(3, 1, 0, 1, 8)},
        Row{"ldr w0, [x1, #4]", 0xb9400420, a64_ldst_uimm(2, 1, 0, 1, 4)},
        Row{"ldrb w0, [x1]", 0x39400020, a64_ldst_uimm(0, 1, 0, 1, 0)},
        Row{"ldrh w0, [x1, #2]", 0x79400420, a64_ldst_uimm(1, 1, 0, 1, 2)},
        Row{"ldrsb x0, [x1]", 0x39800020, a64_ldst_uimm(0, 2, 0, 1, 0)},
        Row{"ldrsw x0, [x1]", 0xb9800020, a64_ldst_uimm(2, 2, 0, 1, 0)},
        Row{"str x0, [x1]", 0xf9000020, a64_ldst_uimm(3, 0, 0, 1, 0)},
        Row{"str w0, [sp, #12]", 0xb9000fe0, a64_ldst_uimm(2, 0, 0, SP, 12)},
        Row{"strb w0, [x1]", 0x39000020, a64_ldst_uimm(0, 0, 0, 1, 0)},
        Row{"ldr x0, [x1, x2, lsl #3]", 0xf8627820, a64_ldst_reg(3, 1, 0, 1, 2, true)},
        Row{"ldr x0, [x1, x2]", 0xf8626820, a64_ldst_reg(3, 1, 0, 1, 2, false)},
        Row{"ldur x0, [x29, #-8]", 0xf85f83a0, a64_ldst_simm9(3, 1, 0, 29, -8)},
        Row{"stur x0, [x29, #-8]", 0xf81f83a0, a64_ldst_simm9(3, 0, 0, 29, -8)},
        Row{"ldr d0, [x1]", 0xfd400020, a64_fldst_uimm(8, true, 0, 1, 0)},
        Row{"ldr s0, [x1]", 0xbd400020, a64_fldst_uimm(4, true, 0, 1, 0)},
        Row{"ldr q0, [x1]", 0x3dc00020, a64_fldst_uimm(16, true, 0, 1, 0)},
        Row{"str d0, [sp, #8]", 0xfd0007e0, a64_fldst_uimm(8, false, 0, SP, 8)},
        Row{"str q0, [x1]", 0x3d800020, a64_fldst_uimm(16, false, 0, 1, 0)},
        Row{"stp x29, x30, [sp, #-16]!", 0xa9bf7bfd, a64_ldstp(false, false, 3, 29, 30, SP, -16)},
        Row{"ldp x29, x30, [sp], #16", 0xa8c17bfd, a64_ldstp(false, true, 1, 29, 30, SP, 16)},
        Row{"stp x19, x20, [sp, #16]", 0xa90153f3, a64_ldstp(false, false, 2, 19, 20, SP, 16)},
        Row{"ldp x19, x20, [sp, #16]", 0xa94153f3, a64_ldstp(false, true, 2, 19, 20, SP, 16)},
        Row{"stp d8, d9, [sp, #-16]!", 0x6dbf27e8, a64_ldstp(true, false, 3, 8, 9, SP, -16)},
        Row{"ldp d8, d9, [sp], #16", 0x6cc127e8, a64_ldstp(true, true, 1, 8, 9, SP, 16)},
        Row{"bl .", 0x94000000, a64_b(true, 0)},
        Row{"b .", 0x14000000, a64_b(false, 0)},
        Row{"b .-4", 0x17ffffff, a64_b(false, -1)},
        Row{"b.eq .", 0x54000000, a64_bcond(A64_EQ, 0)},
        Row{"b.ne .+8", 0x54000041, a64_bcond(A64_NE, 2)},
        Row{"cbz x0, .", 0xb4000000, a64_cbz(1, false, 0, 0)},
        Row{"cbnz w1, .", 0x35000001, a64_cbz(0, true, 1, 0)},
        Row{"blr x1", 0xd63f0020, a64_br(1, 1)},
        Row{"br x16", 0xd61f0200, a64_br(0, 16)},
        Row{"ret", 0xd65f03c0, a64_br(2, 30)},
        Row{"svc #0", 0xd4000001, a64_svc(0)},
        Row{"brk #0", 0xd4200000, a64_brk(0)},
        Row{"nop", 0xd503201f, A64_NOP},
        Row{"dmb ish", 0xd5033bbf, A64_DMB_ISH},
        Row{"mrs x0, tpidr_el0", 0xd53bd040, a64_mrs_tpidr(0)},
        Row{"msr tpidr_el0, x0", 0xd51bd040, a64_msr_tpidr(0)},
        Row{"adrp x0, .", 0x90000000, a64_adrp(0, 0)},
        Row{"adrp x16, .+0x1000", 0xb0000010, a64_adrp(16, 1)},
        Row{"adr x0, .", 0x10000000, a64_adr(0, 0)},
        Row{"ldaxr x0, [x1]", 0xc85ffc20, a64_ldaxr(3, 0, 1)},
        Row{"ldaxr w0, [x1]", 0x885ffc20, a64_ldaxr(2, 0, 1)},
        Row{"ldaxrb w0, [x1]", 0x085ffc20, a64_ldaxr(0, 0, 1)},
        Row{"stlxr w2, x0, [x1]", 0xc802fc20, a64_stlxr(3, 2, 0, 1)},
        Row{"ldar x0, [x1]", 0xc8dffc20, a64_ldar(3, 0, 1)},
        Row{"stlr x0, [x1]", 0xc89ffc20, a64_stlr(3, 0, 1)},
    })
}

test "arm64 floating point and vectors" {
    assert check([]Row{
        Row{"fadd d0, d0, d1", 0x1e612800, a64_fp2(1, 2, 0, 0, 1)},
        Row{"fadd s0, s0, s1", 0x1e212800, a64_fp2(0, 2, 0, 0, 1)},
        Row{"fsub d0, d1, d2", 0x1e623820, a64_fp2(1, 3, 0, 1, 2)},
        Row{"fmul d0, d1, d2", 0x1e620820, a64_fp2(1, 0, 0, 1, 2)},
        Row{"fdiv d0, d1, d2", 0x1e621820, a64_fp2(1, 1, 0, 1, 2)},
        Row{"fsqrt d0, d1", 0x1e61c020, a64_fp1(1, 3, 0, 1)},
        Row{"fneg d0, d1", 0x1e614020, a64_fp1(1, 2, 0, 1)},
        Row{"fabs d0, d1", 0x1e60c020, a64_fp1(1, 1, 0, 1)},
        Row{"fmov d0, d1", 0x1e604020, a64_fp1(1, 0, 0, 1)},
        Row{"fcvt d0, s1", 0x1e22c020, a64_fp1(0, 5, 0, 1)},
        Row{"fcvt s0, d1", 0x1e624020, a64_fp1(1, 4, 0, 1)},
        Row{"fcmp d0, d1", 0x1e612000, a64_fcmp(1, 0, 1)},
        Row{"fcsel d0, d1, d2, mi", 0x1e624c20, a64_fcsel(1, 0, 1, 2, A64_MI)},
        Row{"fmov x0, d0", 0x9e660000, a64_fmov_gen(1, false, 0, 0)},
        Row{"fmov d0, x0", 0x9e670000, a64_fmov_gen(1, true, 0, 0)},
        Row{"fmov w0, s0", 0x1e260000, a64_fmov_gen(0, false, 0, 0)},
        Row{"fmov s0, w0", 0x1e270000, a64_fmov_gen(0, true, 0, 0)},
        Row{"scvtf d0, x0", 0x9e620000, a64_scvtf(1, 1, 0, 0)},
        Row{"scvtf s0, w0", 0x1e220000, a64_scvtf(0, 0, 0, 0)},
        Row{"fcvtzs x0, d0", 0x9e780000, a64_fcvtzs(1, 1, 0, 0)},
        Row{"fcvtzs w0, s0", 0x1e380000, a64_fcvtzs(0, 0, 0, 0)},
        Row{"fadd v0.4s, v1.4s, v2.4s", 0x4e22d420, a64_vfp2(0, 0, 1, 2)},
        Row{"fmul v0.4s, v1.4s, v2.4s", 0x6e22dc20, a64_vfp2(2, 0, 1, 2)},
        Row{"mov v0.16b, v1.16b", 0x4ea11c20, a64_vorr(0, 1, 1)},
        Row{"dup v0.4s, v1.s[0]", 0x4e040420, a64_dup4s(0, 1, 0)},
        Row{"mov s0, v1.s[1]", 0x5e0c0420, a64_dups(0, 1, 1)},
        Row{"mov v0.s[1], v1.s[0]", 0x6e0c0420, a64_ins_s(0, 1, 1, 0)},
        Row{"movi v0.2d, #0", 0x6f00e400, a64_movi_zero(0)},
        Row{"cnt v0.8b, v0.8b", 0x0e205800, a64_cnt8b(0, 0)},
        Row{"addv b0, v0.8b", 0x0e31b800, a64_addv8b(0, 0)},
        Row{"fneg v0.4s, v1.4s", 0x6ea0f820, a64_vfp1(1, 0, 1)},
        Row{"fabs v0.4s, v1.4s", 0x4ea0f820, a64_vfp1(0, 0, 1)},
    })
}
