#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { double x, y, z; } V3;
typedef struct { V3 c; double r, refl; } Ball;
typedef struct { double t; int64_t idx; } Hit;

static V3 v3(double x, double y, double z) { V3 v = {x, y, z}; return v; }
static V3 add(V3 a, V3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
static V3 sub(V3 a, V3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
static V3 scale(V3 a, double s) { return v3(a.x * s, a.y * s, a.z * s); }
static double dot(V3 a, V3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V3 normalize(V3 a) { return scale(a, 1.0 / sqrt(dot(a, a))); }

static const V3 LIGHT = {-5.0, 8.0, -3.0};

static Hit intersect(const Ball *balls, int64_t n, V3 o, V3 d) {
    Hit best = {1e30, -1};
    for (int64_t i = 0; i < n; i++) {
        V3 oc = sub(o, balls[i].c);
        double b = dot(oc, d);
        double c = dot(oc, oc) - balls[i].r * balls[i].r;
        double disc = b * b - c;
        if (disc > 0.0) {
            double s = sqrt(disc);
            double t = -b - s;
            if (t < 1e-6) t = -b + s;
            if (t > 1e-6 && t < best.t) { best.t = t; best.idx = i; }
        }
    }
    return best;
}

static double trace(const Ball *balls, int64_t nb, V3 o, V3 d) {
    double color = 0.0, weight = 1.0;
    for (int depth = 0; depth < 4; depth++) {
        Hit h = intersect(balls, nb, o, d);
        if (h.idx < 0) { color += weight * 0.25 * (d.y + 1.0); break; }
        V3 p = add(o, scale(d, h.t));
        V3 n = normalize(sub(p, balls[h.idx].c));
        V3 l = normalize(sub(LIGHT, p));
        double diff = dot(n, l);
        if (diff < 0.0) diff = 0.0;
        V3 q = add(p, scale(n, 1e-4));
        if (diff > 0.0) {
            Hit sh = intersect(balls, nb, q, l);
            if (sh.idx >= 0) diff *= 0.2;
        }
        double refl = balls[h.idx].refl;
        color += weight * (1.0 - refl) * diff;
        weight *= refl;
        if (weight < 0.01) break;
        d = normalize(sub(d, scale(n, 2.0 * dot(d, n))));
        o = q;
    }
    return color;
}

int main(void) {
    static Ball balls[10];
    int k = 0;
    for (int gz = 0; gz < 3; gz++)
        for (int gx = 0; gx < 3; gx++) {
            double cx = (double)(gx - 1) * 2.2;
            double cz = 4.0 + (double)gz * 2.2;
            double r = 0.6 + (double)((gx + gz) % 3) * 0.2;
            Ball b = {{cx, 0.0 + r - 1.0, cz}, r, (double)(k % 4) * 0.25};
            balls[k++] = b;
        }
    Ball fl = {{0.0, -1001.0, 5.0}, 1000.0, 0.1};
    balls[9] = fl;
    int64_t w = 2400, h = 1800;
    double sum = 0.0;
    V3 eye = {0.0, 1.0, -3.0};
    for (int64_t y = 0; y < h; y++)
        for (int64_t x = 0; x < w; x++) {
            double dx = ((double)x - (double)w * 0.5) / (double)h;
            double dy = ((double)h * 0.5 - (double)y) / (double)h;
            V3 d = normalize(v3(dx, dy - 0.2, 1.0));
            sum += trace(balls, 10, eye, d);
        }
    uint64_t bits; memcpy(&bits, &sum, 8);
    printf("%llu %lld\n", (unsigned long long)bits, (long long)(int64_t)sum);
    return 0;
}
