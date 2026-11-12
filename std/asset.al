// std.asset: files, directories, paths, a cached asset loader with hot-reload polling, and
// readers for two simple data formats (INI-style config, JSON). `use std.asset`.
// Everything goes through raw Linux system calls (no libc). Paths are limited to 4095 bytes.
// Functions that return file contents, lists or parsed data allocate from the program arena;
// the queries (file_exists, file_size, modified_time, is_dir, changed) do not allocate.

// ---------- files and directories ----------
// writes a, a '/' if both parts are non-empty and a does not end in one, b and a NUL into buf
fn __asset_cpath(buf: []u8, a: str, b: str) -> bool {
    sep := if len(a) > 0 && len(b) > 0 && a[len(a) - 1] != '/' { 1 } else { 0 }
    if len(a) + sep + len(b) >= len(buf) {
        return false
    }
    memcopy(ptr(buf), ptr(a), len(a))
    buf[len(a)] = '/'
    memcopy(cast[i64](ptr(buf)) + len(a) + sep, ptr(b), len(b))
    buf[len(a) + sep + len(b)] = 0
    return true
}

// stat(dir/name) into st (struct stat as 18 i64: [3] low half = mode, [6] = size,
// [11] = mtime seconds, [12] = mtime nanoseconds)
fn __asset_stat(dir: str, name: str, st: []i64) -> bool {
    buf: [4096]u8
    return __asset_cpath(buf[..], dir, name) && syscall(4, ptr(buf), ptr(st)) == 0
}

// a system call whose first argument is the path dir/name (open, mkdir, unlink, rmdir)
fn __asset_call(nr: i64, dir: str, name: str, a: i64, b: i64) -> i64 {
    buf: [4096]u8
    if !__asset_cpath(buf[..], dir, name) {
        return -36
    }
    return syscall(nr, ptr(buf), a, b)
}

// true if path names an existing file or directory
fn file_exists(path: str) -> bool {
    st: [18]i64
    return __asset_stat(path, "", st[..])
}

// true if path names a directory
fn is_dir(path: str) -> bool {
    st: [18]i64
    return __asset_stat(path, "", st[..]) && st[3] & 0xF000 == 0x4000
}

// size of the file in bytes, or -1 if it does not exist
fn file_size(path: str) -> i64 {
    st: [18]i64
    return if __asset_stat(path, "", st[..]) { st[6] } else { -1 }
}

fn __asset_mtime(dir: str, name: str) -> i64 {
    st: [18]i64
    return if __asset_stat(dir, name, st[..]) { st[11] * 1000000000 + st[12] } else { 0 }
}

// time of the last modification in nanoseconds since 1970 (0 if the file does not exist);
// compare two readings to detect a change
fn modified_time(path: str) -> i64 {
    return __asset_mtime(path, "")
}

fn __asset_read(dir: str, name: str) -> ([]u8, bool) {
    fd := __io_result(__asset_call(2, dir, name, 0x80000, 0))      // O_RDONLY | O_CLOEXEC
    if fd < 0 {
        return ("", false)
    }
    defer { syscall(3, fd) }
    st: [18]i64
    if syscall(5, fd, ptr(st)) != 0 || st[6] <= 0 {
        // size unknown (pipes, /proc): read until end of file
        data := read_all(fd)
        if io_error() != 0 {
            return ("", false)
        }
        return (data, true)
    }
    buf := alloc[u8](st[6])
    n := 0
    while n < len(buf) {
        r := syscall(0, fd, cast[i64](ptr(buf)) + n, len(buf) - n)
        if r == -4 {
            continue
        }
        if __io_result(r) < 0 {
            return ("", false)
        }
        if r == 0 {
            break
        }
        n += r
    }
    return (buf[..n], true)
}

// the whole content of a file; (empty, false) if it cannot be opened or read (`io_error()`
// is then the OS error number, `error_text(io_error())` its text). Allocates the result.
fn read_bytes(path: str) -> ([]u8, bool) {
    return __asset_read(path, "")
}

