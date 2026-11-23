#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
/* nodes come from a bump arena (16-byte aligned, as AL's), never freed */
static char *arena_cur, *arena_end;
static inline void *arena_alloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    char *p = arena_cur;
    if ((size_t)(arena_end - p) < n) { fprintf(stderr, "oom\n"); exit(1); }
    arena_cur = p + n;
    return p;
}
typedef struct Node { int64_t key, val; uint64_t prio; struct Node *left, *right; } Node;

static uint64_t rng = 1;
static uint64_t next_prio(void) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return rng;
}
static Node *insert(Node *t, int64_t key, int64_t val) {
    if (!t) {
        Node *n = arena_alloc(sizeof(Node));
        n->key = key; n->val = val; n->prio = next_prio(); n->left = NULL; n->right = NULL;
        return n;
    }
    if (key == t->key) {
        t->val += val;
    } else if (key < t->key) {
        t->left = insert(t->left, key, val);
        if (t->left->prio > t->prio) { Node *l = t->left; t->left = l->right; l->right = t; return l; }
    } else {
        t->right = insert(t->right, key, val);
        if (t->right->prio > t->prio) { Node *r = t->right; t->right = r->left; r->left = t; return r; }
    }
    return t;
}
static int64_t lookup(Node *t, int64_t key) {
    Node *p = t;
    while (p) {
        if (key == p->key) return p->val;
        p = key < p->key ? p->left : p->right;
    }
    return -1;
}
static uint64_t walk(Node *t, uint64_t acc) {
    if (!t) return acc;
    uint64_t a = walk(t->left, acc);
    a = a * 31 + (uint64_t)t->key + (uint64_t)t->val;
    return walk(t->right, a);
}
int main(void) {
    size_t cap = (size_t)1 << 30;
    arena_cur = malloc(cap); arena_end = arena_cur + cap;
    uint64_t seed = 31337;
    Node *root = NULL;
    int64_t n = 300000;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        root = insert(root, (int64_t)((seed >> 33) % 1000000), i);
    }
    int64_t found = 0, sum = 0;
    for (int64_t i = 0; i < 2000000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        int64_t v = lookup(root, (int64_t)((seed >> 33) % 1000000));
        if (v >= 0) { found++; sum += v; }
    }
    printf("%lld %lld %llu\n", (long long)found, (long long)sum, (unsigned long long)walk(root, 0));
    return 0;
}
