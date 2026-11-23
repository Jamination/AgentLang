#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { double *x, *y, *z, *vx, *vy, *vz, *m; int64_t *hits; int64_t n; } Soa;

static void step(Soa *s, double dt, double k) {
    for (int64_t i = 0; i < s->n; i++) {
        s->vx[i] += (0.0 - s->x[i] * k) * dt / s->m[i];
        s->vy[i] += (0.0 - s->y[i] * k - 9.81) * dt / s->m[i];
        s->vz[i] += (0.0 - s->z[i] * k) * dt / s->m[i];
        s->x[i] += s->vx[i] * dt;
        s->y[i] += s->vy[i] * dt;
        s->z[i] += s->vz[i] * dt;
        if (s->y[i] < -1.0) {
            s->y[i] = -1.0;
            s->vy[i] = 0.0 - s->vy[i] * 0.9;
            s->hits[i] += 1;
        }
    }
}

int main(void) {
    int64_t n = 200000;
    Soa s;
    s.x = calloc(n, 8); s.y = calloc(n, 8); s.z = calloc(n, 8); s.vx = calloc(n, 8);
    s.vy = calloc(n, 8); s.vz = calloc(n, 8); s.m = calloc(n, 8); s.hits = calloc(n, 8); s.n = n;
    uint64_t seed = 12345;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        s.x[i] = (double)(int64_t)(seed >> 40) / 16777216.0 - 0.5;
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        s.y[i] = (double)(int64_t)(seed >> 40) / 16777216.0;
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        s.z[i] = (double)(int64_t)(seed >> 40) / 16777216.0 - 0.5;
        s.m[i] = 1.0 + (double)(i % 7);
    }
    for (int t = 0; t < 1000; t++) step(&s, 0.001, 3.0);
    double sx = 0.0;
    int64_t hits = 0;
    for (int64_t i = 0; i < n; i++) {
        sx += s.x[i] + s.y[i] + s.z[i] + s.vx[i] + s.vy[i] + s.vz[i];
        hits += s.hits[i];
    }
    printf("%lld %lld\n", (long long)(int64_t)(sx * 1000.0), (long long)hits);
    return 0;
}
