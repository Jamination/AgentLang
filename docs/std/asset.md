# std.asset: files, paths, asset loading, config and JSON

`use std.asset`. Source: `std/asset.al`. Everything goes through raw Linux system calls: a
program using this module stays a static, libc-free executable.

- file and directory operations, path helpers
- `Assets`: loads files relative to a root directory, caches them, and tells when a file
  changed on disk (hot reload)
- `Config`: a reader for `key = value` / INI-style settings files
- `Json`: a small JSON reader that yields a navigable tree

Failures are ordinary results (`false`, `-1`, an empty list, `nil`), never a panic: a missing
file is a situation, not a bug. Paths are relative to the working directory of the process
unless they start with `/`, and are limited to 4095 bytes (longer paths fail with error 36).

**Why it failed.** The functions that open, read, write, create or delete (`read_bytes`,
`write_bytes`, `remove_file`, `remove_dir`, `make_dir`, `list_dir`, and the loader built on
them) record their outcome: right after a failure `io_error()` is the OS error number and
`error_text(io_error())` its text (`no such file or directory`, ...); after a success
`io_error()` is 0. Both are core functions (language reference, "Standard library").

**Allocation.** Functions that return file contents, lists, joined paths or parsed data
allocate from the arena in use (see [mem](mem.md)); wrap temporary work in
`mark()`/`release()`, `frame_begin()`/`frame_end()` or a `Region`. The queries `file_exists`, `is_dir`,
`file_size`, `modified_time` and `changed` do not allocate and are fine to call every frame.

## Files and directories

| Declaration | Description |
|-------------|-------------|
| `file_exists(path str) bool` | True if `path` names an existing file or directory. |
| `is_dir(path str) bool` | True if `path` names a directory. |
| `file_size(path str) i64` | Size in bytes, or -1 if the file does not exist. |
| `modified_time(path str) i64` | Time of the last modification in nanoseconds since 1970, or 0 if the file does not exist. Compare two readings to detect a change. |
| `read_bytes(path str) ([]u8, bool)` | The whole file; `(empty, false)` if it cannot be opened or cannot be read (a directory, for example). One allocation of exactly the file size. Since `str` is `[]u8`, this also reads text. |
| `write_bytes(path str, data []u8) bool` | Creates or replaces the file; `false` on failure. Does not create directories. |
| `remove_file(path str) bool` | Deletes a file. |
| `make_dir(path str) bool` | Creates a directory and any missing parents; true if the directory exists afterwards (also when it existed before). |
| `remove_dir(path str) bool` | Deletes an empty directory. |
| `list_dir(path str) []str` | Names of the entries of a directory, without `.` and `..`, sorted by byte value (so the order is the same on every machine); empty if the directory cannot be read. Names only: join them with the directory to open them. |

Typed data round-trips through the byte views of [mem](mem.md):
`write_bytes(path, as_bytes(vertices))` and `from_bytes[Vertex](data)`.

## Paths

All of these work on text only (no file system access). Except for `path_join` they return
views of their argument and do not allocate.

| Declaration | Description | Examples |
|-------------|-------------|----------|
| `path_join(a str, b str) str` | `a` and `b` with exactly one `/` between them; `b` alone if `a` is empty or `b` is absolute. | `("a", "b")` → `a/b`, `("a/", "b")` → `a/b`, `("", "b")` → `b`, `("a", "/b")` → `/b` |
| `path_dir(p str) str` | Everything before the last `/`. | `a/b/c.png` → `a/b`, `c.png` → empty, `/c` → `/` |
| `path_base(p str) str` | The last component. | `a/b/c.png` → `c.png` |
| `path_ext(p str) str` | Extension of the last component, without the dot. | `a/b/c.png` → `png`, `x.tar.gz` → `gz`, `Makefile` → empty, `.hidden` → empty |
| `path_stem(p str) str` | The last component without its extension. | `a/b/c.png` → `c`, `x.tar.gz` → `x.tar` |

## Asset loader

