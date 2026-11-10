fn main() {
    n := 60000000
    composite := alloc[u8](n + 1)
    i := 2
    while i * i <= n {
        if composite[i] == 0 {
            for j in i * i..=n by i {
                composite[j] = 1
            }
        }
        i += 1
    }
    count := 0
    last := 0
    for k in 2..=n {
        if composite[k] == 0 {
            count += 1
            last = k
        }
    }
    put(count, " ", last, "\n")
}
