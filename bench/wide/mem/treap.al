// ordered map as a treap (rotations, recursive insert), then lookups and an in-order walk
struct Node { key: i64, val: i64, prio: u64, left: *Node, right: *Node }

priv rng: u64 = 1

fn next_prio() -> u64 {
    rng ^= rng << 13
    rng ^= rng >> 7
    rng ^= rng << 17
    rng
}

fn insert(t: *Node, key: i64, val: i64) -> *Node {
    if t == nil {
        return &Node{key: key, val: val, prio: next_prio(), left: nil, right: nil}
    }
    if key == t.key {
        t.val += val
    } else if key < t.key {
        t.left = insert(t.left, key, val)
        if t.left.prio > t.prio {
            l := t.left
            t.left = l.right
            l.right = t
            return l
        }
    } else {
        t.right = insert(t.right, key, val)
        if t.right.prio > t.prio {
            r := t.right
            t.right = r.left
            r.left = t
            return r
        }
    }
    t
}

fn lookup(t: *Node, key: i64) -> i64 {
    p := t
    while p != nil {
        if key == p.key {
            return p.val
        }
        p = if key < p.key { p.left } else { p.right }
    }
    -1
}

fn walk(t: *Node, acc: u64) -> u64 {
    if t == nil {
        return acc
    }
    a := walk(t.left, acc)
    a = a * 31 + u64(t.key) + u64(t.val)
    walk(t.right, a)
}

fn main() {
    seed: u64 = 31337
    root: *Node = nil
    n := 300000
    for i in 0..n {
        seed = seed * 6364136223846793005 + 1442695040888963407
        root = insert(root, i64((seed >> 33) % 1000000), i)
    }
    found := 0
    sum := 0
    for i in 0..2000000 {
        seed = seed * 6364136223846793005 + 1442695040888963407
        v := lookup(root, i64((seed >> 33) % 1000000))
        if v >= 0 {
            found += 1
            sum += v
        }
    }
    put(found, " ", sum, " ", walk(root, 0), "\n")
}
