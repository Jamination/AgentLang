// nested and anonymous functions are plain functions: they can be C callbacks
use std.libc
main :: () {
    a: [6]i32
    for i in 0..6 { a[i] = i32((i * 7 + 3) % 6) }
    qsort(cast[*u8](ptr(a)), 6, 4, (x: *u8, y: *u8) -> i32 {
        p := cast[*i32](x)[0]
        q := cast[*i32](y)[0]
        if p > q { return -1 }
        if p < q { return 1 }
        return 0
    })
    print(a)
    ascending :: (x: *u8, y: *u8) -> i32 { cast[*i32](x)[0] - cast[*i32](y)[0] }
    qsort(cast[*u8](ptr(a)), 6, 4, ascending)
    print(a)
}
