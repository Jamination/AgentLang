/* For win_long_backtrace.al: C code that calls the program back (MinGW -O2), so that a stack
   trace of a panic in the callback names this DLL. */
typedef int (*item_fn)(int);

__attribute__((noinline)) int each(item_fn f, int n) {
    int sum = 0;
    for (int i = 0; i < n; i++) sum += f(i) * (i + 1);
    return sum;
}

int run_each(item_fn f, int n) {
    volatile int pad[40];
    pad[n & 31] = n;
    return each(f, n) * 2 + pad[3];
}
