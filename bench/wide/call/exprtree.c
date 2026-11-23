#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

enum { NUM, VAR, ADD, SUB, MUL, NEG, MIN, MAX, AND, XOR, SHR, SEL };

typedef struct Expr {
    uint32_t tag;
    union {
        int64_t num;
        struct { struct Expr *a, *b; } k;
    } u;
} Expr;

/* bump allocator: one big block, never freed (like AL's arena) */
static char *arena_cur, *arena_end;
static void *arena_alloc(size_t n) {
    if (arena_cur + n > arena_end) {
        size_t sz = 64 << 20;
        arena_cur = calloc(1, sz);
        arena_end = arena_cur + sz;
    }
    void *p = arena_cur;
    arena_cur += n;
    return p;
}

static uint64_t seed = 42;
static int64_t rnd(uint64_t n) {
    seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
    return (int64_t)((seed >> 33) % n);
}

static Expr *build(int64_t depth) {
    Expr *e = arena_alloc(sizeof(Expr));
    if (depth == 0 || rnd(16) == 0) {
        if (rnd(3) == 0) e->tag = VAR;
        else { e->tag = NUM; e->u.num = rnd(1000) - 500; }
        return e;
    }
    int64_t k = rnd(10);
    if (k == 0) { e->tag = NEG; e->u.k.a = build(depth - 1); e->u.k.b = NULL; return e; }
    if (k == 1) { e->tag = SHR; e->u.k.a = build(depth - 1); e->u.k.b = NULL; return e; }
    Expr *l = build(depth - 1);
    Expr *r = build(depth - 1);
    switch (k) {
    case 2: e->tag = ADD; break;
    case 3: e->tag = SUB; break;
    case 4: e->tag = MUL; break;
    case 5: e->tag = MIN; break;
    case 6: e->tag = MAX; break;
    case 7: e->tag = AND; break;
    case 8: e->tag = XOR; break;
    default: e->tag = SEL; break;
    }
    e->u.k.a = l;
    e->u.k.b = r;
    return e;
}

static int64_t eval(const Expr *e, int64_t x) {
    if (!e) return 0;
    switch (e->tag) {
    case NUM: return e->u.num;
    case VAR: return x;
    case ADD: return (int64_t)((uint64_t)eval(e->u.k.a, x) + (uint64_t)eval(e->u.k.b, x));
    case SUB: return (int64_t)((uint64_t)eval(e->u.k.a, x) - (uint64_t)eval(e->u.k.b, x));
    case MUL: return (int64_t)((uint64_t)eval(e->u.k.a, x) * (uint64_t)eval(e->u.k.b, x));
    case NEG: return (int64_t)(0 - (uint64_t)eval(e->u.k.a, x));
    case MIN: { int64_t a = eval(e->u.k.a, x), b = eval(e->u.k.b, x); return a < b ? a : b; }
    case MAX: { int64_t a = eval(e->u.k.a, x), b = eval(e->u.k.b, x); return a > b ? a : b; }
    case AND: return eval(e->u.k.a, x) & eval(e->u.k.b, x);
    case XOR: return eval(e->u.k.a, x) ^ eval(e->u.k.b, x);
    case SHR: return eval(e->u.k.a, x) >> 3;
    case SEL: { int64_t v = eval(e->u.k.a, x); return (v & 1) ? v : eval(e->u.k.b, x); }
    }
    return 0;
}

static int64_t count(const Expr *e) {
    if (!e) return 0;
    switch (e->tag) {
    case NUM: case VAR: return 1;
    case NEG: case SHR: return 1 + count(e->u.k.a);
    default: return 1 + count(e->u.k.a) + count(e->u.k.b);
    }
}

int main(void) {
    Expr *trees[8];
    int64_t nodes = 0;
    for (int t = 0; t < 8; t++) {
        trees[t] = build(16);
        nodes += count(trees[t]);
    }
    uint64_t sum = 0;
    for (int64_t x = 0; x < 1200; x++)
        for (int t = 0; t < 8; t++) sum = sum * 31 + (uint64_t)eval(trees[t], x - 600);
    printf("%lld %lld\n", (long long)nodes, (long long)sum);
    return 0;
}
