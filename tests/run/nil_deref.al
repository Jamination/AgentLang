struct N { v i64, next *N }
fn last(n *N) i64 {
    while n.next != nil {
        n = n.next
    }
    n.v
}
fn main() {
    a := &N{1, &N{2, nil}}
    print(last(a))
    var p *N = nil
    print(last(p))
}
