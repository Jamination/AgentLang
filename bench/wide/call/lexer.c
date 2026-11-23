#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum { START, IDENT, NUM, FRAC, EXPSIGN, EXP, STR, ESC, SLASH, LINECMT, BLOCKCMT, BLOCKSTAR } St;

static bool alpha(uint8_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool digit(uint8_t c) { return c >= '0' && c <= '9'; }

static void lex(const uint8_t *text, int64_t n, int64_t *counts) {
    St st = START;
    int64_t i = 0;
    while (i < n) {
        uint8_t c = text[i];
        switch (st) {
        case START:
            if (alpha(c)) st = IDENT;
            else if (digit(c)) st = NUM;
            else if (c == '"') st = STR;
            else if (c == '/') st = SLASH;
            else if (c != ' ' && c != '\n') counts[8]++;
            i++;
            break;
        case IDENT:
            if (alpha(c) || digit(c)) i++; else { counts[0]++; st = START; }
            break;
        case NUM:
            if (digit(c)) i++;
            else if (c == '.') { st = FRAC; i++; }
            else if (c == 'e') { st = EXPSIGN; i++; }
            else { counts[1]++; st = START; }
            break;
        case FRAC:
            if (digit(c)) i++;
            else if (c == 'e') { st = EXPSIGN; i++; }
            else { counts[2]++; st = START; }
            break;
        case EXPSIGN:
            if (c == '+' || c == '-' || digit(c)) { st = EXP; i++; } else { counts[7]++; st = START; }
            break;
        case EXP:
            if (digit(c)) i++; else { counts[2]++; st = START; }
            break;
        case STR:
            if (c == '"') { counts[3]++; st = START; }
            else if (c == 92) st = ESC; /* backslash */
            else if (c == '\n') { counts[7]++; st = START; }
            i++;
            break;
        case ESC: st = STR; i++; break;
        case SLASH:
            if (c == '/') { st = LINECMT; i++; }
            else if (c == '*') { st = BLOCKCMT; i++; }
            else { counts[4]++; st = START; }
            break;
        case LINECMT:
            if (c == '\n') { counts[5]++; st = START; }
            i++;
            break;
        case BLOCKCMT:
            if (c == '*') st = BLOCKSTAR;
            i++;
            break;
        case BLOCKSTAR:
            if (c == '/') { counts[6]++; st = START; } else if (c != '*') st = BLOCKCMT;
            i++;
            break;
        }
    }
}

int main(void) {
    const char *table = "aaaabbccxyzeeeeE_09912345678.....   \n\n+-+-=();;(){}\"\"\x5c/*/*/*abtr";
    uint64_t tlen = strlen(table);
    int64_t n = 8000000;
    uint8_t *text = malloc(n);
    uint64_t seed = 2024;
    for (int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        text[i] = (uint8_t)table[(seed >> 33) % tlen];
    }
    int64_t *counts = calloc(9, 8);
    for (int64_t r = 0; r < 12; r++) lex(text + r, n - r, counts);
    printf("%lld %lld %lld %lld %lld %lld %lld %lld %lld\n", (long long)counts[0], (long long)counts[1],
           (long long)counts[2], (long long)counts[3], (long long)counts[4], (long long)counts[5],
           (long long)counts[6], (long long)counts[7], (long long)counts[8]);
    return 0;
}
