#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static inline double eval_A(int i, int j) {
    return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1);
}

static void eval_A_times_u(int n, const double *u, double *Au) {
    for (int i = 0; i < n; i++) {
        double s = 0.0;
        for (int j = 0; j < n; j++) {
            s += eval_A(i, j) * u[j];
        }
        Au[i] = s;
    }
}

static void eval_At_times_u(int n, const double *u, double *Au) {
    for (int i = 0; i < n; i++) {
        double s = 0.0;
        for (int j = 0; j < n; j++) {
            s += eval_A(j, i) * u[j];
        }
        Au[i] = s;
    }
}

static void eval_AtA_times_u(int n, const double *u, double *AtAu, double *v) {
    eval_A_times_u(n, u, v);
    eval_At_times_u(n, v, AtAu);
}

int main(void) {
    int n = 2000;
    double *u = malloc(n * sizeof(double));
    double *v = malloc(n * sizeof(double));
    double *t = malloc(n * sizeof(double));
    for (int i = 0; i < n; i++) u[i] = 1.0;
    for (int i = 0; i < 10; i++) {
        eval_AtA_times_u(n, u, v, t);
        eval_AtA_times_u(n, v, u, t);
    }
    double vBv = 0.0, vv = 0.0;
    for (int i = 0; i < n; i++) {
        vBv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    printf("%0.9f\n", sqrt(vBv / vv));
    return 0;
}