| Declaration | Description |
|-------------|-------------|
| `struct Assets { root str, cache Map[str, Asset] }` | A root directory and the files loaded from it so far. |
| `struct Asset { data []u8, mtime i64 }` | A cache entry: the bytes and the file's modification time when it was read. |
| `assets_new(root str) Assets` | A loader for the files under `root` (`""` = the working directory). |
| `load(a *Assets, name str) ([]u8, bool)` | The content of `root/name`. The first call reads the file; later calls return the same cached slice without touching the disk. `(empty, false)` if the file cannot be read. |
| `reload(a *Assets, name str) ([]u8, bool)` | Reads the file again and replaces the cache entry. If reading fails, returns `(empty, false)` and keeps the old entry. |
| `changed(a *Assets, name str) bool` | True if `name` was loaded and its file has a different modification time now. One `stat` call, no allocation. |

Names are paths relative to the root (`"levels/one.json"`). Loaded data is shared by everyone
who asks for the same name: treat it as read-only. The cache only grows; data replaced by
`reload` stays in the arena until a release reaches it, so reload during development, not as a
per-frame mechanism.

Hot reload is polling: every so often ask `changed` for the assets you care about, `reload`
those that did and rebuild what was derived from them (textures, parsed configs):

```
if assets.changed("tuning.ini") {
    text, ok := assets.reload("tuning.ini")
    if ok { game.tuning = config_parse(text) }
}
```

## Config files

```
# a comment
title = Star Miner
[video]
width = 1920          ; comments may follow a value after white space
tint = #ff8800        # a '#' directly after other text belongs to the value
label = "  quoted: spaces, # and ; are kept  "
```

A line `[section]` prefixes the keys that follow with `section.` (`video.width`). White space
around keys and values is trimmed. `#` or `;` starts a comment at the beginning of a line or
after white space. A value in double quotes is taken literally. Lines without `=` are ignored.
A key that occurs twice keeps its last value.

| Declaration | Description |
|-------------|-------------|
| `struct Config { values Map[str, str], keys Vec[str] }` | `keys`: every key once, in file order (`c.keys.items()`). `values`: key → text. |
| `config_parse(text str) Config` | Parses config text. Values are views into `text`, which must stay alive as long as the `Config`. |
| `config_load(path str) (Config, bool)` | Reads and parses a file; an empty config and `false` if it cannot be read. |
| `has(c *Config, key str) bool` | True if the key is present. |
| `get_str(c *Config, key str, default str) str` | The value as text. |
| `get_i64(c *Config, key str, default i64) i64` | The value as a decimal integer. |
| `get_f64(c *Config, key str, default f64) f64` | The value as a number. |
| `get_bool(c *Config, key str, default bool) bool` | `true`/`yes`/`on`/`1` or `false`/`no`/`off`/`0` (lower case). |

Every getter returns `default` when the key is missing or its text does not parse as the
requested type, so a settings file only needs to list what differs from the defaults.

## JSON

| Declaration | Description |
|-------------|-------------|
| `enum JsonKind { JsonNull, JsonBool, JsonNumber, JsonString, JsonArray, JsonObject }` | The kind of a value. |
| `struct Json { kind JsonKind, num f64, text str, key str, items []Json }` | One value. `num`: the number, or 1.0/0.0 for true/false. `text`: the string, or the number as written. `key`: the member name when the value is a member of an object. `items`: the elements of an array or the members of an object, in document order, stored contiguously. |
| `json_parse(text str) (*Json, bool)` | Parses a complete document; `(nil, false)` if it is not valid JSON. |
| `json_error_line(text str) i64` | The 1-based line of the first syntax error, or 0 if the text is valid. For error messages after `json_parse` failed. |
| `get(v *Json, key str) *Json` | The member `key` of an object; `nil` if `v` is not an object or has no such member. |
| `at(v *Json, i i64) *Json` | Element `i` of an array (or member `i` of an object); `nil` if out of range. |
| `count(v *Json) i64` | Number of elements or members; 0 for anything else. |
| `as_str(v *Json, default str) str` | The string, or `default` if `v` is not a string. |
| `as_f64(v *Json, default f64) f64` | The number, or `default` if `v` is not a number. |
| `as_i64(v *Json, default i64) i64` | The number as an integer: exact for integer literals (all 64 bits), truncated toward zero otherwise. |
| `as_bool(v *Json, default bool) bool` | The boolean, or `default` if `v` is not a boolean. |
| `is_null(v *Json) bool` | True if `v` is a JSON `null` (false for `nil`, i.e. for a missing value). |

