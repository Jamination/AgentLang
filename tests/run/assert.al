main :: () {
    assert 1 + 1 == 2
    print("ok")
    assert 1 + 1 == 3, "math is broken"
    print("unreachable")
}
