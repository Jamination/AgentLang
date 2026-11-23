#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static double dot(const double *x, const double *y, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += x[i] * y[i];
    return s;
}

int main(void) {
    int64_t n = 4096, mask = n - 1;
    double *x = calloc(n, 8), *y = calloc(n, 8);
    uint32_t seed = 5;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        x[i] = (double)(seed >> 8) / 16777216.0 - 0.5;
        seed = seed * 1664525u + 1013904223u;
        y[i] = (double)(seed >> 8) / 16777216.0 - 0.5;
    }
    double total = 0.0;
    for (int64_t r = 0; r < 200000; r++) {
        total += dot(x, y, n);
        int64_t j = (r * 7919) & mask;
        x[j] = -x[j];
    }
    printf("%.4f\n", total);
    return 0;
}
