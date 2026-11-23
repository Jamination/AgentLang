// bytecode interpreter: dense match over opcodes (jump table candidate), u64 registers
const LOADI: u32 = 0
const ADD: u32 = 1
const SUB: u32 = 2
const MUL: u32 = 3
const AND: u32 = 4
const OR: u32 = 5
const XOR: u32 = 6
const SHL: u32 = 7
const SHR: u32 = 8
const ADDI: u32 = 9
const JNZ: u32 = 10
const DEC: u32 = 11
const MOV: u32 = 12
const HALT: u32 = 13
const CMPLT: u32 = 14
const NOT: u32 = 15

fn ins(op: u32, a: u32, b: u32, c: u32) -> u32 { op | (a << 8) | (b << 16) | (c << 24) }
fn insi(op: u32, a: u32, imm: u32) -> u32 { op | (a << 8) | (imm << 16) }

fn run(code: []u32) -> u64 {
    r: [16]u64
    pc := 0
    loop {
        w := code[pc]
        pc += 1
        a := (w >> 8) & 0xFF
        b := (w >> 16) & 0xFF
        c := w >> 24
        match w & 0xFF {
            LOADI => { r[a] = u64(w >> 16) }
            ADD => { r[a] = r[b] + r[c] }
            SUB => { r[a] = r[b] - r[c] }
            MUL => { r[a] = r[b] * r[c] }
            AND => { r[a] = r[b] & r[c] }
            OR => { r[a] = r[b] | r[c] }
            XOR => { r[a] = r[b] ^ r[c] }
            SHL => { r[a] = r[b] << (r[c] & 63) }
            SHR => { r[a] = r[b] >> (r[c] & 63) }
            ADDI => { r[a] = r[b] + u64(c) }
            JNZ => { if r[a] != 0 { pc = i64(w >> 16) } }
            DEC => { r[a] -= 1 }
            MOV => { r[a] = r[b] }
            HALT => { return r[1] ^ r[2] }
            CMPLT => { r[a] = if r[b] < r[c] { 1 } else { 0 } }
            NOT => { r[a] = ~r[b] }
            _ => { return 0 }
        }
    }
}

fn main() {
    code := []u32{
        insi(LOADI, 0, 1000), insi(LOADI, 5, 15000), ins(MUL, 0, 0, 5),
        insi(LOADI, 2, 12345), insi(LOADI, 6, 40503), insi(LOADI, 1, 0),
        insi(LOADI, 7, 13), insi(LOADI, 8, 0xFFFF), insi(LOADI, 10, 30000),
        // loop body starts at pc 9
        ins(MUL, 3, 2, 6), ins(ADDI, 3, 3, 7), ins(XOR, 2, 3, 1), ins(SHR, 4, 2, 7),
        ins(XOR, 2, 2, 4), ins(AND, 4, 2, 8), ins(ADD, 1, 1, 4), ins(CMPLT, 9, 4, 10),
        ins(SUB, 1, 1, 9), ins(SHL, 11, 9, 7), ins(OR, 2, 2, 11), ins(NOT, 12, 1, 0), ins(MOV, 13, 12, 0),
        ins(DEC, 0, 0, 0), insi(JNZ, 0, 9),
        ins(HALT, 0, 0, 0),
    }
    put(run(code), "\n")
}
