#include <stdint.h>
#include <stdio.h>

typedef struct { uint64_t s; } Gen;

static double next_double(Gen *g) {
    uint64_t x = g->s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    g->s = x;
    uint64_t r = x * 2685821657736338717ULL;
    return (double)(r >> 11) * (1.0 / 9007199254740992.0);
}

int main(void) {
    Gen g = {88172645463325252ULL};
    int64_t n = 40000000, in2 = 0, in3 = 0, under = 0;
    for (int64_t i = 0; i < n; i++) {
        double x = next_double(&g);
        double y = next_double(&g);
        double z = next_double(&g);
        if (x * x + y * y < 1.0) {
            in2 += 1;
            if (x * x + y * y + z * z < 1.0) in3 += 1;
        }
        if (y < x * x - x * x * x + 0.5) under += 1;
    }
    printf("%lld %lld %lld\n", (long long)in2, (long long)in3, (long long)under);
    return 0;
}
