#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
    int64_t d = (int64_t)argc + 999;
    uint32_t du = (uint32_t)d;
    uint64_t sum = 0;
    int64_t acc = 0;
    uint32_t acc32 = 0;
    for (int64_t i = 0; i < 30000000; i++) {
        uint64_t x = (uint64_t)i * 2654435761ull;
        uint64_t t = x;
        while (t != 0) {
            sum += t % 10;
            t = t / 10;
        }
        int64_t y = (int64_t)x - 0x8000000000000LL;
        acc = (int64_t)((uint64_t)acc + (uint64_t)(y / 7 + y % 13 - y / 1000));
        acc ^= y / d + y % d;
        uint32_t z = (uint32_t)x;
        acc32 += z / 3 + z % 100 + z / du;
    }
    printf("%llu %lld %u\n", (unsigned long long)sum, (long long)acc, acc32);
    return 0;
}