// creates or replaces a file with the given content; false on failure (see `io_error()`)
fn write_bytes(path: str, data: []u8) -> bool {
    m := mark()
    ok := write_file(path, data)
    release(m)
    return ok
}

// deletes a file; false if that failed
fn remove_file(path: str) -> bool {
    return __io_result(__asset_call(87, path, "", 0, 0)) == 0
}

// deletes an empty directory; false if that failed
fn remove_dir(path: str) -> bool {
    return __io_result(__asset_call(84, path, "", 0, 0)) == 0
}

// gives a file or directory another name or place (on the same file system); a file that
// has the new name is replaced. false if that failed
fn rename(from: str, to: str) -> bool {
    a: [4096]u8
    b: [4096]u8
    if !__asset_cpath(a[..], from, "") || !__asset_cpath(b[..], to, "") {
        return __io_result(-36) == 0
    }
    return __io_result(syscall(82, ptr(a), ptr(b))) == 0
}

// creates a directory and any missing parents; true if the directory exists afterwards
fn make_dir(path: str) -> bool {
    for i in 1..len(path) {
        if path[i] == '/' {
            __asset_call(83, path[..i], "", 493, 0)
        }
    }
    r := __asset_call(83, path, "", 493, 0)
    if is_dir(path) {
        __io_result(0)
        return true
    }
    // (not a directory although mkdir reported nothing: a file of that name exists)
    __io_result(if r < 0 { r } else { -20 })
    return false
}

fn __asset_name_less(a: str, b: str) -> bool {
    return cmp(a, b) < 0
}

// names of the entries of a directory (without "." and ".."), sorted by byte value; empty if
// the directory cannot be read. Allocates the names and the list.
fn list_dir(path: str) -> []str {
    names := vec[str]()
    // O_RDONLY | O_DIRECTORY | O_CLOEXEC
    fd := __io_result(__asset_call(2, path, "", 0x90000, 0))
    if fd < 0 {
        return names.items()
    }
    buf: [8192]u8
    loop {
        n := syscall(217, fd, ptr(buf), 8192)
        if n <= 0 {
            break
        }
        // struct linux_dirent64: u64 ino, i64 off, u16 reclen, u8 type, char name[]
        off := 0
        while off < n {
            reclen := i64(buf[off + 16]) | i64(buf[off + 17]) << 8
            name := from_cstr(cast[*u8](cast[i64](ptr(buf)) + off + 19))
            if name != "." && name != ".." {
                names.push(concat(name, ""))
            }
            off += reclen
        }
    }
    syscall(3, fd)
    sort_by(names.items(), __asset_name_less)
    return names.items()
}

// ---------- paths ----------
fn __path_slash(p: str) -> i64 {
    for i in len(p) - 1..=0 by -1 {
        if p[i] == '/' {
            return i
        }
    }
    return -1
}

// a and b joined with exactly one '/' between them; b alone if a is empty or b is absolute.
// Allocates the result.
fn path_join(a: str, b: str) -> str {
    if len(a) == 0 || (len(b) > 0 && b[0] == '/') {
        return b
    }
    if len(b) == 0 {
        return a
    }
    if a[len(a) - 1] == '/' {
        return concat(a, b)
    }
    return fmt(a, "/", b)
}

// the directory part: "a/b/c.png" -> "a/b", "c.png" -> "", "/c" -> "/" (a view of p)
fn path_dir(p: str) -> str {
    i := __path_slash(p)
    return if i < 0 { "" } else if i == 0 { p[..1] } else { p[..i] }
}

// the last component: "a/b/c.png" -> "c.png" (a view of p)
fn path_base(p: str) -> str {
    return p[__path_slash(p) + 1..]
}

// the extension of the last component without the dot: "a/b/c.png" -> "png", "x.tar.gz" ->
// "gz", "Makefile" and ".hidden" -> "" (a view of p)
fn path_ext(p: str) -> str {
    b := path_base(p)
    for i in len(b) - 1..=1 by -1 {
        if b[i] == '.' {
            return b[i + 1..]
        }
    }
    return ""
}

