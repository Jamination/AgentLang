#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { int64_t *a; int64_t len; int64_t n; } Heap;

static void push(Heap *h, int64_t x) {
    int64_t i = h->n;
    h->n += 1;
    while (i > 0) {
        int64_t p = (i - 1) / 2;
        if (h->a[p] <= x) break;
        h->a[i] = h->a[p];
        i = p;
    }
    h->a[i] = x;
}
static int64_t pop(Heap *h) {
    int64_t top = h->a[0];
    h->n -= 1;
    int64_t x = h->a[h->n];
    int64_t n = h->n;
    int64_t i = 0;
    for (;;) {
        int64_t c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && h->a[c + 1] < h->a[c]) c += 1;
        if (x <= h->a[c]) break;
        h->a[i] = h->a[c];
        i = c;
    }
    h->a[i] = x;
    return top;
}
int main(void) {
    int64_t n = 1000000;
    Heap h = { calloc(n, 8), n, 0 };
    uint64_t seed = 99, check = 0;
    for (int r = 0; r < 3; r++) {
        for (int64_t i = 0; i < n; i++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            push(&h, (int64_t)(seed >> 20));
        }
        for (int64_t i = 0; i < n; i++) {
            int64_t x = pop(&h);
            check = check * 31 + (uint64_t)x;
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            push(&h, x + (int64_t)(seed >> 30));
        }
        int64_t prev = 0;
        while (h.n > 0) {
            int64_t x = pop(&h);
            if (x < prev) printf("bad\n");
            prev = x;
            check = check * 31 + (uint64_t)x;
        }
    }
    printf("%llu\n", (unsigned long long)check);
    return 0;
}
