#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct { int64_t v; bool ok; } Res;
typedef struct { bool some; int64_t v; } Opt;

static Res digit(uint8_t c) {
    if (c >= '0' && c <= '9') return (Res){c - '0', true};
    return (Res){0, false};
}

static Res mul_add(int64_t acc, int64_t d) {
    if (acc > 92233720368547757LL) return (Res){0, false};
    return (Res){(int64_t)((uint64_t)acc * 10 + (uint64_t)d), true};
}

static Res parse_num(const uint8_t *text, int64_t len, int64_t *pos) {
    int64_t acc = 0, n = 0;
    bool ok = true;
    while (*pos < len && text[*pos] != ',') {
        Res d = digit(text[*pos]);
        *pos += 1;
        if (!d.ok) { ok = false; continue; }
        Res v = mul_add(acc, d.v);
        if (!v.ok) { ok = false; continue; }
        acc = v.v;
        n++;
    }
    *pos += 1;
    if (n == 0) return (Res){0, false};
    return (Res){acc, ok};
}

static Opt scaled(const uint8_t *text, int64_t len, int64_t *pos, int64_t limit) {
    Res r = parse_num(text, len, pos);
    if (!r.ok) return (Opt){false, 0};
    if (r.v > limit) return (Opt){false, 0};
    return (Opt){true, (int64_t)((uint64_t)r.v * 3 + 1)};
}

static void checksum(const uint8_t *text, int64_t len, int64_t limit, int64_t *sum_out, int64_t *err_out) {
    int64_t pos = 0, errors = 0;
    uint64_t sum = 0;
    while (pos < len) {
        Opt o = scaled(text, len, &pos, limit);
        if (o.some) sum = sum * 31 + (uint64_t)o.v;
        else errors++;
    }
    *sum_out = (int64_t)sum;
    *err_out = errors;
}

int main(void) {
    int64_t n = 4000000;
    uint8_t *text = malloc(n);
    uint64_t seed = 99;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        uint64_t r = (seed >> 33) % 100;
        text[i] = r < 12 ? ',' : r < 13 ? 'x' : (uint8_t)('0' + r % 10);
    }
    uint64_t total = 0;
    int64_t errs = 0;
    for (int64_t r = 0; r < 36; r++) {
        int64_t s, e;
        checksum(text, n, 1000000000000LL + r, &s, &e);
        total = total * 7 + (uint64_t)s;
        errs += e;
    }
    printf("%lld %lld\n", (long long)total, (long long)errs);
    return 0;
}