// the last component without its extension: "a/b/c.png" -> "c" (a view of p)
fn path_stem(p: str) -> str {
    b := path_base(p)
    e := path_ext(p)
    return if len(e) == 0 && !ends_with(b, ".") { b } else { b[..len(b) - len(e) - 1] }
}

// ---------- asset loader ----------
// A loaded file: its bytes and the modification time it had when it was read.
struct Asset { data: []u8, mtime: i64 }

// Loads files by name relative to a root directory and keeps them in a cache, so every asset
// is read once. Loaded data is shared: treat it as read-only.
struct Assets { root: str, cache: Map[str, Asset] }

// a loader for the files under `root` ("" = the working directory)
fn assets_new(root: str) -> Assets {
    return Assets{root: root, cache: map[str, Asset]()}
}

// reads `name` from disk (again), replacing the cached copy; (empty, false) if it cannot be
// read, in which case a cached copy stays. The previous data stays in the arena.
fn reload(a: *Assets, name: str) -> ([]u8, bool) {
    mtime := __asset_mtime(a.root, name)
    data, ok := __asset_read(a.root, name)
    if !ok {
        return ("", false)
    }
    if !a.cache.has(name) {
        name = concat(name, "")
    }
    a.cache.set(name, Asset{data, mtime})
    return (data, true)
}

// the content of the file `name` under the root: from the cache if it was loaded before,
// otherwise read from disk (allocates); (empty, false) if it cannot be read
fn load(a: *Assets, name: str) -> ([]u8, bool) {
    e, ok := a.cache.get(name)
    if ok {
        return (e.data, true)
    }
    return reload(a, name)
}

// true if `name` was loaded and its file has been modified since. Cheap enough to poll every
// frame or every few frames for hot reloading: one stat call, no allocation.
fn changed(a: *Assets, name: str) -> bool {
    e, ok := a.cache.get(name)
    return ok && __asset_mtime(a.root, name) != e.mtime
}

// ---------- config files ----------
// Parsed "key = value" text. A line `[section]` prefixes the keys after it with "section.".
// '#' or ';' starts a comment at the start of a line or after white space; lines without '='
// are ignored. A value in double quotes is taken literally (spaces, '#', ';'). A key that
// occurs twice keeps its last value.
//   keys  all keys in file order (use keys.items())
struct Config { values: Map[str, str], keys: Vec[str] }

// parses config text. Values are views into `text`, which must stay alive. Allocates.
fn config_parse(text: str) -> Config {
    c := Config{values: map[str, str](), keys: vec[str]()}
    section := ""
    for raw in lines(text) {
        line := trim(raw)
        if len(line) == 0 || line[0] == '#' || line[0] == ';' {
            continue
        }
        if line[0] == '[' {
            // `[section]`, possibly followed by white space and a comment
            close := len(line) - 1
            if line[close] != ']' {
                close = find(line, "]")
                rest := if close > 0 { line[close + 1..] } else { "" }
                if len(rest) == 0 || (rest[0] != ' ' && rest[0] != '\t') || (trim(rest)[0] != '#' && trim(rest)[0] != ';') {
                    close = -1
                }
            }
            if close > 0 {
                section = trim(line[1..close])
                continue
            }
        }
        eq := find(line, "=")
        if eq < 0 {
            continue
        }
        key := trim(line[..eq])
        val := trim(line[eq + 1..])
        if len(val) > 0 && val[0] == '"' {
            close := find(val[1..], "\"")
            if close >= 0 {
                val = val[1..close + 1]
            }
        } else {
            for i in 1..len(val) {
                if (val[i] == '#' || val[i] == ';') && (val[i - 1] == ' ' || val[i - 1] == '\t') {
                    val = trim(val[..i])
                    break
                }
            }
        }
        if len(section) > 0 {
            key = fmt(section, ".", key)
        }
        if !c.values.has(key) {
            c.keys.push(key)
        }
        c.values.set(key, val)
    }
    return c
}

