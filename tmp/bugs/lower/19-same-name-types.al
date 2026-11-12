// two private structs `Ctx` of different files: the diagnostic tells where each is declared
use "priv/same_name_ctx.al"
priv struct Ctx { n: i64 }
priv enum Opt { None, Some(i64) }
fn main() {
    c: Ctx
    takes_b(c)
    o: Opt = None
    x: i64 = unwrap(o)
    print(x)
}
