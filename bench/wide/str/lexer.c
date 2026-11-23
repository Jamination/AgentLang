/* [codegen] tokenizing lexer with a character-class switch: see lexer.al */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline uint64_t lcg(uint64_t s) { return s * 6364136223846793005ULL + 1442695040888963407ULL; }
static const char *PIECES[24] = {"if", "while", "return", "fn", "let", "else", "counter", "x", "value_2", "_tmp",
    "12345", "0", "42", "+", "-", "*", "==", "!=", "<=", "&&", "(", ")", "{", "}"};
static uint8_t *gen(int64_t n, int64_t *len) {
    uint8_t *out = calloc(n + 64, 1);
    int64_t k = 0;
    uint64_t seed = 17;
    while (k < n) {
        seed = lcg(seed);
        uint64_t r = (seed >> 33) % 100;
        if (r < 4) { for (const char *c = "// note\n"; *c; c++) out[k++] = (uint8_t)*c; }
        else if (r < 8) { out[k++] = '"'; for (const char *c = "text"; *c; c++) out[k++] = (uint8_t)*c; out[k++] = '"'; }
        else if (r < 12) { out[k] = ';'; out[k + 1] = '\n'; k += 2; }
        else { for (const char *c = PIECES[(seed >> 40) % 24]; *c; c++) out[k++] = (uint8_t)*c; }
        out[k++] = ' ';
    }
    *len = k;
    return out;
}
static inline int is_ident(uint8_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}
static int64_t keyword(const uint8_t *s, int64_t n) {
    switch (n) {
    case 2:
        if (s[0] == 'i' && s[1] == 'f') return 1;
        if (s[0] == 'f' && s[1] == 'n') return 2;
        break;
    case 3: if (s[0] == 'l' && s[1] == 'e' && s[2] == 't') return 3; break;
    case 4: if (s[0] == 'e' && s[1] == 'l' && s[2] == 's' && s[3] == 'e') return 4; break;
    case 5: if (s[0] == 'w' && s[1] == 'h' && s[2] == 'i' && s[3] == 'l' && s[4] == 'e') return 5; break;
    case 6: if (s[0] == 'r' && s[1] == 'e' && s[2] == 't' && s[3] == 'u' && s[4] == 'r' && s[5] == 'n') return 6; break;
    }
    return 0;
}
static uint64_t lex(const uint8_t *s, int64_t n, int64_t *counts) {
    uint64_t h = 0;
    int64_t i = 0, line = 1;
    while (i < n) {
        uint8_t c = s[i];
        int64_t kind = 0, start = i;
        switch (c) {
        case ' ': case '\t': case '\r': i++; continue;
        case '\n': line++; i++; continue;
        case 'a': case 'b': case 'c': case 'd': case 'e': case 'f': case 'g': case 'h': case 'i': case 'j':
        case 'k': case 'l': case 'm': case 'n': case 'o': case 'p': case 'q': case 'r': case 's': case 't':
        case 'u': case 'v': case 'w': case 'x': case 'y': case 'z': case 'A': case 'B': case 'C': case 'D':
        case 'E': case 'F': case 'G': case 'H': case 'I': case 'J': case 'K': case 'L': case 'M': case 'N':
        case 'O': case 'P': case 'Q': case 'R': case 'S': case 'T': case 'U': case 'V': case 'W': case 'X':
        case 'Y': case 'Z': case '_': {
            while (i < n && is_ident(s[i])) i++;
            int64_t kw = keyword(s + start, i - start);
            kind = kw > 0 ? 10 + kw : 1;
            break;
        }
        case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': case '8': case '9': {
            int64_t v = 0;
            while (i < n && s[i] >= '0' && s[i] <= '9') { v = v * 10 + (s[i] - '0'); i++; }
            h = h + (uint64_t)v;
            kind = 2;
            break;
        }
        case '"':
            i++;
            while (i < n && s[i] != '"') i++;
            i++;
            kind = 3;
            break;
        case '/':
            if (i + 1 < n && s[i + 1] == '/') { while (i < n && s[i] != '\n') i++; continue; }
            i++;
            kind = 4;
            break;
        case '=': case '!': case '<': case '>':
            i++;
            kind = 5;
            if (i < n && s[i] == '=') { i++; kind = 6; }
            break;
        case '&':
            i++;
            kind = 7;
            if (i < n && s[i] == '&') i++;
            break;
        case '+': case '-': case '*': i++; kind = 8; break;
        case '(': case ')': case '{': case '}': case ';': i++; kind = 9; break;
        default: i++; kind = 0; break;
        }
        counts[kind]++;
        h = h * 31 + (uint64_t)kind * 7 + (uint64_t)(i - start) + (uint64_t)line;
    }
    return h;
}
int main(void) {
    int64_t n;
    uint8_t *s = gen(16000000, &n);
    int64_t counts[20] = {0};
    uint64_t h = 0;
    for (int r = 0; r < 8; r++) h = h * 3 + lex(s, n, counts);
    printf("%lld %llu [", (long long)n, (unsigned long long)h);
    for (int k = 0; k < 20; k++) printf(k ? ", %lld" : "%lld", (long long)counts[k]);
    printf("]\n");
    return 0;
}
