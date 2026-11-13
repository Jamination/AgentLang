// std.asset: config files and JSON
use std.asset

fn show(v: *Json, depth: i64) {
    for i in 0..depth {
        put("  ")
    }
    if len(v.key) > 0 {
        put(v.key, ": ")
    }
    match v.kind {
        JsonNull => print("null")
        JsonBool => print(v.as_bool(false))
        JsonNumber => print(v.as_f64(0.0))
        JsonString => print(fmt("\"", v.text, "\""))
        JsonArray => print("array", v.count())
        JsonObject => print("object", v.count())
    }
    for i in 0..v.count() {
        show(v.at(i), depth + 1)
    }
}

fn main() {
    // ---- config ----
    text := "# game settings\nname = Space Game\nfullscreen = yes\nvolume=0.75\n\n[video]\nwidth = 1280\n  height=720  \ntitle = \"  padded  \"\n; comment\nthis line has no equals sign\nwidth = 1920\n[ input ]\nsensitivity = 2.5e-1  # inline comment\ninvert = off ; another\nempty =\nurl = http://x/?a=b#frag\ncolor = #ff8800\nquoted = \"a # b ; c\" # comment\n"
    c := config_parse(text)
    print(c.keys.items())
    print(c.get_str("name", "?"), "|", c.get_str("video.title", "?"), "|", c.get_str("missing", "fallback"), "|", len(c.get_str("input.empty", "?")), "|", c.get_str("input.url", ""))
    print(c.get_i64("video.width", 0), c.get_i64("video.height", 0), c.get_i64("name", -1), c.get_i64("volume", -1), c.get_i64("missing", 42))
    print(c.get_f64("volume", 0.0), c.get_f64("input.sensitivity", 0.0), c.get_f64("video.width", 0.0), c.get_f64("name", 1.5))
    print(c.get_f32("volume", 0.0), c.get_f32("input.sensitivity", 0.0), c.get_f32("video.width", 0.0), c.get_f32("name", 1.5), c.get_f32("missing", 0.1))
    print(c.get_bool("fullscreen", false), c.get_bool("input.invert", true), c.get_bool("name", true), c.get_bool("missing", false))
    print(c.get_str("input.color", "?"), "|", c.get_str("input.quoted", "?"), "|", c.get_str("input.url", "?"))
    print(c.has("video.width"), c.has("width"), c.has("input.empty"), c.keys.len, c.values.len)
    e := config_parse("")
    print(e.keys.len, e.get_i64("x", 7))
    _, okc := config_load("no/such/file.ini")
    dir := fmt("tmp/asset_data_", syscall(39))
    ini := path_join(dir, "game.ini")
    make_dir(dir)
    write_bytes(ini, text)
    lc, okl := config_load(ini)
    print(okc, okl, lc.get_i64("video.width", 0))
    print(remove_file(ini), remove_dir(dir))

    // ---- JSON ----
    src := "{\n  \"name\": \"Scout\",\n  \"hp\": 100,\n  \"speed\": 2.5e1,\n  \"pos\": [1.5, -2, 0],\n  \"tags\": [\"fast\", \"small\"],\n  \"alive\": true,\n  \"shield\": false,\n  \"parent\": null,\n  \"id\": 9007199254740993,\n  \"weapon\": {\"kind\": \"laser\", \"damage\": 7, \"mods\": []},\n  \"empty\": {}\n}\n"
    root, ok := json_parse(src)
    print(ok, root.kind, root.count(), json_error_line(src))
    print(root.get("name").as_str("?"), root.get("hp").as_i64(0), root.get("speed").as_f64(0.0), root.get("speed").as_i64(0), root.get("id").as_i64(0))
    pos := root.get("pos")
    print(pos.count(), pos.at(0).as_f64(0.0), pos.at(1).as_i64(0), pos.at(2).as_f64(9.0), pos.at(3) == nil, pos.at(-1) == nil)
    // as_f32 rounds once from the text: f32(as_f64(..)) would give 1.0 here
    near, _ := json_parse("[1.00000005960464477539062500000001]")
    print(root.get("speed").as_f32(0.0), pos.at(0).as_f32(0.0), pos.at(2).as_f32(9.0), root.get("name").as_f32(-1.0), near.at(0).as_f32(0.0), f32(near.at(0).as_f64(0.0)))
    print(root.get("alive").as_bool(false), root.get("shield").as_bool(true), root.get("parent").is_null(), root.get("nope").is_null(), root.get("name").is_null())
    // chains tolerate missing members and wrong kinds
    print(root.get("weapon").get("kind").as_str("?"), root.get("weapon").get("damage").as_i64(0), root.get("weapon").get("mods").count(), root.get("weapon").get("nope").get("deeper").at(3).as_i64(-1))
    print(root.get("name").as_i64(5), root.get("hp").as_str("no"), root.get("hp").as_bool(true), root.get("name").get("x") == nil, root.get("tags").get("x") == nil, root.get("name").count(), root.get("empty").count())
    for i in 0..root.get("tags").count() {
        put(root.get("tags").at(i).as_str(""), " ")
    }
    print(root.at(0).key, root.at(10).key)
    show(root, 0)

    // strings: escapes, unicode, views
    s, oks := json_parse("[\"a\\\"b\\\\c\\/d\\n\\t\\r\\b\\f\", \"\\u0041\\u00e9\\u20ac\\ud83d\\ude00\", \"plain\", \"\"]")
    esc := s.at(0).as_str("")
    print(oks, len(esc), esc[1], esc[3], esc[5], esc[7], esc[8], esc[9], esc[10], esc[11])
    print(s.at(1).as_str(""), len(s.at(1).as_str("")), s.at(2).as_str(""), len(s.at(3).as_str("x")))
    plain := "[\"view\"]"
    pv, _ := json_parse(plain)
    print(ptr(pv.at(0).as_str("")) == ptr(plain[2..]))

    // scalars and white space at the top level
    n, okn := json_parse("  -12.5e-1 \n")
    t, okt := json_parse("true")
    z, okz := json_parse("null")
    q, okq := json_parse("\"x\"")
    print(okn, n.as_f64(0.0), okt, t.as_bool(false), okz, z.is_null(), okq, q.as_str(""))
    nested := "[[[[[[[[[[1]]]]]]]]]]"
    deep, okd := json_parse(nested)
    v := deep
    levels := 0
    while v.kind == JsonArray {
        v = v.at(0)
        levels += 1
    }
    print(okd, levels, v.as_i64(0))

    // errors: nil + false, with the line of the problem
    bad := []str{"", "{", "[1,]", "{\"a\" 1}", "[1] x", "\"abc", "tru", "[1 2]", "{\"a\":}", "\"\\q\"", "-", "{a: 1}", "\"\\u12\"", "[1,\n 2,\n 3,\n oops]", "{\n\"a\": 1,\n\"b\": [1, 2\n}"}
    for b in bad {
        r, okb := json_parse(b)
        put(r == nil && !okb, ":", json_error_line(b), " ")
    }
    print("")
    too_deep := alloc[u8](1000)
    fill(too_deep, '[')
    _, okdeep := json_parse(too_deep)
    print(okdeep, json_error_line("[1, 2]"), json_error_line("{}"))

    // parsing inside a mark/release scope leaves nothing behind
    keep := alloc[u8](1)
    used := mem_used()
    m := mark()
    tmp, _ := json_parse(src)
    hp := tmp.get("hp").as_i64(0)
    release(m)
    print(hp, mem_used() - used, len(keep))
}
