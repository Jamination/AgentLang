// literals in headers are found; what they mean is still checked
Point :: struct { x: i64, y: i64 }
main :: () {
    xs := []i64{1, 2}
    for x in Point{1, 2} {
        print(x)
    }
    if Point{1, 2} {
        print("p")
    }
    while []i64{1} {
        print("q")
    }
    for x in xs { print(x) } { print("no") }
}
