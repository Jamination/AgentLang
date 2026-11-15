// Allocation sizes that are negative or do not fit stop the program instead of handing out a
// slice that is longer than its memory (each case runs in a process of its own: this program,
// started again with the number of the case).
use std.os

fn cases() -> []fn() {
    []fn(){
        fn() {
            first := alloc[i64](1)
            xs := alloc[i64](0x2000_0000_0000_0000)
            xs[3] = 1
        },
        fn() { s := alloc[u8](0x7FFF_FFFF_FFFF_FFF8) },
        fn() { v := vec_fill(-100, 5) },
        fn() { v := vec_fill(0x2000_0000_0000_0000, 5) },
        fn() {
            v := vec[i64]()
            v.reserve(0x2000_0000_0000_0000)
            v.buf[3] = 55
        },
        fn() { s := repeat("abcd", 0x4000_0000_0000_0001) },
        fn() {
            v := vec_of([]i64{1, 2, 3})
            v.resize(-2, 0)
        },
        // sizes computed from (unsafe, made-up) huge strings: the sums and products are checked too
        fn() { s := replace("aaaa", "a", mkslice[u8](ptr("x"), 0x2000_0000_0000_0000)) },
        fn() {
            big := mkslice[u8](ptr("x"), 0x4000_0000_0000_0000)
            s := join([]str{big, big, big}, ",")
        },
        fn() { s := fmt("a", mkslice[u8](ptr("x"), 0x4000_0000_0000_0000)) },
    }
}

fn main() {
    a := args()
    if len(a) > 2 && a[1] == "case" {
        k, _ := parse_i64(a[2])
        cases()[k]()
        print("not stopped")
        return
    }
    keep := alloc[i64](8)
    keep[7] = 42
    for k in 0..len(cases()) {
        print("exit status", run([]str{a[0], "case", fmt(k)}))
    }
    // the empty string repeated any number of times is empty, at once
    print(len(repeat("", 0x4000_0000_0000_0000)), keep[7])
}
