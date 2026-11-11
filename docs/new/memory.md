# Memory: regions, `clone`, builtin names, `Vec` indexing

Reference text for the language reference (`docs/LANGUAGE.md`). Each part says where it
belongs. Every example was compiled and run; the comments show the real output.

---

## Regions (section "Memory", after `mark()` / `release()`)

Memory comes from the **arena in use**. A program starts in the *main arena*. A `Region` is a
further, independent arena: between `enter(&r)` and the matching `leave()` everything that
allocates takes its memory from `r` (`alloc`, `new`, `&T{...}`, slice literals, `Vec`, `Map`,
`fmt`, `concat`, `clone`, every library function), and `reset(&r)` gives all of it back in
one step. Use a region for work whose temporary data should not stay: do the work inside it,
copy the result out with `clone`, reset it.

```
struct Region { ... }            // an arena; the zero value is a valid, empty region
region() Region                  // an empty region (the same as the zero value)
enter(r *Region)                 // allocations now come from r
leave()                          // back to the arena that was in use before the matching enter
reset(r *Region)                 // empties r: everything allocated from it is gone
used(r *Region) i64              // bytes of r in use
region_free(r *Region)           // returns r's memory to the operating system
```

```
struct Token { text str, line i64 }

var scratch Region                       // a global: its address never changes

fn tokenize(src str) Vec[Token] {
    out := vec[Token]()
    for i, w in split(src, ' ') {
        out.push(Token{to_upper(w), i})
    }
    out
}

fn count_long(src str) i64 {
    enter(&scratch)                      // everything below allocates from scratch
    defer { leave() }
    toks := tokenize(src)
    n := 0
    for t in toks {
        if len(t.text) > 3 {
            n += 1
        }
    }
    n
}

fn longest(src str) Token {
    enter(&scratch)
    toks := tokenize(src)
    best := toks[0]
    for t in toks {
        if len(t.text) > len(best.text) {
            best = t
        }
    }
    leave()
    result := clone(best)                // copied into the arena of the caller
    reset(&scratch)                      // now the temporary data may go
    result
}

fn main() {
    for round in 0..1000 {
        count_long("the quick brown fox jumps")
        reset(&scratch)
    }
    print(count_long("the quick brown fox jumps"), used(&scratch) < 4096)   // 3 true
    reset(&scratch)
    print(longest("a bb cccc dd"), used(&scratch))       // Token{text: CCCC, line: 2} 0
    region_free(&scratch)
}
```

Rules:

- **Nesting.** `enter` / `leave` form a stack with the main arena at the bottom; up to 64
  regions can be entered at the same time. `leave()` returns to whatever was in use before
  the matching `enter` (a region or the main arena). `defer { leave() }` right after `enter`
  leaves on every path out of the block.
- **`mark()` / `release(m)` act on the arena in use.** A mark belongs to the arena it was
  taken in; releasing it while another arena is in use does nothing. (A mark taken before the
  first allocation of an arena means "everything in the arena in use".)
- **`reset(&r)`** may be called whether `r` is in use, entered further down the stack, or not
  entered at all. The region keeps its memory and hands it out again; as everywhere, memory
  is zeroed when it is handed out (only the part that was used before is cleared, so a reset
  costs nothing by itself).
- **`used(&r)`** is the number of bytes handed out since the last reset (sizes are rounded up
  to 16). `mem_used()` (std.mem) is the same number for the arena in use.
- **`region_free(&r)`** unmaps the region's memory; `r` is empty afterwards and can be entered
  again. The region must not be entered.
- **Sizes.** A region reserves address space on its first allocation and commits memory only
  as it is used: 16 GiB per region (the main arena: 64 GiB), so thousands of regions can
  exist. If the system refuses the reservation (address-space limit, strict overcommit),
  smaller sizes down to 16 MiB are tried and the region is limited to what it got. A region
  that is never allocated from costs nothing. Exhausting an arena is `panic: out of memory`.
- **A `Region` is used through a pointer** (`&r`, or a `*Region` field). Keep it in a
  variable that outlives its use (a global, a field of a long-lived struct, a local of the
  function that brackets the work). The struct holds the state of the region while it is not
  in use, so **never copy a `Region` that has memory or is entered**: both copies would hand
  out the same memory. Its fields are internal.
