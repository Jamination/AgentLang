#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void radix_sort(uint32_t *a, uint32_t *tmp, int64_t n) {
    int64_t count[256];
    uint32_t *src = a, *dst = tmp;
    for (int shift = 0; shift < 4; shift++) {
        uint32_t sh = (uint32_t)(shift * 8);
        memset(count, 0, sizeof count);
        for (int64_t i = 0; i < n; i++) count[(src[i] >> sh) & 255] += 1;
        int64_t s = 0;
        for (int d = 0; d < 256; d++) { int64_t c = count[d]; count[d] = s; s += c; }
        for (int64_t i = 0; i < n; i++) {
            uint32_t x = src[i];
            int64_t b = (x >> sh) & 255;
            dst[count[b]] = x;
            count[b] += 1;
        }
        uint32_t *t = src; src = dst; dst = t;
    }
}
int main(void) {
    int64_t n = 5000000;
    uint32_t *a = calloc(n, 4), *tmp = calloc(n, 4);
    uint64_t seed = 9, check = 0;
    for (int r = 0; r < 6; r++) {
        for (int64_t i = 0; i < n; i++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            a[i] = (uint32_t)(seed >> 32);
        }
        radix_sort(a, tmp, n);
        for (int64_t i = 0; i < n; i += 1000) check = check * 31 + a[i];
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
