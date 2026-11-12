// main is `fn main()` or `fn main() -> i64`: other forms are reported at main, not in the
// generated entry
fn main(x: i64) {}
fn main[T](a: T, b: T) {}
fn main(s: str) -> u8 { 0 }
