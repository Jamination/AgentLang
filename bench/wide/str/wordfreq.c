/* [library] word frequencies: see wordfreq.al. malloc/realloc, no frees in the hot path. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
typedef struct { const uint8_t *p; int64_t n; int64_t count; uint64_t h; } Ent;
typedef struct { Ent *e; int64_t cap, len; } Tab;
static uint64_t hstr(const uint8_t *p, int64_t n) {
    uint64_t h = 0xcbf29ce484222325ULL;
    for (int64_t i = 0; i < n; i++) h = (h ^ p[i]) * 0x100000001b3ULL;
    h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; h ^= h >> 33; h *= 0xc4ceb9fe1a85ec53ULL; h ^= h >> 33;
    return h;
}
static void tab_grow(Tab *t) {
    Ent *old = t->e;
    int64_t oc = t->cap;
    t->cap = oc ? oc * 2 : 16;
    t->e = calloc(t->cap, sizeof(Ent));
    for (int64_t i = 0; i < oc; i++) {
        if (old[i].p) {
            uint64_t j = old[i].h & (t->cap - 1);
            while (t->e[j].p) j = (j + 1) & (t->cap - 1);
            t->e[j] = old[i];
        }
    }
    free(old);
}
static void tab_add(Tab *t, const uint8_t *p, int64_t n) {
    if ((t->len + 1) * 2 > t->cap) tab_grow(t);
    uint64_t h = hstr(p, n);
    uint64_t mask = t->cap - 1, j = h & mask;
    for (;;) {
        Ent *e = &t->e[j];
        if (!e->p) { e->p = p; e->n = n; e->count = 1; e->h = h; t->len++; return; }
        if (e->h == h && e->n == n && memcmp(e->p, p, n) == 0) { e->count++; return; }
        j = (j + 1) & mask;
    }
}
int main(void) {
    uint64_t seed = 7, nv = 50000;
    uint8_t **vocab = malloc(nv * sizeof *vocab);
    int64_t *vlen = malloc(nv * sizeof *vlen);
    for (uint64_t i = 0; i < nv; i++) {
        seed = lcg(seed);
        int64_t l = 2 + (int64_t)((seed >> 33) % 11);
        uint8_t *w = malloc(l);
        for (int64_t j = 0; j < l; j++) { seed = lcg(seed); w[j] = (uint8_t)(97 + (seed >> 33) % 26); }
        vocab[i] = w; vlen[i] = l;
    }
    int64_t cap = 16, n = 0;
    uint8_t *b = malloc(cap);
    for (int k = 0; k < 4000000; k++) {
        seed = lcg(seed);
        uint64_t x = (seed >> 33) % nv, y = (seed >> 13) % nv;
        uint64_t idx = x < y ? x : y;
        int64_t l = vlen[idx];
        if (n + l + 1 > cap) { while (n + l + 1 > cap) cap *= 2; b = realloc(b, cap); }
        memcpy(b + n, vocab[idx], l); n += l;
        b[n++] = ' ';
    }
    int64_t distinct = 0, total = 0, check = 0;
    for (int r = 0; r < 3; r++) {
        Tab t = {0};
        int64_t i = 0;
        while (i <= n) {
            int64_t j = i;
            while (j < n && b[j] != ' ') j++;
            if (j > i) tab_add(&t, b + i, j - i);
            i = j + 1;
        }
        distinct += t.len;
        for (int64_t k = 0; k < t.cap; k++) {
            if (t.e[k].p) { total += t.e[k].count; check += t.e[k].count * t.e[k].count + t.e[k].n; }
        }
        free(t.e);
    }
    printf("%lld %lld %lld %lld\n", (long long)n, (long long)distinct, (long long)total, (long long)check);
    return 0;
}
