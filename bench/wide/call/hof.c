#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef int64_t (*map_fn)(int64_t);
typedef int (*pred_fn)(int64_t);
typedef int64_t (*fold_fn)(int64_t, int64_t);
typedef int (*less_fn)(int64_t, int64_t);
typedef int (*less_ctx_fn)(const int64_t *, int64_t, int64_t);

static void map_into(int64_t *dst, const int64_t *src, int64_t n, map_fn f) {
    for (int64_t i = 0; i < n; i++) dst[i] = f(src[i]);
}
static int64_t filter_into(int64_t *dst, const int64_t *src, int64_t n, pred_fn keep) {
    int64_t m = 0;
    for (int64_t i = 0; i < n; i++)
        if (keep(src[i])) dst[m++] = src[i];
    return m;
}
static int64_t fold(const int64_t *src, int64_t n, int64_t init, fold_fn f) {
    int64_t acc = init;
    for (int64_t i = 0; i < n; i++) acc = f(acc, src[i]);
    return acc;
}

static void merge_sort(int64_t *a, int64_t *tmp, int64_t n, less_fn less) {
    if (n < 2) return;
    int64_t mid = n / 2;
    merge_sort(a, tmp, mid, less);
    merge_sort(a + mid, tmp + mid, n - mid, less);
    int64_t i = 0, j = mid, k = 0;
    while (i < mid && j < n) {
        if (less(a[j], a[i])) tmp[k++] = a[j++];
        else tmp[k++] = a[i++];
    }
    while (i < mid) tmp[k++] = a[i++];
    while (j < n) tmp[k++] = a[j++];
    for (int64_t t = 0; t < n; t++) a[t] = tmp[t];
}

static void merge_sort_ctx(int64_t *a, int64_t *tmp, int64_t n, const int64_t *keys, less_ctx_fn less) {
    if (n < 2) return;
    int64_t mid = n / 2;
    merge_sort_ctx(a, tmp, mid, keys, less);
    merge_sort_ctx(a + mid, tmp + mid, n - mid, keys, less);
    int64_t i = 0, j = mid, k = 0;
    while (i < mid && j < n) {
        if (less(keys, a[j], a[i])) tmp[k++] = a[j++];
        else tmp[k++] = a[i++];
    }
    while (i < mid) tmp[k++] = a[i++];
    while (j < n) tmp[k++] = a[j++];
    for (int64_t t = 0; t < n; t++) a[t] = tmp[t];
}

static int64_t m1(int64_t x) { return (int64_t)((uint64_t)x * 3 + 1); }
static int p1(int64_t x) { return x % 7 != 3; }
static int64_t f1(int64_t acc, int64_t x) { return (int64_t)((uint64_t)acc * 31 + (uint64_t)(x ^ (acc >> 11))); }
static int64_t m2(int64_t x) { return (x >> 3) ^ (int64_t)((uint64_t)x << 2); }
static int64_t f2(int64_t acc, int64_t x) { return x > acc ? x : acc - 1; }
static int64_t f3(int64_t acc, int64_t x) { return (int64_t)((uint64_t)acc * 31 + (uint64_t)x); }
static int l1(int64_t x, int64_t y) { return x < y; }
static int l2(int64_t x, int64_t y) { return (x & 1023) > (y & 1023); }
static int l3(const int64_t *keys, int64_t x, int64_t y) { return keys[x] % 1000 < keys[y] % 1000; }

int main(void) {
    int64_t n = 1000000;
    int64_t *src = malloc(n * 8), *a = malloc(n * 8), *b = malloc(n * 8);
    uint64_t seed = 12345;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        src[i] = (int64_t)(seed >> 40);
    }
    int64_t total = 0;
    for (int64_t r = 0; r < 20; r++) {
        map_into(a, src, n, m1);
        int64_t m = filter_into(b, a, n, p1);
        total += fold(b, m, r, f1);
        map_into(a, b, m, m2);
        total += fold(a, m, 0, f2);
    }
    int64_t *tmp = malloc(n * 8);
    for (int64_t i = 0; i < n; i++) a[i] = src[i];
    merge_sort(a, tmp, n, l1);
    int64_t s1 = fold(a, n, 0, f3);
    merge_sort(a, tmp, n, l2);
    int64_t s2 = fold(a, n, 0, f3);
    int64_t *idx = malloc(n * 8);
    for (int64_t i = 0; i < n; i++) idx[i] = i;
    merge_sort_ctx(idx, tmp, n, src, l3);
    int64_t s3 = fold(idx, n, 0, f3);
    printf("%lld %lld %lld %lld\n", (long long)total, (long long)s1, (long long)s2, (long long)s3);
    return 0;
}
