// The DLL side of tests/winabi/frames.al: what a C caller expects of an AL function.
#include <stdint.h>
#define EXPORT __declspec(dllexport)

// check_saved(cb): loads known values into every register that the Microsoft x64 convention
// preserves across calls (rbx, rbp, rdi, rsi, r12-r15, xmm6-xmm15), calls cb, and returns a
// bit mask of the registers that cb changed (0: all preserved). Also checks that rsp is the
// same after the call.
__asm__(
    ".text\n"
    ".globl check_saved\n"
    "check_saved:\n"
    ".intel_syntax noprefix\n"
    "    push rbx\n push rbp\n push rdi\n push rsi\n push r12\n push r13\n push r14\n push r15\n"
    "    sub rsp, 200\n"
    "    movdqu [rsp+32], xmm6\n movdqu [rsp+48], xmm7\n movdqu [rsp+64], xmm8\n movdqu [rsp+80], xmm9\n"
    "    movdqu [rsp+96], xmm10\n movdqu [rsp+112], xmm11\n movdqu [rsp+128], xmm12\n movdqu [rsp+144], xmm13\n"
    "    movdqu [rsp+160], xmm14\n movdqu [rsp+176], xmm15\n"
    "    mov rax, 0x1111111111111101\n movq xmm6, rax\n pinsrq xmm6, rax, 1\n"
    "    mov rax, 0x1111111111111102\n movq xmm7, rax\n pinsrq xmm7, rax, 1\n"
    "    mov rax, 0x1111111111111103\n movq xmm8, rax\n pinsrq xmm8, rax, 1\n"
    "    mov rax, 0x1111111111111104\n movq xmm9, rax\n pinsrq xmm9, rax, 1\n"
    "    mov rax, 0x1111111111111105\n movq xmm10, rax\n pinsrq xmm10, rax, 1\n"
    "    mov rax, 0x1111111111111106\n movq xmm11, rax\n pinsrq xmm11, rax, 1\n"
    "    mov rax, 0x1111111111111107\n movq xmm12, rax\n pinsrq xmm12, rax, 1\n"
    "    mov rax, 0x1111111111111108\n movq xmm13, rax\n pinsrq xmm13, rax, 1\n"
    "    mov rax, 0x1111111111111109\n movq xmm14, rax\n pinsrq xmm14, rax, 1\n"
    "    mov rax, 0x111111111111110a\n movq xmm15, rax\n pinsrq xmm15, rax, 1\n"
    "    mov rbx, 0x2222222222222201\n mov rbp, 0x2222222222222202\n mov rdi, 0x2222222222222203\n"
    "    mov rsi, 0x2222222222222204\n mov r12, 0x2222222222222205\n mov r13, 0x2222222222222206\n"
    "    mov r14, 0x2222222222222207\n mov r15, 0x2222222222222208\n"
    "    mov [rsp+192], rsp\n"
    "    call rcx\n"
    "    xor eax, eax\n"
    "    cmp [rsp+192], rsp\n jz 1f\n or eax, 0x40000\n1:\n"
    "    mov rdx, 0x2222222222222201\n cmp rbx, rdx\n jz 1f\n or eax, 1\n1:\n"
    "    mov rdx, 0x2222222222222202\n cmp rbp, rdx\n jz 1f\n or eax, 2\n1:\n"
    "    mov rdx, 0x2222222222222203\n cmp rdi, rdx\n jz 1f\n or eax, 4\n1:\n"
    "    mov rdx, 0x2222222222222204\n cmp rsi, rdx\n jz 1f\n or eax, 8\n1:\n"
    "    mov rdx, 0x2222222222222205\n cmp r12, rdx\n jz 1f\n or eax, 16\n1:\n"
    "    mov rdx, 0x2222222222222206\n cmp r13, rdx\n jz 1f\n or eax, 32\n1:\n"
    "    mov rdx, 0x2222222222222207\n cmp r14, rdx\n jz 1f\n or eax, 64\n1:\n"
    "    mov rdx, 0x2222222222222208\n cmp r15, rdx\n jz 1f\n or eax, 128\n1:\n"
#define XCHK(n, v, bit) \
    "    mov rdx, " v "\n movq r8, xmm" n "\n cmp r8, rdx\n jnz 2f\n pextrq r8, xmm" n ", 1\n cmp r8, rdx\n jz 1f\n2: or eax, " bit "\n1:\n"
    XCHK("6", "0x1111111111111101", "0x100") XCHK("7", "0x1111111111111102", "0x200")
    XCHK("8", "0x1111111111111103", "0x400") XCHK("9", "0x1111111111111104", "0x800")
    XCHK("10", "0x1111111111111105", "0x1000") XCHK("11", "0x1111111111111106", "0x2000")
    XCHK("12", "0x1111111111111107", "0x4000") XCHK("13", "0x1111111111111108", "0x8000")
    XCHK("14", "0x1111111111111109", "0x10000") XCHK("15", "0x111111111111110a", "0x20000")
    "    movdqu xmm6, [rsp+32]\n movdqu xmm7, [rsp+48]\n movdqu xmm8, [rsp+64]\n movdqu xmm9, [rsp+80]\n"
    "    movdqu xmm10, [rsp+96]\n movdqu xmm11, [rsp+112]\n movdqu xmm12, [rsp+128]\n movdqu xmm13, [rsp+144]\n"
    "    movdqu xmm14, [rsp+160]\n movdqu xmm15, [rsp+176]\n"
    "    add rsp, 200\n"
    "    pop r15\n pop r14\n pop r13\n pop r12\n pop rsi\n pop rdi\n pop rbp\n pop rbx\n"
    "    ret\n"
    ".att_syntax prefix\n"
    ".section .drectve\n"
    ".ascii \" -export:check_saved\"\n"
    ".text\n");

static volatile int sink;
__attribute__((noinline)) static void touch(void) { sink++; }

// 1 if the caller called with rsp aligned to 16 bytes (as the convention requires)
EXPORT int32_t stack_aligned(void) {
    touch();
    uintptr_t sp;
    __asm__ volatile("mov %%rsp, %0" : "=r"(sp));
    return (sp & 15) == 0;
}

// calls an AL function and returns its result
EXPORT int32_t call_back(int32_t (*cb)(void)) {
    return cb() + 1000;
}
