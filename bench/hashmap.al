struct Entry { key u64, val u64 }
struct Map { e []Entry, cap u64, len u64 }

fn hash(k u64) u64 {
    (k * 0x9E3779B97F4A7C15) >> 32
}

fn map_init(m *Map, cap u64) {
    m.e = alloc[Entry](i64(cap))
    m.cap = cap
    m.len = 0
}

fn map_grow(m *Map) {
    old := m.e
    map_init(m, m.cap * 2)
    for en in old {
        if en.key != 0 {
            *map_slot(m, en.key) = en.val
        }
    }
}

// find the value slot of key, inserting it if missing
fn map_slot(m *Map, key u64) *u64 {
    if (m.len + 1) * 4 > m.cap * 3 {
        map_grow(m)
    }
    mask := m.cap - 1
    i := hash(key) & mask
    loop {
        e := &m.e[i]
        if e.key == key {
            return &e.val
        }
        if e.key == 0 {
            e.key = key
            m.len += 1
            return &e.val
        }
        i = (i + 1) & mask
    }
}

fn map_get(m *Map, key u64) (u64, bool) {
    mask := m.cap - 1
    i := hash(key) & mask
    loop {
        e := &m.e[i]
        if e.key == key {
            return (e.val, true)
        }
        if e.key == 0 {
            return (0, false)
        }
        i = (i + 1) & mask
    }
}

fn main() {
    var m Map
    map_init(&m, 16)
    var seed u64 = 42
    for i in 0..u64(5000000) {
        seed = seed * 6364136223846793005 + 1442695040888963407
        key := (seed >> 33) % 3000000 + 1
        *map_slot(&m, key) += i
    }
    var hits u64 = 0
    var sum u64 = 0
    for i in 0..10000000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        key := (seed >> 33) % 6000000 + 1
        v, ok := map_get(&m, key)
        if ok {
            hits += 1
            sum += v
        }
    }
    put(m.len, " ", hits, " ", sum, "\n")
}
