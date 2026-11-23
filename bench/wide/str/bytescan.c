/* [codegen] byte scanning: see bytescan.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }

static uint8_t *gen(int64_t n) {
    uint8_t *buf = calloc(n, 1);
    uint64_t seed = 12345;
    for (int64_t i = 0; i < n; i++) {
        seed = lcg(seed);
        uint64_t r = (seed >> 33) % 200;
        buf[i] = r < 3 ? '\n' : r == 3 ? 0 : (uint8_t)(97 + (seed >> 45) % 26);
    }
    return buf;
}
static int64_t count_nl(const uint8_t *s, int64_t len) {
    int64_t n = 0;
    for (int64_t i = 0; i < len; i++) if (s[i] == '\n') n++;
    return n;
}
static int64_t strlens(const uint8_t *s, int64_t n) {
    int64_t total = 0, k = 0, i = 0;
    while (i < n) {
        int64_t j = i;
        while (j < n && s[j] != 0) j++;
        total += (j - i) * (k & 7);
        k++;
        i = j + 1;
    }
    return total;
}
static int64_t find_byte(const uint8_t *s, int64_t len, int64_t from, uint8_t c) {
    for (int64_t i = from; i < len; i++) if (s[i] == c) return i;
    return -1;
}
static int64_t count_q(const uint8_t *s, int64_t len) {
    int64_t n = 0, sum = 0;
    int64_t i = find_byte(s, len, 0, 'q');
    while (i >= 0) {
        n++;
        sum += i & 1023;
        i = find_byte(s, len, i + 1, 'q');
    }
    return n * 1000003 + sum;
}
int main(void) {
    int64_t n = 16 << 20;
    uint8_t *buf = gen(n);
    int64_t a = 0, b = 0, c = 0;
    for (int r = 0; r < 12; r++) {
        a += count_nl(buf, n);
        b += strlens(buf, n);
        c += count_q(buf, n);
        buf[r * 1000] = '\n';
    }
    printf("%lld %lld %lld\n", (long long)a, (long long)b, (long long)c);
    return 0;
}
