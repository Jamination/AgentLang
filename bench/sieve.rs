fn main() {
    let n: usize = 60000000;
    let mut composite = vec![0u8; n + 1];
    let mut i = 2;
    while i * i <= n {
        if composite[i] == 0 {
            let mut j = i * i;
            while j <= n {
                composite[j] = 1;
                j += i;
            }
        }
        i += 1;
    }
    let (mut count, mut last) = (0i64, 0usize);
    for i in 2..=n {
        if composite[i] == 0 {
            count += 1;
            last = i;
        }
    }
    println!("{} {}", count, last);
}
