// Regression tests for P0 compiler and runtime soundness fixes:
// - `when` inside Assign and MultiAssign LHS expressions
// - `mem2reg` promotion of vector locals
// - `licm` not speculatively hoisting out-of-bounds Alloca loads
// - `from_bytes` on zero-sized structs

struct Empty {}

noinline fn guarded_oob(n: i64, take: bool) -> i64 {
    arr := [4]i64{1, 2, 3, 4}
    s := 0
    for i in 0..n {
        if take {
            p := cast[*i64](cast[i64](&arr[0]) + 1000000000)
            s += *p
        }
        s += arr[i & 3]
    }
    s
}

noinline fn vec_branch(n: i64) -> vec4 {
    v := vec4(1.0, 2.0, 3.0, 4.0)
    for i in 0..n {
        if i % 2 == 0 {
            v = v + vec4(1.0)
        } else {
            v = v + vec4(0.5)
        }
    }
    v
}

fn main() {
    a := [2]i64{10, 20}
    a[if true {
        idx := 0
        when TARGET_OS == Windows {
            idx = 1
        } else {
            idx = 1
        }
        idx
    } else {
        0
    }] = 99
    b := [2]i64{1, 2}
    b[if true {
        idx := 0
        when TARGET_OS == Windows {
            idx = 0
        } else {
            idx = 0
        }
        idx
    } else {
        1
    }], b[1] = (7, 8)
    print("when_lhs:", a[0], a[1], b[0], b[1])
    print("licm_oob:", guarded_oob(8, false))
    v := vec_branch(4)
    print("vec_m2r:", i64(v.x), i64(v.y), i64(v.z), i64(v.w))
    eb := from_bytes[Empty]([]u8{1, 2, 3})
    print("zst_from_bytes:", len(eb))
}
