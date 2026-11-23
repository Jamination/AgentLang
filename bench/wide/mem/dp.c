#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static int32_t edit_distance(const uint8_t *a, int64_t n, const uint8_t *b, int64_t m, int32_t *d) {
    int64_t w = m + 1;
    for (int64_t j = 0; j <= m; j++) d[j] = (int32_t)j;
    for (int64_t i = 1; i <= n; i++) {
        d[i * w] = (int32_t)i;
        uint8_t ai = a[i - 1];
        for (int64_t j = 1; j <= m; j++) {
            int32_t cost = ai == b[j - 1] ? 0 : 1;
            int32_t best = d[(i - 1) * w + j - 1] + cost;
            int32_t up = d[(i - 1) * w + j] + 1;
            int32_t left = d[i * w + j - 1] + 1;
            if (up < best) best = up;
            if (left < best) best = left;
            d[i * w + j] = best;
        }
    }
    return d[n * w + m];
}
static int64_t knapsack(const int64_t *wt, const int64_t *val, int64_t items, int64_t cap, int64_t *best) {
    for (int64_t w = 0; w <= cap; w++) best[w] = 0;
    for (int64_t k = 0; k < items; k++) {
        int64_t wk = wt[k], vk = val[k];
        for (int64_t w = cap; w >= wk; w--) {
            int64_t cand = best[w - wk] + vk;
            if (cand > best[w]) best[w] = cand;
        }
    }
    return best[cap];
}
int main(void) {
    int64_t n = 4000;
    uint8_t *a = calloc(n, 1), *b = calloc(n, 1);
    uint64_t seed = 5;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        a[i] = (uint8_t)(97 + (seed >> 33) % 4);
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        b[i] = (uint8_t)(97 + (seed >> 33) % 4);
    }
    int32_t *d = calloc((n + 1) * (n + 1), 4);
    int64_t total = 0;
    for (int r = 0; r < 6; r++) total += edit_distance(a + r, n - r, b, n, d);
    int64_t items = 2000;
    int64_t *wt = calloc(items, 8), *val = calloc(items, 8);
    for (int64_t i = 0; i < items; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        wt[i] = 1 + (int64_t)((seed >> 33) % 1000);
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        val[i] = 1 + (int64_t)((seed >> 33) % 10000);
    }
    int64_t cap = 300000;
    int64_t *best = calloc(cap + 1, 8);
    total += knapsack(wt, val, items, cap, best);
    printf("%lld\n", (long long)total);
    return 0;
}
