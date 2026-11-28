#include <array>
#include <cstdio>
#include <utility>

static int fannkuch(int n) {
    std::array<int, 16> perm, perm1, count;
    int maxflips = 0, checksum = 0, permcount = 0, r = n;
    for (int i = 0; i < n; i++) perm1[i] = i;
    for (;;) {
        for (; r != 1; r--) count[r - 1] = r;
        for (int i = 0; i < n; i++) perm[i] = perm1[i];
        int flips = 0, k;
        while ((k = perm[0]) != 0) {
            int k2 = (k + 1) >> 1;
            for (int i = 0; i < k2; i++) {
                std::swap(perm[i], perm[k - i]);
            }
            flips++;
        }
        if (flips > maxflips) maxflips = flips;
        checksum += (permcount % 2 == 0) ? flips : -flips;
        for (;;) {
            if (r == n) {
                std::printf("%d\nPfannkuchen(%d) = %d\n", checksum, n, maxflips);
                return maxflips;
            }
            int p0 = perm1[0];
            for (int i = 0; i < r; i++) perm1[i] = perm1[i + 1];
            perm1[r] = p0;
            if (--count[r] > 0) break;
            r++;
        }
        permcount++;
    }
}

int main() {
    fannkuch(10);
    return 0;
}
