#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void gen(const uint8_t *cur, uint8_t *nxt, int64_t w, int64_t h) {
    for (int64_t y = 1; y < h - 1; y++) {
        int64_t row = y * w;
        for (int64_t x = 1; x < w - 1; x++) {
            int64_t i = row + x;
            uint8_t n = (uint8_t)(cur[i - w - 1] + cur[i - w] + cur[i - w + 1] + cur[i - 1] + cur[i + 1] + cur[i + w - 1] + cur[i + w] + cur[i + w + 1]);
            uint8_t alive = cur[i];
            nxt[i] = (n == 3 || (n == 2 && alive == 1)) ? 1 : 0;
        }
    }
}
int main(void) {
    int64_t w = 514, h = 514;
    uint8_t *a = calloc(w * h, 1), *b = calloc(w * h, 1);
    uint64_t seed = 4242;
    for (int64_t y = 1; y < h - 1; y++)
        for (int64_t x = 1; x < w - 1; x++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            a[y * w + x] = (uint8_t)((seed >> 33) % 3 == 0);
        }
    for (int g = 0; g < 500; g++) {
        if (g % 2 == 0) gen(a, b, w, h); else gen(b, a, w, h);
    }
    int64_t live = 0;
    uint64_t hsh = 0;
    for (int64_t i = 0; i < w * h; i++) { live += a[i]; hsh = hsh * 3 + a[i]; }
    printf("%lld %llu\n", (long long)live, (unsigned long long)hsh);
    return 0;
}
