handlers := [3]fn(i64) -> i64{dbl, neg, dbl}

fn dbl(x: i64) -> i64 { x * 2 }
fn neg(x: i64) -> i64 { -x }

fn main() {
    print(pad_left("42", 6, ' '), "|", pad_right("ab", 5, '.'), "|", pad_left("toolong", 3, '0'))
    print(hex(255), hex(0), hex(0xDEADBEEF), to_upper("Mixed Case 1"), to_lower("Mixed Case 1"))
    print(join(split("a-b-c", '-'), ", "), "|", join([]str{"solo"}, "+"), "|", len(join([]str{}, "+")))
    t := fmt(pad_left(fmt(7), 3, '0'), ":", pad_left(fmt(5), 2, '0'))
    print(t, len(t))
    total := 0
    for i, h in handlers {
        total += h(i + 1)
    }
    print(total, handlers[1](5))
    row := vec[str]()
    for i in 0..3 {
        row.push(fmt(i * i))
    }
    print(join(row.items(), " "))
}
