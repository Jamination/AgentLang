/* [codegen] UTF-8 encode + validate/decode: see utf8.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static int64_t encode(uint8_t *out, int64_t k, uint32_t cp) {
    if (cp < 0x80) { out[k] = (uint8_t)cp; return k + 1; }
    if (cp < 0x800) { out[k] = (uint8_t)(0xC0 | (cp >> 6)); out[k + 1] = (uint8_t)(0x80 | (cp & 0x3F)); return k + 2; }
    if (cp < 0x10000) {
        out[k] = (uint8_t)(0xE0 | (cp >> 12)); out[k + 1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        out[k + 2] = (uint8_t)(0x80 | (cp & 0x3F)); return k + 3;
    }
    out[k] = (uint8_t)(0xF0 | (cp >> 18)); out[k + 1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
    out[k + 2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); out[k + 3] = (uint8_t)(0x80 | (cp & 0x3F));
    return k + 4;
}
static uint8_t *gen(int64_t ncp, int64_t *len) {
    uint8_t *out = calloc(ncp * 4, 1);
    uint64_t seed = 4242;
    int64_t k = 0;
    for (int64_t i = 0; i < ncp; i++) {
        seed = lcg(seed);
        uint64_t r = (seed >> 33) % 100;
        uint32_t x = (uint32_t)((seed >> 12) & 0x1FFFFF);
        uint32_t cp;
        if (r < 60) cp = 32 + x % 95;
        else if (r < 80) cp = 0x80 + x % (0x800 - 0x80);
        else if (r < 95) cp = 0x800 + x % (0xD800 - 0x800);
        else cp = 0x10000 + x % (0x110000 - 0x10000);
        k = encode(out, k, cp);
    }
    *len = k;
    return out;
}
static int64_t decode(const uint8_t *s, int64_t n, int64_t *out2) {
    int64_t i = 0, count = 0, sum = 0;
    while (i < n) {
        uint32_t c = s[i];
        if (c < 0x80) { sum += c; i += 1; }
        else if (c < 0xC2) { *out2 = i; return -1; }
        else if (c < 0xE0) {
            if (i + 1 >= n) { *out2 = i; return -1; }
            uint32_t c1 = s[i + 1];
            if ((c1 & 0xC0) != 0x80) { *out2 = i; return -1; }
            sum += ((c & 0x1F) << 6) | (c1 & 0x3F);
            i += 2;
        } else if (c < 0xF0) {
            if (i + 2 >= n) { *out2 = i; return -1; }
            uint32_t c1 = s[i + 1], c2 = s[i + 2];
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80) { *out2 = i; return -1; }
            uint32_t cp = ((c & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
            if (cp < 0x800 || (cp >= 0xD800 && cp < 0xE000)) { *out2 = i; return -1; }
            sum += cp;
            i += 3;
        } else if (c < 0xF5) {
            if (i + 3 >= n) { *out2 = i; return -1; }
            uint32_t c1 = s[i + 1], c2 = s[i + 2], c3 = s[i + 3];
            if ((c1 & 0xC0) != 0x80 || (c2 & 0xC0) != 0x80 || (c3 & 0xC0) != 0x80) { *out2 = i; return -1; }
            uint32_t cp = ((c & 0x07) << 18) | ((c1 & 0x3F) << 12) | ((c2 & 0x3F) << 6) | (c3 & 0x3F);
            if (cp < 0x10000 || cp > 0x10FFFF) { *out2 = i; return -1; }
            sum += cp;
            i += 4;
        } else { *out2 = i; return -1; }
        count++;
    }
    *out2 = sum;
    return count;
}
int main(void) {
    int64_t n;
    uint8_t *s = gen(4000000, &n);
    int64_t tc = 0, ts = 0;
    for (int r = 0; r < 20; r++) {
        int64_t sm;
        int64_t c = decode(s, n, &sm);
        tc += c;
        ts += sm;
    }
    s[n / 2] = 0xFF;
    int64_t at;
    int64_t bad = decode(s, n, &at);
    printf("%lld %lld %lld %lld %s\n", (long long)n, (long long)tc, (long long)ts, (long long)bad, at > 0 ? "true" : "false");
    return 0;
}
