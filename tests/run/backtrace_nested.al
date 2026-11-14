// nested and anonymous functions are named as in diagnostics: outer.name, outer.fn@line:col
fn process(xs: []i64) -> i64 {
    fn scale(x: i64) -> i64 {
        assert x < 100, "too big"
        return x * 2
    }
    apply := fn(xs: []i64, f: fn(i64) -> i64) -> i64 {
        total := 0
        for x in xs { total += f(x) }
        total
    }
    return apply(xs, scale)
}

fn main() {
    print(process([]i64{1, 2}))
    print(process([]i64{1, 200}))
}
