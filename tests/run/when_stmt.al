// `when` in function bodies: it opens no scope (the taken branch's statements belong to the
// enclosing block), chains, blocks of loops, anonymous functions and match arms, values
const FAST = true
const SIZE = 3

fn sep() -> str {
    when TARGET_OS == Windows { "\\" } else { "/" }
}

fn pick(x: i64) -> i64 {
    when SIZE == 3 {
        y := x * 2
    } else {
        y := undefined_name
    }
    when !FAST { return 0 }
    y + 1
}

fn main() {
    when FAST {
        msg := "fast"
    } else when SIZE == 3 {
        msg := "three"
    } else {
        msg := 42
    }
    print(msg, pick(5))
    for i in 0..2 {
        when FAST { put(i, " ") }
    }
    print()
    f := fn(a: i64) -> i64 {
        when SIZE == 3 { a * 3 } else { a }
    }
    r := match f(2) {
        6 => {
            when FAST { "six" } else { "slow six" }
        }
        _ => "other"
    }
    print(f(2), r, sep() == (if TARGET_OS == Windows { "\\" } else { "/" }))
    when false {
        print("never")
    }
    {
        when FAST {
            defer { print("deferred") }
        }
        print("block")
    }
}
