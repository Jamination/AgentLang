// std.mem: sizes, byte views, frame scopes, Arena
struct Particle { pos vec3, vel vec3, life f32 }
struct Header { magic u32, count u16, flags u16 }

var static_buf [1000]u8

fn main() {
    print(kb(4), mb(2), kb(0))

    // byte views
    xs := []u32{1, 0x01020304, 0xFFFFFFFF}
    b := as_bytes(xs)
    print(len(b), b[0], b[4], b[7], b[11])
    b[0] = 9
    back := from_bytes[u32](b)
    print(xs[0], len(back), back[1] == xs[1], ptr(back) == ptr(xs))
    print(len(from_bytes[u64](b)), len(from_bytes[Header](b)), len(as_bytes(alloc[Particle](3))))
    h := Header{0xCAFE, 3, 1}
    zero(&h)
    zero(xs[1..])
    print(h, xs)

    // frame scopes nest and give memory back
    keep := alloc[i64](4)
    base := mem_used()
    frame_begin()
    tmp := alloc[u8](5000)
    tmp[0] = 1
    frame_begin()
    alloc[u8](3000)
    print(mem_used() - base)
    frame_end()
    print(mem_used() - base)
    frame_end()
    print(mem_used() - base)
    for frame in 0..1000 {
        frame_begin()
        scratch := alloc[f32](10000)
        scratch[frame] = 1.0
        text := fmt("frame ", frame)
        keep[0] += len(text)
        frame_end()
    }
    print(mem_used() - base, keep[0])
    // memory handed out again is zeroed
    frame_begin()
    again := alloc[f32](10000)
    clean := true
    for v in again {
        clean = clean && v == 0.0
    }
    frame_end()
    print(clean)

    // Arena: a block with its own cursor
    a := arena_new(kb(1))
    print(a.used(), a.remaining())
    ps := alloc[Particle](&a, 8)
    ids := a.alloc[u8](3)
    one := new[Particle](&a)
    one.life = 2.5
    print(len(ps), len(ids), a.used(), a.remaining(), cast[i64](ptr(ids)) % 16, one.life)
    outside := mem_used()
    m := a.mark()
    big := a.alloc[u64](50)
    for i in 0..50 {
        big[i] = 0xFFFFFFFFFFFFFFFF
    }
    print(a.used(), mem_used() == outside)
    a.release(m)
    print(a.used())
    reused := a.alloc[u64](60)
    sum := u64(0)
    for v in reused {
        sum += v
    }
    print(len(reused), sum, one.life)
    a.reset()
    print(a.used(), a.remaining())
    // survives a release of the main arena taken after its creation
    lvl := mark()
    alloc[u8](100000)
    release(lvl)
    print(len(a.alloc[i32](256)), a.remaining())

    // arena over static storage: contents are zeroed on allocation
    for i in 0..1000 {
        static_buf[i] = 0xAA
    }
    s := arena_of(static_buf[..])
    v := s.alloc[u32](10)
    print(v[0], v[9], s.used(), s.remaining() >= 1000 - 16 - 48, s.base % 16)
    empty := arena_of(static_buf[..0])
    print(empty.remaining())
}
