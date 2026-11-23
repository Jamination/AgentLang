#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void fill_bytes(uint8_t *a, int64_t n, uint8_t v) {
    for (int64_t i = 0; i < n; i++) a[i] = v;
}

static void copy_bytes(uint8_t *dst, const uint8_t *src, int64_t n) {
    for (int64_t i = 0; i < n; i++) dst[i] = src[i];
}

int main(void) {
    int64_t n = 1 << 18, mask = n - 1;
    uint8_t *a = calloc(n, 1), *b = calloc(n, 1);
    uint64_t check = 0;
    for (int64_t r = 0; r < 40000; r++) {
        fill_bytes(a, n, (uint8_t)r);
        a[(r * 7919) & mask] = 7;
        copy_bytes(b, a, n);
        check = check * 31 + (uint64_t)b[(r * 4099) & mask] + (uint64_t)b[(r * 7919) & mask];
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
