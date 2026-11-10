fn eval_a(i i64, j i64) f64 {
    1.0 / f64((i + j) * (i + j + 1) / 2 + i + 1)
}

fn eval_a_times_u(u []f64, au []f64) {
    n := len(u)
    for i in 0..n {
        s := 0.0
        for j in 0..n {
            s += eval_a(i, j) * u[j]
        }
        au[i] = s
    }
}

fn eval_at_times_u(u []f64, au []f64) {
    n := len(u)
    for i in 0..n {
        s := 0.0
        for j in 0..n {
            s += eval_a(j, i) * u[j]
        }
        au[i] = s
    }
}

fn eval_ata_times_u(u []f64, atau []f64, v []f64) {
    eval_a_times_u(u, v)
    eval_at_times_u(v, atau)
}

fn main() {
    n := 2000
    u := alloc[f64](n)
    v := alloc[f64](n)
    t := alloc[f64](n)
    for i in 0..n {
        u[i] = 1.0
    }
    for i in 0..10 {
        eval_ata_times_u(u, v, t)
        eval_ata_times_u(v, u, t)
    }
    vbv := 0.0
    vv := 0.0
    for i in 0..n {
        vbv += u[i] * v[i]
        vv += v[i] * v[i]
    }
    putf(sqrt(vbv / vv), 9)
    putc('\n')
}
