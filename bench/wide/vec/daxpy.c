#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void daxpy(double a, const double *x, double *y, int64_t n) {
    for (int64_t i = 0; i < n; i++) y[i] = y[i] + a * x[i];
}

int main(void) {
    int64_t n = 4096;
    double *x = calloc(n, sizeof(double));
    double *y = calloc(n, sizeof(double));
    uint32_t seed = 1;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        x[i] = (double)(seed >> 8) / 16777216.0;
        seed = seed * 1664525u + 1013904223u;
        y[i] = (double)(seed >> 8) / 16777216.0;
    }
    for (int64_t r = 0; r < 400000; r++) {
        double a = (r & 1) == 0 ? 0.25 : -0.2;
        daxpy(a, x, y, n);
    }
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += y[i];
    printf("%.6f\n", s);
    return 0;
}
