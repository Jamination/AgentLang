// check_released_memory (ALC_CHECK_MEMORY=1): a Map that lives longer than the frame and grows
// inside it stops the program at the growth, before frame_end() releases its new storage
struct World {
    cells: Map[i64, i64]
}

fn main() {
    check_released_memory()
    w := new[World]()
    w.cells.set(0, 0)                       // grown before any frame: fine
    for frame in 1..4 {
        frame_begin()
        scratch := vec[i64]()               // lives in the frame: may grow
        for i in 0..100 {
            scratch.push(i)
        }
        print("frame", frame, len(scratch))
        w.cells.set(frame * 1000, frame)    // 16 entries fit: no growth yet
        if frame == 3 {
            for k in 0..20 {
                w.cells.set(k, k)           // grows inside the frame
            }
        }
        frame_end()
    }
    print("not reached")
}
