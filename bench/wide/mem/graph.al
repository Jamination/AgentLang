// random weighted graph in CSR form: BFS, Dijkstra with a binary heap, union-find
struct Item { d: i64, v: i64 }
struct Pq { a: []Item, n: i64 }

fn pq_push(h: *Pq, it: Item) {
    i := h.n
    h.n += 1
    while i > 0 {
        p := (i - 1) / 2
        if h.a[p].d <= it.d {
            break
        }
        h.a[i] = h.a[p]
        i = p
    }
    h.a[i] = it
}

fn pq_pop(h: *Pq) -> Item {
    top := h.a[0]
    h.n -= 1
    x := h.a[h.n]
    n := h.n
    i := 0
    loop {
        c := 2 * i + 1
        if c >= n {
            break
        }
        if c + 1 < n && h.a[c + 1].d < h.a[c].d {
            c += 1
        }
        if x.d <= h.a[c].d {
            break
        }
        h.a[i] = h.a[c]
        i = c
    }
    h.a[i] = x
    top
}

fn bfs(off: []i64, adj: []i32, src: i64, dist: []i32, queue: []i32) -> i64 {
    fill(dist, -1)
    dist[src] = 0
    queue[0] = i32(src)
    head := 0
    tail := 1
    while head < tail {
        u := i64(queue[head])
        head += 1
        du := dist[u]
        for e in off[u]..off[u + 1] {
            v := i64(adj[e])
            if dist[v] < 0 {
                dist[v] = du + 1
                queue[tail] = i32(v)
                tail += 1
            }
        }
    }
    s := 0
    for x in dist {
        s += i64(x)
    }
    s
}

fn dijkstra(off: []i64, adj: []i32, w: []i32, src: i64, dist: []i64, h: *Pq) -> i64 {
    fill(dist, 0x7FFF_FFFF_FFFF_FFFF)
    dist[src] = 0
    h.n = 0
    pq_push(h, Item{0, src})
    while h.n > 0 {
        it := pq_pop(h)
        u := it.v
        if it.d > dist[u] {
            continue
        }
        for e in off[u]..off[u + 1] {
            v := i64(adj[e])
            nd := it.d + i64(w[e])
            if nd < dist[v] {
                dist[v] = nd
                pq_push(h, Item{nd, v})
            }
        }
    }
    s := 0
    for x in dist {
        if x != 0x7FFF_FFFF_FFFF_FFFF {
            s += x
        }
    }
    s
}

fn find(parent: []i32, x: i64) -> i64 {
    while i64(parent[x]) != x {
        parent[x] = parent[i64(parent[x])]
        x = i64(parent[x])
    }
    x
}

fn components(n: i64, eu: []i32, ev: []i32, parent: []i32, size: []i32) -> i64 {
    for i in 0..n {
        parent[i] = i32(i)
        size[i] = 1
    }
    comps := n
    for k in 0..len(eu) {
        a := find(parent, i64(eu[k]))
        b := find(parent, i64(ev[k]))
        if a != b {
            if size[a] < size[b] {
                t := a
                a = b
                b = t
            }
            parent[b] = i32(a)
            size[a] += size[b]
            comps -= 1
        }
    }
    comps
}

fn main() {
    n := 300000
    m := 1500000
    seed: u64 = 2024
    eu := alloc[i32](m)
    ev := alloc[i32](m)
    deg := alloc[i64](n + 1)
    for k in 0..m {
        seed = seed * 6364136223846793005 + 1442695040888963407
        u := i64((seed >> 33) % u64(n))
        seed = seed * 6364136223846793005 + 1442695040888963407
        v := i64((seed >> 33) % u64(n))
        eu[k] = i32(u)
        ev[k] = i32(v)
        deg[u] += 1
        deg[v] += 1
    }
    // CSR of the undirected graph
    off := alloc[i64](n + 1)
    for i in 0..n {
        off[i + 1] = off[i] + deg[i]
    }
    pos := alloc[i64](n)
    for i in 0..n {
        pos[i] = off[i]
    }
    adj := alloc[i32](2 * m)
    wt := alloc[i32](2 * m)
    for k in 0..m {
        u := i64(eu[k])
        v := i64(ev[k])
        seed = seed * 6364136223846793005 + 1442695040888963407
        w := i32(1 + (seed >> 33) % 100)
        adj[pos[u]] = i32(v)
        wt[pos[u]] = w
        pos[u] += 1
        adj[pos[v]] = i32(u)
        wt[pos[v]] = w
        pos[v] += 1
    }
    total := 0
    dist32 := alloc[i32](n)
    queue := alloc[i32](n)
    for r in 0..6 {
        total += bfs(off, adj, r * 1000, dist32, queue)
    }
    dist := alloc[i64](n)
    h := Pq{a: alloc[Item](2 * m + 1), n: 0}
    for r in 0..2 {
        total += dijkstra(off, adj, wt, r * 7, dist, &h)
    }
    parent := alloc[i32](n)
    size := alloc[i32](n)
    for r in 0..4 {
        k := m / 4 * (r + 1) / 2
        total += components(n, eu[..k], ev[..k], parent, size)
    }
    put(total, "\n")
}
