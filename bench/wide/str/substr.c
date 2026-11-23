/* [codegen] naive and BMH substring search: see substr.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static int64_t naive_count(const uint8_t *s, int64_t n, const uint8_t *p, int64_t m) {
    int64_t c = 0;
    for (int64_t i = 0; i < n - m + 1; i++) {
        int64_t j = 0;
        while (j < m && s[i + j] == p[j]) j++;
        if (j == m) c++;
    }
    return c;
}
static int64_t bmh_count(const uint8_t *s, int64_t n, const uint8_t *p, int64_t m) {
    int64_t shift[256];
    for (int k = 0; k < 256; k++) shift[k] = m;
    for (int64_t k = 0; k < m - 1; k++) shift[p[k]] = m - 1 - k;
    uint8_t last = p[m - 1];
    int64_t c = 0, i = 0;
    while (i + m <= n) {
        uint8_t x = s[i + m - 1];
        if (x == last) {
            int64_t j = 0;
            while (j < m - 1 && s[i + j] == p[j]) j++;
            if (j == m - 1) c++;
        }
        i += shift[x];
    }
    return c;
}
int main(void) {
    int64_t n = 8 << 20;
    uint8_t *s = malloc(n);
    uint64_t seed = 3;
    for (int64_t i = 0; i < n; i++) { seed = lcg(seed); s[i] = (uint8_t)(97 + (seed >> 61)); }
    int64_t a = 0, b = 0;
    for (int q = 0; q < 24; q++) {
        seed = lcg(seed);
        int64_t m = 3 + q % 12;
        int64_t at = (int64_t)((seed >> 33) % (uint64_t)(n - m));
        const uint8_t *p = s + at;
        a = a * 31 + naive_count(s, n, p, m);
        b = b * 31 + bmh_count(s, n, p, m);
    }
    printf("%lld %lld\n", (long long)a, (long long)b);
    return 0;
}
