/* [library] snprintf/strtoll/strtod: see fmtparse.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
int main(void) {
    uint64_t seed = 77;
    int64_t isum = 0, lens = 0;
    double fsum = 0.0;
    char buf[64];
    for (int64_t i = 0; i < 2000000; i++) {
        seed = lcg(seed);
        int64_t x = (int64_t)seed >> (int64_t)((seed >> 20) % 63);
        int n = snprintf(buf, sizeof buf, "%lld", (long long)x);
        lens += n;
        char *end;
        long long v = strtoll(buf, &end, 10);
        if (*end == 0) isum += v ^ i;
        double f = (double)((int64_t)(seed >> 34) - (1LL << 29)) / 8.0;
        n = snprintf(buf, sizeof buf, "%.3f", f);
        lens += n;
        double g = strtod(buf, &end);
        if (*end == 0) fsum += g;
    }
    printf("%lld %lld %lld\n", (long long)lens, (long long)isum, (long long)(fsum * 8.0));
    return 0;
}
