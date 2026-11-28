#include <array>
#include <bit>
#include <cstdint>
#include <cstdio>
#include <span>
#include <vector>

static constexpr std::array<std::uint32_t, 64> K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};

using State = std::array<std::uint32_t, 8>;
using Digest = std::array<std::uint8_t, 32>;

static void sha256_block(State &st, const std::uint8_t *p) {
    std::array<std::uint32_t, 64> w;
    for (int i = 0; i < 16; i++) {
        w[i] = (std::uint32_t{p[4 * i]} << 24) | (std::uint32_t{p[4 * i + 1]} << 16) | (std::uint32_t{p[4 * i + 2]} << 8) | std::uint32_t{p[4 * i + 3]};
    }
    for (int i = 16; i < 64; i++) {
        std::uint32_t s0 = std::rotr(w[i - 15], 7) ^ std::rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
        std::uint32_t s1 = std::rotr(w[i - 2], 17) ^ std::rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }
    std::uint32_t a = st[0], b = st[1], c = st[2], d = st[3], e = st[4], f = st[5], g = st[6], h = st[7];
    for (int i = 0; i < 64; i++) {
        std::uint32_t S1 = std::rotr(e, 6) ^ std::rotr(e, 11) ^ std::rotr(e, 25);
        std::uint32_t ch = (e & f) ^ (~e & g);
        std::uint32_t t1 = h + S1 + ch + K[i] + w[i];
        std::uint32_t S0 = std::rotr(a, 2) ^ std::rotr(a, 13) ^ std::rotr(a, 22);
        std::uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
        std::uint32_t t2 = S0 + maj;
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    st[0] += a;
    st[1] += b;
    st[2] += c;
    st[3] += d;
    st[4] += e;
    st[5] += f;
    st[6] += g;
    st[7] += h;
}

// hash of a message whose length is a multiple of 64 bytes
static void sha256(std::span<const std::uint8_t> data, Digest &out) {
    State st = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    const long len = static_cast<long>(data.size());
    for (long off = 0; off < len; off += 64) {
        sha256_block(st, data.data() + off);
    }
    std::array<std::uint8_t, 64> pad{};
    pad[0] = 0x80;
    std::uint64_t bits = static_cast<std::uint64_t>(len) * 8;
    for (int i = 0; i < 8; i++) pad[63 - i] = static_cast<std::uint8_t>(bits >> (8 * i));
    sha256_block(st, pad.data());
    for (int i = 0; i < 8; i++) {
        out[4 * i] = static_cast<std::uint8_t>(st[i] >> 24);
        out[4 * i + 1] = static_cast<std::uint8_t>(st[i] >> 16);
        out[4 * i + 2] = static_cast<std::uint8_t>(st[i] >> 8);
        out[4 * i + 3] = static_cast<std::uint8_t>(st[i]);
    }
}

int main() {
    const long len = 1 << 20;
    std::vector<std::uint8_t> buf(len);
    std::uint32_t seed = 12345;
    for (long i = 0; i < len; i++) {
        seed = seed * 1664525u + 1013904223u;
        buf[i] = static_cast<std::uint8_t>(seed >> 24);
    }
    Digest digest;
    for (int round = 0; round < 200; round++) {
        sha256(buf, digest);
        for (int i = 0; i < 32; i++) buf[i] ^= digest[i];
    }
    for (std::uint8_t byte : digest) std::printf("%02x", byte);
    std::printf("\n");
    return 0;
}
