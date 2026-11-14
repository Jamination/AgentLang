// panic in instances of a generic function: the frame names the instance
struct Box[T] { items: []T }

fn pick[T](b: Box[T], i: i64) -> T {
    if i >= len(b.items) {
        panic(fmt("no item ", i))
    }
    return b.items[i]
}

fn first_word(words: Box[str]) -> str {
    return pick(words, 3)
}

fn main() {
    nums := Box[i64]{[]i64{1, 2}}
    print(pick(nums, 1))
    print(first_word(Box[str]{[]str{"a"}}))
}
