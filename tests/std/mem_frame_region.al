// a frame scope must be closed in the arena it was opened in
var r Region

fn main() {
    frame_begin()
    alloc[u8](100)
    enter(&r)
    print("in the region")
    frame_end()
    print("not reached")
}
