// [library] f64 math-library calls: sin cos exp log pow atan2
fn main() {
    n := 8000000
    s1: f64 = 0.0
    s2: f64 = 0.0
    s3: f64 = 0.0
    s4: f64 = 0.0
    s5: f64 = 0.0
    s6: f64 = 0.0
    for i in 0..n {
        x := f64(i) * 0.00037 - 50.0
        s1 += sin(x)
        s2 += cos(x * 1.7)
        s3 += exp(x * 0.013)
        s4 += log(fabs(x) + 0.5)
        s5 += pow(fabs(x) + 1.0, 0.37)
        s6 += atan2(x, 3.0 + f64(i & 7))
    }
    // scaled and truncated: insensitive to last-ulp library differences
    print(i64(s1 * 1000.0), i64(s2 * 1000.0), i64(s3 * 1000.0), i64(s4 * 1000.0), i64(s5 * 1000.0), i64(s6 * 1000.0))
}