- Leaving does not reset: data in a region stays valid after `leave()` until the region is
  reset or freed. That is what makes "leave, `clone` the result, reset" work.

Nested regions, marks and resets:

```
fn main() {
    a := region()
    b := region()
    enter(&a)
    xs := alloc[i64](4)                  // from a
    enter(&b)
    ys := alloc[i64](4)                  // from b
    m := mark()
    alloc[u8](100)
    release(m)                           // mark / release act on b
    leave()
    zs := alloc[i64](4)                  // from a again
    leave()
    ws := alloc[i64](4)                  // from the main arena
    print(used(&a), used(&b))            // 64 32
    reset(&b)                            // ys is gone
    reset(&a)                            // xs and zs are gone
    print(used(&a), used(&b), len(ws))   // 0 0 4
    region_free(&a)
    region_free(&b)
}
```

What to watch (none of this is checked):

- Everything allocated while a region is in use lives in that region, also what library code
  allocates on your behalf. In particular **a `Vec` or `Map` that grows while a region is in
  use moves its storage into that region**, even if it was created elsewhere. Containers
  that must survive belong to code that runs outside the region, or are cloned out.
- Slices, pointers, `Vec`s and `Map`s into a region are invalid after `reset` /
  `region_free` (the next allocation reuses the memory). Copy what must survive with `clone`
  *before* the reset, while the arena that should own the copy is in use.
- `enter` / `leave` must be balanced like brackets; an early `return` between them leaves the
  region entered (use `defer`).

Section "Run-time errors", new rows:

| Situation | Message |
|-----------|---------|
| `enter` of a region that is already entered | `panic: enter: this region is already entered` |
| more than 64 regions entered | `panic: enter: more than 64 regions are entered (is a leave() missing?)` |
| `leave()` without `enter` | `panic: leave without enter` |
| `region_free` of an entered region | `panic: region_free: this region is entered (leave() first)` |

Section "Standard library", the memory line becomes:

```
alloc[T](n i64) []T            new[T]() *T                    mark() i64       release(m i64)
region() Region                enter(r *Region)               leave()          reset(r *Region)
used(r *Region) i64            region_free(r *Region)         clone(x) T       // builtin
```

Section "Unsafe corners", add: using memory of a region after `reset()` / `region_free()`;
copying a `Region` that holds memory.

The relation of `Region` to `Arena` (std.mem) and to `frame_begin()` / `frame_end()` is
described in `docs/std/mem.md` ("Region, Arena, mark / release: which one").

---

## `clone(x)` (section "Builtin functions", and a paragraph in "Memory")

Builtin table row:

| Builtin | Meaning |
|---------|---------|
| `clone(x) T` | an independent deep copy of `x` (any type), allocated from the arena in use |

Assignment, argument passing and returning copy a value but share the storage behind the
slices inside it (and so behind every `str`, `Vec` and `Map`). `clone(x)` returns a value
that shares nothing with `x`:

| Type of `x` | Result |
|-------------|--------|
| integers, floats, `bool`, vectors, `quat`, `mat4`, enums without data | the value |
| `str`, `[]T` | a new slice of the same length with cloned elements |
| `[N]T`, tuples, structs | each element / field cloned |
| enums with data | the same variant with cloned payload |
| `Vec[T]` | a `Vec` of the same length with cloned elements; the capacity of the copy is its length (the spare capacity of `x` is uninitialised memory and is not read) |
| `Map[K, V]` | an independent map with cloned keys and values |
| `*T`, function values | **the pointer itself: what it points to is shared** |

```
struct Node { name str, kids []Node }
struct Doc { title str, root Node, words Vec[str], index Map[str, i64], owner *Node }

fn main() {
    a := []i64{1, 2, 3}
    b := a                               // shares the elements
    c := clone(a)                        // its own elements
    b[0] = 10
    c[1] = 20
    print(a, b, c)                       // [10, 2, 3] [10, 2, 3] [1, 20, 3]

    d := Doc{title: "t", root: Node{"r", []Node{Node{"k", nil}}}, words: vec[str](), index: map[str, i64]()}
    d.words.push("w")
    d.index.set("w", 0)
    d.owner = &d.root
    e := clone(d)                        // title, root (recursively), words and index are copied
    e.root.kids[0].name = "changed"
    e.words.push("x")
    e.index.set("x", 1)
    print(d.root.kids[0].name, d.words.len, d.index.len)   // k 1 1
    print(e.root.kids[0].name, e.words.len, e.index.len)   // changed 2 2
    print(e.owner == d.owner)            // true: a pointer is copied, not what it points to

    s := "text".clone()                  // method form; a writable copy of a literal
    s[0] = 'n'
    print(s)                             // next
}
```

