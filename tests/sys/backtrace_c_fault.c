/* For backtrace_c_fault.al: C code that calls the program back and C code that faults, built
   without frame pointers (clang -O2 on Linux, MinGW -O2 on Windows). */
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

__attribute__((noinline)) void poke(int *p, int v) { p[v] = v; }

int poke_twice(int *p, int v) {
    volatile int pad[100];
    pad[v & 63] = v;
    poke(p, v);
    poke(p, v + 1);
    return pad[5];
}
