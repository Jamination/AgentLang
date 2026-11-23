#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void mul(const uint32_t *a, int64_t na, const uint32_t *b, int64_t nb, uint32_t *r) {
    for (int64_t k = 0; k < na + nb; k++) r[k] = 0;
    for (int64_t i = 0; i < na; i++) {
        uint64_t carry = 0;
        uint64_t ai = (uint64_t)a[i];
        for (int64_t j = 0; j < nb; j++) {
            uint64_t t = ai * (uint64_t)b[j] + (uint64_t)r[i + j] + carry;
            r[i + j] = (uint32_t)t;
            carry = t >> 32;
        }
        r[i + nb] = (uint32_t)carry;
    }
}
static uint64_t add(const uint64_t *a, const uint64_t *b, uint64_t *r, int64_t n) {
    uint64_t carry = 0;
    for (int64_t i = 0; i < n; i++) {
        uint64_t s = a[i] + carry;
        uint64_t c1 = s < carry ? 1 : 0;
        uint64_t s2 = s + b[i];
        uint64_t c2 = s2 < s ? 1 : 0;
        r[i] = s2;
        carry = c1 + c2;
    }
    return carry;
}
int main(void) {
    int64_t n = 1200;
    uint32_t *a = calloc(n, 4), *b = calloc(n, 4), *r = calloc(2 * n, 4);
    uint64_t seed = 1;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        a[i] = (uint32_t)(seed >> 32);
        seed = seed * 6364136223846793005ull + 1442695040888963407ull;
        b[i] = (uint32_t)(seed >> 32);
    }
    uint32_t chk = 0;
    for (int64_t rep = 0; rep < 250; rep++) {
        a[rep] ^= chk;
        mul(a, n, b, n, r);
        for (int64_t k = 0; k < 2 * n; k++) chk = chk * 31 + r[k];
    }
    int64_t m = 2048;
    uint64_t *x = calloc(m, 8), *y = calloc(m, 8), *z = calloc(m, 8);
    x[0] = 1;
    y[0] = 1;
    uint64_t carries = 0;
    for (int64_t it = 0; it < 150000; it++) {
        carries += add(x, y, z, m);
        uint64_t *t = x;
        x = y;
        y = z;
        z = t;
    }
    uint64_t xs = 0;
    for (int64_t k = 0; k < m; k++) xs = xs * 1099511628211ull ^ y[k];
    printf("%u %llu %llu\n", chk, (unsigned long long)carries, (unsigned long long)xs);
    return 0;
}
