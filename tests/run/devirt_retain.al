// retain with function values whose target is known (the optimiser makes the calls direct and
// inlines them): named, nested and anonymous functions, with and without a context value
fn is_even(x: i64) -> bool {
    return x % 2 == 0
}

fn below(lim: i64, x: i64) -> bool {
    return x < lim
}

struct Item {
    id: i64
    hp: i64
}

fn alive(it: Item) -> bool {
    return it.hp > 0
}

// a keep function with side effects: called once per element, first to last
calls: Vec[i64]

fn logged(x: i64) -> bool {
    calls.push(x)
    return x != 3
}

fn nums(n: i64) -> Vec[i64] {
    v := vec[i64]()
    for i in 0..n {
        v.push((i * 7 + 3) % 11)
    }
    return v
}

fn main() {
    v := nums(20)
    v.retain(is_even)
    print(v.items())
    v = nums(20)
    v.retain(fn(x: i64) -> bool { x > 4 })
    print(v.items())
    v = nums(20)
    v.retain(6, below)
    print(v.items())
    v = nums(20)
    v.retain(3, fn(m: i64, x: i64) -> bool { x % m == 1 })
    print(v.items())
    fn odd(x: i64) -> bool {
        return x % 2 != 0
    }
    v = nums(20)
    v.retain(odd)
    print(v.items())
    items := vec[Item]()
    for i in 0..8 {
        items.push(Item{id: i, hp: (i * 5) % 4 - 1})
    }
    items.retain(alive)
    for it in items {
        put(it.id, ":", it.hp, " ")
    }
    put("\n")
    // empty, and everything removed
    e := vec[i64]()
    e.retain(is_even)
    print(e.len)
    v = nums(5)
    v.retain(fn(x: i64) -> bool { false })
    print(v.len)
    v = vec_of([]i64{1, 2, 3, 4, 3})
    v.retain(logged)
    print(v.items(), calls.items())
    // a large one, checked against a loop
    big := vec[i64]()
    for i in 0..100000 {
        big.push((i * 7919) % 1000)
    }
    want := 0
    for x in big {
        if x % 3 == 0 {
            want += x
        }
    }
    big.retain(fn(x: i64) -> bool { x % 3 == 0 })
    got := 0
    for x in big {
        got += x
    }
    print(big.len, got == want)
}
