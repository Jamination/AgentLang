#include <stdio.h>
#include <stdlib.h>

static double **mm_init(int n) {
    double **m = malloc(n * sizeof(double *));
    for (int i = 0; i < n; i++) m[i] = calloc(n, sizeof(double));
    return m;
}

static double **mm_gen(int n, double seed) {
    double **a = mm_init(n);
    double tmp = seed / n / n;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) a[i][j] = tmp * (i - j) * (i + j);
    return a;
}

static double **mm_mul(int n, double **a, double **b) {
    double **m = mm_init(n);
    double **c = mm_init(n);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) c[i][j] = b[j][i];
    for (int i = 0; i < n; i++) {
        double *p = a[i], *q = m[i];
        for (int j = 0; j < n; j++) {
            double t = 0.0, *r = c[j];
            for (int k = 0; k < n; k++) t += p[k] * r[k];
            q[j] = t;
        }
    }
    return m;
}

int main(void) {
    int n = 800;
    double **a = mm_gen(n, 1.0);
    double **b = mm_gen(n, 2.0);
    double **m = mm_mul(n, a, b);
    double trace = 0.0;
    for (int i = 0; i < n; i++) trace += m[i][i];
    printf("%.9f\n%.9f\n", m[n / 2][n / 2], trace);
    return 0;
}
