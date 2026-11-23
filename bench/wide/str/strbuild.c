/* [library] string building: see strbuild.al. Buffers grow by realloc doubling and are
   never freed (like the AL arena). */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static const char *WORDS[8] = {"alpha", "be", "gamma", "delta-epsilon", "z", "theta", "iota kappa", "lambda"};
static int64_t WLEN[8];
typedef struct { uint8_t *p; int64_t n, cap; } Sb;
static void sb_reserve(Sb *b, int64_t need) {
    if (need > b->cap) {
        int64_t c = b->cap ? b->cap * 2 : 8;
        while (c < need) c *= 2;
        b->p = realloc(b->p, c);
        b->cap = c;
    }
}
static inline void sb_push(Sb *b, uint8_t c) { if (b->n == b->cap) sb_reserve(b, b->n + 1); b->p[b->n++] = c; }
static inline void sb_extend(Sb *b, const char *s, int64_t n) { sb_reserve(b, b->n + n); memcpy(b->p + b->n, s, n); b->n += n; }
typedef struct { const char *p; int64_t n; } Str;
typedef struct { Str *p; int64_t n, cap; } Parts;
static uint64_t checksum(const uint8_t *s, int64_t n) {
    uint64_t h = 0;
    for (int64_t i = 0; i < n; i++) h = h * 31 + s[i];
    return h;
}
static uint8_t *join(Str *parts, int64_t n, const char *sep, int64_t *outlen) {
    int64_t sl = (int64_t)strlen(sep), t = 0;
    for (int64_t i = 0; i < n; i++) t += parts[i].n;
    if (n > 0) t += sl * (n - 1);
    uint8_t *o = malloc(t > 0 ? t : 1), *q = o;
    for (int64_t i = 0; i < n; i++) {
        if (i > 0) { memcpy(q, sep, sl); q += sl; }
        memcpy(q, parts[i].p, parts[i].n); q += parts[i].n;
    }
    *outlen = t;
    return o;
}
int main(void) {
    for (int i = 0; i < 8; i++) WLEN[i] = (int64_t)strlen(WORDS[i]);
    uint64_t seed = 5, h = 0;
    int64_t total = 0;
    for (int r = 0; r < 6; r++) {
        Sb b = {0};
        for (int i = 0; i < 3000000; i++) {
            seed = lcg(seed);
            int w = (int)(seed >> 61);
            sb_extend(&b, WORDS[w], WLEN[w]);
            sb_push(&b, ' ');
            uint64_t v = (seed >> 40) % 1000;
            if (v >= 100) sb_push(&b, (uint8_t)(48 + v / 100));
            if (v >= 10) sb_push(&b, (uint8_t)(48 + v / 10 % 10));
            sb_push(&b, (uint8_t)(48 + v % 10));
            sb_push(&b, ';');
        }
        total += b.n;
        h ^= checksum(b.p, b.n);
        Parts ps = {0};
        for (int i = 0; i < 1000000; i++) {
            seed = lcg(seed);
            int w = (int)(seed >> 61);
            if (ps.n == ps.cap) { ps.cap = ps.cap ? ps.cap * 2 : 8; ps.p = realloc(ps.p, ps.cap * sizeof(Str)); }
            ps.p[ps.n].p = WORDS[w]; ps.p[ps.n].n = WLEN[w]; ps.n++;
        }
        int64_t jl;
        uint8_t *j = join(ps.p, ps.n, ", ", &jl);
        total += jl;
        h ^= checksum(j, jl);
    }
    printf("%lld %llu\n", (long long)total, (unsigned long long)h);
    return 0;
}