// reads and parses a config file; false if the file cannot be read
fn config_load(path: str) -> (Config, bool) {
    text, ok := read_bytes(path)
    return (config_parse(text), ok)
}

// true if the key is present
fn has(c: *Config, key: str) -> bool {
    return c.values.has(key)
}

// the value of key as text, or `default` if the key is missing
fn get_str(c: *Config, key: str, default: str) -> str {
    return c.values.get_or(key, default)
}

// the value of key as an integer, or `default` if the key is missing or not an integer
fn get_i64(c: *Config, key: str, default: i64) -> i64 {
    x, ok := parse_i64(c.values.get_or(key, ""))
    return if ok { x } else { default }
}

// the value of key as a number, or `default` if the key is missing or not a number
fn get_f64(c: *Config, key: str, default: f64) -> f64 {
    x, ok := parse_f64(c.values.get_or(key, ""))
    return if ok { x } else { default }
}

// the value of key as a boolean (true/yes/on/1 or false/no/off/0, lower case), or `default`
fn get_bool(c: *Config, key: str, default: bool) -> bool {
    match c.values.get_or(key, "") {
        "true", "yes", "on", "1" => true
        "false", "no", "off", "0" => false
        _ => default
    }
}

// ---------- JSON ----------
// the kind of a JSON value
enum JsonKind { JsonNull, JsonBool, JsonNumber, JsonString, JsonArray, JsonObject }

// One value of a parsed JSON document.
//   kind   what the value is
//   num    the number (JsonNumber), or 1.0 / 0.0 for true / false (JsonBool)
//   text   the string (JsonString) or the number as written (JsonNumber)
//   key    the member name if this value is a member of an object
//   items  the elements (JsonArray) or members (JsonObject) in document order
struct Json { kind: JsonKind, num: f64, text: str, key: str, items: []Json }

struct __JsonReader { s: str, i: i64, ok: bool, depth: i64 }

// skips white space and returns the next byte without consuming it (0 at the end)
fn __json_peek(p: *__JsonReader) -> u8 {
    while p.i < len(p.s) {
        c := p.s[p.i]
        if c != ' ' && c != '\n' && c != '\t' && c != '\r' {
            return c
        }
        p.i += 1
    }
    return 0
}

// the value of 4 hex digits at s[i..], or -1
fn __json_hex4(s: str, i: i64) -> i64 {
    if i + 4 > len(s) {
        return -1
    }
    v := 0
    for k in i..i + 4 {
        c := s[k]
        if c >= '0' && c <= '9' {
            v = v * 16 + i64(c - '0')
        } else if (c | 0x20) >= 'a' && (c | 0x20) <= 'f' {
            v = v * 16 + i64(c | 0x20) - 'a' + 10
        } else {
            return -1
        }
    }
    return v
}

