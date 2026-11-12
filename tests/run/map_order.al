// Map keeps the insertion order: keys(), values(), print; through updates, deletes,
// re-inserts, growth, compaction, clone and clear.
struct Enemy { hp: i64, loot: Vec[str] }
struct Box { m: Map[str, i64], n: i64 }

fn make() -> Map[i64, str] {
    m := map[i64, str]()
    m.set(3, "three")
    m.set(1, "one")
    m
}

// the reference: pairs in insertion order
struct Ref { ks: Vec[i64], vs: Vec[i64] }

fn ref_set(r: *Ref, k: i64, v: i64) {
    i := index_of(r.ks[..], k)
    if i >= 0 {
        r.vs[i] = v
    } else {
        r.ks.push(k)
        r.vs.push(v)
    }
}

fn ref_del(r: *Ref, k: i64) -> bool {
    i := index_of(r.ks[..], k)
    if i < 0 { return false }
    r.ks.remove(i)
    r.vs.remove(i)
    true
}

fn same(m: *Map[i64, i64], r: *Ref) -> bool {
    m.len == r.ks.len && len(m) == r.ks.len && m.keys() == r.ks[..] && m.values() == r.vs[..]
}

fn small() {
    m := map[str, i64]()
    print(m, m.len, m.keys(), m.values(), m.has("a"), m.del("a"), m.get("a"), m.ptr("a") == nil)
    for w in split("pear fig apple fig kiwi pear date", ' ') {
        m.set(w, m.get_or(w, 0) + 1)
    }
    print(m, m.len)                              // first insertion decides the place
    print(m.keys(), m.values())
    m.set("fig", 20)                             // an update keeps the place
    *m.ptr("apple") += 100
    print(m)
    print(m.del("fig"), m.del("fig"), m.del("nope"), m.len)
    print(m, m.keys(), m.values())
    m.set("fig", 3)                              // deleted and set again: at the end
    m.set("pear", 9)
    print(m, m.len, m.get("fig"), m.get("zzz"), m.get_or("kiwi", -1), m.has("date"))
    c := clone(m)
    c.set("extra", 1)
    c.del("pear")
    m.set("own", 7)
    print(c)
    print(m)
    m.clear()
    print(m, m.len, m.keys(), m.has("pear"))
    m.set("z", 1)
    m.set("a", 2)
    print(m, c.len, c.keys())
    // delete everything, insert again: the new order
    for k in c.keys() { c.del(k) }
    print(c, c.len, c.keys(), c.values())
    c.set("b", 1)
    c.set("a", 2)
    print(c)
    // the zero value, other key and value types, a Map inside values
    z: Map[(i64, bool), f64]
    print(z, len(z), z.keys(), z.values(), z.del((1, true)))
    z.set((2, true), 0.5)
    z.set((1, false), 1.5)
    z.set((2, true), 2.5)
    print(z, z.keys(), z.values())
    b := Box{n: 1}
    b.m.set("y", 1)
    b.m.set("x", 2)
    print(b, make(), fmt(make()), Some(make()))
    e := map[str, Enemy]()
    e.set("orc", Enemy{hp: 10})
    e.set("bat", Enemy{hp: 2})
    e.ptr("orc").loot.push("axe")
    d := clone(e)
    d.ptr("orc").loot.push("gold")
    d.ptr("bat").hp = 3
    put(e.get_or("orc", Enemy{}).loot[..], d.get_or("orc", Enemy{}).loot[..], e.keys(), d.keys(), "\n")
    print(e.get_or("bat", Enemy{}).hp, d.get_or("bat", Enemy{}).hp)
    // keys() and values() are copies: changing the map while visiting them is fine
    for k in e.keys() {
        e.del(k)
        e.set(fmt(k, "2"), Enemy{})
    }
    print(e.keys())
    ks := z.keys()
    ks[0] = (9, false)
    print(z.keys())
}

// 100,000 keys against the reference, with updates, deletes and re-inserts across growth
fn large() {
    m := map[i64, i64]()
    r: Ref
    x: u64 = 1
    bad := 0
    live := vec[i64]()                           // keys set at some time (may be deleted)
    for step in 0..100000 {
        x = x * 6364136223846793005 + 1442695040888963407
        k := i64(x >> 12)
        m.set(k, step)
        r.ks.push(k)                             // (the keys are distinct: checked below)
        r.vs.push(step)
        live.push(k)
    }
    if !same(&m, &r) { bad += 1 }
    print("inserted", m.len, m.keys()[..3], m.values()[99997..])
    // updates keep the place
    for i in 0..live.len by 7 {
        m.set(live[i], -i)
        r.vs[i] = -i
    }
    if !same(&m, &r) { bad += 1 }
    // delete every third key (the reference is rebuilt: Vec.remove would be quadratic)
    nk := vec[i64]()
    nv := vec[i64]()
    for i in 0..live.len {
        if i % 3 == 0 {
            if !m.del(live[i]) { bad += 1 }
        } else {
            nk.push(r.ks[i])
            nv.push(r.vs[i])
        }
    }
    r = Ref{nk, nv}
    if !same(&m, &r) { bad += 1 }
    print("deleted", m.len, m.keys()[..3])
    // re-insert half of the deleted ones (they go to the end), and new keys: growth with holes
    for i in 0..live.len by 6 {
        m.set(live[i], i)
        r.ks.push(live[i])
        r.vs.push(i)
    }
    for i in 0..150000 {
        m.set(-1 - i, i)
        r.ks.push(-1 - i)
        r.vs.push(i)
    }
    if !same(&m, &r) { bad += 1 }
    for i, k in r.ks {
        v, ok := m.get(k)
        if !ok || v != r.vs[i] || *m.ptr(k) != v { bad += 1 }
    }
    for i in 0..live.len by 3 {
        if i % 6 != 0 && (m.has(live[i]) || m.ptr(live[i]) != nil) { bad += 1 }
    }
    c := clone(m)
    if !same(&c, &r) { bad += 1 }
    c.del(-1)
    c.set(123456789012, 1)
    if !same(&m, &r) || c.len != m.len || c.keys()[c.len - 1] != 123456789012 { bad += 1 }
    print("grown", m.len, m.keys()[m.len - 2..], bad)
}

// a small map with endless churn stays small and ordered (compaction in place)
fn churn() {
    m := map[i64, i64]()
    r: Ref
    bad := 0
    for i in 0..200000 {
        m.set(i, i * 2)
        r.ref_set(i, i * 2)
        if i >= 5 {
            if !m.del(i - 5) || !r.ref_del(i - 5) { bad += 1 }
        }
        if i % 3 == 0 {
            m.set(i - 2, 7)
            r.ref_set(i - 2, 7)
        }
        if i % 1000 == 0 && !same(&m, &r) { bad += 1 }
    }
    print("churn", m, m.len, len(m.index) <= 64, bad)
    // random operations on a small key range
    m.clear()
    r = Ref{}
    x: u64 = 7
    for step in 0..300000 {
        x = x ^ (x << 13)
        x = x ^ (x >> 7)
        x = x ^ (x << 17)
        k := i64(x % 300)
        if (x >> 20) % 3 == 0 {
            if m.del(k) != r.ref_del(k) { bad += 1 }
        } else {
            m.set(k, step)
            r.ref_set(k, step)
        }
        if step % 5000 == 0 && !same(&m, &r) { bad += 1 }
    }
    print("random", m.len, same(&m, &r), bad)
}

fn main() {
    small()
    large()
    churn()
}
