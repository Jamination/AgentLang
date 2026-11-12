// A function that is only referenced from the initializer of a global (a table of handlers)
// is compiled together with everything it calls, also what nothing else calls.
struct Handlers {
    scale: fn(i64) -> i64
    name: fn(i64) -> str
}

noinline fn triple(x: i64) -> i64 { x * 3 }

noinline fn label(x: i64) -> str { if x % 2 == 0 { "even" } else { "odd" } }

fn on_scale(x: i64) -> i64 { triple(x) + 1 }

fn on_name(x: i64) -> str { fmt(label(x), ":", x) }

handlers := Handlers{scale: on_scale, name: on_name}

fn main() {
    print(handlers.scale(5), handlers.name(7))
}
