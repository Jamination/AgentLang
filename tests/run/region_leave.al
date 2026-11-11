// leave() needs a matching enter()
fn main() {
    a := region()
    enter(&a)
    leave()
    print("balanced")
    leave()
    print("not reached")
}
