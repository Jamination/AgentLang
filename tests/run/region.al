// Regions: independent arenas for temporary work; results are copied out with clone.
struct Item { name str, tags []str, n i64 }
struct Report { title str, items Vec[Item], by_name Map[str, i64] }

var tmp Region
var inner Region

fn build(n i64) Vec[Item] {
    v := vec[Item]()
    for i in 0..n {
        v.push(Item{fmt("item", i), []str{fmt("t", i), "x"}, i})
    }
    v
}

// temporary work in `tmp`, scratch tables in `inner` (nested); the result is copied to the
// arena of the caller
fn work(n i64) Report {
    enter(&tmp)
    r := Report{fmt("report of ", n), build(n), map[str, i64]()}
    enter(&inner)
    scratch := alloc[i64](1000)
    for i in 0..1000 {
        scratch[i] = i
    }
    total := 0
    for x in scratch {
        total += x
    }
    leave()
    reset(&inner)
    for i, it in r.items {
        r.by_name.set(it.name, i)
    }
    r.items.push(Item{fmt("total", total), nil, total})
    leave()
    out := clone(r)
    reset(&tmp)
    out
}

// fills memory with a pattern
fn dirty(n i64) i64 {
    a := alloc[u64](n)
    for i in 0..n {
        a[i] = 0xFFFFFFFFFFFFFFFF
    }
    return cast[i64](ptr(a))
}

fn all_zero(a []u64) bool {
    for x in a {
        if x != 0 {
            return false
        }
    }
    true
}

fn main() {
    r := region()
    var z Region
    print(used(&r), used(&z), used(&tmp), mem_used())

    // nested regions, data copied out by clone
    main_before := mem_used()
    rep := work(3)
    print(rep.title, rep.items.len, rep.items[0].name, rep.items[1].tags, rep.items[3].name, rep.by_name.get_or("item2", -1))
    print(used(&tmp), used(&inner), mem_used() > main_before)
    // the copy does not live in the regions: overwrite their memory and look again
    enter(&tmp)
    dirty(4096)
    leave()
    enter(&inner)
    dirty(4096)
    leave()
    reset(&tmp)
    reset(&inner)
    print(rep.title, rep.items[2].name, rep.items[2].tags, rep.by_name.get_or("item1", -1))

    // reset: the same addresses are handed out again, zeroed
    enter(&r)
    a1 := dirty(100)
    u1 := used(&r)
    reset(&r)                        // r is the region in use
    u2 := used(&r)
    b := alloc[u64](50)
    print(cast[i64](ptr(b)) == a1, all_zero(b), u1, u2, used(&r))
    c := alloc[u64](100)             // partly memory that was used before the reset
    print(all_zero(c), used(&r))
    leave()
    reset(&r)                        // r is not in use
    print(used(&r))
    enter(&r)
    d := new[[64]u64]()
    print(cast[i64](d) == a1, all_zero(d[..]))

    // mark / release act on the arena in use
    m := mark()
    dirty(512)
    print(used(&r))
    release(m)
    print(used(&r), all_zero(alloc[u64](512)))
    leave()

    // a loop doing temporary work: the region does not grow
    reset(&r)
    peak := 0
    last := ""
    main_before = mem_used()
    for round in 0..3000 {
        enter(&r)
        v := build(20)
        s := fmt(v.len, ":", v[19].name, ":", round)
        if used(&r) > peak {
            peak = used(&r)
        }
        leave()
        if round == 2999 {
            last = clone(s)
        }
        reset(&r)
    }
    print(last, peak > 0, peak < 100000, used(&r), mem_used() - main_before)

    // everything that allocates follows the arena in use
    enter(&r)
    u0 := used(&r)
    lit := []i64{1, 2, 3}
    u1 = used(&r)
    txt := fmt("x", 1)
    u2 = used(&r)
    mp := map[i64, i64]()
    mp.set(1, 2)
    u3 := used(&r)
    nd := &Item{"p", nil, 1}
    u4 := used(&r)
    cp := clone(lit)
    u5 := used(&r)
    leave()
    print(u1 > u0, u2 > u1, u3 > u2, u4 > u3, u5 > u4, lit, txt, mp.get_or(1, 0), nd.name, cp)

    // defer leaves the region on every path
    {
        enter(&r)
        defer { leave() }
        alloc[u8](10)
    }
    un := used(&r)
    alloc[u8](1000)                  // main arena again
    print(used(&r) == un)

    // 64 regions can be entered at once
    many := alloc[Region](63)
    for i in 0..63 {
        enter(&many[i])
        alloc[i64](i + 1)
    }
    enter(&r)
    leave()
    for i in 0..63 {
        leave()
    }
    sum := 0
    for i in 0..63 {
        sum += used(&many[i])
        region_free(&many[i])
    }
    print(sum, used(&many[5]))

    // region_free: the memory goes back to the system, the region can be used again
    region_free(&r)
    print(used(&r), r.base)
    enter(&r)
    e := []i64{4, 5, 6}
    leave()
    print(e, used(&r))
    region_free(&r)
    region_free(&tmp)
    region_free(&inner)
    region_free(&z)
}
