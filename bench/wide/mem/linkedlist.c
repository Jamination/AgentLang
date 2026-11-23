#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
/* bump arena (as AL's): 16-byte aligned allocation, reset to a mark */
static char *arena_cur, *arena_end;
static inline void *arena_alloc(size_t n) {
    n = (n + 15) & ~(size_t)15;
    char *p = arena_cur;
    if ((size_t)(arena_end - p) < n) { fprintf(stderr, "oom\n"); exit(1); }
    arena_cur = p + n;
    return p;
}
typedef struct Node { int64_t val; struct Node *next; } Node;

static Node *mk(int64_t v, Node *next) { Node *n = arena_alloc(sizeof(Node)); n->val = v; n->next = next; return n; }

static Node *build(int64_t n, uint64_t *seed) {
    Node **nodes = arena_alloc(n * sizeof(Node *));
    for (int64_t i = 0; i < n; i++) nodes[i] = mk(i, NULL);
    for (int64_t i = 1; i < n; i++) {
        *seed = *seed * 6364136223846793005ULL + 1442695040888963407ULL;
        int64_t j = (int64_t)((*seed >> 33) % (uint64_t)(i + 1));
        Node *t = nodes[i]; nodes[i] = nodes[j]; nodes[j] = t;
    }
    for (int64_t i = 0; i < n - 1; i++) nodes[i]->next = nodes[i + 1];
    return nodes[0];
}
static int64_t sum(Node *l) {
    uint64_t s = 0;
    for (Node *p = l; p; p = p->next) s = s * 31 + (uint64_t)p->val;
    return (int64_t)s;
}
static Node *reverse(Node *l) {
    Node *prev = NULL, *p = l;
    while (p) { Node *nx = p->next; p->next = prev; prev = p; p = nx; }
    return prev;
}
static Node *build_seq(int64_t n) {
    Node *head = NULL;
    for (int64_t i = 0; i < n; i++) head = mk(i ^ 5, head);
    return head;
}
int main(void) {
    size_t cap = (size_t)1 << 30;
    arena_cur = malloc(cap); arena_end = arena_cur + cap;
    uint64_t seed = 7;
    uint64_t total = 0;
    char *m = arena_cur;
    Node *l = build(1000000, &seed);
    for (int r = 0; r < 6; r++) { total += (uint64_t)sum(l); l = reverse(l); }
    arena_cur = m;
    for (int r = 0; r < 40; r++) {
        char *m2 = arena_cur;
        Node *s = build_seq(1000000);
        for (int k = 0; k < 3; k++) { total += (uint64_t)sum(s); s = reverse(s); }
        arena_cur = m2;
    }
    printf("%lld\n", (long long)total);
    return 0;
}
