#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    int64_t n = (int64_t)1 << 20;
    float *a = calloc(n, 4);
    for (int64_t i = 0; i < n; i++) a[i] = (float)(i % 1000) * 0.01f;
    int64_t isum = 0;
    for (int pass = 0; pass < 160; pass++) {
        for (int64_t i = 0; i < n; i++) {
            float x = a[i];
            float y = x * 1.37f + (float)(i & 255);
            double d = (double)y * 0.731;
            int64_t k = (int64_t)d;
            isum += k;
            a[i] = (float)(d - (double)k) + (float)(k & 15) * 0.25f;
        }
    }
    double fsum = 0.0;
    for (int64_t i = 0; i < n; i++) fsum += (double)a[i];
    uint64_t b; memcpy(&b, &fsum, 8);
    printf("%lld %llu\n", (long long)isum, (unsigned long long)b);
    return 0;
}
