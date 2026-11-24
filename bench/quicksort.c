#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void quicksort(int64_t *a, int64_t lo, int64_t hi) {
    int64_t p = a[(lo + hi) / 2];
    int64_t i = lo, j = hi;
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
    int64_t n = 5000000;
    int64_t *a = malloc(n * sizeof(int64_t));
    uint64_t seed = 88172645463325252ULL;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        a[i] = (int64_t)(seed >> 16);
    }
    quicksort(a, 0, n - 1);
    uint64_t sum = 0;
    for (int64_t i = 0; i < n; i++) {
        if (i > 0 && a[i - 1] > a[i]) {
            printf("not sorted at %lld\n", (long long)i);
            return 1;
        }
        sum = sum * 31 + (uint64_t)a[i];
    }
    printf("%lld %lld %lld %llu\n", (long long)a[0], (long long)a[n / 2], (long long)a[n - 1], (unsigned long long)sum);
    return 0;
}
