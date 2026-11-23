#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int64_t cur, end, step; } Stride;

static bool stride_next(Stride *it, int64_t *out) {
    if (it->cur >= it->end) return false;
    *out = it->cur;
    it->cur += it->step;
    return true;
}

typedef struct { const uint8_t *s; int64_t len, pos; } Words;

static bool words_next(Words *it, const uint8_t **wp, int64_t *wl) {
    int64_t n = it->len;
    while (it->pos < n && it->s[it->pos] == ' ') it->pos++;
    if (it->pos >= n) return false;
    int64_t start = it->pos;
    while (it->pos < n && it->s[it->pos] != ' ') it->pos++;
    *wp = it->s + start;
    *wl = it->pos - start;
    return true;
}

int main(void) {
    int64_t n = 1000000;
    int64_t *v = malloc(n * 8);
    uint64_t seed = 5;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        v[i] = (int64_t)(seed >> 40);
    }
    uint8_t *text = malloc(n);
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        text[i] = (seed >> 60) < 3 ? ' ' : (uint8_t)('a' + (seed >> 33) % 26);
    }
    uint64_t s1 = 0, s2 = 0, s5 = 0;
    int64_t s3 = 0, s4 = 0;
    for (int64_t r = 0; r < 60; r++) {
        for (int64_t i = 0; i < n; i++) s1 = s1 * 31 + (uint64_t)v[i];
        for (int64_t i = 0; i < n; i++)
            if ((v[i] & 1) == 0) s2 += (uint64_t)v[i] * (uint64_t)i;
        for (int64_t i = r; i < n; i += 3) s3 += v[i] ^ i;
        for (int64_t i = 100; i < n - 100; i++) {
            if (v[i] > (s4 & 0xFFFFFF)) s4 += 1; else s4 += 3;
        }
        Stride it = {r, n, 7};
        int64_t k;
        while (stride_next(&it, &k)) s4 += v[k] & 255;
        Words w = {text, n, 0};
        const uint8_t *wp;
        int64_t wl;
        while (words_next(&w, &wp, &wl)) s5 = s5 * 31 + (uint64_t)(wl * (int64_t)wp[0]);
    }
    printf("%lld %lld %lld %lld %lld\n", (long long)s1, (long long)s2, (long long)s3, (long long)s4, (long long)s5);
    return 0;
}
