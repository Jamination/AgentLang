#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void colsum(const uint8_t *img, int64_t w, int64_t h, uint32_t *acc) {
    for (int64_t x = 0; x < w; x++) acc[x] = 0;
    for (int64_t y = 0; y < h; y++) {
        const uint8_t *row = img + y * w;
        for (int64_t x = 0; x < w; x++) acc[x] += (uint32_t)row[x];
    }
}

int main(void) {
    int64_t w = 512, h = 512;
    uint8_t *img = calloc(w * h, 1);
    uint32_t *acc = calloc(w, 4);
    uint32_t seed = 555;
    for (int64_t i = 0; i < w * h; i++) {
        seed = seed * 1664525u + 1013904223u;
        img[i] = (uint8_t)(seed >> 24);
    }
    uint64_t check = 0;
    for (int64_t r = 0; r < 18000; r++) {
        colsum(img, w, h, acc);
        for (int64_t x = 0; x < w; x++) check = check * 31 + (uint64_t)acc[x];
        img[(r * 7919) & (w * h - 1)] += 3;
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
