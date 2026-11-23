#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double kahan(const double *a, int64_t n) {
    double sum = 0.0, c = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double y = a[i] - c;
        double t = sum + y;
        c = (t - sum) - y;
        sum = t;
    }
    return sum;
}

static double dot(const double *a, const double *b, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += a[i] * b[i];
    return s;
}

static double total(const double *a, int64_t n) {
    double s = 0.0;
    for (int64_t i = 0; i < n; i++) s += a[i];
    return s;
}

static unsigned long long bits(double d) { uint64_t b; memcpy(&b, &d, 8); return (unsigned long long)b; }

int main(void) {
    int64_t n = (int64_t)1 << 20;
    double *a = calloc(n, 8), *b = calloc(n, 8);
    for (int64_t i = 0; i < n; i++) {
        a[i] = 1.0 / (double)(i + 1) + (double)(i % 3) * 1e8;
        b[i] = (double)(i % 17) * 0.125 - 1.0;
    }
    double s1 = 0.0, s2 = 0.0, s3 = 0.0;
    for (int r = 0; r < 60; r++) {
        s1 += total(a, n);
        s2 += dot(a, b, n);
        s3 += kahan(a, n);
        a[r] = a[r] + 1.0;
    }
    printf("%llu %llu %llu\n", bits(s1), bits(s2), bits(s3));
    return 0;
}
