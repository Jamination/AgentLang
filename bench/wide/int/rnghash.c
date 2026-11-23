#include <stdint.h>
#include <stdio.h>
static uint32_t pcg32(uint64_t *state) {
    uint64_t old = *state;
    *state = old * 6364136223846793005ull + 1442695040888963407ull;
    uint32_t xorshifted = (uint32_t)(((old >> 18) ^ old) >> 27);
    uint32_t rot = (uint32_t)(old >> 59);
    return (xorshifted >> rot) | (xorshifted << ((0 - rot) & 31));
}
static uint64_t xorshift64s(uint64_t *s) {
    uint64_t x = *s;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    *s = x;
    return x * 0x2545F4914F6CDD1Dull;
}
static uint64_t splitmix64(uint64_t *s) {
    *s += 0x9E3779B97F4A7C15ull;
    uint64_t z = *s;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}
static uint64_t fmix64(uint64_t k) {
    k ^= k >> 33;
    k *= 0xff51afd7ed558ccdull;
    k ^= k >> 33;
    k *= 0xc4ceb9fe1a85ec53ull;
    return k ^ (k >> 33);
}
static uint64_t fnv1a_u64(uint64_t h, uint64_t v) {
    for (int i = 0; i < 8; i++) {
        h ^= (v >> (uint64_t)(8 * i)) & 0xFF;
        h *= 0x100000001B3ull;
    }
    return h;
}
int main(void) {
    uint64_t ps = 42, xs = 88172645463325252ull, ss = 7, h = 0xcbf29ce484222325ull, acc = 0;
    uint32_t acc32 = 0;
    for (int64_t i = 0; i < 45000000; i++) {
        uint32_t a = pcg32(&ps);
        uint64_t b = xorshift64s(&xs);
        uint64_t c = splitmix64(&ss);
        acc32 += a;
        acc += fmix64(b ^ (uint64_t)a) + c;
        h = fnv1a_u64(h, c ^ b);
    }
    printf("%llu %u %llu\n", (unsigned long long)acc, acc32, (unsigned long long)h);
    return 0;
}
