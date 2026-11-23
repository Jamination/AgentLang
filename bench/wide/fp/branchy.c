#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double clamp_f(double x, double lo, double hi) { return x < lo ? lo : (x > hi ? hi : x); }

static double step(double x) {
    double c = clamp_f(x, -1.5, 1.5);
    double ax = x < 0.0 ? -x : x;
    double s = x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
    double m = ax > 0.75 ? ax - 0.75 : 0.75 - ax;
    double r = c * 1.9 - s * m * 0.6;
    return r > 2.0 ? r - 4.0 : (r < -2.0 ? r + 4.0 : r);
}

int main(void) {
    int64_t n = (int64_t)1 << 16;
    double *a = calloc(n, 8);
    for (int64_t i = 0; i < n; i++) a[i] = (double)(i % 4001) / 1000.0 - 2.0;
    for (int pass = 0; pass < 4000; pass++)
        for (int64_t i = 0; i < n; i++) a[i] = step(a[i]);
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += a[i];
    uint64_t b; memcpy(&b, &s, 8);
    printf("%llu\n", (unsigned long long)b);
    return 0;
}
