#include <stdint.h>
#include <stdio.h>

static int64_t fib(int64_t n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    (void)argv;
    int64_t base = argc, f = 0;
    for (int64_t i = 0; i < 4; i++) f += fib(35 + base + i);
    printf("%lld\n", (long long)f);
    return 0;
}
