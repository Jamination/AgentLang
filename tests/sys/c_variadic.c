// Variadic C functions for c_variadic.al: they read their arguments with va_arg and report
// what they got as text. Built by clang for Linux and by MinGW for Windows (see tests/run.sh);
// no C library formatting is used, so both report the same text.
#include <stdarg.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif

static char *put_str(char *o, const char *s) {
    while (*s) *o++ = *s++;
    return o;
}

static char *put_u64(char *o, uint64_t v) {
    char t[24];
    int n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) *o++ = t[--n];
    return o;
}

static char *put_i64(char *o, int64_t v) {
    if (v < 0) { *o++ = '-'; return put_u64(o, (uint64_t)0 - (uint64_t)v); }
    return put_u64(o, (uint64_t)v);
}

static char *put_hex(char *o, uint64_t v) {
    char t[17];
    int n = 0;
    do { t[n++] = "0123456789abcdef"[v & 15]; v >>= 4; } while (v);
    o = put_str(o, "0x");
    while (n) *o++ = t[--n];
    return o;
}

// a double as its bits (exact) and, for moderate values, with 4 decimals
static char *put_double(char *o, double d) {
    uint64_t bits;
    memcpy(&bits, &d, 8);
    if (d > -1e15 && d < 1e15) {
        double a = d < 0 ? -d : d;
        int64_t scaled = (int64_t)(a * 10000.0 + 0.5);
        if (d < 0) *o++ = '-';
        o = put_u64(o, (uint64_t)(scaled / 10000));
        *o++ = '.';
        char f[4];
        int64_t r = scaled % 10000;
        for (int i = 3; i >= 0; i--) { f[i] = (char)('0' + r % 10); r /= 10; }
        for (int i = 0; i < 4; i++) *o++ = f[i];
        *o++ = '/';
    }
    return put_hex(o, bits);
}

// Reads one argument per letter of `spec` and writes `letter=value` words to `out`:
//   i int (also what a narrower integer or a bool is promoted to: the int as it was received,
//   so a value that was not extended to 32 bits shows), u unsigned int, l long long,
//   L unsigned long long, d double, p pointer, f function pointer int(*)(int), called with 20.
// Returns the number of arguments read.
EXPORT int va_report(char *out, const char *spec, ...) {
    va_list ap;
    va_start(ap, spec);
    char *o = out;
    int n = 0;
    for (const char *s = spec; *s; s++, n++) {
        if (s != spec) *o++ = ' ';
        *o++ = *s;
        *o++ = '=';
        switch (*s) {
        case 'i': o = put_i64(o, va_arg(ap, int)); break;
        case 'u': o = put_u64(o, va_arg(ap, unsigned int)); break;
        case 'l': o = put_i64(o, va_arg(ap, long long)); break;
        case 'L': o = put_u64(o, va_arg(ap, unsigned long long)); break;
        case 'd': o = put_double(o, va_arg(ap, double)); break;
        case 'p': o = put_hex(o, (uint64_t)(uintptr_t)va_arg(ap, void *)); break;
        case 'f': { int (*f)(int) = va_arg(ap, int (*)(int)); o = put_i64(o, f(20)); break; }
        default: o = put_str(o, "?"); break;
        }
    }
    *o = 0;
    va_end(ap);
    return n;
}

// The sum of `n` doubles, the first in the slot right after `n` (Windows: rdx and xmm1);
// the result comes back in xmm0.
EXPORT double va_sum(int n, ...) {
    va_list ap;
    va_start(ap, n);
    double s = 0;
    for (int i = 0; i < n; i++) s = s * 10 + va_arg(ap, double);
    va_end(ap);
    return s;
}

// A float fixed parameter, then variadic ones: `x` stays a float (not promoted), the rest are
// doubles and ints, alternating.
EXPORT double va_after_float(float x, int n, ...) {
    va_list ap;
    va_start(ap, n);
    double s = x;
    for (int i = 0; i < n; i++) {
        s = s * 2 + va_arg(ap, double);
        s = s * 2 + va_arg(ap, int);
    }
    va_end(ap);
    return s;
}
