#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { double x, y, z; } V3;
typedef struct { V3 p, v; } Body;
typedef struct { double re, im; } Cx;

static V3 add(V3 a, V3 b) { return (V3){a.x + b.x, a.y + b.y, a.z + b.z}; }
static V3 scale(V3 a, double s) { return (V3){a.x * s, a.y * s, a.z * s}; }
static double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V3 cross(V3 a, V3 b) { return (V3){a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}; }

static V3 accel(V3 p, V3 axis) {
    double r2 = dot(p, p) + 0.01;
    return add(scale(p, -1.0 / r2), scale(cross(axis, p), 0.001));
}

static Body step(Body b, V3 axis, double dt) {
    V3 v = add(b.v, scale(accel(b.p, axis), dt));
    return (Body){add(b.p, scale(v, dt)), v};
}

static Cx cmul(Cx a, Cx b) { return (Cx){a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
static Cx cadd(Cx a, Cx b) { return (Cx){a.re + b.re, a.im + b.im}; }
static double norm2(Cx a) { return a.re * a.re + a.im * a.im; }

static int64_t julia(Cx z0, Cx c, int64_t limit) {
    Cx z = z0;
    for (int64_t i = 0; i < limit; i++) {
        if (norm2(z) > 4.0) return i;
        z = cadd(cmul(z, z), c);
    }
    return limit;
}

int main(void) {
    V3 axis = {0.0, 0.0, 1.0};
    Body *bodies = calloc(64, sizeof(Body));
    for (int64_t i = 0; i < 64; i++) {
        double f = (double)i;
        bodies[i] = (Body){{1.0 + f * 0.01, 0.5, -0.25}, {0.0, 0.8 - f * 0.005, 0.1}};
    }
    for (int64_t s = 0; s < 1000000; s++)
        for (int64_t i = 0; i < 64; i++) bodies[i] = step(bodies[i], axis, 0.001);
    double e = 0.0;
    for (int64_t i = 0; i < 64; i++) e += dot(bodies[i].v, bodies[i].v) + dot(bodies[i].p, bodies[i].p);
    Cx c = {-0.8, 0.156};
    int64_t iters = 0;
    for (int64_t y = 0; y < 1200; y++)
        for (int64_t x = 0; x < 1200; x++) {
            Cx z = {(double)x * (3.0 / 1200.0) - 1.5, (double)y * (3.0 / 1200.0) - 1.5};
            iters += julia(z, c, 200);
        }
    printf("%.6f %lld\n", e, (long long)iters);
    return 0;
}
