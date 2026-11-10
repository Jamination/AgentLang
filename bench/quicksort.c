#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void quicksort(int64_t *a, long lo, long hi) {
    int64_t p = a[(lo + hi) / 2];
    long i = lo, j = hi;
    while (i <= j) {
        while (a[i] < p) i++;
        while (a[j] > p) j--;
        if (i <= j) {
            int64_t t = a[i];
            a[i] = a[j];
            a[j] = t;
            i++;
            j--;
        }
    }
    if (lo < j) quicksort(a, lo, j);
    if (i < hi) quicksort(a, i, hi);
}

int main(void) {
    long n = 5000000;
    int64_t *a = malloc(n * sizeof(int64_t));
    uint64_t seed = 88172645463325252ULL;
    for (long i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        a[i] = (int64_t)(seed >> 16);
    }
    quicksort(a, 0, n - 1);
    uint64_t sum = 0;
    for (long i = 0; i < n; i++) {
        if (i > 0 && a[i - 1] > a[i]) {
            printf("not sorted at %ld\n", i);
            return 1;
        }
        sum = sum * 31 + (uint64_t)a[i];
    }
    printf("%ld %ld %ld %lu\n", (long)a[0], (long)a[n / 2], (long)a[n - 1], (unsigned long)sum);
    return 0;
}
