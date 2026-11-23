#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const double COEF[16] = {1.0, -0.5, 0.25, -0.125, 0.0625, 0.3, -0.7, 0.11, 0.013, -0.21, 0.17, -0.019, 0.0023, 0.31, -0.29, 0.07};

static double horner(const double *c, int64_t n, double x) {
    double r = 0.0;
    for (int64_t i = 0; i < n; i++) r = r * x + c[n - 1 - i];
    return r;
}

static double clenshaw(const double *c, int64_t n, double x) {
    double b1 = 0.0, b2 = 0.0, x2 = 2.0 * x;
    for (int64_t i = 0; i < n - 1; i++) {
        double t = x2 * b1 - b2 + c[n - 1 - i];
        b2 = b1;
        b1 = t;
    }
    return x * b1 - b2 + c[0];
}

static double taylor_exp(double x) {
    double sum = 1.0, term = 1.0, n = 1.0;
    while (fabs(term) > 1e-16 * fabs(sum)) {
        term = term * x / n;
        sum += term;
        n += 1.0;
    }
    return sum;
}

static unsigned long long bits(double d) { uint64_t b; memcpy(&b, &d, 8); return (unsigned long long)b; }

int main(void) {
    double *cheb = calloc(24, 8);
    for (int64_t i = 0; i < 24; i++) cheb[i] = 1.0 / (double)(i * i + 1);
    double coef[16];
    memcpy(coef, COEF, sizeof coef);
    int64_t m = 6000000;
    double *ys = calloc(m, 8);
    for (int64_t i = 0; i < m; i++) ys[i] = (double)i / (double)m * 2.0 - 1.0;
    double sh = 0.0, sc = 0.0, st = 0.0;
    for (int64_t i = 0; i < m; i++) {
        double x = ys[i];
        sh += horner(coef, 16, x);
        sc += clenshaw(cheb, 24, x);
    }
    for (int64_t i = 0; i < m / 4; i++) st += taylor_exp(ys[i * 4] * 3.0);
    printf("%llu %llu %llu\n", bits(sh), bits(sc), bits(st));
    return 0;
}
