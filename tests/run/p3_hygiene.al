// P3 runtime arena hygiene: Map.clear() reuses buffers, sort([]str) releases scratch,
// and raw-allocated string helpers match exact outputs.
fn main() {
    // 1. Map.clear() reuses allocated buffers across repeated clear/refill cycles
    m := map[i64, i64]()
    for i in 0..64 {
        m.set(i, i * 3)
    }
    used0 := mem_used()
    for round in 0..20 {
        m.clear()
        assert m.len == 0
        assert !m.has(0)
        assert len(m.keys()) == 0
        for i in 0..64 {
            m.set(i + round * 1000, i)
        }
        assert m.len == 64
        v, ok := m.get(round * 1000 + 42)
        assert ok && v == 42
    }
    // Map.clear() should not grow the arena for repeated 64-entry refills (aside from tiny len(m.keys())=0)
    used1 := mem_used()
    assert used1 - used0 < 4096, fmt("Map.clear leaked ", used1 - used0, " bytes")
    print("map_clear_ok")

    // 2. sort([]str) releases its merge scratch buffer
    xs := alloc[str](512)
    for i in 0..512 {
        xs[i] = fmti(511 - i, 4, '0')
    }
    u0 := mem_used()
    sort(xs)
    u1 := mem_used()
    assert u1 == u0, fmt("sort([]str) kept ", u1 - u0, " bytes")
    assert xs[0] == "0000" && xs[511] == "0511"
    print("sort_str_ok")

    // 3. String helpers using unzeroed __alloc_raw buffers
    assert concat("hello ", "world") == "hello world"
    assert concat("", "") == ""
    assert repeat("ab", 4) == "abababab"
    assert pad_left("42", 5, '0') == "00042"
    assert pad_right("hi", 5, '.') == "hi..."
    assert to_upper("Abc-123z") == "ABC-123Z"
    assert to_lower("AbC-123Z") == "abc-123z"
    assert join([]str{"a", "bb", "ccc"}, ",") == "a,bb,ccc"
    assert replace("foo-bar-foo", "foo", "quux") == "quux-bar-quux"
    assert hex(0xdeadbeef) == "deadbeef"
    assert fmtf(3.5, 2) == "3.50"
    sp := split("x,y,z", ',')
    assert len(sp) == 3 && sp[0] == "x" && sp[2] == "z"
    sp2 := split("a::b::c", "::")
    assert len(sp2) == 3 && sp2[1] == "b"
    fs := fields("  one\ttwo\nthree  ")
    assert len(fs) == 3 && fs[0] == "one" && fs[2] == "three"
    assert from_cstr(cstr("nul-check")) == "nul-check"
    print("strings_ok")
}
