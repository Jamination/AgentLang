#include <cstdio>

int main() {
    int w = 3000, h = 3000;
    const int iter = 50;
    const double limit = 2.0;
    int bit_num = 0;
    char byte_acc = 0;
    std::printf("P4\n%d %d\n", w, h);
    for (double y = 0; y < h; ++y) {
        for (double x = 0; x < w; ++x) {
            double Zr = 0.0, Zi = 0.0, Tr = 0.0, Ti = 0.0;
            double Cr = (2.0 * x / w - 1.5);
            double Ci = (2.0 * y / h - 1.0);
            for (int i = 0; i < iter && (Tr + Ti <= limit * limit); ++i) {
                Zi = 2.0 * Zr * Zi + Ci;
                Zr = Tr - Ti + Cr;
                Tr = Zr * Zr;
                Ti = Zi * Zi;
            }
            byte_acc <<= 1;
            if (Tr + Ti <= limit * limit) byte_acc |= 0x01;
            ++bit_num;
            if (bit_num == 8) {
                std::putc(byte_acc, stdout);
                byte_acc = 0;
                bit_num = 0;
            } else if (x == w - 1) {
                byte_acc <<= (8 - w % 8);
                std::putc(byte_acc, stdout);
                byte_acc = 0;
                bit_num = 0;
            }
        }
    }
    return 0;
}
