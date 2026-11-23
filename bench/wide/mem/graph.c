#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
typedef struct { int64_t d, v; } Item;
typedef struct { Item *a; int64_t len; int64_t n; } Pq;

static void pq_push(Pq *h, Item it) {
    int64_t i = h->n;
    h->n += 1;
    while (i > 0) {
        int64_t p = (i - 1) / 2;
        if (h->a[p].d <= it.d) break;
        h->a[i] = h->a[p];
        i = p;
    }
    h->a[i] = it;
}
static Item pq_pop(Pq *h) {
    Item top = h->a[0];
    h->n -= 1;
    Item x = h->a[h->n];
    int64_t n = h->n, i = 0;
    for (;;) {
        int64_t c = 2 * i + 1;
        if (c >= n) break;
        if (c + 1 < n && h->a[c + 1].d < h->a[c].d) c += 1;
        if (x.d <= h->a[c].d) break;
        h->a[i] = h->a[c];
        i = c;
    }
    h->a[i] = x;
    return top;
}
static int64_t bfs(const int64_t *off, const int32_t *adj, int64_t n, int64_t src, int32_t *dist, int32_t *queue) {
    for (int64_t i = 0; i < n; i++) dist[i] = -1;
    dist[src] = 0;
    queue[0] = (int32_t)src;
    int64_t head = 0, tail = 1;
    while (head < tail) {
        int64_t u = queue[head++];
        int32_t du = dist[u];
        for (int64_t e = off[u]; e < off[u + 1]; e++) {
            int64_t v = adj[e];
            if (dist[v] < 0) { dist[v] = du + 1; queue[tail++] = (int32_t)v; }
        }
    }
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) s += dist[i];
    return s;
}
#define INF 0x7FFFFFFFFFFFFFFFLL
static int64_t dijkstra(const int64_t *off, const int32_t *adj, const int32_t *w, int64_t n, int64_t src, int64_t *dist, Pq *h) {
    for (int64_t i = 0; i < n; i++) dist[i] = INF;
    dist[src] = 0;
    h->n = 0;
    pq_push(h, (Item){0, src});
    while (h->n > 0) {
        Item it = pq_pop(h);
        int64_t u = it.v;
        if (it.d > dist[u]) continue;
        for (int64_t e = off[u]; e < off[u + 1]; e++) {
            int64_t v = adj[e];
            int64_t nd = it.d + w[e];
            if (nd < dist[v]) { dist[v] = nd; pq_push(h, (Item){nd, v}); }
        }
    }
    int64_t s = 0;
    for (int64_t i = 0; i < n; i++) if (dist[i] != INF) s += dist[i];
    return s;
}
static int64_t find(int32_t *parent, int64_t x) {
    while (parent[x] != x) { parent[x] = parent[parent[x]]; x = parent[x]; }
    return x;
}
static int64_t components(int64_t n, const int32_t *eu, const int32_t *ev, int64_t m, int32_t *parent, int32_t *size) {
    for (int64_t i = 0; i < n; i++) { parent[i] = (int32_t)i; size[i] = 1; }
    int64_t comps = n;
    for (int64_t k = 0; k < m; k++) {
        int64_t a = find(parent, eu[k]), b = find(parent, ev[k]);
        if (a != b) {
            if (size[a] < size[b]) { int64_t t = a; a = b; b = t; }
            parent[b] = (int32_t)a;
            size[a] += size[b];
            comps -= 1;
        }
    }
    return comps;
}
int main(void) {
    int64_t n = 300000, m = 1500000;
    uint64_t seed = 2024;
    int32_t *eu = calloc(m, 4), *ev = calloc(m, 4);
    int64_t *deg = calloc(n + 1, 8);
    for (int64_t k = 0; k < m; k++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        int64_t u = (int64_t)((seed >> 33) % (uint64_t)n);
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        int64_t v = (int64_t)((seed >> 33) % (uint64_t)n);
        eu[k] = (int32_t)u; ev[k] = (int32_t)v;
        deg[u]++; deg[v]++;
    }
    int64_t *off = calloc(n + 1, 8);
    for (int64_t i = 0; i < n; i++) off[i + 1] = off[i] + deg[i];
    int64_t *pos = calloc(n, 8);
    for (int64_t i = 0; i < n; i++) pos[i] = off[i];
    int32_t *adj = calloc(2 * m, 4), *wt = calloc(2 * m, 4);
    for (int64_t k = 0; k < m; k++) {
        int64_t u = eu[k], v = ev[k];
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        int32_t w = (int32_t)(1 + (seed >> 33) % 100);
        adj[pos[u]] = (int32_t)v; wt[pos[u]] = w; pos[u]++;
        adj[pos[v]] = (int32_t)u; wt[pos[v]] = w; pos[v]++;
    }
    int64_t total = 0;
    int32_t *dist32 = calloc(n, 4), *queue = calloc(n, 4);
    for (int r = 0; r < 6; r++) total += bfs(off, adj, n, r * 1000, dist32, queue);
    int64_t *dist = calloc(n, 8);
    Pq h = { calloc(2 * m + 1, sizeof(Item)), 2 * m + 1, 0 };
    for (int r = 0; r < 2; r++) total += dijkstra(off, adj, wt, n, r * 7, dist, &h);
    int32_t *parent = calloc(n, 4), *size = calloc(n, 4);
    for (int r = 0; r < 4; r++) {
        int64_t k = m / 4 * (r + 1) / 2;
        total += components(n, eu, ev, k, parent, size);
    }
    printf("%lld\n", (long long)total);
    return 0;
}
