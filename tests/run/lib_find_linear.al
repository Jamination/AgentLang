// Substring search is linear in the worst case: "aaa...ab" in "aaaa..." made find, rfind,
// count, replace and split compare len(s) * len(sub) bytes (here: about 2 * 10^10, minutes).
fn main() {
    s := repeat("a", 10_000_000)
    pat := fmt(repeat("a", 2000), "b")
    tap := fmt("b", repeat("a", 2000))
    print(find(s, pat), rfind(s, pat), find(s, tap), rfind(s, tap), count(s, pat))
    print(len(replace(s, pat, "x")), len(split(s, pat)))
    // matches are still found after the switch to the linear search
    t := fmt(s, pat, "a", pat, s)
    print(find(t, pat), rfind(t, pat), count(t, pat), find(t, pat, 10_000_001), len(split(t, pat)))
}
