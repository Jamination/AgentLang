#include <math.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    int64_t n = 8000000;
    double s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0, s5 = 0.0, s6 = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double x = (double)i * 0.00037 - 50.0;
        s1 += sin(x);
        s2 += cos(x * 1.7);
        s3 += exp(x * 0.013);
        s4 += log(fabs(x) + 0.5);
        s5 += pow(fabs(x) + 1.0, 0.37);
        s6 += atan2(x, 3.0 + (double)(i & 7));
    }
    printf("%lld %lld %lld %lld %lld %lld\n", (long long)(int64_t)(s1 * 1000.0), (long long)(int64_t)(s2 * 1000.0),
           (long long)(int64_t)(s3 * 1000.0), (long long)(int64_t)(s4 * 1000.0), (long long)(int64_t)(s5 * 1000.0),
           (long long)(int64_t)(s6 * 1000.0));
    return 0;
}
