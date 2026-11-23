#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static double lu(double *a, int64_t n, int64_t *piv) {
    double det = 1.0;
    for (int64_t k = 0; k < n; k++) {
        int64_t p = k;
        double best = fabs(a[k * n + k]);
        for (int64_t i = k + 1; i < n; i++) {
            double v = fabs(a[i * n + k]);
            if (v > best) { best = v; p = i; }
        }
        piv[k] = p;
        if (p != k) {
            det = -det;
            for (int64_t j = 0; j < n; j++) {
                double t = a[k * n + j];
                a[k * n + j] = a[p * n + j];
                a[p * n + j] = t;
            }
        }
        double pivot = a[k * n + k];
        det *= pivot;
        double *rk = a + k * n;
        for (int64_t i = k + 1; i < n; i++) {
            double *ri = a + i * n;
            double f = ri[k] / pivot;
            ri[k] = f;
            for (int64_t j = k + 1; j < n; j++) ri[j] -= f * rk[j];
        }
    }
    return det;
}

int main(void) {
    int64_t n = 400;
    double *a = calloc(n * n, 8);
    int64_t *piv = calloc(n, 8);
    uint64_t seed = 12345;
    double total = 0.0;
    int64_t psum = 0;
    for (int64_t rep = 0; rep < 60; rep++) {
        for (int64_t i = 0; i < n * n; i++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            a[i] = (double)((int64_t)(seed >> 33) % 2001 - 1000) / 1000.0;
        }
        double det = lu(a, n, piv);
        total += a[(rep * 37) % (n * n)] + (det < 0.0 ? -1.0 : 1.0);
        for (int64_t i = 0; i < n; i++) psum += piv[i] * (i + 1);
        double s = 0.0;
        for (int64_t i = 0; i < n * n; i++) s += a[i];
        total += s;
    }
    uint64_t b; memcpy(&b, &total, 8);
    printf("%llu %lld %lld\n", (unsigned long long)b, (long long)psum, (long long)(int64_t)(total * 1000.0));
    return 0;
}
