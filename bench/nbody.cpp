#include <array>
#include <cmath>
#include <cstddef>
#include <cstdio>

constexpr double PI = 3.141592653589793;
constexpr double SOLAR_MASS = 4 * PI * PI;
constexpr double DAYS_PER_YEAR = 365.24;

struct Body {
    double x, y, z, vx, vy, vz, mass;
};

struct System {
    std::array<Body, 5> b;

    void advance(double dt) {
        const std::size_t n = b.size();
        for (std::size_t i = 0; i < n; i++) {
            for (std::size_t j = i + 1; j < n; j++) {
                double dx = b[i].x - b[j].x;
                double dy = b[i].y - b[j].y;
                double dz = b[i].z - b[j].z;
                double d2 = dx * dx + dy * dy + dz * dz;
                double mag = dt / (d2 * std::sqrt(d2));
                b[i].vx -= dx * b[j].mass * mag;
                b[i].vy -= dy * b[j].mass * mag;
                b[i].vz -= dz * b[j].mass * mag;
                b[j].vx += dx * b[i].mass * mag;
                b[j].vy += dy * b[i].mass * mag;
                b[j].vz += dz * b[i].mass * mag;
            }
        }
        for (Body &p : b) {
            p.x += dt * p.vx;
            p.y += dt * p.vy;
            p.z += dt * p.vz;
        }
    }

    double energy() const {
        const std::size_t n = b.size();
        double e = 0.0;
        for (std::size_t i = 0; i < n; i++) {
            e += 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz);
            for (std::size_t j = i + 1; j < n; j++) {
                double dx = b[i].x - b[j].x;
                double dy = b[i].y - b[j].y;
                double dz = b[i].z - b[j].z;
                e -= (b[i].mass * b[j].mass) / std::sqrt(dx * dx + dy * dy + dz * dz);
            }
        }
        return e;
    }

    void offset_momentum() {
        double px = 0.0, py = 0.0, pz = 0.0;
        for (const Body &p : b) {
            px += p.vx * p.mass;
            py += p.vy * p.mass;
            pz += p.vz * p.mass;
        }
        b[0].vx = -px / SOLAR_MASS;
        b[0].vy = -py / SOLAR_MASS;
        b[0].vz = -pz / SOLAR_MASS;
    }
};

int main() {
    System sys{{{
        {0, 0, 0, 0, 0, 0, SOLAR_MASS},
        {4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR, -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS},
        {8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS},
        {1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS},
        {1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS},
    }}};
    const int steps = 5000000;
    sys.offset_momentum();
    std::printf("%.9f\n", sys.energy());
    for (int i = 0; i < steps; i++) {
        sys.advance(0.01);
    }
    std::printf("%.9f\n", sys.energy());
    return 0;
}
