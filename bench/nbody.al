const PI = 3.141592653589793
const SOLAR_MASS = 4.0 * PI * PI
const DAYS_PER_YEAR = 365.24

struct Body { x f64, y f64, z f64, vx f64, vy f64, vz f64, mass f64 }

fn advance(b []Body, dt f64) {
    n := len(b)
    for i in 0..n {
        for j in i + 1..n {
            dx := b[i].x - b[j].x
            dy := b[i].y - b[j].y
            dz := b[i].z - b[j].z
            d2 := dx * dx + dy * dy + dz * dz
            mag := dt / (d2 * sqrt(d2))
            b[i].vx -= dx * b[j].mass * mag
            b[i].vy -= dy * b[j].mass * mag
            b[i].vz -= dz * b[j].mass * mag
            b[j].vx += dx * b[i].mass * mag
            b[j].vy += dy * b[i].mass * mag
            b[j].vz += dz * b[i].mass * mag
        }
    }
    for i in 0..n {
        b[i].x += dt * b[i].vx
        b[i].y += dt * b[i].vy
        b[i].z += dt * b[i].vz
    }
}

fn energy(b []Body) f64 {
    n := len(b)
    e := 0.0
    for i in 0..n {
        e += 0.5 * b[i].mass * (b[i].vx * b[i].vx + b[i].vy * b[i].vy + b[i].vz * b[i].vz)
        for j in i + 1..n {
            dx := b[i].x - b[j].x
            dy := b[i].y - b[j].y
            dz := b[i].z - b[j].z
            e -= (b[i].mass * b[j].mass) / sqrt(dx * dx + dy * dy + dz * dz)
        }
    }
    e
}

fn offset_momentum(b []Body) {
    px := 0.0
    py := 0.0
    pz := 0.0
    for i in 0..len(b) {
        px += b[i].vx * b[i].mass
        py += b[i].vy * b[i].mass
        pz += b[i].vz * b[i].mass
    }
    b[0].vx = -px / SOLAR_MASS
    b[0].vy = -py / SOLAR_MASS
    b[0].vz = -pz / SOLAR_MASS
}

fn main() {
    var bodies [5]Body
    bodies[0] = Body{0.0, 0.0, 0.0, 0.0, 0.0, 0.0, SOLAR_MASS}
    bodies[1] = Body{4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01, 1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR, -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS}
    bodies[2] = Body{8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01, -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR, 2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS}
    bodies[3] = Body{1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01, 2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR, -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS}
    bodies[4] = Body{1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01, 2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR, -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS}
    steps := 5000000
    b := bodies[..]
    offset_momentum(b)
    putf(energy(b), 9)
    putc('\n')
    for i in 0..steps {
        advance(b, 0.01)
    }
    putf(energy(b), 9)
    putc('\n')
}
