// check_released_memory (ALC_CHECK_MEMORY=1): data allocated inside a frame scope and kept past
// frame_end() faults at its next use, and the report names frame_end
struct Chunk {
    data: []i64
}

fn load(n: i64) -> *Chunk {
    c := new[Chunk]()
    c.data = alloc[i64](n)
    for i in 0..n {
        c.data[i] = i
    }
    c
}

fn main() {
    check_released_memory()
    level := mark()
    kept := load(10)                        // outside any frame: lives until release(level)
    stale: *Chunk = nil
    for frame in 0..3 {
        frame_begin()
        c := load(20000)
        if stale == nil {
            stale = c                       // kept past frame_end: the bug
        }
        print("frame", frame, c.data[19999], kept.data[9])
        frame_end()
    }
    print("kept", kept.data[9])
    print(stale.data[5])
}
