struct Node { val: i64, next: *Node }

fn build(n: i64, seed: *u64) -> *Node {
    // allocate n nodes, then link them in a random order (pointer chasing through memory)
    nodes := alloc[*Node](n)
    for i in 0..n {
        nodes[i] = &Node{val: i, next: nil}
    }
    for i in 1..n {
        *seed = *seed * 6364136223846793005 + 1442695040888963407
        j := i64((*seed >> 33) % u64(i + 1))
        t := nodes[i]
        nodes[i] = nodes[j]
        nodes[j] = t
    }
    for i in 0..n - 1 {
        nodes[i].next = nodes[i + 1]
    }
    nodes[0]
}

fn sum(l: *Node) -> i64 {
    s := 0
    p := l
    while p != nil {
        s = s * 31 + p.val
        p = p.next
    }
    s
}

fn reverse(l: *Node) -> *Node {
    prev: *Node = nil
    p := l
    while p != nil {
        nx := p.next
        p.next = prev
        prev = p
        p = nx
    }
    prev
}

// builds a list front to back, as a parser would (sequential allocation)
fn build_seq(n: i64) -> *Node {
    head: *Node = nil
    for i in 0..n {
        head = &Node{val: i ^ 5, next: head}
    }
    head
}

fn main() {
    seed: u64 = 7
    total := 0
    m := mark()
    l := build(1000000, &seed)
    for r in 0..6 {
        total += sum(l)
        l = reverse(l)
    }
    release(m)
    for r in 0..40 {
        m2 := mark()
        s := build_seq(1000000)
        for k in 0..3 {
            total += sum(s)
            s = reverse(s)
        }
        release(m2)
    }
    put(total, "\n")
}
