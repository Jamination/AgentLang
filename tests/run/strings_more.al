// replace, count, repeat, fields, split by a string, the trim family, character tests,
// find from a position, find_any, rfind, integers in other bases, formatting with a width.
fn show(parts: []str) {
    put(len(parts), ":")
    for p in parts { put(" <", p, ">") }
    put("\n")
}

fn main() {
    // replace: every occurrence, left to right, not overlapping
    print(replace("a-b-c", "-", "+"), replace("aaaa", "aa", "b"), replace("aaa", "aa", "b"), replace("abc", "x", "y"))
    print(replace("", "x", "y") == "", replace("abc", "abc", ""), replace("abab", "ab", "abab"), replace("a.b", ".", ""))
    print(replace("xx", "x", "xx"), replace("hello", "l", "L"), "one two".replace(" ", "  "))
    r := replace("same", "q", "z")                 // always a new string
    r[0] = 'S'
    print(r)

    // count: occurrences that do not overlap
    print(count("banana", "a"), count("banana", "an"), count("aaaa", "aa"), count("aaa", "aa"), count("", "a"), count("abc", "abcd"), count("abc", "abc"))

    // repeat
    print(repeat("ab", 3), repeat("-", 10), repeat("ab", 1), repeat("ab", 0) == "", repeat("ab", -1) == "", repeat("", 5) == "", len(repeat("xyz", 1000)))

    // fields: runs of white space separate, no empty piece
    show(fields("  one two\t\tthree\n four \r\n"))
    show(fields(""))
    show(fields(" \t\n"))
    show(fields("word"))
    show(fields("a\x0bb\x0cc"))
    print(join(fields("  int   *  p "), " "))

    // split by a string: always (number of separators + 1) pieces
    show(split("a, b, c", ", "))
    show(split("a--b----c", "--"))
    show(split("", "ab"))
    show(split("ab", "ab"))
    show(split("abc", "x"))
    show(split("aaa", "aa"))
    show(split("k=v", "="))
    show(split("a b", ' '))                      // the u8 form is still there

    // trim family
    s := " \t x y \r\n\x0b\x0c"
    print(fmt("<", trim(s), "> <", trim_left(s).len, "> <", trim_right(s), ">"))
    print(fmt("<", trim(""), "><", trim("   "), "><", trim_left("   "), "><", trim_right("   "), "><", trim("a"), ">"))
    print(trim("--x-y--", "-"), trim_left("--x-y--", "-"), trim_right("--x-y--", "-"), trim("xyxhixyx", "xy"), trim("abc", ""), trim("aaa", "a") == "")
    print(trim_right("path///", "/"), trim_left("0042", "0"), trim("\"quoted\"", "\""), trim_right("", "/") == "", trim_left("abc", "cb"))

    // character tests
    for c in " \t\n\r\x0b\x0c\x00a_AZazmM09{@[`" {
        put(i64(is_space(c)), i64(is_upper(c)), i64(is_lower(c)), i64(is_alpha(c)), i64(is_digit(c)), i64(is_alnum(c)), " ")
    }
    put("\n")

    // find from a position (like from + find(s[from..], sub)), find_any, rfind
    t := "one, two, one"
    print(find(t, "one", 0), find(t, "one", 1), find(t, "one", 10), find(t, "one", 11), find(t, "one", 13), find(t, "", 5), find(t, "", 13), find("", "", 0), find("", "a", 0))
    print(find_any(t, ",;", 0), find_any(t, ",;", 4), find_any(t, ",;", 9), find_any(t, "", 0), find_any(t, "xyz", 0), find_any(t, "eo", 12), find_any(t, "o", 13), find_any("", "a", 0))
    print(rfind(t, "one"), rfind(t, ","), rfind(t, "x"), rfind(t, ""), rfind("", ""), rfind("", "a"), rfind("aaa", "aa"), rfind("ab", "abc"), t.rfind("one, "))
    n := 0
    i := find(t, "o", 0)
    while i >= 0 {
        n += 1
        i = find(t, "o", i + 1)
    }
    print(n)

    // integers in other bases
    print(parse_i64("ff", 16), parse_i64("FF", 16), parse_i64("-fF", 16), parse_i64("+101", 2), parse_i64("777", 8), parse_i64("zz", 36), parse_i64("Zz", 36))
    print(parse_i64("0x1f", 16), parse_i64("12", 2), parse_i64("g", 16), parse_i64("", 16), parse_i64("-", 16), parse_i64(" 1", 10), parse_i64("1_000", 10), parse_i64("1.5", 10))
    print(parse_i64("0x1F", 0), parse_i64("0XfF", 0), parse_i64("-0x10", 0), parse_i64("0b101", 0), parse_i64("0o17", 0), parse_i64("017", 0), parse_i64("42", 0), parse_i64("-42", 0), parse_i64("0", 0))
    print(parse_i64("0x", 0), parse_i64("0b2", 0), parse_i64("x10", 0), parse_i64("0x-1", 0), parse_i64("", 0), parse_i64("+", 0), parse_i64("0b", 0), parse_i64("1f", 0))
    // the range of i64 in every form
    print(parse_i64("7fffffffffffffff", 16), parse_i64("8000000000000000", 16), parse_i64("-8000000000000000", 16), parse_i64("-8000000000000001", 16))
    print(parse_i64("9223372036854775807", 10), parse_i64("9223372036854775808", 10), parse_i64("-9223372036854775808", 10), parse_i64("-9223372036854775809", 10), parse_i64("99999999999999999999", 10))
    print(parse_i64("111111111111111111111111111111111111111111111111111111111111111", 2), parse_i64("1000000000000000000000000000000000000000000000000000000000000000", 2))
    print(parse_i64("1y2p0ij32e8e7", 36), parse_i64("1y2p0ij32e8e8", 36), parse_i64("-1y2p0ij32e8e8", 36), parse_i64("0xffffffffffffffff", 0))
    print(parse_i64("9223372036854775807"), parse_i64("-9223372036854775808"), parse_i64("9223372036854775808"), parse_i64("0x10"), parse_i64("+7"), parse_i64(""))

    print(to_base(255, 2), to_base(255, 8), to_base(255, 16), to_base(35, 36), to_base(36, 36), to_base(0, 2), to_base(0xFFFF_FFFF_FFFF_FFFF, 2).len, to_base(0xFFFF_FFFF_FFFF_FFFF, 36), to_base(u64(-1), 16))
    for base in 2..=36 {
        for v in []i64{0, 1, 35, 36, 1234567890123, 0x7FFF_FFFF_FFFF_FFFF} {
            back, ok := parse_i64(to_base(u64(v), base), base)
            assert ok && back == v
        }
    }

    // formatting with a width: %5d %05d %-5d %x %08x %10s %-10s %.2f %8.2f
    print(fmt("[", fmti(42, 5, ' '), "] [", fmti(-42, 5, ' '), "] [", fmti(42, 5, '0'), "] [", fmti(-42, 5, '0'), "] [", pad_right(fmt(42), 5, ' '), "]"))
    print(fmt("[", fmti(123456, 3, ' '), "] [", fmti(-123456, 3, '0'), "] [", fmti(-7, 2, '0'), "] [", fmti(-7, 3, '0'), "] [", fmti(0, 0, '0'), "] [", fmti(5, -3, ' '), "] [", fmti(-5, 4, '*'), "]"))
    a: u8 = 200
    b: i8 = -100
    c: u64 = 0xFFFF_FFFF_FFFF_FFFF
    d: i64 = -0x8000_0000_0000_0000
    print(fmti(a, 6, '0'), fmti(b, 6, '0'), fmti(c, 22, '0'), fmti(d, 22, '0'), fmti(i32(-1), 4, ' '), fmti(u16(7), 3, '0'))
    print(fmt("[", hex(255), "] [", hex(255, 8), "] [", hex(255, 1), "] [", hex(0, 4), "] [", hex(0xDEADBEEF, 0), "] [", hex(u64(-1), 20), "] [", to_upper(hex(0xbeef, 6)), "]"))
    print(fmt("[", pad_left("abc", 10, ' '), "] [", pad_right("abc", 10, ' '), "] [", pad_left(to_base(5, 2), 8, '0'), "]"))
    print(fmt("[", fmtf(3.14159, 2), "] [", fmtf(3.14159, 2, 8), "] [", fmtf(-3.14159, 2, 8), "] [", fmtf(1234.5, 1, 3), "] [", fmtf(2.5, 0, 4), "] [", fmtf(0.0, 3, 0), "] [", fmtf(1e10, 0, 14), "]"))
}