Every accessor accepts `nil` and values of the wrong kind, so a lookup can be written as one
chain and checked once, at the end, through the default:

```
width := root.get("window").get("size").at(0).as_i64(1280)
```

Loops go over `items` (or `count`/`at`): `for i in 0..v.count() { item := v.at(i) ... }`;
members carry their name in `item.key`.

The reader accepts standard JSON (RFC 8259): objects, arrays, strings with all escapes
(`\n`, `\"`, `\uXXXX` including surrogate pairs, decoded to UTF-8), numbers, `true`, `false`,
`null`, nested up to 200 levels. No comments, no trailing commas. Member lookup is a linear
search, which is the fastest choice for the small objects of data files.

Memory: the tree is allocated from the arena. Strings without escapes and number texts are
views into the source text, which therefore must stay alive as long as the tree. To read a
few values and throw the tree away, parse between `mark()` and `release()`.

## Example

```
use std.asset

struct Settings { title str, width i64, height i64, vsync bool, volume f64 }

fn load_settings(a *Assets) Settings {
    text, _ := a.load("settings.ini")            // a missing file gives the defaults below
    c := config_parse(text)
    return Settings{
        title: c.get_str("title", "Untitled"),
        width: c.get_i64("video.width", 1280),
        height: c.get_i64("video.height", 720),
        vsync: c.get_bool("video.vsync", true),
        volume: c.get_f64("audio.volume", 1.0),
    }
}

fn main() {
    // set up a small asset directory (a real game ships these files)
    root := "tmp/asset_example"
    make_dir(path_join(root, "levels"))
    write_bytes(path_join(root, "settings.ini"), "title = Star Miner\n[video]\nwidth = 1920\nvsync = off\n")
    write_bytes(path_join(root, "levels/one.json"), "{\"name\": \"Asteroid Field\", \"size\": [64, 48],\n \"spawns\": [{\"kind\": \"rock\", \"at\": [3, 4]}, {\"kind\": \"ship\", \"at\": [10, 20], \"hp\": 5}]}")

    assets := assets_new(root)
    s := load_settings(&assets)
    print(s.title, s.width, s.height, s.vsync, s.volume)

    for name in list_dir(path_join(root, "levels")) {
        text, ok := assets.load(path_join("levels", name))
        level, valid := json_parse(text)
        if !ok || !valid {
            print(name, "is broken at line", json_error_line(text))
            continue
        }
        size := level.get("size")
        print(path_stem(name), path_ext(name), level.get("name").as_str("?"), size.at(0).as_i64(0), "x", size.at(1).as_i64(0))
        spawns := level.get("spawns")
        for i in 0..spawns.count() {
            sp := spawns.at(i)
            print(" ", sp.get("kind").as_str("?"), "at", sp.get("at").at(0).as_i64(0), sp.get("at").at(1).as_i64(0), "hp", sp.get("hp").as_i64(1))
        }
    }

    // hot reload: poll, and re-read when the file on disk is newer
    sleep_ms(30)
    write_bytes(path_join(root, "settings.ini"), "title = Star Miner 2\n")
    if assets.changed("settings.ini") {
        assets.reload("settings.ini")
        s = load_settings(&assets)
        print("reloaded:", s.title, s.width)
    }

    remove_file(path_join(root, "levels/one.json"))
    remove_file(path_join(root, "settings.ini"))
    remove_dir(path_join(root, "levels"))
    remove_dir(root)
}
```

Output:

```
Star Miner 1920 720 false 1.0
one json Asteroid Field 64 x 48
  rock at 3 4 hp 1
  ship at 10 20 hp 5
reloaded: Star Miner 2 1280
```
