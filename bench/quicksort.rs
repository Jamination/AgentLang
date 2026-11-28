use std::process;

fn quicksort(a: &mut [i64], lo: i64, hi: i64) {
    let p = a[((lo + hi) / 2) as usize];
    let (mut i, mut j) = (lo, hi);
    while i <= j {
        while a[i as usize] < p {
            i += 1;
        }
        while a[j as usize] > p {
            j -= 1;
        }
        if i <= j {
            a.swap(i as usize, j as usize);
            i += 1;
            j -= 1;
        }
    }
    if lo < j {
        quicksort(a, lo, j);
    }
    if i < hi {
        quicksort(a, i, hi);
    }
}

fn main() {
    let n: usize = 5000000;
    let mut a = vec![0i64; n];
    let mut seed: u64 = 88172645463325252;
    for i in 0..n {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        a[i] = (seed >> 16) as i64;
    }
    quicksort(&mut a, 0, n as i64 - 1);
    let mut sum: u64 = 0;
    for i in 0..n {
        if i > 0 && a[i - 1] > a[i] {
            println!("not sorted at {}", i);
            process::exit(1);
        }
        sum = sum.wrapping_mul(31).wrapping_add(a[i] as u64);
    }
    println!("{} {} {} {}", a[0], a[n / 2], a[n - 1], sum);
}
