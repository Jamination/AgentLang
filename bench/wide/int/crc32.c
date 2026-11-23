#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void make_table(uint32_t *t) {
    for (int i = 0; i < 256; i++) {
        uint32_t c = (uint32_t)i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        t[i] = c;
    }
}
static uint32_t crc_table(const uint32_t *t, uint32_t crc0, const uint8_t *buf, int64_t n) {
    uint32_t c = ~crc0;
    for (int64_t i = 0; i < n; i++) c = t[(c ^ (uint32_t)buf[i]) & 0xFF] ^ (c >> 8);
    return ~c;
}
static uint32_t crc_bitwise(uint32_t crc0, const uint8_t *buf, int64_t n) {
    uint32_t c = ~crc0;
    for (int64_t i = 0; i < n; i++) {
        c ^= (uint32_t)buf[i];
        for (int k = 0; k < 8; k++) {
            uint32_t mask = 0 - (c & 1);
            c = (c >> 1) ^ (0xEDB88320u & mask);
        }
    }
    return ~c;
}
int main(void) {
    int64_t n = 1 << 20;
    uint8_t *buf = calloc(n, 1);
    uint32_t seed = 12345;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 1664525u + 1013904223u;
        buf[i] = (uint8_t)(seed >> 24);
    }
    uint32_t *t = calloc(256, 4);
    make_table(t);
    uint32_t acc = 0;
    for (int r = 0; r < 160; r++) {
        buf[r] ^= (uint8_t)acc;
        acc ^= crc_table(t, acc, buf, n);
    }
    for (int r = 0; r < 12; r++) {
        buf[r] ^= (uint8_t)acc;
        acc ^= crc_bitwise(acc, buf, n);
    }
    printf("%u\n", acc);
    return 0;
}
