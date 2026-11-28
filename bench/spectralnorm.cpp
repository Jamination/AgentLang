#include <cmath>
#include <cstdio>
#include <span>
#include <vector>

static inline double eval_A(int i, int j) {
    return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1);
}

static void eval_A_times_u(std::span<const double> u, std::span<double> Au) {
    const int n = static_cast<int>(u.size());
    for (int i = 0; i < n; i++) {
        double s = 0.0;
        for (int j = 0; j < n; j++) {
            s += eval_A(i, j) * u[j];
        }
        Au[i] = s;
    }
}

static void eval_At_times_u(std::span<const double> u, std::span<double> Au) {
    const int n = static_cast<int>(u.size());
    for (int i = 0; i < n; i++) {
        double s = 0.0;
        for (int j = 0; j < n; j++) {
            s += eval_A(j, i) * u[j];
        }
        Au[i] = s;
    }
}

static void eval_AtA_times_u(std::span<const double> u, std::span<double> AtAu, std::span<double> v) {
    eval_A_times_u(u, v);
    eval_At_times_u(v, AtAu);
}

int main() {
    const int n = 2000;
    std::vector<double> u(n, 1.0);
    std::vector<double> v(n);
    std::vector<double> t(n);
    for (int i = 0; i < 10; i++) {
        eval_AtA_times_u(u, v, t);
        eval_AtA_times_u(v, u, t);
    }
    double vBv = 0.0, vv = 0.0;
    for (int i = 0; i < n; i++) {
        vBv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    std::printf("%0.9f\n", std::sqrt(vBv / vv));
    return 0;
}
