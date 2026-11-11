// leave() needs a matching enter()
main :: () {
    a := region()
    enter(&a)
    leave()
    print("balanced")
    leave()
    print("not reached")
}
