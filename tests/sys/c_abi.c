/* For c_abi.al: the C calling convention in both directions, as a C compiler implements it
   (clang for linux-arm64, under the emulator; MinGW for Windows). Every function folds its
   arguments into a hash in the order of its parameters, so an argument in the wrong place or
   with the wrong bits changes the result; the program computes the same hash itself.
   Freestanding: no headers, no C library. */
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
typedef signed char i8;
typedef unsigned char u8;
typedef short i16;
typedef unsigned short u16;
typedef int i32;
typedef unsigned u32;
typedef long long i64;
typedef unsigned long long u64;

static u64 mix(u64 h, i64 v) { return (h ^ (u64)v) * 1099511628211ull; }
static u64 mixf(u64 h, double v) { return mix(h, (i64)(v * 1024.0)); }
#define H0 14695981039346656037ull

struct F2 { float x, y; };
struct F3 { float x, y, z; };
struct D1 { double a; };
struct D4 { double a, b, c, d; };
struct I2 { i32 a, b; };
struct C3 { i8 a, b, c; };
struct I3 { i32 a, b, c; };
struct L2 { i64 a, b; };
struct M { i8 c; i32 i; i64 l; };
struct FI { float f; i32 i; };
struct DL { double d; i64 l; };
struct Big { i64 a, b, c; };
struct Arr { i32 v[5]; };

/* ---- scalars ---- */
EXPORT i64 ints9(i8 a, u8 b, i16 c, u16 d, i32 e, u32 f, i64 g, u64 h, i8 i) {
    u64 x = H0;
    x = mix(x, a); x = mix(x, b); x = mix(x, c); x = mix(x, d); x = mix(x, e);
    x = mix(x, f); x = mix(x, g); x = mix(x, (i64)h); x = mix(x, i);
    return (i64)x;
}

EXPORT double floats10(float a, double b, float c, double d, float e, double f, float g, double h, float i, double j) {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j;
}

EXPORT i64 mixed18(i32 a, double b, i64 c, float d, i8 e, double f, u16 g, float h, i64 i, double j,
                   i32 k, float l, i64 m, double n, u8 o, double p, i64 q, float r) {
    u64 x = H0;
    x = mix(x, a); x = mixf(x, b); x = mix(x, c); x = mixf(x, d); x = mix(x, e); x = mixf(x, f);
    x = mix(x, g); x = mixf(x, h); x = mix(x, i); x = mixf(x, j); x = mix(x, k); x = mixf(x, l);
    x = mix(x, m); x = mixf(x, n); x = mix(x, o); x = mixf(x, p); x = mix(x, q); x = mixf(x, r);
    return (i64)x;
}

EXPORT _Bool not_(_Bool b) { return !b; }
EXPORT i8 neg8(i8 v) { return (i8)-v; }
EXPORT u16 inc16(u16 v) { return (u16)(v + 1); }
EXPORT float half(float v) { return v / 2; }
EXPORT i64 twice(i64 v) { return 2 * v; }

/* ---- structs ---- */
EXPORT double hfa_regs(struct F3 a, struct D4 b, float c, struct F2 d, struct D1 e) {
    return a.x + 2 * a.y + 3 * a.z + 4 * b.a + 5 * b.b + 6 * b.c + 7 * b.d + 8 * c + 9 * d.x + 10 * d.y + 11 * e.a;
}

/* six doubles leave two v registers: the F3 goes to the stack, and so does `after` */
EXPORT double hfa_spill(double a0, double a1, double a2, double a3, double a4, double a5, struct F3 s, double after) {
    return a0 + 2 * a1 + 3 * a2 + 4 * a3 + 5 * a4 + 6 * a5 + 7 * s.x + 8 * s.y + 9 * s.z + 10 * after;
}

/* seven integers leave one x register: the L2 goes to the stack, and so does `after` */
EXPORT i64 composite_spill(i64 a0, i64 a1, i64 a2, i64 a3, i64 a4, i64 a5, i64 a6, struct L2 s, i64 after) {
    u64 x = H0;
    x = mix(x, a0); x = mix(x, a1); x = mix(x, a2); x = mix(x, a3); x = mix(x, a4); x = mix(x, a5);
    x = mix(x, a6); x = mix(x, s.a); x = mix(x, s.b); x = mix(x, after);
    return (i64)x;
}

