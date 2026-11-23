#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    int64_t n = 1 << 22;
    uint8_t *b = calloc(n, 1);
    uint32_t seed = 1234;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        b[i] = (uint8_t)((seed >> 24) & (seed >> 16));
    }
    uint32_t hist[256];
    uint64_t check = 0;
    for (int64_t r = 0; r < 300; r++) {
        for (int64_t i = 0; i < 256; i++) hist[i] = 0;
        for (int64_t i = 0; i < n; i++) hist[b[i]] += 1;
        for (int64_t i = 0; i < 256; i++) check = check * 31 + (uint64_t)hist[i];
        b[r] = (uint8_t)r;
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
