#include <stdint.h>
#include <stdio.h>
static uint64_t gcd(uint64_t a, uint64_t b) {
    while (b != 0) {
        uint64_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}
static uint64_t bgcd(uint64_t a, uint64_t b) {
    if (a == 0) return b;
    if (b == 0) return a;
    uint64_t shift = 0;
    while (((a | b) & 1) == 0) {
        a >>= 1;
        b >>= 1;
        shift += 1;
    }
    while ((a & 1) == 0) a >>= 1;
    while (b != 0) {
        while ((b & 1) == 0) b >>= 1;
        if (a > b) {
            uint64_t t = a;
            a = b;
            b = t;
        }
        b -= a;
    }
    return a << shift;
}
static int64_t collatz_len(uint64_t n) {
    int64_t steps = 0;
    while (n != 1) {
        n = (n & 1) == 0 ? n >> 1 : 3 * n + 1;
        steps += 1;
    }
    return steps;
}
int main(void) {
    uint64_t s = 0, x = 0x9E3779B97F4A7C15ull;
    for (int64_t i = 0; i < 1500000; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
        uint64_t a = x >> 20;
        uint64_t b = (x << 7) >> 30;
        s += gcd(a, b) + bgcd(a + 2, b * 6);
    }
    int64_t best = 0, total = 0;
    uint64_t bestn = 0;
    for (int64_t n = 1; n < 1500000; n++) {
        int64_t l = collatz_len((uint64_t)n);
        total += l;
        if (l > best) {
            best = l;
            bestn = (uint64_t)n;
        }
    }
    printf("%llu %lld %llu %lld\n", (unsigned long long)s, (long long)best, (unsigned long long)bestn, (long long)total);
    return 0;
}
