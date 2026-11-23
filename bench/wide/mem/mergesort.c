#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void merge_sort(int64_t *a, int64_t *tmp, int64_t lo, int64_t hi) {
    if (hi - lo < 2) return;
    int64_t mid = (lo + hi) / 2;
    merge_sort(a, tmp, lo, mid);
    merge_sort(a, tmp, mid, hi);
    if (a[mid - 1] <= a[mid]) return;
    int64_t i = lo, j = mid, k = lo;
    while (i < mid && j < hi) {
        if (a[j] < a[i]) { tmp[k] = a[j]; j++; } else { tmp[k] = a[i]; i++; }
        k++;
    }
    while (i < mid) { tmp[k] = a[i]; i++; k++; }
    while (j < hi) { tmp[k] = a[j]; j++; k++; }
    for (int64_t t = lo; t < hi; t++) a[t] = tmp[t];
}
int main(void) {
    int64_t n = 4000000;
    int64_t *a = calloc(n, 8), *tmp = calloc(n, 8);
    uint64_t seed = 1, check = 0;
    for (int r = 0; r < 2; r++) {
        for (int64_t i = 0; i < n; i++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            a[i] = (int64_t)(seed >> 24);
        }
        merge_sort(a, tmp, 0, n);
        for (int64_t i = 0; i < n; i++) check = check * 31 + (uint64_t)a[i];
    }
    printf("%llu %lld %lld\n", (unsigned long long)check, (long long)a[0], (long long)a[n - 1]);
    return 0;
}
