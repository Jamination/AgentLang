#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void saxpy(float a, const float *x, float *y, int64_t n) {
    for (int64_t i = 0; i < n; i++) y[i] = y[i] + a * x[i];
}

int main(void) {
    int64_t n = 1 << 24;
    float *x = calloc(n, sizeof(float));
    float *y = calloc(n, sizeof(float));
    uint32_t seed = 3;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        x[i] = (float)(seed >> 8) / 16777216.0f;
        seed = seed * 1664525u + 1013904223u;
        y[i] = (float)(seed >> 8) / 16777216.0f;
    }
    for (int64_t r = 0; r < 40; r++) {
        float a = (r & 1) == 0 ? 0.25f : -0.2f;
        saxpy(a, x, y, n);
    }
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += (double)y[i];
    printf("%.4f\n", s);
    return 0;
}
