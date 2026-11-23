#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int64_t count_above(const int32_t *a, int64_t n, int32_t t) {
    int64_t c = 0;
    for (int64_t i = 0; i < n; i++) {
        if (a[i] > t) c += 1;
    }
    return c;
}

int main(void) {
    int64_t n = 1 << 14;
    int32_t *a = calloc(n, 4);
    uint32_t seed = 31337;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = (int32_t)(seed >> 16);
    }
    int64_t total = 0;
    for (int64_t r = 0; r < 150000; r++) {
        total += count_above(a, n, (int32_t)(r & 0xFFFF));
        a[r & (n - 1)] = (int32_t)(r & 0xFFFF);
    }
    printf("%lld\n", (long long)total);
    return 0;
}
