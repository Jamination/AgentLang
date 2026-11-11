// std.mem next to regions: frame scopes, Arena and mem_used follow the arena in use
r: Region

main :: () {
    keep := alloc[i64](4)
    main_used := mem_used()

    // mem_used reports the arena in use
    enter(&r)
    print(mem_used(), used(&r))
    alloc[u8](1000)
    print(mem_used(), used(&r), mem_used() == used(&r))

    // frame scopes inside a region release region memory
    frame_begin()
    alloc[u8](5000)
    frame_begin()
    text := fmt("frame ", 1)
    keep[0] = len(text)
    frame_end()
    print(used(&r))
    frame_end()
    print(used(&r), keep[0])

    // an Arena carved while the region is in use lives in the region
    a := arena_new(kb(1))
    xs := a.alloc[i64](8)
    xs[7] = 7
    print(used(&r), a.used(), xs[7])
    leave()
    print(mem_used() == main_used)

    // an Arena of the main arena is not affected by regions: its allocations are explicit
    b := arena_new(kb(1))
    main_used = mem_used()
    enter(&r)
    reset(&r)
    ys := b.alloc[i64](8)
    ys[0] = 42
    print(used(&r), b.used(), mem_used())
    leave()
    reset(&r)
    print(ys[0], b.used(), mem_used() == main_used, used(&r))

    // a frame scope around a balanced enter / leave
    frame_begin()
    alloc[u8](100)
    enter(&r)
    alloc[u8](100)
    leave()
    frame_end()
    print(mem_used() == main_used, used(&r))
    region_free(&r)
    print(used(&r))
}
