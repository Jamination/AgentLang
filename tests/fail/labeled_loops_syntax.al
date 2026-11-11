// a label must be followed by a loop; `break` takes a label, not an expression
main :: () {
    x := 0
    lbl: if x == 0 {
        x = 1
    }
    blk: {
        x = 2
    }
    loop {
        break 1
    }
}
