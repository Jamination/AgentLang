#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int64_t prio, id; } Job;

static int before_i64(int64_t a, int64_t b) { return a < b; }
static int before_f64(double a, double b) { return a < b; }
static int before_job(Job a, Job b) { return a.prio < b.prio || (a.prio == b.prio && a.id < b.id); }
static int64_t key_i64(int64_t x) { return x; }
static int64_t key_f64(double x) { return (int64_t)(x * 1000.0); }
static int64_t key_job(Job x) { return (int64_t)((uint64_t)x.prio * 7 + (uint64_t)x.id); }

/* the "generic" heap: one macro instantiated per element type */
#define DEFINE_HEAP(T, S)                                                        \
    typedef struct { T *items; int64_t n; } Heap_##S;                            \
    static void heap_push_##S(Heap_##S *h, T x) {                                \
        int64_t i = h->n++;                                                      \
        while (i > 0) {                                                          \
            int64_t p = (i - 1) / 2;                                             \
            if (!before_##S(x, h->items[p])) break;                              \
            h->items[i] = h->items[p];                                           \
            i = p;                                                               \
        }                                                                        \
        h->items[i] = x;                                                         \
    }                                                                            \
    static T heap_pop_##S(Heap_##S *h) {                                         \
        T top = h->items[0];                                                     \
        T x = h->items[--h->n];                                                  \
        int64_t i = 0;                                                           \
        for (;;) {                                                               \
            int64_t c = 2 * i + 1;                                               \
            if (c >= h->n) break;                                                \
            if (c + 1 < h->n && before_##S(h->items[c + 1], h->items[c])) c++;   \
            if (!before_##S(h->items[c], x)) break;                              \
            h->items[i] = h->items[c];                                           \
            i = c;                                                               \
        }                                                                        \
        h->items[i] = x;                                                         \
        return top;                                                              \
    }                                                                            \
    static int64_t heapsort_checksum_##S(const T *xs, int64_t n) {               \
        Heap_##S h = {calloc(n, sizeof(T)), 0};                                  \
        for (int64_t i = 0; i < n; i++) heap_push_##S(&h, xs[i]);                \
        uint64_t sum = 0;                                                        \
        for (int64_t i = 0; i < n; i++) sum = sum * 31 + (uint64_t)key_##S(heap_pop_##S(&h)); \
        return (int64_t)sum;                                                     \
    }

DEFINE_HEAP(int64_t, i64)
DEFINE_HEAP(double, f64)
DEFINE_HEAP(Job, job)

int main(void) {
    int64_t n = 400000;
    int64_t *ints = malloc(n * 8);
    double *floats = malloc(n * 8);
    Job *jobs = malloc(n * sizeof(Job));
    uint64_t seed = 7;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        ints[i] = (int64_t)(seed >> 20);
        floats[i] = (double)(seed >> 11) * (1.0 / 9007199254740992.0);
        jobs[i] = (Job){(int64_t)(seed >> 50), i};
    }
    uint64_t total = 0;
    for (int r = 0; r < 3; r++) {
        total = total * 13 + (uint64_t)heapsort_checksum_i64(ints, n);
        total = total * 13 + (uint64_t)heapsort_checksum_f64(floats, n);
        total = total * 13 + (uint64_t)heapsort_checksum_job(jobs, n);
    }
    printf("%lld\n", (long long)total);
    return 0;
}
