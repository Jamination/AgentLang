// the closure examples of docs/LANGUAGE.md
struct Button { label str, on_click |i64| }
struct Point { x i64, y i64 }

fn double(x i64) i64 { x * 2 }
fn apply[T, U](x T, f |T| U) U { f(x) }
fn call_plain(f fn(i64) i64, x i64) i64 { f(x) }
fn describe(f |i64| i64) str { "numbers" }
fn describe(f |str| str) str { "text" }
fn ident[T](x T) T { x }

fn largest[T](items []T, less |T, T| bool) T {
    best := items[0]
    for x in items {
        if less(best, x) {
            best = x
        }
    }
    best
}

// calls `visit` for every number below `limit` that has the property `keep`
fn walk(limit i64, keep |i64| bool, visit |i64|) {
    for i in 0..limit {
        if keep(i) {
            visit(i)
        }
    }
}

fn main() {
    // --- quick example
    scores := []i64{70, 95, 80}
    names := []str{"ann", "bob", "cy"}
    order := []i64{0, 1, 2}
    sort_by(order, |a i64, b i64| bool { scores[a] > scores[b] })   // uses the local `scores`
    for i in order {
        put(names[i], " ")
    }
    print("")                                    // bob cy ann

    // --- literals
    less := |a i64, b i64| bool { a < b }        // two parameters, result bool
    show := |x i64| { print("value", x) }        // no result
    count := 0
    tick := || { count += 1 }                    // no parameters
    sign := |x i64| i64 {
        if x < 0 {
            return -1                            // returns from the closure
        }
        1
    }
    show(sign(-5))                               // value -1
    tick()
    tick()
    print(less(1, 2), count)                     // true 2

    // --- capture by reference
    total := 0
    add := |x i64| { total += x }
    add(5)
    total = 100                                  // the closure sees later changes
    add(1)
    print(total)                                 // 101
    p := Point{1, 2}
    move := |dx i64| { p.x += dx }
    move(10)
    print(p)                                     // Point{x: 11, y: 2}

    // --- nested literals
    hits := 0
    outer := |n i64| {
        inner := |k i64| { hits += n * k }       // `n` of outer, `hits` of main
        inner(1)
        inner(2)
    }
    outer(10)
    print(hits)                                  // 30

    // --- a closure that calls itself: declare the variable first
    var fact |i64| i64
    fact = |n i64| i64 { if n <= 1 { 1 } else { n * fact(n - 1) } }
    print(fact(10))                              // 3628800

    // --- conversions
    var f |i64| i64 = double                     // function name
    fv := double                                 // fv has the type fn(i64) i64
    f = fv                                       // fn value
    f = |x i64| i64 { x + count }                // literal
    print(f(1), apply(4, double), apply(4, |x i64| str { fmt("<", x, ">") }))   // 3 8 <4>
    print(call_plain(|x i64| i64 { x + 1 }, 41)) // 42: a literal without captures is a plain function
    var g |i64| i64 = ident                      // generic function: T = i64 from the closure type
    print(g(7), describe(|s str| str { s }), describe(double))   // 7 text numbers

    // --- struct fields, collections
    clicked := 0
    b := Button{label: "ok", on_click: |n i64| { clicked += n }}
    b.on_click(2)
    b.on_click(3)
    handlers := vec[|i64| i64]()
    handlers.push(double)
    handlers.push(|x i64| i64 { x + clicked })
    print(clicked, handlers.buf[1](1), b)        // 5 6 Button{label: ok, on_click: <closure>}

    // --- generic code
    print(largest([]f64{1.5, 9.25, 3.0}, |a f64, b f64| bool { a < b }))        // 9.25
    seen := vec[i64]()
    walk(20, |i i64| bool { i % 7 == 0 }, |i i64| { seen.push(i) })
    print(seen.items())                          // [0, 7, 14]

    // --- library
    xs := []i64{3, 8, 1, 6}
    limit := 5
    print(xs.any(|x i64| bool { x > limit }), xs.all(|x i64| bool { x > limit }))      // true false
    print(xs.count_if(|x i64| bool { x > limit }), xs.index_where(|x i64| bool { x > limit }))   // 2 1
    print(xs.filter(|x i64| bool { x > limit }), xs.map_to(|x i64| str { fmt(x, "!") }))   // [8, 6] [3!, 8!, 1!, 6!]
    sum := 0
    xs.each(|x i64| { sum += x })
    print(sum)                                   // 18

    // --- zero value
    var none |i64| i64                           // nil closure: calling it is a memory fault
    none = nil
    print(sizeof[|i64| i64](), none)             // 16 <closure>
}
