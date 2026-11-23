/* [library] strstr occurrence counting: see substr_lib.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
int main(void) {
    int64_t n = 8 << 20;
    char *s = malloc(n + 1);
    uint64_t seed = 3;
    for (int64_t i = 0; i < n; i++) {
        seed = lcg(seed);
        uint64_t r = seed >> 58;
        s[i] = r < 10 ? ' ' : (char)(97 + (seed >> 33) % 20);
    }
    s[n] = 0;
    int64_t total = 0;
    for (int q = 0; q < 120; q++) {
        seed = lcg(seed);
        int64_t m = 4 + q % 6;
        int64_t at = (int64_t)((seed >> 33) % (uint64_t)(n - m));
        char p[16];
        memcpy(p, s + at, m);
        p[m] = 0;
        int64_t c = 0;
        char *i = strstr(s, p);
        while (i) {
            c++;
            i = strstr(i + 1, p);
        }
        total = total * 31 + c;
    }
    printf("%lld\n", (long long)total);
    return 0;
}
