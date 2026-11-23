#include <stdint.h>
#include <stdio.h>

enum { PUSH, LOAD, STORE, INC, ADD, SUB, MUL, AND, OR, XOR, SHL, SHR, LT, EQ, DUP, SWAP, OVER, POP, JMP, JZ, JNZ, HALT };

typedef struct { uint32_t op; int64_t arg; } Ins;

static int64_t run(const Ins *code) {
    int64_t stack[64] = {0}, locals[8] = {0};
    int64_t sp = 0, pc = 0;
    for (;;) {
        Ins ins = code[pc];
        pc++;
        switch (ins.op) {
        case PUSH: stack[sp++] = ins.arg; break;
        case LOAD: stack[sp++] = locals[ins.arg]; break;
        case STORE: locals[ins.arg] = stack[--sp]; break;
        case INC: locals[ins.arg]++; break;
        case ADD: sp--; stack[sp - 1] = (int64_t)((uint64_t)stack[sp - 1] + (uint64_t)stack[sp]); break;
        case SUB: sp--; stack[sp - 1] = (int64_t)((uint64_t)stack[sp - 1] - (uint64_t)stack[sp]); break;
        case MUL: sp--; stack[sp - 1] = (int64_t)((uint64_t)stack[sp - 1] * (uint64_t)stack[sp]); break;
        case AND: sp--; stack[sp - 1] &= stack[sp]; break;
        case OR: sp--; stack[sp - 1] |= stack[sp]; break;
        case XOR: sp--; stack[sp - 1] ^= stack[sp]; break;
        case SHL: sp--; stack[sp - 1] = (int64_t)((uint64_t)stack[sp - 1] << (stack[sp] & 63)); break;
        case SHR: sp--; stack[sp - 1] >>= (stack[sp] & 63); break;
        case LT: sp--; stack[sp - 1] = stack[sp - 1] < stack[sp]; break;
        case EQ: sp--; stack[sp - 1] = stack[sp - 1] == stack[sp]; break;
        case DUP: stack[sp] = stack[sp - 1]; sp++; break;
        case SWAP: { int64_t t = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = t; break; }
        case OVER: stack[sp] = stack[sp - 2]; sp++; break;
        case POP: sp--; break;
        case JMP: pc = ins.arg; break;
        case JZ: if (stack[--sp] == 0) pc = ins.arg; break;
        case JNZ: if (stack[--sp] != 0) pc = ins.arg; break;
        case HALT: return stack[sp - 1];
        }
    }
}

int main(int argc, char **argv) {
    (void)argv;
    int64_t n = 2000 + argc, m = 1500;
    Ins code[] = {
        {PUSH, 0}, {STORE, 0}, {PUSH, 0}, {STORE, 2},
        {LOAD, 0}, {PUSH, n}, {LT, 0}, {JZ, 41},
        {PUSH, 0}, {STORE, 1},
        {LOAD, 1}, {PUSH, m}, {LT, 0}, {JZ, 39},
        {LOAD, 2}, {PUSH, 31}, {MUL, 0},
        {LOAD, 0}, {LOAD, 1}, {XOR, 0}, {DUP, 0}, {PUSH, 3}, {SHL, 0}, {OR, 0}, {ADD, 0},
        {DUP, 0}, {PUSH, 13}, {SHR, 0}, {SWAP, 0}, {XOR, 0},
        {LOAD, 1}, {PUSH, 1}, {AND, 0}, {JZ, 36}, {PUSH, 7}, {SUB, 0},
        {STORE, 2}, {INC, 1}, {JMP, 10},
        {INC, 0}, {JMP, 4},
        {LOAD, 2}, {HALT, 0},
    };
    int64_t total = 0;
    for (int r = 0; r < 3; r++) {
        code[1] = (Ins){STORE, 0};
        total = (int64_t)((uint64_t)total * 7 + (uint64_t)run(code));
    }
    printf("%lld\n", (long long)total);
    return 0;
}
