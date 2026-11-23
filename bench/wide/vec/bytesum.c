#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static uint64_t bytesum(const uint8_t *b, int64_t n) {
    uint64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += (uint64_t)b[i];
    return s;
}

int main(void) {
    int64_t n = 1 << 20, mask = n - 1;
    uint8_t *b = calloc(n, 1);
    uint32_t seed = 99;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        b[i] = (uint8_t)(seed >> 24);
    }
    uint64_t total = 0;
    for (int64_t r = 0; r < 6000; r++) {
        total += bytesum(b, n) * (uint64_t)(r + 1);
        b[(r * 7919) & mask] += 1;
    }
    printf("%llu\n", (unsigned long long)total);
    return 0;
}
