const SRC = `line "one"
  two\n`
fn main() {
    print(len(SRC), SRC)
    big := alloc[u8](5000)
    fill(big, 'x')
    s := fmt(big, "|", 12)
    print(len(s), fmt("a", fmt(1, fmt(2))))
}
