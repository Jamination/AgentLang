Node :: struct { left: *Node, right: *Node }

item_check :: (t: *Node) -> i64 {
    if t.left == nil {
        return 1
    }
    1 + item_check(t.left) + item_check(t.right)
}

bottom_up :: (depth: i64) -> *Node {
    if depth > 0 {
        return &Node{bottom_up(depth - 1), bottom_up(depth - 1)}
    }
    &Node{nil, nil}
}

main :: () {
    n := 20
    min_depth := 4
    max_depth := if min_depth + 2 > n { min_depth + 2 } else { n }
    stretch_depth := max_depth + 1
    m := mark()
    stretch := bottom_up(stretch_depth)
    put("stretch tree of depth ", stretch_depth, "\t check: ", item_check(stretch), "\n")
    release(m)
    long_lived := bottom_up(max_depth)
    for depth in min_depth..=max_depth by 2 {
        iterations := 1 << (max_depth - depth + min_depth)
        check := 0
        for i in 0..iterations {
            tm := mark()
            temp := bottom_up(depth)
            check += item_check(temp)
            release(tm)
        }
        put(iterations, "\t trees of depth ", depth, "\t check: ", check, "\n")
    }
    put("long lived tree of depth ", max_depth, "\t check: ", item_check(long_lived), "\n")
}
