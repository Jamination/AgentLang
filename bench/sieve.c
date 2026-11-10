#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    long n = 60000000;
    uint8_t *composite = calloc(n + 1, 1);
    for (long i = 2; i * i <= n; i++) {
        if (!composite[i]) {
            for (long j = i * i; j <= n; j += i) composite[j] = 1;
        }
    }
    long count = 0, last = 0;
    for (long i = 2; i <= n; i++) {
        if (!composite[i]) {
            count++;
            last = i;
        }
    }
    printf("%ld %ld\n", count, last);
    return 0;
}
