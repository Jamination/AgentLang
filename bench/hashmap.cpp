#include <cstdint>
#include <cstdio>
#include <utility>
#include <vector>

struct Entry {
    std::uint64_t key, val;
};

// open addressing with linear probing; key 0 marks an empty slot
class Map {
public:
    explicit Map(std::uint64_t cap) : e_(cap), cap_(cap) {}

    std::uint64_t size() const { return len_; }

    // find the value slot of key, inserting it if missing
    std::uint64_t &slot(std::uint64_t key) {
        if ((len_ + 1) * 4 > cap_ * 3) grow();
        std::uint64_t mask = cap_ - 1;
        std::uint64_t i = hash(key) & mask;
        for (;;) {
            Entry &e = e_[i];
            if (e.key == key) return e.val;
            if (e.key == 0) {
                e.key = key;
                len_++;
                return e.val;
            }
            i = (i + 1) & mask;
        }
    }

    bool get(std::uint64_t key, std::uint64_t &out) const {
        std::uint64_t mask = cap_ - 1;
        std::uint64_t i = hash(key) & mask;
        for (;;) {
            const Entry &e = e_[i];
            if (e.key == key) {
                out = e.val;
                return true;
            }
            if (e.key == 0) return false;
            i = (i + 1) & mask;
        }
    }

private:
    static std::uint64_t hash(std::uint64_t k) {
        return (k * 0x9E3779B97F4A7C15ULL) >> 32;
    }

    void grow() {
        std::vector<Entry> old = std::move(e_);
        std::uint64_t oldcap = cap_;
        e_ = std::vector<Entry>(oldcap * 2);
        cap_ = oldcap * 2;
        len_ = 0;
        for (std::uint64_t i = 0; i < oldcap; i++) {
            if (old[i].key != 0) slot(old[i].key) = old[i].val;
        }
    }

    std::vector<Entry> e_;
    std::uint64_t cap_;
    std::uint64_t len_ = 0;
};

int main() {
    Map m(16);
    std::uint64_t seed = 42;
    for (std::uint64_t i = 0; i < 5000000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        std::uint64_t key = (seed >> 33) % 3000000 + 1;
        m.slot(key) += i;
    }
    std::uint64_t hits = 0, sum = 0;
    for (std::uint64_t i = 0; i < 10000000; i++) {
        seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
        std::uint64_t key = (seed >> 33) % 6000000 + 1;
        std::uint64_t v;
        if (m.get(key, v)) {
            hits++;
            sum += v;
        }
    }
    std::printf("%llu %llu %llu\n", static_cast<unsigned long long>(m.size()), static_cast<unsigned long long>(hits), static_cast<unsigned long long>(sum));
    return 0;
}
