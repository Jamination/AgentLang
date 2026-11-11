// `test` blocks see the private declarations of their file.
priv struct Acc { total i64 }
priv const STEP = 3
priv var runs i64
priv fn add(a *Acc, x i64) {
    a.total += x
    runs += 1
}
priv fn twice[T](x T) T { x + x }

test "private function and struct" {
    var a Acc
    a.add(STEP)
    add(&a, STEP)
    assert a.total == 6, "total"
    assert runs == 2
}

test "private generic" {
    assert twice(STEP) == 6
    assert twice(1.5) == 3.0
}

test "private name as local" {
    STEP := 10
    assert STEP == 10
    assert twice(STEP) == 20
}

test "failing with a private call" {
    var a Acc
    a.add(1)
    assert a.total == STEP, fmt("got ", a)
}

fn main() {}

// a private function named like a builtin: the builtin still takes what it does not accept
struct Wrapped { n i64 }
priv fn len(w Wrapped) i64 { w.n }
test "priv builtin name" {
    assert len(Wrapped{n: 7}) == 7
    assert len("abc") == 3
    assert "abcd".len() == 4
}
