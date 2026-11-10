#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    uint64_t key, val;
} entry;

typedef struct {
    entry *e;
    uint64_t cap, len;
} map;

static inline uint64_t hash(uint64_t k) {
    return (k * 0x9E3779B97F4A7C15ULL) >> 32;
}

static void map_init(map *m, uint64_t cap) {
    m->e = calloc(cap, sizeof(entry));
    m->cap = cap;
    m->len = 0;
}

static uint64_t *map_slot(map *m, uint64_t key);

static void map_grow(map *m) {
    entry *old = m->e;
    uint64_t oldcap = m->cap;
    map_init(m, oldcap * 2);
    for (uint64_t i = 0; i < oldcap; i++) {
        if (old[i].key != 0) *map_slot(m, old[i].key) = old[i].val;
    }
    free(old);
}

/* find the value slot of key, inserting it if missing */
static uint64_t *map_slot(map *m, uint64_t key) {
    if ((m->len + 1) * 4 > m->cap * 3) map_grow(m);
    uint64_t mask = m->cap - 1;
    uint64_t i = hash(key) & mask;
    for (;;) {
        entry *e = &m->e[i];
        if (e->key == key) return &e->val;
        if (e->key == 0) {
            e->key = key;
            m->len++;
            return &e->val;
        }
        i = (i + 1) & mask;
    }
}

static int map_get(map *m, uint64_t key, uint64_t *out) {
    uint64_t mask = m->cap - 1;
    uint64_t i = hash(key) & mask;
    for (;;) {
        entry *e = &m->e[i];
        if (e->key == key) {
            *out = e->val;
            return 1;
        }
        if (e->key == 0) return 0;
        i = (i + 1) & mask;
    }
}

int main(void) {
    map m;
    map_init(&m, 16);
    uint64_t seed = 42;
    for (uint64_t i = 0; i < 5000000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        uint64_t key = (seed >> 33) % 3000000 + 1;
        *map_slot(&m, key) += i;
    }
    uint64_t hits = 0, sum = 0;
    for (uint64_t i = 0; i < 10000000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        uint64_t key = (seed >> 33) % 6000000 + 1;
        uint64_t v;
        if (map_get(&m, key, &v)) {
            hits++;
            sum += v;
        }
    }
    printf("%lu %lu %lu\n", (unsigned long)m.len, (unsigned long)hits, (unsigned long)sum);
    return 0;
}
