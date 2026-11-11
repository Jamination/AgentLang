// the examples of docs/LANGUAGE.md that use nested functions
struct Point { x f64, y f64 }
enum Shape { Circle(Point, f64), Rect(Point, Point), Empty }
struct Item { name str, hp i64 }

fn area(s Shape) f64 {
    match s {
        Circle(c, r) => 3.141592653589793 * r * r
        Rect(a, b) => (b.x - a.x) * (b.y - a.y)
        Empty => 0.0
    }
}

fn largest[T](items []T, less fn(T, T) bool) T {
    best := items[0]
    for x in items {
        if less(best, x) {
            best = x
        }
    }
    best
}

fn tour() {
    shapes := []Shape{Circle(Point{0.0, 0.0}, 1.0), Rect(Point{0.0, 0.0}, Point{2.0, 3.0}), Empty}
    fn smaller(a Shape, b Shape) bool { area(a) < area(b) }    // a nested function
    print("largest:", largest(shapes, smaller))
    // largest: Rect(Point{x: 0.0, y: 0.0}, Point{x: 2.0, y: 3.0})
    counts := map[str, i64]()
    words := vec[str]()
    for w in split("a b a c a", ' ') {
        counts.set(w, counts.get_or(w, 0) + 1)
        words.push(w)
    }
    often := 0
    fn tally(w str) {                      // sees and changes the variables of main
        if counts.get_or(w, 0) > 1 { often += 1 }
    }
    for w in words { tally(w) }
    print(counts.get_or("a", 0), counts.len, words[1], often)   // 3 3 b 3
}

// --- Nested functions
fn rank(items []Item, floor i64) i64 {
    n := 0
    fn keep(it Item) bool {                // sees `floor` and `n` of rank
        if it.hp < floor { return false }  // returns from keep
        n += 1                             // assigns the variable of rank
        true
    }
    fn by_hp(a Item, b Item) bool { a.hp > b.hp }   // uses no variable of rank: a function value
    for it in items { it.keep() }          // called as keep(it) or it.keep()
    sort_by(items, by_hp)
    n
}

fn depth(n i64) i64 {
    deepest := 0
    fn visit(level i64) {                  // may call itself
        if level > deepest { deepest = level }
        if level < n { visit(level + 1) }
    }
    visit(0)
    deepest
}

// --- Standard library: sort_by with a context
fn by_score(scores []i64, a i64, b i64) bool { scores[a] > scores[b] }

fn main() {
    tour()
    items := []Item{Item{"imp", 3}, Item{"orc", 9}, Item{"elf", 5}}
    print(rank(items, 4), items[0].name, depth(3))   // 2 orc 3

    scores := []i64{70, 95, 80}
    order := []i64{0, 1, 2}
    sort_by(order, scores, by_score)       // the comparison gets `scores` as its first argument
    print(order)                           // [1, 2, 0]
}
