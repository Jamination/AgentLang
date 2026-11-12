// path_join puts exactly one '/' between its parts (it kept "a//b"); path_stem / path_ext follow
// pathlib: a dot with only dots before it starts no extension ("..": stem "..", was ".")
use std.asset

fn main() {
    print(path_join("a//", "b"), path_join("a/", "b"), path_join("/", "b"), path_join("//", "b"), path_join("a", "b"), path_join("", "b"), path_join("a", "/b"), path_join("a/", ""))
    for p in []str{"..", "...", "..a", ".hidden", ".a.b", "a.", "a..", "a..b", "x.tar.gz", "d/c.png", "Makefile", ".", "a/"} {
        put(fmt("[", path_stem(p), "|", path_ext(p), "] "))
    }
    print("")
}
