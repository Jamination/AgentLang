#include <cstdio>
#include <vector>

// one separately allocated, zeroed row per line, like the C program's array of row pointers
using Matrix = std::vector<std::vector<double>>;

static Matrix mm_init(int n) {
    return Matrix(n, std::vector<double>(n));
}

static Matrix mm_gen(int n, double seed) {
    Matrix a = mm_init(n);
    double tmp = seed / n / n;
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) a[i][j] = tmp * (i - j) * (i + j);
    return a;
}

static Matrix mm_mul(int n, const Matrix &a, const Matrix &b) {
    Matrix m = mm_init(n);
    Matrix c = mm_init(n);
    for (int i = 0; i < n; i++)
        for (int j = 0; j < n; j++) c[i][j] = b[j][i];
    for (int i = 0; i < n; i++) {
        const double *p = a[i].data();
        double *q = m[i].data();
        for (int j = 0; j < n; j++) {
            double t = 0.0;
            const double *r = c[j].data();
            for (int k = 0; k < n; k++) t += p[k] * r[k];
            q[j] = t;
        }
    }
    return m;
}

int main() {
    const int n = 800;
    Matrix a = mm_gen(n, 1.0);
    Matrix b = mm_gen(n, 2.0);
    Matrix m = mm_mul(n, a, b);
    double trace = 0.0;
    for (int i = 0; i < n; i++) trace += m[i][i];
    std::printf("%.9f\n%.9f\n", m[n / 2][n / 2], trace);
    return 0;
}
