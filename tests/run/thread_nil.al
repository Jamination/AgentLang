use std.os

struct Node { v: i64, next: *Node }

fn walk(n: *Node) -> i64 {
    return n.next.v
}

fn main() {
    t, _ := thread_spawn(fn(n: *Node) { print(walk(n)) }, &Node{v: 1})
    thread_join(&t)
}