EXPORT i64 small_structs(struct I2 a, struct C3 b, struct I3 c, struct M d, struct FI e, struct DL f) {
    u64 x = H0;
    x = mix(x, a.a); x = mix(x, a.b); x = mix(x, b.a); x = mix(x, b.b); x = mix(x, b.c);
    x = mix(x, c.a); x = mix(x, c.b); x = mix(x, c.c); x = mix(x, d.c); x = mix(x, d.i); x = mix(x, d.l);
    x = mixf(x, e.f); x = mix(x, e.i); x = mixf(x, f.d); x = mix(x, f.l);
    return (i64)x;
}

/* the callee may change its copies: the caller's values stay */
EXPORT i64 big_structs(struct Big b, struct Arr a, i64 k) {
    u64 x = H0;
    x = mix(x, b.a); x = mix(x, b.b); x = mix(x, b.c);
    for (int j = 0; j < 5; j++) x = mix(x, a.v[j]);
    x = mix(x, k);
    b.a = 99;
    a.v[0] = 99;
    return (i64)x;
}

EXPORT struct F3 ret_f3(float v) { struct F3 r = {v, v + 1, v + 2}; return r; }
EXPORT struct D4 ret_d4(double v) { struct D4 r = {v, v * 2, v * 3, v * 4}; return r; }
EXPORT struct D1 ret_d1(double v) { struct D1 r = {v + 0.5}; return r; }
EXPORT struct F2 ret_f2(float v) { struct F2 r = {v, -v}; return r; }
EXPORT struct I3 ret_i3(i32 v) { struct I3 r = {v, v + 1, v + 2}; return r; }
EXPORT struct C3 ret_c3(i8 v) { struct C3 r = {v, (i8)(v + 1), (i8)(v + 2)}; return r; }
EXPORT struct M ret_m(i64 v) { struct M r = {(i8)v, (i32)v * 2, v * 3}; return r; }
EXPORT struct FI ret_fi(i32 v) { struct FI r = {v + 0.25f, v}; return r; }
EXPORT struct DL ret_dl(i64 v) { struct DL r = {v + 0.75, -v}; return r; }
EXPORT struct Big ret_big(i64 v) { struct Big r = {v, v + 1, v + 2}; return r; }

/* ---- variadic ---- */
EXPORT i64 va_hash(const char *spec, ...) {
    __builtin_va_list ap;
    __builtin_va_start(ap, spec);
    u64 x = H0;
    for (; *spec; spec++) {
        if (*spec == 'i') x = mix(x, __builtin_va_arg(ap, i32));
        else if (*spec == 'l') x = mix(x, __builtin_va_arg(ap, i64));
        else if (*spec == 'd') x = mixf(x, __builtin_va_arg(ap, double));
        else if (*spec == 'p') x = mix(x, (i64)__builtin_va_arg(ap, void *));
    }
    __builtin_va_end(ap);
    return (i64)x;
}

/* ---- callbacks: C calls the program ---- */
EXPORT i64 call_ints(i64 (*cb)(i8, u8, i16, u16, i32, u32, i64, u64, i8, i64)) {
    return cb(-3, 250, -1234, 60000, -100000, 4000000000u, -5000000000ll, 18000000000000000000ull, 7, 123456789) * 2 + 1;
}

EXPORT double call_floats(double (*cb)(float, double, float, double, float, double, float, double, float, double)) {
    return cb(0.5f, 1.25, 2.5f, 3.75, 4.5f, 5.25, 6.5f, 7.75, 8.5f, 9.25) + 1;
}

EXPORT i64 call_mixed(i64 (*cb)(i32, double, i64, float, i8, double, u16, float, i64, double, i32, float, i64, double, u8, double, i64, float)) {
    return cb(1, 2.5, 3, 4.25f, -5, 6.75, 7, 8.5f, 9, 10.25, 11, 12.5f, 13, 14.75, 200, 16.5, 17, 18.25f);
}

EXPORT i64 call_narrow(i8 (*f)(i8), u16 (*g)(u16), _Bool (*h)(i64), float (*k)(float)) {
    i8 a = f(-5);
    u16 b = g(65534);
    _Bool c = h(42);
    float d = k(1.5f);
    return a * 1000000 + b * 10 + c + (i64)(d * 4);
}

