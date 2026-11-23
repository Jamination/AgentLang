/* [codegen] base64 encode/decode: see base64.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static const uint8_t ALPHA[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
static int64_t encode(const uint8_t *src, int64_t n, uint8_t *dst) {
    int64_t k = 0, i = 0;
    while (i + 3 <= n) {
        uint32_t v = ((uint32_t)src[i] << 16) | ((uint32_t)src[i + 1] << 8) | src[i + 2];
        dst[k] = ALPHA[v >> 18];
        dst[k + 1] = ALPHA[(v >> 12) & 63];
        dst[k + 2] = ALPHA[(v >> 6) & 63];
        dst[k + 3] = ALPHA[v & 63];
        k += 4;
        i += 3;
    }
    int64_t rest = n - i;
    if (rest > 0) {
        uint32_t v = (uint32_t)src[i] << 16;
        if (rest == 2) v |= (uint32_t)src[i + 1] << 8;
        dst[k] = ALPHA[v >> 18];
        dst[k + 1] = ALPHA[(v >> 12) & 63];
        dst[k + 2] = rest == 2 ? ALPHA[(v >> 6) & 63] : '=';
        dst[k + 3] = '=';
        k += 4;
    }
    return k;
}
static int64_t decode(const uint8_t *src, int64_t n, uint8_t *dst, const int32_t *rev) {
    int64_t k = 0, i = 0;
    while (i + 4 <= n) {
        int32_t a = rev[src[i]], b = rev[src[i + 1]], c = rev[src[i + 2]], d = rev[src[i + 3]];
        if ((a | b | c | d) < 0) {
            if (src[i + 3] == '=' && i + 4 == n) break;
            return -1;
        }
        int32_t v = (a << 18) | (b << 12) | (c << 6) | d;
        dst[k] = (uint8_t)(v >> 16);
        dst[k + 1] = (uint8_t)(v >> 8);
        dst[k + 2] = (uint8_t)v;
        k += 3;
        i += 4;
    }
    if (i < n) {
        int32_t a = rev[src[i]], b = rev[src[i + 1]];
        if (a < 0 || b < 0) return -1;
        dst[k++] = (uint8_t)((a << 2) | (b >> 4));
        if (src[i + 2] != '=') {
            int32_t c = rev[src[i + 2]];
            if (c < 0) return -1;
            dst[k++] = (uint8_t)((b << 4) | (c >> 2));
        }
    }
    return k;
}
int main(void) {
    int64_t n = 12000001;
    uint8_t *src = malloc(n);
    uint64_t seed = 11;
    for (int64_t i = 0; i < n; i++) { seed = lcg(seed); src[i] = (uint8_t)(seed >> 56); }
    int32_t rev[256];
    for (int i = 0; i < 256; i++) rev[i] = -1;
    for (int i = 0; i < 64; i++) rev[ALPHA[i]] = i;
    uint8_t *enc = calloc(n / 3 * 4 + 8, 1), *dec = calloc(n + 8, 1);
    uint64_t h = 0;
    int64_t tot = 0;
    for (int r = 0; r < 16; r++) {
        src[r] = (uint8_t)r;
        int64_t k = encode(src, n, enc);
        int64_t m = decode(enc, k, dec, rev);
        tot += k + m;
        for (int j = 0; j < 1000; j++) h = h * 31 + enc[j * 997] + dec[j * 991];
        h = h * 31 + dec[m - 1];
    }
    printf("%lld %llu\n", (long long)tot, (unsigned long long)h);
    return 0;
}
