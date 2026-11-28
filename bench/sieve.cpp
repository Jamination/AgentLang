#include <cstdint>
#include <cstdio>
#include <vector>

int main() {
    const long n = 60000000;
    std::vector<std::uint8_t> composite(n + 1);
    for (long i = 2; i * i <= n; i++) {
        if (!composite[i]) {
            for (long j = i * i; j <= n; j += i) composite[j] = 1;
        }
    }
    long count = 0, last = 0;
    for (long i = 2; i <= n; i++) {
        if (!composite[i]) {
            count++;
            last = i;
        }
    }
    std::printf("%ld %ld\n", count, last);
    return 0;
}
