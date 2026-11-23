#include <stdint.h>
#include <stdio.h>

static int64_t tak(int64_t x, int64_t y, int64_t z) {
    return y < x ? tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y)) : z;
}

static int64_t ack(int64_t m, int64_t n) {
    if (m == 0) return n + 1;
    if (n == 0) return ack(m - 1, 1);
    return ack(m - 1, ack(m, n - 1));
}

int main(int argc, char **argv) {
    (void)argv;
    int64_t base = argc, t = 0, a = 0;
    for (int64_t i = 0; i < 4; i++) t += tak(22 + base + i, 14 + base, 6 + base);
    for (int64_t i = 0; i < 3; i++) a += ack(2 + base, 8 + base + i);
    printf("%lld %lld\n", (long long)t, (long long)a);
    return 0;
}
