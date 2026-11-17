// The register allocator drops a store to a spill slot that a later store in the same block
// overwrites before anything reads the slot (a spilled two-address result `v = u; v -= w`
// was stored after the copy and again after the operation). `kernel` keeps more f64 values
// live around its loop than there are xmm registers; its machine code (`--emit-asm`) must not
// store to a slot twice in a block without reading it in between. Slots that the code also
// addresses with an offset (memory of the program, not spill slots) are not looked at.
use std.os

// the compiler for the system this program runs on, as ./build.sh builds it
when TARGET_OS == Windows {
    const ALC = "build/alc.exe"
} else {
    const ALC = "./build/alc"
}

const SRC = `noinline fn kernel(n: i64, dt: f64) -> f64 {
    x0: f64 = 0.0
    y0: f64 = 0.0
    z0: f64 = 0.0
    x1: f64 = 1.0
    y1: f64 = 0.5
    z1: f64 = 0.25
    x2: f64 = -1.0
    y2: f64 = 0.75
    z2: f64 = -0.5
    x3: f64 = 0.3
    y3: f64 = -0.9
    z3: f64 = 0.6
    u0: f64 = 0.01
    v0: f64 = 0.02
    w0: f64 = 0.03
    u1: f64 = -0.01
    v1: f64 = 0.0
    w1: f64 = 0.02
    u2: f64 = 0.005
    v2: f64 = -0.02
    w2: f64 = 0.0
    u3: f64 = 0.0
    v3: f64 = 0.01
    w3: f64 = -0.01
    for i in 0..n {
        dx := x0 - x1
        dy := y0 - y1
        dz := z0 - z1
        d2 := dx * dx + dy * dy + dz * dz + 0.01
        m := dt / (d2 * sqrt(d2))
        u0 -= dx * m
        v0 -= dy * m
        w0 -= dz * m
        u1 += dx * m
        v1 += dy * m
        w1 += dz * m
        ex := x2 - x3
        ey := y2 - y3
        ez := z2 - z3
        e2 := ex * ex + ey * ey + ez * ez + 0.01
        k := dt / (e2 * sqrt(e2))
        u2 -= ex * k
        v2 -= ey * k
        w2 -= ez * k
        u3 += ex * k
        v3 += ey * k
        w3 += ez * k
        fx := x0 - x3
        fy := y0 - y3
        fz := z0 - z3
        f2 := fx * fx + fy * fy + fz * fz + 0.01
        q := dt / (f2 * sqrt(f2))
        u0 -= fx * q
        v0 -= fy * q
        w0 -= fz * q
        u3 += fx * q
        v3 += fy * q
        w3 += fz * q
        x0 += dt * u0
        y0 += dt * v0
        z0 += dt * w0
        x1 += dt * u1
        y1 += dt * v1
        z1 += dt * w1
        x2 += dt * u2
        y2 += dt * v2
        z2 += dt * w2
        x3 += dt * u3
        y3 += dt * v3
        z3 += dt * w3
    }
    return x0 + y0 + z0 + x1 + y1 + z1 + x2 + y2 + z2 + x3 + y3 + z3 + u0 + v0 + w0 + u1 + v1 + w1 + u2 + v2 + w2 + u3 + v3 + w3
}
fn main() {
    print(kernel(1000, 0.001))
}
`

// the memory operand `[slotN ..]` of a line: (N, whether it has an offset), N = -1 for none
fn slot_ref(line: str) -> (i64, bool) {
    p := find(line, "[slot")
    if p < 0 {
        return (-1, false)
    }
    q := p + 5
    n := 0
    while q < len(line) && line[q] >= '0' && line[q] <= '9' {
        n = n * 10 + i64(line[q] - '0')
        q += 1
    }
    return (n, !starts_with(line[q..], " ]"))
}

fn main() {
    if !file_exists(ALC) {
        print(fmt("no compiler at ", ALC, " (./build.sh builds it)"))
        exit(77)
    }
    make_dir("tmp")
    src := fmt("tmp/al_spill_dead_store_", process_id(), ".al")
    exe := src[..len(src) - 3]
    write_file(src, SRC)
    out, status := run_capture([]str{ALC, "build", "--emit-asm", src, "-o", exe})
    // the lines of kernel
    lines := vec[str]()
    inside := false
    for l in split(out, "\n") {
        if len(l) > 0 && l[len(l) - 1] == ':' && !starts_with(l, ".") {
            inside = l == "kernel:"
        } else if inside {
            lines.push(trim(l))
        }
    }
    // the slots addressed with an offset somewhere are not spill slots
    other := vec_fill(4096, false)
    for l in lines {
        s, off := slot_ref(l)
        if s >= 0 && s < 4096 && off {
            other[s] = true
        }
    }
    spills := 0
    dead := 0
    // per block: the slots stored to and not read since
    pending := vec_fill(4096, false)
    for l in lines {
        if starts_with(l, ".L") {
            fill(pending.items(), false)
            continue
        }
        s, off := slot_ref(l)
        if s < 0 || s >= 4096 || off || other[s] {
            continue
        }
        if starts_with(l, "movsd8 [slot") || starts_with(l, "mov8 [slot") {
            spills += 1
            if pending[s] {
                dead += 1
                print("overwritten before it is read: ", l)
            }
            pending[s] = true
        } else {
            pending[s] = false
        }
    }
    print(status, spills > 0, dead)
    res, _ := run_capture([]str{exe})
    print(trim(res))
    remove_file(src)
    remove_file(exe)
}
