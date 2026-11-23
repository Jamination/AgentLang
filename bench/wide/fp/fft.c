#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void fft(double *re, double *im, int64_t n, const double *twr, const double *twi, int inverse) {
    int64_t j = 0;
    for (int64_t i = 1; i < n; i++) {
        int64_t bit = n >> 1;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            double t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    double sign = inverse ? -1.0 : 1.0;
    for (int64_t size = 2; size <= n; size <<= 1) {
        int64_t half = size >> 1;
        int64_t step = n / size;
        for (int64_t start = 0; start < n; start += size) {
            for (int64_t k = 0; k < half; k++) {
                double wr = twr[k * step];
                double wi = sign * twi[k * step];
                int64_t a = start + k, b = a + half;
                double xr = re[b] * wr - im[b] * wi;
                double xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr;
                im[b] = im[a] - xi;
                re[a] = re[a] + xr;
                im[a] = im[a] + xi;
            }
        }
    }
    if (inverse) {
        double s = 1.0 / (double)n;
        for (int64_t i = 0; i < n; i++) { re[i] = re[i] * s; im[i] = im[i] * s; }
    }
}

int main(void) {
    int logn = 16;
    int64_t n = (int64_t)1 << logn;
    double c = 0.0, s = 1.0;
    for (int l = 2; l < logn; l++) {
        double c2 = sqrt((1.0 + c) * 0.5);
        s = s / (2.0 * c2);
        c = c2;
    }
    double *twr = calloc(n / 2, 8), *twi = calloc(n / 2, 8);
    twr[0] = 1.0; twi[0] = 0.0;
    for (int64_t k = 1; k < n / 2; k++) {
        twr[k] = twr[k - 1] * c + twi[k - 1] * s;
        twi[k] = twi[k - 1] * c - twr[k - 1] * s;
    }
    double *re = calloc(n, 8), *im = calloc(n, 8);
    for (int64_t i = 0; i < n; i++) {
        re[i] = (double)((i * 7919) % 1000) / 1000.0;
        im[i] = (double)((i * 104729) % 777) / 777.0;
    }
    for (int r = 0; r < 60; r++) {
        fft(re, im, n, twr, twi, 0);
        fft(re, im, n, twr, twi, 1);
    }
    double sr = 0.0, si = 0.0;
    for (int64_t i = 0; i < n; i++) {
        sr += re[i] * (double)(i % 7 + 1);
        si += im[i] * (double)(i % 5 + 1);
    }
    uint64_t br, bi; memcpy(&br, &sr, 8); memcpy(&bi, &si, 8);
    printf("%llu %llu %lld %lld\n", (unsigned long long)br, (unsigned long long)bi, (long long)(int64_t)sr, (long long)(int64_t)si);
    return 0;
}
