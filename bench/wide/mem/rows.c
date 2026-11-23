#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
/* rows as an array of row pointers (double **), the C analogue of [][]f64 */
static void relax_rows(double **src, double **dst, int64_t n, int64_t w) {
    for (int64_t y = 1; y < n - 1; y++) {
        double *up = src[y - 1], *mid = src[y], *dn = src[y + 1], *out = dst[y];
        for (int64_t x = 1; x < w - 1; x++) out[x] = 0.25 * (up[x] + dn[x] + mid[x - 1] + mid[x + 1]);
    }
}
static void relax_flat(const double *src, double *dst, int64_t n) {
    for (int64_t y = 1; y < n - 1; y++)
        for (int64_t x = 1; x < n - 1; x++) {
            int64_t i = y * n + x;
            dst[i] = 0.25 * (src[i - n] + src[i + n] + src[i - 1] + src[i + 1]);
        }
}
static double col_sum(double **g, int64_t n, int64_t w) {
    double s = 0.0;
    for (int64_t x = 0; x < w; x++)
        for (int64_t y = 0; y < n; y++) s += g[y][x] * (double)(y + 1);
    return s;
}
int main(void) {
    int64_t n = 1024;
    double **a = calloc(n, sizeof(double *)), **b = calloc(n, sizeof(double *));
    for (int64_t y = 0; y < n; y++) { a[y] = calloc(n, 8); b[y] = calloc(n, 8); }
    double *fa = calloc(n * n, 8), *fb = calloc(n * n, 8);
    uint64_t seed = 3;
    for (int64_t y = 0; y < n; y++)
        for (int64_t x = 0; x < n; x++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            double v = (double)(int64_t)(seed >> 40) / 16777216.0;
            a[y][x] = v; b[y][x] = v; fa[y * n + x] = v; fb[y * n + x] = v;
        }
    for (int it = 0; it < 100; it++) { relax_rows(a, b, n, n); relax_rows(b, a, n, n); }
    for (int it = 0; it < 100; it++) { relax_flat(fa, fb, n); relax_flat(fb, fa, n); }
    double cs = 0.0;
    for (int it = 0; it < 10; it++) cs += col_sum(a, n, n);
    double s1 = 0.0, s2 = 0.0;
    for (int64_t y = 0; y < n; y++)
        for (int64_t x = 0; x < n; x++) { s1 += a[y][x]; s2 += fa[y * n + x]; }
    printf("%lld %lld %lld\n", (long long)(int64_t)(s1 * 1000.0), (long long)(int64_t)(s2 * 1000.0), (long long)(int64_t)cs);
    return 0;
}
