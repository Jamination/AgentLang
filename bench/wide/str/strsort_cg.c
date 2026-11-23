/* [codegen] hand-written merge sort of strings: see strsort_cg.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
typedef struct { const uint8_t *p; int64_t n; } Str;
static int less(Str a, Str b) {
    int64_t n = a.n < b.n ? a.n : b.n;
    for (int64_t i = 0; i < n; i++)
        if (a.p[i] != b.p[i]) return a.p[i] < b.p[i];
    return a.n < b.n;
}
static void msort(Str *a, Str *tmp, int64_t n) {
    if (n < 2) return;
    int64_t mid = n / 2;
    msort(a, tmp, mid);
    msort(a + mid, tmp + mid, n - mid);
    int64_t i = 0, j = mid, k = 0;
    while (i < mid && j < n) {
        if (less(a[j], a[i])) tmp[k] = a[j++];
        else tmp[k] = a[i++];
        k++;
    }
    while (i < mid) tmp[k++] = a[i++];
    while (j < n) tmp[k++] = a[j++];
    for (int64_t t = 0; t < n; t++) a[t] = tmp[t];
}
int main(void) {
    int64_t n = 1000000;
    uint64_t seed = 31;
    uint8_t *pool = malloc(n * 24);
    Str *a = malloc(n * sizeof(Str));
    int64_t off = 0;
    for (int64_t i = 0; i < n; i++) {
        seed = lcg(seed);
        int64_t l = 6 + (int64_t)((seed >> 33) % 18);
        for (int64_t j = 0; j < l; j++) { seed = lcg(seed); pool[off + j] = (uint8_t)(97 + (seed >> 33) % 4); }
        a[i].p = pool + off; a[i].n = l;
        off += l;
    }
    msort(a, malloc(n * sizeof(Str)), n);
    uint64_t h = 0;
    for (int64_t i = 0; i < n; i++) h = h * 1000003 + (uint64_t)a[i].n * 7 + a[i].p[0] + (uint64_t)a[i].p[a[i].n - 1] * 3;
    printf("%llu %.*s %.*s %.*s\n", (unsigned long long)h, (int)a[0].n, a[0].p, (int)a[n / 2].n, a[n / 2].p,
           (int)a[n - 1].n, a[n - 1].p);
    return 0;
}
