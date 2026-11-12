fn main() {
    a := vec_fill(5, 1)
    s := 0
    for i in 0..10 {
        if i == 3 {
            print(s)
            exit(0)
        }
        s += a[i]
    }
    print(s)
}
