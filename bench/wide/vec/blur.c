#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void blur(const uint8_t *src, uint8_t *dst, int64_t w, int64_t h) {
    for (int64_t y = 1; y < h - 1; y++) {
        const uint8_t *up = src + (y - 1) * w;
        const uint8_t *mid = src + y * w;
        const uint8_t *dn = src + (y + 1) * w;
        uint8_t *out = dst + y * w;
        for (int64_t x = 1; x < w - 1; x++) {
            uint32_t s = (uint32_t)up[x - 1] + (uint32_t)up[x] + (uint32_t)up[x + 1];
            s += (uint32_t)mid[x - 1] + (uint32_t)mid[x] + (uint32_t)mid[x + 1];
            s += (uint32_t)dn[x - 1] + (uint32_t)dn[x] + (uint32_t)dn[x + 1];
            out[x] = (uint8_t)(s / 9);
        }
    }
}

int main(void) {
    int64_t w = 1024, h = 1024;
    uint8_t *a = calloc(w * h, 1), *b = calloc(w * h, 1);
    uint32_t seed = 4242;
    for (int64_t i = 0; i < w * h; i++) {
        seed = seed * 1664525u + 1013904223u;
        a[i] = (uint8_t)(seed >> 24);
        b[i] = a[i];
    }
    uint64_t check = 0;
    for (int64_t r = 0; r < 1000; r++) {
        if ((r & 1) == 0) blur(a, b, w, h);
        else blur(b, a, w, h);
        a[(r * 4099) & (w * h - 1)] = 255;
        check = check * 1000003 + (uint64_t)a[(r * 7919) & (w * h - 1)];
    }
    for (int64_t i = 0; i < w * h; i++) check += (uint64_t)a[i];
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
