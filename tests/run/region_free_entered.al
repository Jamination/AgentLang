// a region cannot be freed while it is entered
fn main() {
    a := region()
    enter(&a)
    xs := alloc[i64](4)
    print(len(xs))
    region_free(&a)
    print("not reached")
}
