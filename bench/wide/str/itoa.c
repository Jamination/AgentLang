/* [codegen] hand-written itoa/atoi round trip: see itoa.al */
#include <stdint.h>
#include <stdio.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static int64_t itoa_(int64_t v, uint8_t *buf) {
    uint8_t tmp[24];
    int neg = v < 0;
    uint64_t u = neg ? 0 - (uint64_t)v : (uint64_t)v;
    int64_t k = 0;
    for (;;) { tmp[k++] = (uint8_t)(48 + u % 10); u /= 10; if (u == 0) break; }
    int64_t n = 0;
    if (neg) { buf[0] = '-'; n = 1; }
    while (k > 0) buf[n++] = tmp[--k];
    return n;
}
static int64_t atoi_(const uint8_t *s, int64_t len) {
    int64_t i = 0;
    int neg = 0;
    if (len > 0 && s[0] == '-') { neg = 1; i = 1; }
    uint64_t v = 0;
    while (i < len) {
        uint8_t d = (uint8_t)(s[i] - '0');
        if (d > 9) break;
        v = v * 10 + d;
        i++;
    }
    return neg ? (int64_t)(0 - v) : (int64_t)v;
}
int main(void) {
    uint8_t buf[32];
    uint64_t seed = 1;
    int64_t sum = 0, lens = 0;
    for (int64_t i = 0; i < 15000000; i++) {
        seed = lcg(seed);
        int64_t x = (int64_t)seed >> (int64_t)((seed >> 20) % 63);
        int64_t n = itoa_(x, buf);
        lens += n;
        int64_t y = atoi_(buf, n);
        sum += y ^ i;
    }
    printf("%lld %lld\n", (long long)lens, (long long)sum);
    return 0;
}
