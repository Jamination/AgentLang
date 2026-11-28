#[inline]
fn eval_a(i: i32, j: i32) -> f64 {
    1.0 / ((i + j) * (i + j + 1) / 2 + i + 1) as f64
}

fn eval_a_times_u(u: &[f64], au: &mut [f64]) {
    for (i, out) in au.iter_mut().enumerate() {
        let mut s = 0.0;
        for (j, &uj) in u.iter().enumerate() {
            s += eval_a(i as i32, j as i32) * uj;
        }
        *out = s;
    }
}

fn eval_at_times_u(u: &[f64], au: &mut [f64]) {
    for (i, out) in au.iter_mut().enumerate() {
        let mut s = 0.0;
        for (j, &uj) in u.iter().enumerate() {
            s += eval_a(j as i32, i as i32) * uj;
        }
        *out = s;
    }
}

fn eval_ata_times_u(u: &[f64], atau: &mut [f64], v: &mut [f64]) {
    eval_a_times_u(u, v);
    eval_at_times_u(v, atau);
}

fn main() {
    let n = 2000;
    let mut u = vec![1.0f64; n];
    let mut v = vec![0.0f64; n];
    let mut t = vec![0.0f64; n];
    for _ in 0..10 {
        eval_ata_times_u(&u, &mut v, &mut t);
        eval_ata_times_u(&v, &mut u, &mut t);
    }
    let (mut vbv, mut vv) = (0.0, 0.0);
    for i in 0..n {
        vbv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    println!("{:.9}", (vbv / vv).sqrt());
}
