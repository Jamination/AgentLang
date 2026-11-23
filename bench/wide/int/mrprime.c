#include <stdint.h>
#include <stdio.h>
typedef unsigned __int128 u128;
static inline uint64_t mulhi(uint64_t a, uint64_t b) { return (uint64_t)(((u128)a * b) >> 64); }
static inline uint64_t mont_mul(uint64_t a, uint64_t b, uint64_t n, uint64_t ninv) {
    uint64_t lo = a * b;
    uint64_t hi = mulhi(a, b);
    uint64_t m = lo * ninv;
    uint64_t mh = mulhi(m, n);
    uint64_t t = hi - mh;
    return hi < mh ? t + n : t;
}
static int is_prime(uint64_t n) {
    uint64_t ninv = n;
    for (int i = 0; i < 5; i++) ninv *= 2 - n * ninv;
    uint64_t one = (0 - n) % n;
    uint64_t r2 = one;
    for (int i = 0; i < 64; i++) {
        r2 = r2 + r2;
        if (r2 >= n) r2 -= n;
    }
    uint64_t nm1 = n - one;
    uint64_t d = n - 1;
    int64_t s = 0;
    while ((d & 1) == 0) {
        d >>= 1;
        s += 1;
    }
    static const uint64_t bases[12] = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37};
    for (int bi = 0; bi < 12; bi++) {
        uint64_t a = bases[bi];
        uint64_t x = one;
        uint64_t b = mont_mul(a, r2, n, ninv);
        uint64_t e = d;
        while (e != 0) {
            if ((e & 1) != 0) x = mont_mul(x, b, n, ninv);
            b = mont_mul(b, b, n, ninv);
            e >>= 1;
        }
        if (x == one || x == nm1) continue;
        int found = 0;
        for (int64_t j = 1; j < s; j++) {
            x = mont_mul(x, x, n, ninv);
            if (x == nm1) {
                found = 1;
                break;
            }
        }
        if (!found) return 0;
    }
    return 1;
}
int main(void) {
    uint64_t base = 0x4000000000000001ull;
    int64_t count = 0;
    uint64_t xs = 0;
    for (int64_t k = 0; k < 2000000; k++) {
        uint64_t n = base + (uint64_t)k * 2;
        if (is_prime(n)) {
            count += 1;
            xs ^= n * 0x9E3779B97F4A7C15ull;
        }
    }
    printf("%lld %llu\n", (long long)count, (unsigned long long)xs);
    return 0;
}
