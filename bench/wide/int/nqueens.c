#include <stdint.h>
#include <stdio.h>
static int64_t solve(uint32_t cols, uint32_t ld, uint32_t rd, uint32_t all) {
    if (cols == all) return 1;
    int64_t count = 0;
    uint32_t avail = all & ~(cols | ld | rd);
    while (avail != 0) {
        uint32_t bit = avail & (0 - avail);
        avail ^= bit;
        count += solve(cols | bit, ((ld | bit) << 1) & all, (rd | bit) >> 1, all);
    }
    return count;
}
int main(void) {
    int64_t total = 0;
    for (int64_t n = 4; n <= 15; n++) {
        uint32_t all = (1u << (uint32_t)n) - 1;
        int64_t c = solve(0, 0, 0, all);
        total = total * 31 + c;
        printf("%lld %lld\n", (long long)n, (long long)c);
    }
    printf("%lld\n", (long long)total);
    return 0;
}
