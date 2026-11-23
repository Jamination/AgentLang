#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { double m[16]; } M4;
typedef struct { double x, y, z, w; } Quat;
typedef struct { double x, y, z; } V3;

static M4 mul(M4 a, M4 b) {
    M4 r;
    memset(&r, 0, sizeof r);
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            double s = 0.0;
            for (int k = 0; k < 4; k++) s += a.m[i * 4 + k] * b.m[k * 4 + j];
            r.m[i * 4 + j] = s;
        }
    return r;
}

static Quat qmul(Quat a, Quat b) {
    Quat r = {
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
    return r;
}

static Quat qnormalize(Quat q) {
    double inv = 1.0 / sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    Quat r = {q.x * inv, q.y * inv, q.z * inv, q.w * inv};
    return r;
}

static M4 to_matrix(Quat q, V3 t) {
    M4 r;
    memset(&r, 0, sizeof r);
    r.m[0] = 1.0 - 2.0 * (q.y * q.y + q.z * q.z);
    r.m[1] = 2.0 * (q.x * q.y - q.z * q.w);
    r.m[2] = 2.0 * (q.x * q.z + q.y * q.w);
    r.m[3] = t.x;
    r.m[4] = 2.0 * (q.x * q.y + q.z * q.w);
    r.m[5] = 1.0 - 2.0 * (q.x * q.x + q.z * q.z);
    r.m[6] = 2.0 * (q.y * q.z - q.x * q.w);
    r.m[7] = t.y;
    r.m[8] = 2.0 * (q.x * q.z - q.y * q.w);
    r.m[9] = 2.0 * (q.y * q.z + q.x * q.w);
    r.m[10] = 1.0 - 2.0 * (q.x * q.x + q.y * q.y);
    r.m[11] = t.z;
    r.m[15] = 1.0;
    return r;
}

static V3 transform(M4 m, V3 p) {
    V3 r = {
        m.m[0] * p.x + m.m[1] * p.y + m.m[2] * p.z + m.m[3],
        m.m[4] * p.x + m.m[5] * p.y + m.m[6] * p.z + m.m[7],
        m.m[8] * p.x + m.m[9] * p.y + m.m[10] * p.z + m.m[11]};
    return r;
}

static V3 rotate(Quat q, V3 v) {
    Quat vq = {v.x, v.y, v.z, 0.0};
    Quat cq = {-q.x, -q.y, -q.z, q.w};
    Quat p = qmul(qmul(q, vq), cq);
    V3 r = {p.x, p.y, p.z};
    return r;
}

static unsigned long long bits(double d) { uint64_t b; memcpy(&b, &d, 8); return (unsigned long long)b; }

int main(void) {
    Quat q = {0.0, 0.0, 0.0, 1.0};
    Quat dq0 = {0.001, 0.002, 0.0015, 1.0};
    Quat dq = qnormalize(dq0);
    M4 acc;
    memset(&acc, 0, sizeof acc);
    for (int i = 0; i < 4; i++) acc.m[i * 4 + i] = 1.0;
    V3 pts[8];
    for (int i = 0; i < 8; i++) {
        V3 p = {(double)i * 0.5, 1.0 - (double)i * 0.25, (double)(i % 3)};
        pts[i] = p;
    }
    double sx = 0.0, sy = 0.0, sz = 0.0;
    V3 tr = {0.001, -0.002, 0.0005};
    for (int64_t it = 0; it < 6000000; it++) {
        q = qnormalize(qmul(q, dq));
        M4 r = to_matrix(q, tr);
        acc = mul(r, acc);
        if (it % 64 == 63) acc = r;
        V3 p = pts[it & 7];
        V3 a = transform(acc, p);
        V3 b = rotate(q, p);
        sx += a.x + b.x;
        sy += a.y + b.y;
        sz += a.z + b.z;
    }
    printf("%llu %llu %llu %llu\n", bits(sx), bits(sy), bits(sz), bits(q.w));
    return 0;
}