// decodes the escapes of a string body; returns false on an invalid escape
fn __json_unescape(raw: str) -> (str, bool) {
    out := alloc[u8](len(raw))
    k := 0
    i := 0
    while i < len(raw) {
        c := raw[i]
        i += 1
        if c != '\\' {
            out[k] = c
            k += 1
            continue
        }
        e := raw[i]
        i += 1
        if e == 'u' {
            cp := __json_hex4(raw, i)
            i += 4
            if cp >= 0xD800 && cp < 0xDC00 && i + 1 < len(raw) && raw[i] == '\\' && raw[i + 1] == 'u' {
                // surrogate pair
                lo := __json_hex4(raw, i + 2)
                if lo >= 0xDC00 && lo < 0xE000 {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    i += 6
                }
            }
            if cp < 0 {
                return ("", false)
            }
            if cp < 0x80 {
                out[k] = u8(cp)
                k += 1
            } else if cp < 0x800 {
                out[k] = u8(0xC0 | cp >> 6)
                out[k + 1] = u8(0x80 | cp & 0x3F)
                k += 2
            } else if cp < 0x10000 {
                out[k] = u8(0xE0 | cp >> 12)
                out[k + 1] = u8(0x80 | (cp >> 6) & 0x3F)
                out[k + 2] = u8(0x80 | cp & 0x3F)
                k += 3
            } else {
                out[k] = u8(0xF0 | cp >> 18)
                out[k + 1] = u8(0x80 | (cp >> 12) & 0x3F)
                out[k + 2] = u8(0x80 | (cp >> 6) & 0x3F)
                out[k + 3] = u8(0x80 | cp & 0x3F)
                k += 4
            }
            continue
        }
        b := match e {
            '"' => '"'
            '\\' => '\\'
            '/' => '/'
            'n' => '\n'
            't' => '\t'
            'r' => '\r'
            'b' => 8
            'f' => 12
            _ => -1
        }
        if b < 0 {
            return ("", false)
        }
        out[k] = u8(b)
        k += 1
    }
    return (out[..k], true)
}

// reads a string starting at the opening quote; a view of the source unless it has escapes
fn __json_string(p: *__JsonReader) -> str {
    start := p.i + 1
    i := start
    escaped := false
    while i < len(p.s) && p.s[i] != '"' {
        if p.s[i] < 0x20 {
            // control characters must be escaped
            p.i = i
            p.ok = false
            return ""
        }
        if p.s[i] == '\\' {
            escaped = true
            i += 1
        }
        i += 1
    }
    if i >= len(p.s) {
        p.ok = false
        return ""
    }
    p.i = i + 1
    if !escaped {
        return p.s[start..i]
    }
    text, ok := __json_unescape(p.s[start..i])
    if !ok {
        p.i = start
        p.ok = false
    }
    return text
}

fn __json_word(p: *__JsonReader, word: str) {
    if starts_with(p.s[p.i..], word) {
        p.i += len(word)
    } else {
        p.ok = false
    }
}

// reads the elements of an array (close = ']') or the members of an object (close = '}')
fn __json_items(p: *__JsonReader, close: u8) -> []Json {
    items := vec[Json]()
    p.i += 1
    if __json_peek(p) == close {
        p.i += 1
        return items.items()
    }
    p.depth += 1
    while p.ok && p.depth <= 200 {
        item: Json
        if close == '}' {
            if __json_peek(p) != '"' {
                break
            }
            item.key = __json_string(p)
            if !p.ok || __json_peek(p) != ':' {
                break
            }
            p.i += 1
        }
        __json_value(p, &item)
        if !p.ok {
            break
        }
        items.push(item)
        c := __json_peek(p)
        if c == close {
            p.i += 1
            p.depth -= 1
            return items.items()
        }
        if c != ',' {
            break
        }
        p.i += 1
    }
    p.ok = false
    return items.items()
}

