use std.asset
fn main() {
    text, _ := read_file("/tmp/paths.txt")
    for p in lines(text) {
        print(fmt("[", path_stem(p), "][", path_ext(p), "][", path_base(p), "][", path_dir(p), "][", path_join(p, "x"), "]"))
    }
}
