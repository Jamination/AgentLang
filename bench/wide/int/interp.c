#include <stdint.h>
#include <stdio.h>
enum { LOADI, ADD, SUB, MUL, AND, OR, XOR, SHL, SHR, ADDI, JNZ, DEC, MOV, HALT, CMPLT, NOT };
static uint32_t ins(uint32_t op, uint32_t a, uint32_t b, uint32_t c) { return op | (a << 8) | (b << 16) | (c << 24); }
static uint32_t insi(uint32_t op, uint32_t a, uint32_t imm) { return op | (a << 8) | (imm << 16); }
static uint64_t run(const uint32_t *code) {
    uint64_t r[16] = {0};
    int64_t pc = 0;
    for (;;) {
        uint32_t w = code[pc];
        pc += 1;
        uint32_t a = (w >> 8) & 0xFF, b = (w >> 16) & 0xFF, c = w >> 24;
        switch (w & 0xFF) {
        case LOADI: r[a] = (uint64_t)(w >> 16); break;
        case ADD: r[a] = r[b] + r[c]; break;
        case SUB: r[a] = r[b] - r[c]; break;
        case MUL: r[a] = r[b] * r[c]; break;
        case AND: r[a] = r[b] & r[c]; break;
        case OR: r[a] = r[b] | r[c]; break;
        case XOR: r[a] = r[b] ^ r[c]; break;
        case SHL: r[a] = r[b] << (r[c] & 63); break;
        case SHR: r[a] = r[b] >> (r[c] & 63); break;
        case ADDI: r[a] = r[b] + (uint64_t)c; break;
        case JNZ: if (r[a] != 0) pc = (int64_t)(w >> 16); break;
        case DEC: r[a] -= 1; break;
        case MOV: r[a] = r[b]; break;
        case HALT: return r[1] ^ r[2];
        case CMPLT: r[a] = r[b] < r[c] ? 1 : 0; break;
        case NOT: r[a] = ~r[b]; break;
        default: return 0;
        }
    }
}
int main(void) {
    uint32_t code[] = {
        insi(LOADI, 0, 1000), insi(LOADI, 5, 15000), ins(MUL, 0, 0, 5),
        insi(LOADI, 2, 12345), insi(LOADI, 6, 40503), insi(LOADI, 1, 0),
        insi(LOADI, 7, 13), insi(LOADI, 8, 0xFFFF), insi(LOADI, 10, 30000),
        ins(MUL, 3, 2, 6), ins(ADDI, 3, 3, 7), ins(XOR, 2, 3, 1), ins(SHR, 4, 2, 7),
        ins(XOR, 2, 2, 4), ins(AND, 4, 2, 8), ins(ADD, 1, 1, 4), ins(CMPLT, 9, 4, 10),
        ins(SUB, 1, 1, 9), ins(SHL, 11, 9, 7), ins(OR, 2, 2, 11), ins(NOT, 12, 1, 0), ins(MOV, 13, 12, 0),
        ins(DEC, 0, 0, 0), insi(JNZ, 0, 9),
        ins(HALT, 0, 0, 0),
    };
    printf("%llu\n", (unsigned long long)run(code));
    return 0;
}
