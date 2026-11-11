// std.mem: Pool with generational handles, Ring, SparseSet
Mob :: struct { name: str, hp: i64 }

main :: () {
    // fixed-capacity pool
    p := pool_new[Mob](3)
    a := p.insert(Mob{"orc", 10})
    b := p.insert(Mob{"elf", 20})
    c := p.insert(Mob{"imp", 30})
    full := p.insert(Mob{"none", 0})
    print(a, b, c, full, p.len, p.used)
    print(p.is_valid(a), p.is_valid(full), p.is_valid(Handle{}), p.is_valid(Handle{7, 1}), p.is_valid(Handle{0, 2}))
    p.get(b).hp -= 5
    print(*p.get(b), p.get(full) == nil)
    // removal makes the handle stale; the slot is reused with a new generation
    print(p.remove(b), p.remove(b), p.get(b) == nil, p.len)
    d := p.insert(Mob{"bat", 40})
    print(d, d.idx == b.idx, p.get(b) == nil, p.get(d).name, p.len)
    // iterate live slots
    p.remove(a)
    for i in 0..p.used {
        if p.is_live(i) {
            print(i, p.handle_at(i), p.items[i].name, p.handle_at(i) == d || p.handle_at(i) == c)
        }
    }
    p.clear()
    print(p.len, p.used, p.is_valid(c), p.is_valid(d), p.insert(Mob{"new", 1}), p.get(a) == nil)

    // growable pool: handles stay valid across growth
    g := pool_growable[i64](2)
    hs := alloc[Handle](1000)
    for i in 0..1000 {
        hs[i] = g.insert(i * 3)
    }
    ok := true
    for i in 0..1000 {
        ok = ok && *g.get(hs[i]) == i * 3
    }
    print(g.len, len(g.items) >= 1000, ok)
    // churn: remove every other object, insert again, the old handles stay dead
    for i in 0..1000 by 2 {
        g.remove(hs[i])
    }
    cap := len(g.items)
    for i in 0..500 {
        g.insert(-1)
    }
    stale := 0
    for i in 0..1000 {
        if g.get(hs[i]) == nil {
            stale += 1
        }
    }
    print(g.len, g.used, len(g.items) == cap, stale)

    // ring buffer as a queue
    r := ring_new[i64](4)
    print(r.push(1), r.push(2), r.push(3), r.push(4), r.push(5), r.len, r.is_full())
    print(r.pop(), r.pop(), r.len, r.is_full())
    print(r.push(6), r.push(7), r.at(0), r.at(1), r.at(2), r.at(3))
    // keep the last N
    for i in 10..20 {
        r.push_overwrite(i)
    }
    print(r.at(0), r.at(3), r.len)
    while r.len > 0 {
        x, _ := r.pop()
        put(x, " ")
    }
    print(r.pop())
    r.push(8)
    r.clear()
    print(r.len, r.pop())
    names := ring_new[str](2)
    names.push_overwrite("a")
    names.push_overwrite("b")
    names.push_overwrite("c")
    print(names.at(0), names.at(1))

    // sparse set with a parallel data array
    s := sparse_set(8)
    data := alloc[f64](64)
    ids := []u32{5, 2, 7, 40, 2}
    for id in ids {
        data[s.insert(id)] = f64(id) * 1.5
    }
    print(s.items(), s.len, s.has(40), s.has(3), s.has(4000), s.index_of(7), s.index_of(6))
    i := s.remove(2)
    data[i] = data[s.len]
    print(i, s.remove(2), s.items(), data[s.index_of(40)], data[s.index_of(5)], data[s.index_of(7)])
    s.clear()
    print(s.len, s.has(5), s.insert(9), s.items())
}
