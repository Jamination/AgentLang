#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    int64_t n = 1 << 16;
    uint8_t *a = calloc(n, 1);
    int16_t *b = calloc(n, 2);
    uint16_t *w = calloc(n, 2);
    uint32_t seed = 7;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = (uint8_t)(seed >> 24);
        b[i] = (int16_t)(uint16_t)(seed >> 8);
    }
    int32_t h = 17;
    uint16_t q = 1;
    for (int64_t r = 0; r < 5000; r++) {
        for (int64_t i = 1; i < n - 1; i++) {
            uint16_t v = (uint16_t)((uint16_t)a[i - 1] + 2 * (uint16_t)a[i] + (uint16_t)a[i + 1]);
            w[i] = v;
            int16_t nb = (int16_t)(uint16_t)(b[i] + (int16_t)a[i] * 3 - (int16_t)v);
            b[i] = nb;
            h = (int32_t)((uint32_t)h * 31u + (uint32_t)(int32_t)nb);
            q = (uint16_t)(q * 3 + (uint16_t)a[i] + (v >> 2));
        }
        a[r & (n - 1)] ^= (uint8_t)h;
        a[(r * 7) & (n - 1)] += (uint8_t)q;
    }
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += (int64_t)b[i] * 3 + (int64_t)w[i];
    printf("%d %u %lld\n", h, (unsigned)q, (long long)s);
    return 0;
}
