fn add(a: i64, b: i64) -> i64 { a + b }

fn clamp(x: i64, lo: i64, hi: i64) -> i64 {
    if x < lo { lo } else if x > hi { hi } else { x }
}

test "addition" {
    assert add(2, 3) == 5
    assert add(-2, 2) == 0, "negatives"
}

test "clamp fails on purpose" {
    assert clamp(5, 0, 10) == 5
    assert clamp(50, 0, 10) == 11, "upper bound"
}

test "out of bounds is caught" {
    a := alloc[i64](2)
    i := 2
    a[i] = 1
}

test "strings" {
    assert concat("a", "b") == "ab"
    assert find("hello", "ll") == 2
}

fn main() {
    print("main is not run by `alc test`")
}
