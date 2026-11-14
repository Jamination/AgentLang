// a nil dereference arrives as a signal (Windows: an exception): the trace starts at the
// faulting line, in -O0, default and --unchecked builds alike
struct Node { value: i64, next: *Node }

fn second(n: *Node) -> i64 {
    return n.next.value
}

fn walk(n: *Node, depth: i64) -> i64 {
    if depth == 0 {
        return second(n)
    }
    return walk(n, depth - 1) + 1
}

fn main() {
    a := Node{value: 1, next: nil}
    print("start")
    print(walk(&a, 2))
}
