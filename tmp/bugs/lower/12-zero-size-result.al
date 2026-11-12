// a call whose result is a zero-size struct was "no value" (cannot bind / printed ())
struct E {}
struct F { e: E, t: () }
enum G { Ga(E), Gb }
fn id(e: E) -> E { e }
fn idf(f: F) -> F { f }
fn gen[T](x: T) -> T { x }
fn mk() -> (E, E) { (E{}, E{}) }
fn main() {
    e := E{}
    y := id(e)
    print(y, id(e), e, idf(F{}), gen(e), gen(Ga(e)), mk())
    v := vec[E]()
    v.push(e)
    v.push(E{})
    print(v.pop(), v.len, v.last(), sizeof[E](), y == id(e), hash(id(e)) == hash(e))
    f := id
    print(f(e))
    m := map[i64, E]()
    m.set(1, E{})
    print(m.get(1), m.get_or(2, E{}))
    a, b := mk()
    print(a, b)
}
