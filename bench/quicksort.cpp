#include <cstdint>
#include <cstdio>
#include <utility>
#include <vector>

static void quicksort(std::int64_t *a, std::int64_t lo, std::int64_t hi) {
    std::int64_t p = a[(lo + hi) / 2];
    std::int64_t i = lo, j = hi;
    while (i <= j) {
        while (a[i] < p) i++;
        while (a[j] > p) j--;
        if (i <= j) {
            std::swap(a[i], a[j]);
            i++;
            j--;
        }
    }
    if (lo < j) quicksort(a, lo, j);
    if (i < hi) quicksort(a, i, hi);
}

int main() {
    const std::int64_t n = 5000000;
    std::vector<std::int64_t> a(n);
    std::uint64_t seed = 88172645463325252ULL;
    for (std::int64_t i = 0; i < n; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        a[i] = static_cast<std::int64_t>(seed >> 16);
    }
    quicksort(a.data(), 0, n - 1);
    std::uint64_t sum = 0;
    for (std::int64_t i = 0; i < n; i++) {
        if (i > 0 && a[i - 1] > a[i]) {
            std::printf("not sorted at %lld\n", static_cast<long long>(i));
            return 1;
        }
        sum = sum * 31 + static_cast<std::uint64_t>(a[i]);
    }
    std::printf("%lld %lld %lld %llu\n", static_cast<long long>(a[0]), static_cast<long long>(a[n / 2]), static_cast<long long>(a[n - 1]), static_cast<unsigned long long>(sum));
    return 0;
}