- The copy is allocated from the arena in use **at the call**: to move a result out of a
  region, `leave()` first (or enter the destination), then `clone`.
- `x.clone()` is the same as `clone(x)`. With a pointer `p`, `clone(p)` and `p.clone()` copy
  the pointer; write `clone(*p)` for a copy of the value it points to.
- Data that refers to itself through slices (`struct Node { kids []Node }`, `enum Tree {
  Leaf(i64), Fork([]Tree) }`) is copied completely. Data linked through pointers is not
  followed (a pointer may be shared or cyclic on purpose): copy such structures by hand, or
  give the type its own `clone` function (next section).
- A string literal is read-only; its clone is ordinary writable memory.
- Cost: a type without any slice inside is a plain copy (no call, no allocation); a slice (or
  `Vec`) whose elements contain no slice is one allocation and one memory copy; otherwise one
  allocation per slice plus the work for the elements.
- A user struct that happens to be named `Vec` or `Map` is an ordinary struct: its fields are
  cloned one by one (a `buf` slice with its full length).

---

## Builtins and declared functions with the same name (section "Declarations", after "Overloading")

- A function may have the name of a builtin (`len`, `ptr`, `clone`, `hash`, `print`, `fmt`,
  `sqrt`, ...). The builtin stays available: a call uses the **declared functions first, by
  the overloading rules**; when none of them accepts the arguments (their number or their
  types), the **builtin** is used. A declared function therefore extends a builtin to new
  argument types, or replaces it for exactly the types it declares.
- The arguments are evaluated once, from left to right, before the function is chosen. (One
  visible consequence: the builtin `print` / `put` normally writes each argument as soon as it
  is evaluated; when the program declares its own `print`, a `print` call with as many
  arguments as a declared `print` takes evaluates all of them first.)
- This holds for method calls too: `x.f(a)` tries the declared `f` and then the builtin `f`.
- Library code is not affected by such declarations: inside the library, `len`, `hash`, `ptr`,
  ... always mean the builtins (for example `Map` hashes its keys with the builtin `hash`
  even if the program declares a `hash` of its own).
- When exactly one function of that name is declared and it is not generic, its parameter
  types are the expected types of the arguments, as in any call (so `f(Some(1))` builds an
  `Opt[u8]` for `fn f(o Opt[u8])`). An argument that cannot be built for that type is an
  error at the argument, not a reason to use the builtin.

```
struct Types { n i64 }
struct Money { cents i64 }

fn ptr(self *Types, t i64) i64 { t + self.n }      // next to the builtin ptr(slice)
fn len(m Money) i64 { m.cents }                    // next to the builtin len
fn print(m Money) { put("$", m.cents / 100, ".", m.cents % 100, "\n") }
fn clone(t Types) Types { Types{t.n + 1} }         // replaces the builtin for Types only

fn main() {
    ty := Types{1}
    m := Money{250}
    xs := []i64{7, 8}
    print(ty.ptr(4), ptr(xs)[1])         // 5 8
    print(len(m), len(xs), m.len(), xs.len())      // 250 2 250 2
    print(m)                             // $2.50      (declared)
    print(m, xs)                         // Money{cents: 250} [7, 8]   (builtin: two arguments)
    print(clone(ty).n, clone(m).cents)   // 2 250
}
```

Section "Expressions", method-call paragraph, add:

Method-call syntax also works for the builtins that take a value as their first argument:
`len`, `clone`, `hash`, `ptr`, `sqrt`, `fabs`, `fmin`, `fmax`, `popcnt`, `ctz`, `clz`,
`bswap`, `rotl`, `rotr` (`s.len()`, `x.clone()`, `key.hash()`). The receiver is passed as it
is (no automatic `&` or `*`). The other builtins (`print`, `put`, `fmt`, `panic`, `sizeof`,
`cast`, `mkslice`, `syscall`, `memcopy`, `memfill`, `embed`) have no method form.

