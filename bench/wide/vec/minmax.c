#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static inline int32_t min32(int32_t a, int32_t b) { return a < b ? a : b; }
static inline int32_t max32(int32_t a, int32_t b) { return a > b ? a : b; }

static void minmax(const int32_t *a, int64_t n, int32_t *plo, int32_t *phi) {
    int32_t lo = a[0], hi = a[0];
    for (int64_t i = 1; i < n; i++) {
        lo = min32(lo, a[i]);
        hi = max32(hi, a[i]);
    }
    *plo = lo;
    *phi = hi;
}

int main(void) {
    int64_t n = 1 << 14, mask = n - 1;
    int32_t *a = calloc(n, 4);
    uint32_t seed = 77;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = (int32_t)seed;
    }
    int64_t total = 0;
    for (int64_t r = 0; r < 120000; r++) {
        int32_t lo, hi;
        minmax(a, n, &lo, &hi);
        total += (int64_t)hi - (int64_t)lo + (r & 7);
        seed = seed * 1664525u + 1013904223u;
        a[(r * 7919) & mask] = (int32_t)seed >> 1;
    }
    printf("%lld\n", (long long)total);
    return 0;
}
