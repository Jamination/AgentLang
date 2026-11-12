// A call that only a private function of another file would accept: the error about the
// visible definitions says that the private one exists.
use "priv/over.al"
struct Types { n: i64 }
fn is_int(self: *Types, t: i64) -> bool { t < self.n }
fn size(self: *Types) -> i64 { self.n }
fn size(self: *Types, k: i64) -> i64 { self.n * k }
fn main() {
    ts := Types{3}
    print(ts.is_int(2), over_use(), is_int(K.I8), size(K.I8), K.F64.size())
}
