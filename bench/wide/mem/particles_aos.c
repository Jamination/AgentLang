#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { double x, y, z, vx, vy, vz, m; int64_t hits; } P;

static void step(P *ps, int64_t n, double dt, double k) {
    for (int64_t i = 0; i < n; i++) {
        P *p = &ps[i];
        p->vx += (0.0 - p->x * k) * dt / p->m;
        p->vy += (0.0 - p->y * k - 9.81) * dt / p->m;
        p->vz += (0.0 - p->z * k) * dt / p->m;
        p->x += p->vx * dt;
        p->y += p->vy * dt;
        p->z += p->vz * dt;
        if (p->y < -1.0) {
            p->y = -1.0;
            p->vy = 0.0 - p->vy * 0.9;
            p->hits += 1;
        }
    }
}

int main(void) {
    int64_t n = 200000;
    P *ps = calloc(n, sizeof(P));
    uint64_t seed = 12345;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        ps[i].x = (double)(int64_t)(seed >> 40) / 16777216.0 - 0.5;
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        ps[i].y = (double)(int64_t)(seed >> 40) / 16777216.0;
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        ps[i].z = (double)(int64_t)(seed >> 40) / 16777216.0 - 0.5;
        ps[i].m = 1.0 + (double)(i % 7);
    }
    for (int s = 0; s < 1000; s++) step(ps, n, 0.001, 3.0);
    double sx = 0.0;
    int64_t hits = 0;
    for (int64_t i = 0; i < n; i++) {
        P p = ps[i];
        sx += p.x + p.y + p.z + p.vx + p.vy + p.vz;
        hits += p.hits;
    }
    printf("%lld %lld\n", (long long)(int64_t)(sx * 1000.0), (long long)hits);
    return 0;
}
