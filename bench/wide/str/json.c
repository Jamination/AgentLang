/* [codegen] hand-written JSON tokenizer: see json.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
typedef struct { uint8_t *b; int64_t n; } Buf;
static void putb(Buf *o, uint8_t c) { o->b[o->n++] = c; }
static void puts_(Buf *o, const char *s) { while (*s) putb(o, (uint8_t)*s++); }
static void puti(Buf *o, int64_t v) {
    if (v < 0) { putb(o, '-'); v = -v; }
    uint8_t tmp[20];
    int k = 0;
    for (;;) { tmp[k++] = (uint8_t)(48 + v % 10); v /= 10; if (v == 0) break; }
    while (k > 0) putb(o, tmp[--k]);
}
static uint8_t *gen(int64_t nrec, int64_t *len) {
    Buf o = {calloc(nrec * 160, 1), 0};
    uint64_t seed = 99;
    puts_(&o, "[\n");
    for (int64_t r = 0; r < nrec; r++) {
        seed = lcg(seed);
        puts_(&o, "  {\"id\": ");
        puti(&o, r);
        puts_(&o, ", \"name\": \"");
        int64_t nl = 3 + (int64_t)((seed >> 40) % 12);
        for (int64_t j = 0; j < nl; j++) {
            seed = lcg(seed);
            uint8_t c = (uint8_t)(97 + (seed >> 50) % 26);
            if ((seed >> 33) % 23 == 0) { putb(&o, '\\'); putb(&o, 'n'); }
            else putb(&o, c);
        }
        puts_(&o, "\", \"score\": ");
        seed = lcg(seed);
        puti(&o, (int64_t)((seed >> 40) % 200000) - 100000);
        putb(&o, '.');
        puti(&o, (int64_t)((seed >> 20) % 1000));
        puts_(&o, ", \"tags\": [");
        int64_t nt = (int64_t)((seed >> 10) % 4);
        for (int64_t t = 0; t < nt; t++) {
            if (t > 0) puts_(&o, ", ");
            seed = lcg(seed);
            puti(&o, (int64_t)((seed >> 35) % 1000));
        }
        puts_(&o, "], \"ok\": ");
        puts_(&o, (seed & 4) != 0 ? "true" : "false");
        puts_(&o, ", \"next\": null}");
        if (r + 1 < nrec) putb(&o, ',');
        putb(&o, '\n');
    }
    puts_(&o, "]\n");
    *len = o.n;
    return o.b;
}
typedef struct { int64_t tokens, strings, strbytes, numsum, depth, maxdepth, lits; } Stats;
static int tokenize(const uint8_t *s, int64_t n, Stats *st) {
    int64_t i = 0;
    while (i < n) {
        uint8_t c = s[i];
        switch (c) {
        case ' ': case '\t': case '\n': case '\r': i++; break;
        case '{': case '[':
            st->depth++;
            if (st->depth > st->maxdepth) st->maxdepth = st->depth;
            st->tokens++; i++; break;
        case '}': case ']': st->depth--; st->tokens++; i++; break;
        case ':': case ',': st->tokens++; i++; break;
        case '"': {
            i++;
            int64_t start = i;
            while (i < n && s[i] != '"') { if (s[i] == '\\') i++; i++; }
            if (i >= n) return 0;
            st->strbytes += i - start;
            st->strings++; st->tokens++; i++;
            break;
        }
        case '-': case '0': case '1': case '2': case '3': case '4':
        case '5': case '6': case '7': case '8': case '9': {
            int neg = c == '-';
            if (neg) i++;
            int64_t v = 0;
            while (i < n && s[i] >= '0' && s[i] <= '9') { v = v * 10 + (s[i] - '0'); i++; }
            if (i < n && s[i] == '.') {
                i++;
                while (i < n && s[i] >= '0' && s[i] <= '9') { v = v * 10 + (s[i] - '0'); i++; }
            }
            st->numsum += neg ? -v : v;
            st->tokens++;
            break;
        }
        case 't': case 'n': i += 4; st->lits++; st->tokens++; break;
        case 'f': i += 5; st->lits++; st->tokens++; break;
        default: return 0;
        }
    }
    return 1;
}
int main(void) {
    int64_t n;
    uint8_t *text = gen(200000, &n);
    Stats st = {0};
    int ok = 1;
    for (int r = 0; r < 25; r++) ok = ok && tokenize(text, n, &st);
    printf("%lld %s %lld %lld %lld %lld %lld %lld\n", (long long)n, ok ? "true" : "false", (long long)st.tokens,
           (long long)st.strings, (long long)st.strbytes, (long long)st.numsum, (long long)st.maxdepth, (long long)st.lits);
    return 0;
}
