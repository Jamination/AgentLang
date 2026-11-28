fn mm_init(n: usize) -> Vec<Vec<f64>> {
    let mut m = Vec::with_capacity(n);
    for _ in 0..n {
        m.push(vec![0.0f64; n]);
    }
    m
}

fn mm_gen(n: usize, seed: f64) -> Vec<Vec<f64>> {
    let mut a = mm_init(n);
    let tmp = seed / n as f64 / n as f64;
    for i in 0..n {
        for j in 0..n {
            a[i][j] = tmp * (i as i32 - j as i32) as f64 * (i as i32 + j as i32) as f64;
        }
    }
    a
}

fn mm_mul(n: usize, a: &[Vec<f64>], b: &[Vec<f64>]) -> Vec<Vec<f64>> {
    let mut m = mm_init(n);
    let mut c = mm_init(n);
    for i in 0..n {
        for j in 0..n {
            c[i][j] = b[j][i];
        }
    }
    for i in 0..n {
        let p = &a[i];
        let q = &mut m[i];
        for j in 0..n {
            let mut t = 0.0;
            let r = &c[j];
            for k in 0..n {
                t += p[k] * r[k];
            }
            q[j] = t;
        }
    }
    m
}

fn main() {
    let n = 800;
    let a = mm_gen(n, 1.0);
    let b = mm_gen(n, 2.0);
    let m = mm_mul(n, &a, &b);
    let mut trace = 0.0;
    for i in 0..n {
        trace += m[i][i];
    }
    println!("{:.9}\n{:.9}", m[n / 2][n / 2], trace);
}
