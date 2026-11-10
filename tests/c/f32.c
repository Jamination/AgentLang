// Reference for tests/c/f32.al: the two programs must print the same bytes.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

static uint32_t bits(float x) { uint32_t u; memcpy(&u, &x, 4); return u; }
static float from_bits(uint32_t u) { float x; memcpy(&x, &u, 4); return x; }

static uint32_t state = 12345;
static uint32_t next(void) { state = state * 1664525u + 1013904223u; return state; }

int main(void) {
    float vals[12] = {0.0f, 1.0f, -1.0f, 0.1f, 3.14159274f, 1e-20f, 1e20f, 16777216.0f, 16777217.0f, 0.333333343f, -2.5f, 123456.789f};
    for (int i = 0; i < 12; i++) {
        for (int j = 0; j < 12; j++) {
            float a = vals[i], b = vals[j];
            printf("%x %x %x %x %d%d%d%d%d%d\n", bits(a + b), bits(a - b), bits(a * b), bits(b != 0.0f ? a / b : 0.0f), a < b, a <= b, a > b, a >= b, a == b, a != b);
        }
    }
    for (int i = 0; i < 12; i++) {
        float a = vals[i];
        printf("%.6f %.9f %x %x %x\n", (double)a, (double)a, bits(-a), bits(fabsf(a)), bits(sqrtf(fabsf(a))));
    }
    // conversions
    int64_t ints[8] = {0, 1, -1, 7, 16777217, -123456789, 2147483647, 9007199254740993};
    for (int i = 0; i < 8; i++) {
        float f = (float)ints[i];
        printf("%x %.1f\n", bits(f), (double)f);
    }
    uint32_t u32s[4] = {0u, 1u, 4294967295u, 2147483648u};
    for (int i = 0; i < 4; i++) {
        printf("%x\n", bits((float)u32s[i]));
    }
    double ds[6] = {0.1, 1.0 / 3.0, 1e40, -1e-50, 16777217.0, 2.5};
    for (int i = 0; i < 6; i++) {
        float f = (float)ds[i];
        printf("%x %.17g\n", bits(f), 0.0 + (double)f == (double)f ? 1.0 : 0.0);
    }
    float fs[6] = {0.0f, 0.99f, -0.99f, 2.5f, -2.5f, 1e9f};
    for (int i = 0; i < 6; i++) {
        printf("%ld %d\n", (long)fs[i], (int)fs[i]);
    }
    // a pseudo-random stream of bit patterns through every operation
    uint32_t acc = 0;
    float sum = 0.0f;
    for (int i = 0; i < 20000; i++) {
        float a = from_bits(next() & 0x7fffffffu) , b = from_bits(next());
        if (a != a || b != b || a > 3.0e38f || b > 3.0e38f || b < -3.0e38f) {
            continue;
        }
        acc = acc * 31u + bits(a + b);
        acc = acc * 31u + bits(a - b);
        acc = acc * 31u + bits(a * b);
        if (b != 0.0f) {
            float q = a / b;
            if (q == q) {
                acc = acc * 31u + bits(q);
            }
        }
        acc = acc * 31u + bits(sqrtf(a));
        acc = acc * 31u + (uint32_t)(a < b) + 2u * (uint32_t)(a == b);
        float small = from_bits((next() & 0x007fffffu) | 0x3f000000u);
        sum = sum * 0.999f + small;
    }
    printf("%x %x %.6f\n", acc, bits(sum), (double)sum);
    // accumulation order and precision
    float h = 0.0f;
    for (int i = 1; i <= 100000; i++) {
        h += 1.0f / (float)i;
    }
    double hd = 0.0;
    for (int i = 1; i <= 100000; i++) {
        hd += (double)(1.0f / (float)i);
    }
    printf("%.9f %.12f %x\n", (double)h, hd, bits((float)hd));
    return 0;
}
