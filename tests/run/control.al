fn classify(n: i64) -> str {
    if n < 0 {
        return "neg"
    } else if n == 0 {
        return "zero"
    } else if n < 10 {
        return "small"
    }
    "big"
}

fn collatz(n: i64) -> i64 {
    steps := 0
    while n != 1 {
        if n % 2 == 0 {
            n = n / 2
        } else {
            n = 3 * n + 1
        }
        steps += 1
    }
    steps
}

fn main() {
    print(classify(-5), classify(0), classify(7), classify(70))
    print(collatz(27))
    s := 0
    for i in 0..10 {
        if i == 3 {
            continue
        }
        if i == 8 {
            break
        }
        s += i
    }
    print(s)
    for i in 5..=7 {
        put(i, " ")
    }
    for i in 10..0 by -3 {
        put(i, " ")
    }
    for i in 0..10 by 4 {
        put(i, " ")
    }
    print()
    n := 0
    loop {
        n += 1
        if n > 4 {
            break
        }
    }
    print(n)
    x := if n > 3 { 100 } else { 200 }
    print(x)
    total := 0
    for i in 0..4 {
        for j in 0..4 {
            if j > i {
                break
            }
            total += i * j
        }
    }
    print(total)
    u: u8 = 0
    cnt := 0
    for k in u8(250)..u8(255) {
        cnt += 1
        u = k
    }
    print(cnt, u)
    for i in 3..3 {
        print("never")
    }
    k := 10
    while k > 0 && k % 7 != 0 {
        k -= 1
    }
    print(k)
}
