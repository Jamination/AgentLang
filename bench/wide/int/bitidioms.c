#include <stdint.h>
#include <stdio.h>
static uint64_t pop_loop(uint64_t v) {
    uint64_t x = v, c = 0;
    while (x != 0) {
        x &= x - 1;
        c += 1;
    }
    return c;
}
static uint64_t pop_swar(uint64_t v) {
    uint64_t x = v - ((v >> 1) & 0x5555555555555555ull);
    x = (x & 0x3333333333333333ull) + ((x >> 2) & 0x3333333333333333ull);
    x = (x + (x >> 4)) & 0x0F0F0F0F0F0F0F0Full;
    return (x * 0x0101010101010101ull) >> 56;
}
static uint64_t rotl64(uint64_t x, uint64_t r) { return (x << (r & 63)) | (x >> ((64 - r) & 63)); }
static uint64_t bswap64(uint64_t x) {
    return (x >> 56) | ((x >> 40) & 0xFF00ull) | ((x >> 24) & 0xFF0000ull) | ((x >> 8) & 0xFF000000ull) |
           ((x << 8) & 0xFF00000000ull) | ((x << 24) & 0xFF0000000000ull) | ((x << 40) & 0xFF000000000000ull) | (x << 56);
}
static uint64_t ctz_loop(uint64_t v) {
    if (v == 0) return 64;
    uint64_t x = v, n = 0;
    while ((x & 1) == 0) {
        x >>= 1;
        n += 1;
    }
    return n;
}
static uint64_t clz_loop(uint64_t v) {
    if (v == 0) return 64;
    uint64_t x = v, n = 0;
    while ((x & 0x8000000000000000ull) == 0) {
        x <<= 1;
        n += 1;
    }
    return n;
}
static uint64_t rev64(uint64_t v) {
    uint64_t x = ((v >> 1) & 0x5555555555555555ull) | ((v & 0x5555555555555555ull) << 1);
    x = ((x >> 2) & 0x3333333333333333ull) | ((x & 0x3333333333333333ull) << 2);
    x = ((x >> 4) & 0x0F0F0F0F0F0F0F0Full) | ((x & 0x0F0F0F0F0F0F0F0Full) << 4);
    return bswap64(x);
}
int main(void) {
    uint64_t s = 0x123456789ABCDEF1ull, acc = 0;
    for (int64_t i = 0; i < 12000000; i++) {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        uint64_t x = s;
        acc += pop_loop(x & 0x00FF00FF00FF00FFull);
        acc += pop_swar(x);
        acc ^= rotl64(x, acc);
        acc += bswap64(x) >> 3;
        acc += ctz_loop(x & 0xFFFFFFFFFFFFFF00ull) + clz_loop(x >> (x & 31));
        acc ^= x & (0 - x);
        acc += rev64(x) >> 7;
    }
    printf("%llu\n", (unsigned long long)acc);
    return 0;
}
