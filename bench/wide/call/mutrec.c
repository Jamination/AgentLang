#include <stdint.h>
#include <stdio.h>

static int64_t hm(int64_t n);
static int64_t hf(int64_t n) { return n == 0 ? 1 : n - hm(hf(n - 1)); }
static int64_t hm(int64_t n) { return n == 0 ? 0 : n - hf(hm(n - 1)); }

static int64_t odd_step(int64_t n, int64_t steps);
static int64_t even_step(int64_t n, int64_t steps) {
    if (n == 1) return steps;
    if ((n & 1) == 1) return odd_step(n, steps);
    return even_step(n >> 1, steps + 1);
}
static int64_t odd_step(int64_t n, int64_t steps) { return even_step(3 * n + 1, steps + 1); }

static int64_t gcd(int64_t a, int64_t b) { return b == 0 ? a : gcd(b, a % b); }

static int64_t digsum(int64_t n, int64_t acc) { return n == 0 ? acc : digsum(n / 10, acc + n % 10); }

int main(int argc, char **argv) {
    (void)argv;
    int64_t base = argc;
    int64_t h = 0, c = 0, g = 0, d = 0;
    for (int64_t i = 0; i < 60; i++) h += hf(i + base) + hm(i + base);
    for (int64_t i = 1; i < 1500000; i++) c += even_step(i + base, 0);
    for (int64_t i = 1; i < 1500; i++)
        for (int64_t j = 1; j < 400; j++) g += gcd(i * 7919 + base, j * 104729);
    for (int64_t i = 0; i < 3000000; i++) d += digsum(i * base, 0);
    printf("%lld %lld %lld %lld\n", (long long)h, (long long)c, (long long)g, (long long)d);
    return 0;
}
