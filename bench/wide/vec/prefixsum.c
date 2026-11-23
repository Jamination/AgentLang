#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void scan(uint64_t *a, int64_t n) {
    uint64_t acc = 0;
    for (int64_t i = 0; i < n; i++) {
        acc += a[i];
        a[i] = acc;
    }
}

int main(void) {
    int64_t n = 1 << 16;
    uint64_t *a = calloc(n, 8);
    uint32_t seed = 2024;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = (uint64_t)(seed >> 8);
    }
    uint64_t check = 0;
    for (int64_t r = 0; r < 30000; r++) {
        scan(a, n);
        check = check * 31 + a[n - 1] + a[(r * 7919) & (n - 1)];
        a[r & (n - 1)] = (uint64_t)r;
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
