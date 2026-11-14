// an index out of bounds: the trace names every function on the way, innermost first
fn load_level(levels: []i64, i: i64) -> i64 {
    return levels[i]
}

fn start(n: i64) -> i64 {
    levels := []i64{10, 20, 30}
    return load_level(levels, n) + 1
}

fn main() {
    print("before")
    print(start(len(args()) + 5))
}