fn __json_in_number(c: u8) -> bool {
    return (c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E'
}

// true if s has the JSON number syntax: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
fn __json_number_ok(s: str) -> bool {
    i := 0
    n := len(s)
    if i < n && s[i] == '-' {
        i += 1
    }
    if i >= n || !is_digit(s[i]) {
        return false
    }
    if s[i] == '0' {
        i += 1
    } else {
        while i < n && is_digit(s[i]) {
            i += 1
        }
    }
    if i < n && s[i] == '.' {
        i += 1
        if i >= n || !is_digit(s[i]) {
            return false
        }
        while i < n && is_digit(s[i]) {
            i += 1
        }
    }
    if i < n && (s[i] == 'e' || s[i] == 'E') {
        i += 1
        if i < n && (s[i] == '+' || s[i] == '-') {
            i += 1
        }
        if i >= n || !is_digit(s[i]) {
            return false
        }
        while i < n && is_digit(s[i]) {
            i += 1
        }
    }
    return i == n
}

fn __json_value(p: *__JsonReader, out: *Json) {
    c := __json_peek(p)
    if c == '{' {
        out.kind = JsonObject
        out.items = __json_items(p, '}')
    } else if c == '[' {
        out.kind = JsonArray
        out.items = __json_items(p, ']')
    } else if c == '"' {
        out.kind = JsonString
        out.text = __json_string(p)
    } else if c == 't' {
        out.kind = JsonBool
        out.num = 1.0
        __json_word(p, "true")
    } else if c == 'f' {
        out.kind = JsonBool
        __json_word(p, "false")
    } else if c == 'n' {
        __json_word(p, "null")
    } else {
        start := p.i
        while p.i < len(p.s) && __json_in_number(p.s[p.i]) {
            p.i += 1
        }
        out.kind = JsonNumber
        out.text = p.s[start..p.i]
        x, ok := parse_f64(out.text)
        out.num = x
        if !ok || !__json_number_ok(out.text) {
            p.i = start
            p.ok = false
        }
    }
}

fn __json_read(p: *__JsonReader) -> *Json {
    root := new[Json]()
    __json_value(p, root)
    if p.ok && __json_peek(p) != 0 {
        p.ok = false
    }
    return root
}

// parses a JSON document into a tree; (nil, false) if the text is not valid JSON. Strings
// without escapes and number texts are views into `text`, which must stay alive. Allocates
// the tree; wrap in mark()/release() to discard it.
fn json_parse(text: str) -> (*Json, bool) {
    p := __JsonReader{s: text, i: 0, ok: true, depth: 0}
    root := __json_read(&p)
    if !p.ok {
        return (nil, false)
    }
    return (root, true)
}

// 1-based line of the first syntax error in JSON text, or 0 if it is valid (for diagnostics)
fn json_error_line(text: str) -> i64 {
    m := mark()
    p := __JsonReader{s: text, i: 0, ok: true, depth: 0}
    __json_read(&p)
    release(m)
    if p.ok {
        return 0
    }
    line := 1
    for c in text[..min(p.i, len(text))] {
        if c == '\n' {
            line += 1
        }
    }
    return line
}

// The accessors below accept nil and values of the wrong kind, so lookups can be chained
// without checks: root.get("window").get("size").at(0).as_i64(800)

// the member `key` of an object, or nil if v is not an object or has no such member
fn get(v: *Json, key: str) -> *Json {
    if v != nil && v.kind == JsonObject {
        for i in 0..len(v.items) {
            if v.items[i].key == key {
                return &v.items[i]
            }
        }
    }
    return nil
}

// element i of an array (or member i of an object), or nil if there is none
fn at(v: *Json, i: i64) -> *Json {
    if v == nil || i < 0 || i >= len(v.items) {
        return nil
    }
    return &v.items[i]
}

// number of elements of an array or members of an object; 0 for anything else
fn count(v: *Json) -> i64 {
    return if v == nil { 0 } else { len(v.items) }
}

// the string, or `default` if v is nil or not a string
fn as_str(v: *Json, default: str) -> str {
    return if v != nil && v.kind == JsonString { v.text } else { default }
}

// the number, or `default` if v is nil or not a number
fn as_f64(v: *Json, default: f64) -> f64 {
    return if v != nil && v.kind == JsonNumber { v.num } else { default }
}

// the number as an integer (exact for integers written without fraction or exponent,
// otherwise truncated), or `default` if v is nil or not a number
fn as_i64(v: *Json, default: i64) -> i64 {
    if v == nil || v.kind != JsonNumber {
        return default
    }
    x, ok := parse_i64(v.text)
    return if ok { x } else { i64(v.num) }
}

// the boolean, or `default` if v is nil or not a boolean
fn as_bool(v: *Json, default: bool) -> bool {
    return if v != nil && v.kind == JsonBool { v.num != 0.0 } else { default }
}

// true if v is a JSON null (false for nil, i.e. a missing value)
fn is_null(v: *Json) -> bool {
    return v != nil && v.kind == JsonNull
}
