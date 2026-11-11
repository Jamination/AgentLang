// labelled loop errors: unknown label, duplicate label in nested loops
fn f(n i64) {
    for i in 0..n {
        break nowhere
    }
    outer: for i in 0..n {
        inner: while true {
            continue outr
        }
    }
    again: for i in 0..n {
        again: for j in 0..n {
            break again
        }
    }
    done: loop {
        break done
    }
    // the label of a loop that has ended is not in scope
    for i in 0..n {
        continue done
    }
    break done
}

fn main() {
    f(3)
}
