// the nested-function examples of docs/LANGUAGE.md
struct Item { name: str, hp: i64 }

fn rank(items: []Item, floor: i64) -> i64 {
    n := 0
    fn keep(it: Item, floor: i64, n: *i64) -> bool {   // state comes in as parameters
        if it.hp < floor { return false }          // returns from keep
        *n += 1
        true
    }
    for it in items { it.keep(floor, &n) }         // keep(it, floor, &n) or it.keep(floor, &n)
    sort_by(items, fn(a: Item, b: Item) -> bool { a.hp > b.hp })  // anonymous function
    n
}

fn main() {
    xs := []Item{Item{name: "a", hp: 3}, Item{name: "b", hp: 9}, Item{name: "c", hp: 5}}
    print(rank(xs, 4), xs[0].name, xs[1].name, xs[2].name)
    scores := []i64{70, 95, 80}
    order := []i64{0, 1, 2}
    // the comparison gets `scores` as its first argument
    sort_by(order, scores, fn(scores: []i64, a: i64, b: i64) -> bool { scores[a] > scores[b] })
    print(order)                           // [1, 2, 0]
}
