// `in`, `by` and `test` are keywords only in their place (`for x in`, `.. by step`,
// `test "name" { }` where a declaration starts); everywhere else they are ordinary names:
// variables, parameters, fields, functions, globals, loop variables and labels
struct Block { bx: i64, by: i64, in: bool }

struct Case { test: str, want: i64 }

test := 3

fn test_of(test: i64) -> i64 {
    test * 2
}

fn by(n: i64) -> i64 {
    n + 1
}

fn sum_every(in: []i64, by: i64) -> i64 {
    s := 0
    for i in 0..len(in) by by {
        s += in[i]
    }
    s
}

test "the test block is still a test" {
    assert test_of(test) == 6
}

fn main() {
    b := Block{bx: 1, by: 2, in: true}
    print(b.bx, b.by, b.in)
    b.by = 5
    print(b.by)
    c := Case{test: "t", want: 1}
    print(c.test, c.want)
    print(test, test_of(test), by(test))
    test = 4
    print(test)
    print(sum_every([]i64{1, 2, 3, 4, 5}, 2))
    by := 3
    for i in 0..10 by by {
        print(i)
    }
    for i in 9..=0 by -3 {
        print(i)
    }
    // a step that continues on the next line, as with the keyword
    for i in 0..4 by
        2 {
        print(i)
    }
    in := []i64{7, 8}
    for in in in {
        print(in)
    }
    for i, by in "ab" {
        print(i, by)
    }
    in: for x in 0..3 {
        for y in 0..3 {
            if y == 1 {
                continue in
            }
            if x == 2 {
                break in
            }
            print(x, y)
        }
    }
}
