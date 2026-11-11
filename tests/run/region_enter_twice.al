// entering a region that is already entered is an error (also when it is not the innermost)
main :: () {
    a := region()
    b := region()
    enter(&a)
    enter(&b)
    print("entered")
    enter(&a)
    print("not reached")
}