/* i64 saved_regs(i64 (*cb)(i64), i64 v, i64 *result): x19-x28 and d8-d15 hold patterns
   across a call of the program, which must preserve them, and sp is the same after it; returns 1
   if all is well, and cb's result in *result (aarch64, in assembly: a C compiler would keep its
   own values in those registers; elsewhere just the call) */
#ifdef __aarch64__
__asm__(
    ".text\n .globl saved_regs\n .type saved_regs, %function\n .p2align 2\n"
    "saved_regs:\n"
    "  stp x29, x30, [sp, #-176]!\n  mov x29, sp\n"
    "  stp x19, x20, [sp, #16]\n  stp x21, x22, [sp, #32]\n  stp x23, x24, [sp, #48]\n"
    "  stp x25, x26, [sp, #64]\n  stp x27, x28, [sp, #80]\n"
    "  stp d8, d9, [sp, #96]\n  stp d10, d11, [sp, #112]\n  stp d12, d13, [sp, #128]\n"
    "  stp d14, d15, [sp, #144]\n  str x2, [sp, #160]\n"
    "  mov x9, x0\n  mov x0, x1\n"
    "  mov x19, #0x1901\n  mov x20, #0x2002\n  mov x21, #0x2103\n  mov x22, #0x2204\n"
    "  mov x23, #0x2305\n  mov x24, #0x2406\n  mov x25, #0x2507\n  mov x26, #0x2608\n"
    "  mov x27, #0x2709\n  mov x28, #0x280a\n"
    "  fmov d8, #1.0\n  fmov d9, #2.0\n  fmov d10, #3.0\n  fmov d11, #4.0\n"
    "  fmov d12, #5.0\n  fmov d13, #6.0\n  fmov d14, #7.0\n  fmov d15, #8.0\n"
    "  mov x10, sp\n  str x10, [sp, #168]\n"
    "  blr x9\n"
    "  ldr x10, [sp, #168]\n  mov x11, sp\n  cmp x10, x11\n  cset x12, eq\n"
    "  mov x9, #0x1901\n  cmp x19, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2002\n  cmp x20, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2103\n  cmp x21, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2204\n  cmp x22, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2305\n  cmp x23, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2406\n  cmp x24, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2507\n  cmp x25, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2608\n  cmp x26, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x2709\n  cmp x27, x9\n  csel x12, x12, xzr, eq\n"
    "  mov x9, #0x280a\n  cmp x28, x9\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #1.0\n  fcmp d8, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #2.0\n  fcmp d9, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #3.0\n  fcmp d10, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #4.0\n  fcmp d11, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #5.0\n  fcmp d12, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #6.0\n  fcmp d13, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #7.0\n  fcmp d14, d0\n  csel x12, x12, xzr, eq\n"
    "  fmov d0, #8.0\n  fcmp d15, d0\n  csel x12, x12, xzr, eq\n"
    "  ldr x2, [sp, #160]\n  str x0, [x2]\n  mov x0, x12\n"
    "  ldp d8, d9, [sp, #96]\n  ldp d10, d11, [sp, #112]\n  ldp d12, d13, [sp, #128]\n"
    "  ldp d14, d15, [sp, #144]\n"
    "  ldp x19, x20, [sp, #16]\n  ldp x21, x22, [sp, #32]\n  ldp x23, x24, [sp, #48]\n"
    "  ldp x25, x26, [sp, #64]\n  ldp x27, x28, [sp, #80]\n"
    "  ldp x29, x30, [sp], #176\n  ret\n"
    "  .size saved_regs, . - saved_regs\n");
#else
EXPORT i64 saved_regs(i64 (*cb)(i64), i64 v, i64 *result) {
    *result = cb(v);
    return 1;
}
#endif


/* the stack pointer modulo 16 in a C function the program calls (0: aligned as required) */
EXPORT i64 sp_mod16(void) {
#ifdef __aarch64__
    i64 sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    return sp & 15;
#else
    return 0;
#endif
}

/* ---- a variable of the library ---- */
EXPORT i32 abi_counter = 5;
EXPORT i32 read_counter(void) { return abi_counter; }
