#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* bump arena as AL's: 16-byte aligned, reset to a mark; Vec grows exactly like AL's Vec
   (capacity max(2*cap, max(need, 8)), new buffer from the arena, memcpy of the live part) */
static char *arena_cur, *arena_end;
static inline void *arena_alloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    char *p = arena_cur;
    if ((size_t)(arena_end - p) < n) { fprintf(stderr, "oom\n"); exit(1); }
    arena_cur = p + n;
    return p;
}
typedef struct { int64_t *buf; int64_t cap; int64_t len; } Vec;
static void vec_reserve(Vec *v, int64_t n) {
    if (n > v->cap) {
        int64_t cap = v->cap * 2;
        int64_t m = n > 8 ? n : 8;
        if (m > cap) cap = m;
        int64_t *nb = arena_alloc(cap * sizeof(int64_t));
        memcpy(nb, v->buf, v->len * sizeof(int64_t));
        v->buf = nb;
        v->cap = cap;
    }
}
static inline void vec_push(Vec *v, int64_t x) {
    if (v->len == v->cap) vec_reserve(v, v->len + 1);
    v->buf[v->len] = x;
    v->len += 1;
}
static inline int64_t vec_pop(Vec *v) {
    if (v->len == 0) { fprintf(stderr, "pop from empty\n"); exit(1); }
    v->len -= 1;
    return v->buf[v->len];
}
typedef struct { int64_t *buf; int64_t cap; int64_t head, tail; } Ring;
static inline void ring_push(Ring *r, int64_t x) { r->buf[r->tail & (r->cap - 1)] = x; r->tail += 1; }
static inline int64_t ring_pop(Ring *r) { int64_t x = r->buf[r->head & (r->cap - 1)]; r->head += 1; return x; }

int main(void) {
    size_t acap = (size_t)1 << 30;
    arena_cur = malloc(acap); arena_end = arena_cur + acap;
    uint64_t seed = 77, total = 0;
    for (int round = 0; round < 60; round++) {
        char *m = arena_cur;
        Vec v = { NULL, 0, 0 };
        for (int64_t i = 0; i < 1000000; i++) {
            vec_push(&v, i * 3);
            if ((i & 7) == 7) {
                int64_t a = vec_pop(&v);
                int64_t b = vec_pop(&v);
                vec_push(&v, a + b);
            }
        }
        uint64_t s = 0;
        while (v.len > 0) s = s * 31 + (uint64_t)vec_pop(&v);
        total += s;
        arena_cur = m;
    }
    Ring r = { calloc(1 << 12, 8), 1 << 12, 0, 0 };
    for (int64_t i = 0; i < 1024; i++) ring_push(&r, i);
    for (int64_t i = 0; i < 150000000; i++) {
        int64_t x = ring_pop(&r);
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        ring_push(&r, x + (int64_t)(seed >> 60));
        total += (uint64_t)x;
    }
    printf("%llu\n", (unsigned long long)total);
    return 0;
}