Diagnostics: when neither a declared function nor the builtin accepts a call, the message of
the builtin is shown and names the declared candidates, e.g.

```
error: `len` needs a slice, array, str or Vec, found i64 (the declared functions do not accept these arguments either: len(*T))
```

---

## `Vec`: indexing, slicing, iteration (sections "Expressions", "Statements", "Standard library")

For the library's `Vec[T]`, and for a pointer to one (`*Vec[T]`):

```
v[i]                    // element i as a place: read, v[i] = x, v[i] += x, &v[i], v[i].field = x
v[a..b]  v[..b]  v[a..]  v[..]      // slices of the live elements (they share the storage)
len(v)   v.len          // the number of elements
for x in v { ... }      // the live elements, copied into x
for i, x in v { ... }   // index and element
```

- `v[i]` is checked against the **length** `v.len` (index out of range stops the program with
  `panic: index out of bounds at file:line`), not against the capacity, and `v[a..b]` requires
  `a <= b <= v.len`. `v.buf[i]` remains available: it addresses the buffer including the
  spare capacity and is only checked against the capacity.
- With a pointer `p *Vec[T]`, `p[i]`, `p[a..b]`, `len(p)` and `for x in p` act on the `Vec`
  (a pointer to a struct is never indexed as an array).
- `for x in v` reads the length and the buffer once, when the loop starts: elements pushed
  during the loop are not visited, and after a push that grew the `Vec` the loop continues
  over the old buffer. `for i in 0..v.len { ... v[i] ... }` re-reads both on every access.
- A slice `v[a..b]` and a pointer `&v[i]` refer to the current buffer; they stay valid until a
  `push` / `reserve` that grows the `Vec` (then they refer to the old buffer, which is still
  allocated but no longer the `Vec`'s).
- Only the library's `Vec` is treated this way. A user struct named `Vec` is an ordinary
  struct (`cannot index Vec`).

```
struct P { x i64, y i64 }

fn sum(v *Vec[i64]) i64 {
    s := 0
    for i in 0..len(v) {                 // v is a pointer: v[i] indexes the Vec
        s += v[i]
    }
    s
}

fn main() {
    v := vec[i64]()
    for i in 0..5 {
        v.push(i * i)
    }
    v[0] = 7                             // assign
    v[1] += 10                           // compound assign
    p := &v[2]                           // address of an element (until the Vec grows)
    *p = 40
    print(v[3], len(v), v[1..3], v[..2], v[3..], sum(&v))   // 9 5 [11, 40] [7, 11] [9, 16] 83
    for x in v {                         // the live elements
        put(x, " ")
    }
    print()                              // 7 11 40 9 16
    for i, x in v {
        if x > 30 {
            print(i, x)                  // 2 40
        }
    }
    ps := vec[P]()
    ps.push(P{1, 2})
    ps[0].y = 20                         // field of an element
    print(ps[0])                         // P{x: 1, y: 20}
}
```

Places to update in the reference:

- "Statements": `for x in items { ... }   // elements of a slice, array, str or Vec`.
- "Expressions": "`a[i]` works on slices, arrays, `Vec`s and pointers to them. `s.len` and
  `len(s)` give the length of a slice, array, string or `Vec`."
- "Builtin functions": `len(x)`: length of a slice, array, string or `Vec`.
- "Standard library", Vec lines:

```
// Vec[T]: growable array
v := vec[i64]()        v.push(x)        v.pop()        v.len  len(v)
v[i]                   v[a..b]          for x in v     for i, x in v          // the live elements
v.reserve(n)           v.items()  // = v[..]           v.buf[i]               // the raw buffer (capacity)
```

### Bounds checks in loops (section "Run-time errors", the paragraph on loops)

A check that cannot fail is removed: in `for i in k..n` (constant `k >= 0`) an access `a[i]`
needs no check when `n` is the length of `a` itself (`for i in 0..len(s) { ... s[i] ... }`,
`for i in 0..v.len { ... v[i] ... }`), whatever else the loop does. For a `Vec` the length
lives in memory: it is known to be unchanged only if the loop contains no call and no store
that could reach it (a store of an `i64`/`u64`/8-bit element may, as far as the compiler can
tell). Where that matters, take the slice once (`xs := v[..]`) or use `for x in v`.
