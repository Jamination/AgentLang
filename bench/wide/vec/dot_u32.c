#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint32_t dot(const uint32_t *x, const uint32_t *y, int64_t n) {
    uint32_t s = 0;
    for (int64_t i = 0; i < n; i++) s += x[i] * y[i];
    return s;
}

int main(void) {
    int64_t n = 8192, mask = n - 1;
    uint32_t *x = calloc(n, 4), *y = calloc(n, 4);
    uint32_t seed = 11;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        x[i] = seed >> 4;
        seed = seed * 1664525u + 1013904223u;
        y[i] = seed >> 4;
    }
    uint64_t total = 0;
    for (int64_t r = 0; r < 300000; r++) {
        total += (uint64_t)dot(x, y, n);
        x[(r * 7919) & mask] += 1;
    }
    printf("%llu\n", (unsigned long long)total);
    return 0;
}
