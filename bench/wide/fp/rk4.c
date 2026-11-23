#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { double x, y, z; } S3;

static S3 lorenz(S3 s) {
    S3 r = {10.0 * (s.y - s.x), s.x * (28.0 - s.z) - s.y, s.x * s.y - 8.0 / 3.0 * s.z};
    return r;
}

static S3 axpy(S3 a, double h, S3 b) {
    S3 r = {a.x + h * b.x, a.y + h * b.y, a.z + h * b.z};
    return r;
}

static S3 rk4_step(S3 s, double h) {
    S3 k1 = lorenz(s);
    S3 k2 = lorenz(axpy(s, h * 0.5, k1));
    S3 k3 = lorenz(axpy(s, h * 0.5, k2));
    S3 k4 = lorenz(axpy(s, h, k3));
    double h6 = h / 6.0;
    S3 r = {
        s.x + h6 * (k1.x + 2.0 * k2.x + 2.0 * k3.x + k4.x),
        s.y + h6 * (k1.y + 2.0 * k2.y + 2.0 * k3.y + k4.y),
        s.z + h6 * (k1.z + 2.0 * k2.z + 2.0 * k3.z + k4.z)};
    return r;
}

static void well(double x, double v, double *a, double *b) {
    *a = v;
    *b = x - x * x * x - 0.1 * v;
}

static void rk4_well(double *px, double *pv, double h) {
    double x = *px, v = *pv, a1, b1, a2, b2, a3, b3, a4, b4;
    well(x, v, &a1, &b1);
    well(x + 0.5 * h * a1, v + 0.5 * h * b1, &a2, &b2);
    well(x + 0.5 * h * a2, v + 0.5 * h * b2, &a3, &b3);
    well(x + h * a3, v + h * b3, &a4, &b4);
    *px = x + h / 6.0 * (a1 + 2.0 * a2 + 2.0 * a3 + a4);
    *pv = v + h / 6.0 * (b1 + 2.0 * b2 + 2.0 * b3 + b4);
}

static unsigned long long bits(double d) { uint64_t b; memcpy(&b, &d, 8); return (unsigned long long)b; }

int main(void) {
    S3 s = {1.0, 1.0, 1.0};
    double h = 0.0005, acc = 0.0;
    for (int64_t i = 0; i < 8000000; i++) {
        s = rk4_step(s, h);
        acc += s.z;
    }
    double x = 0.5, v = 1.2;
    for (int64_t i = 0; i < 8000000; i++) rk4_well(&x, &v, 0.001);
    printf("%llu %llu %llu %llu %llu %llu\n", bits(s.x), bits(s.y), bits(s.z), bits(acc), bits(x), bits(v));
    return 0;
}
