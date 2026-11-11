// labelled loops: `name: for/while/loop`, `break name`, `continue name`
find :: (grid: [][]i64, want: i64) -> (i64, i64) {
    r := -1
    c := -1
    rows: for i, row in grid {
        for j, x in row {
            if x == want {
                r = i
                c = j
                break rows
            }
        }
    }
    return (r, c)
}

primes :: (n: i64) -> []i64 {
    out := vec[i64]()
    next: for i in 2..n {
        for d in 2..i {
            if d * d > i {
                break
            }
            if i % d == 0 {
                continue next
            }
        }
        out.push(i)
    }
    return out.items()
}

defers :: () {
    outer: for i in 0..3 {
        defer { print("  leave outer body", i) }
        j := 0
        inner: while true {
            defer { print("  leave inner body", i, j) }
            j += 1
            if j == 2 && i == 0 {
                continue outer
            }
            if i == 1 {
                {
                    defer { print("  leave block") }
                    break outer
                }
            }
            if j > 2 {
                break inner
            }
        }
        print("  after inner", i)
    }
    print("  done")
}

three :: () -> i64 {
    n := 0
    a: loop {
        b: loop {
            c: for k in 0..10 by 3 {
                n += 1
                if k == 6 {
                    continue b
                }
                if n > 20 {
                    break a
                }
            }
        }
    }
    return n
}

Step :: enum { Go, Skip, Stop }

steps :: (s: []Step) -> i64 {
    n := 0
    all: for round in 0..3 {
        for x in s {
            match x {
                Go => n += 1
                Skip => continue all
                Stop => break all
            }
        }
        n += 100
    }
    return n
}

generic[T] :: (rows: [][]T, stop: T) -> i64 {
    n := 0
    rows: for row in rows {
        for x in row {
            if x == stop {
                break rows
            }
            n += 1
        }
    }
    return n
}

// a label is only a label directly before a loop; names stay usable as variables
names :: () -> i64 {
    outer := 5
    outer: for i in 0..3 {
        outer += i
        if i == 1 {
            break outer
        }
    }
    // `break` at the end of a line is a plain break: the next line is a new statement
    x := 0
    loop {
        if x > 2 {
            break
        }
        x += 1
    }
    lbl: while x < 10 {
        x += 1
        if x == 7 {
            break
            lbl2 := 1
            x += lbl2
        }
    }
    // the same label may be used again once its loop has ended
    lbl: for i in 0..5 {
        for j in 0..5 {
            if j == 2 { continue lbl }
            if i == 3 { break lbl }
            x += 1
        }
    }
    return outer * 100 + x
}

main :: () {
    g := [][]i64{[]i64{1, 2, 3}, []i64{4, 5, 6}, []i64{7, 8, 9}}
    print(find(g, 6), find(g, 10))
    print(primes(40))
    defers()
    print(three())
    print(steps([]Step{Go, Go, Skip, Go}), steps([]Step{Go, Stop}), steps([]Step{Go}))
    print(generic([][]str{[]str{"a", "b"}, []str{"c", "stop", "d"}, []str{"e"}}, "stop"), generic(g, 8))
    print(names())
    // label and loop on separate lines, range loops with a step, labelled `loop`
    total := 0
    down:
    for i in 9..=0 by -1 {
        k := 0
        loop {
            k += 1
            if k > i { continue down }
            if i < 5 { break down }
            total += 1
        }
    }
    print(total)
}
