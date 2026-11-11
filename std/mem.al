// std.mem: memory building blocks for games on top of the program arena. Core module:
// available in every program.
//
// Allocation in AL is bump allocation from the arena in use: alloc/new bump a pointer,
// mark()/release(m) give back everything allocated since the mark. A program starts in the
// main arena; a Region (language reference, "Memory") is a further arena that enter()/leave()
// put in use. The pieces here structure the arena in use for a game:
//   - frame_begin()/frame_end(): scratch memory that lives for one frame (or one nested scope)
//   - Arena: a fixed block with its own cursor and explicit allocation calls, for data whose
//     lifetime does not nest with the frame and level marks (it stays valid across releases
//     of marks taken after it)
//   - Pool[T]: objects created and destroyed individually, addressed by generational handles
//   - Ring[T], SparseSet: fixed queues and integer sets without per-operation allocation
// Typical layout: allocate long-lived state first, take `level := mark()` and load the level,
// wrap every frame in frame_begin()/frame_end(), and `release(level)` to unload.

// n kibibytes in bytes
kb :: (n: i64) -> i64 {
    return n * 1024
}

// n mebibytes in bytes
mb :: (n: i64) -> i64 {
    return n * 1048576
}

// bytes in use in the arena that allocations currently come from: the main arena, or the
// innermost entered Region (compare per frame to find leaks)
mem_used :: () -> i64 {
    return __heap_cur - __heap_base
}

// the memory of a slice as bytes (a view, nothing is copied)
as_bytes[T] :: (s: []T) -> []u8 {
    return mkslice[u8](ptr(s), len(s) * sizeof[T]())
}

// bytes reinterpreted as a slice of T (a view; trailing bytes that do not fill a T are dropped)
from_bytes[T] :: (b: []u8) -> []T {
    return mkslice[T](ptr(b), len(b) / sizeof[T]())
}

// sets the value p points to to all zero bytes
zero[T] :: (p: *T) {
    memfill(p, 0, sizeof[T]())
}

// sets every element of s to all zero bytes
zero[T] :: (s: []T) {
    memfill(ptr(s), 0, len(s) * sizeof[T]())
}

// ---------- frame scratch memory ----------
__frame_marks: [32]i64
__frame_arenas: [32]*Region
__frame_depth: i64

// opens a scratch scope: everything allocated from the arena in use until the matching
// frame_end() is temporary. Scopes nest up to 32 deep. A scope belongs to the arena it was
// opened in: enter()/leave() calls inside it must be balanced before frame_end().
frame_begin :: () {
    assert __frame_depth < 32, "frame_begin: nested too deeply (missing frame_end?)"
    __frame_marks[__frame_depth] = mark()
    __frame_arenas[__frame_depth] = __region_top()
    __frame_depth += 1
}

// closes the innermost scratch scope and releases what was allocated inside it
frame_end :: () {
    assert __frame_depth > 0, "frame_end without frame_begin"
    __frame_depth -= 1
    assert __frame_arenas[__frame_depth] == __region_top(), "frame_end: the arena in use is not the one of the matching frame_begin (unbalanced enter/leave?)"
    release(__frame_marks[__frame_depth])
}

// ---------- Arena ----------
// A fixed-size block with its own bump cursor. Allocation is zero-initialized and 16-byte
// aligned like the program arena; running out of space is a programming error (panic).
Arena :: struct { base: i64, cur: i64, end: i64, dirty: i64 }

// an arena of `bytes` bytes carved from the program arena (it lives as long as that memory:
// releasing a mark taken before arena_new() frees the whole arena)
arena_new :: (bytes: i64) -> Arena {
    p := cast[i64](ptr(alloc[u8](bytes)))
    return Arena{base: p, cur: p, end: p + bytes, dirty: p}
}

// an arena over caller-provided storage, for example a global `buf: [65536]u8`
arena_of :: (buf: []u8) -> Arena {
    p := (cast[i64](ptr(buf)) + 15) & ~15
    e := cast[i64](ptr(buf)) + len(buf)
    return Arena{base: p, cur: p, end: max(e, p), dirty: e}
}

__arena_take :: (a: *Arena, bytes: i64) -> i64 {
    n := (bytes + 15) & ~15
    p := a.cur
    if bytes < 0 || n > a.end - p {
        panic("arena exhausted")
    }
    a.cur = p + n
    // only memory that was handed out before can hold old data
    if p < a.dirty {
        memfill(p, 0, min(a.dirty - p, n))
    }
    return p
}

// n zeroed elements from the arena
alloc[T] :: (a: *Arena, n: i64) -> []T {
    return mkslice[T](__arena_take(a, n * sizeof[T]()), n)
}

// one zeroed T from the arena
new[T] :: (a: *Arena) -> *T {
    return cast[*T](__arena_take(a, sizeof[T]()))
}

// the arena's current position, for release()
mark :: (a: *Arena) -> i64 {
    return a.cur
}

// gives back everything allocated from the arena since mark() returned m
release :: (a: *Arena, m: i64) {
    if m >= a.base && m < a.cur {
        a.dirty = max(a.dirty, a.cur)
        a.cur = m
    }
}

// gives back everything allocated from the arena
reset :: (a: *Arena) {
    release(a, a.base)
}

// bytes handed out
used :: (a: *Arena) -> i64 {
    return a.cur - a.base
}

// bytes still available
remaining :: (a: *Arena) -> i64 {
    return a.end - a.cur
}

// ---------- Pool ----------
// Names a slot of a Pool. `gen` tells apart successive objects in the same slot, so a handle
// to a removed object is detected instead of reaching its successor. The zero Handle is never
// valid and serves as "none".
Handle :: struct { idx: u32, gen: u32 }

// Object pool: slots are reused through a free list and never move, so pointers from get()
// stay valid until that object is removed (or, for a growable pool, until the pool grows).
//   len   number of live objects
//   used  number of slots that have ever been occupied: iterate 0..used with is_live()
Pool[T] :: struct { items: []T, gens: []u32, free: []u32, len: i64, used: i64, nfree: i64, growable: bool }

// a pool with room for exactly `cap` objects; allocates once, insert() never allocates
pool_new[T] :: (cap: i64) -> Pool[T] {
    return Pool[T]{items: alloc[T](cap), gens: alloc[u32](cap), free: alloc[u32](cap)}
}

// a pool that doubles its storage when full (insert() then allocates and moves the objects;
// the old storage stays in the arena until it is released)
pool_growable[T] :: (cap: i64) -> Pool[T] {
    p := pool_new[T](cap)
    p.growable = true
    return p
}

// doubles the storage; only called when the free list is empty, so `free` starts afresh
__pool_grow[T] :: (p: *Pool[T]) {
    cap := max(len(p.items) * 2, 8)
    items := alloc[T](cap)
    gens := alloc[u32](cap)
    copy(items, p.items)
    copy(gens, p.gens)
    p.items = items
    p.gens = gens
    p.free = alloc[u32](cap)
}

// stores v and returns its handle; the zero Handle if a fixed-capacity pool is full
insert[T] :: (p: *Pool[T], v: T) -> Handle {
    i: i64
    if p.nfree > 0 {
        p.nfree -= 1
        i = i64(p.free[p.nfree])
    } else {
        if p.used == len(p.items) {
            if !p.growable {
                return Handle{}
            }
            __pool_grow(p)
        }
        i = p.used
        p.used += 1
    }
    // generations are odd while the slot is occupied
    p.gens[i] += 1
    p.items[i] = v
    p.len += 1
    return Handle{u32(i), p.gens[i]}
}

// true if h names an object that is still in the pool
is_valid[T] :: (p: *Pool[T], h: Handle) -> bool {
    return i64(h.idx) < p.used && p.gens[i64(h.idx)] == h.gen && h.gen & 1 == 1
}

// the object h names, or nil if it was removed (stale handle)
get[T] :: (p: *Pool[T], h: Handle) -> *T {
    if !is_valid(p, h) {
        return nil
    }
    return &p.items[i64(h.idx)]
}

// removes the object h names; false if the handle was stale
remove[T] :: (p: *Pool[T], h: Handle) -> bool {
    if !is_valid(p, h) {
        return false
    }
    p.gens[i64(h.idx)] += 1
    p.free[p.nfree] = h.idx
    p.nfree += 1
    p.len -= 1
    return true
}

// true if slot i (0 <= i < p.used) holds an object; the object is p.items[i]
is_live[T] :: (p: *Pool[T], i: i64) -> bool {
    return p.gens[i] & 1 == 1
}

// the handle of the object in slot i (meaningful only if is_live(p, i))
handle_at[T] :: (p: *Pool[T], i: i64) -> Handle {
    return Handle{u32(i), p.gens[i]}
}

// removes every object; all handles become stale, the capacity is kept
clear[T] :: (p: *Pool[T]) {
    for i in 0..p.used {
        p.gens[i] += p.gens[i] & 1
    }
    p.len = 0
    p.used = 0
    p.nfree = 0
}

// ---------- Ring ----------
// Fixed-capacity FIFO queue (ring buffer): events, input history, audio blocks, trails.
//   len  number of queued elements; the capacity is len(r.buf)
Ring[T] :: struct { buf: []T, head: i64, len: i64 }

// an empty ring with room for `cap` elements; allocates once
ring_new[T] :: (cap: i64) -> Ring[T] {
    return Ring[T]{buf: alloc[T](cap)}
}

inline __ring_slot[T] :: (r: *Ring[T], i: i64) -> i64 {
    k := r.head + i
    return if k >= len(r.buf) { k - len(r.buf) } else { k }
}

// appends x at the back; false (and nothing stored) if the ring is full
push[T] :: (r: *Ring[T], x: T) -> bool {
    if r.len == len(r.buf) {
        return false
    }
    r.buf[__ring_slot(r, r.len)] = x
    r.len += 1
    return true
}

// appends x at the back, dropping the oldest element if the ring is full ("keep the last N")
push_overwrite[T] :: (r: *Ring[T], x: T) {
    if r.len == len(r.buf) {
        r.head = __ring_slot(r, 1)
        r.len -= 1
    }
    r.buf[__ring_slot(r, r.len)] = x
    r.len += 1
}

// removes and returns the oldest element; (zero value, false) if the ring is empty
pop[T] :: (r: *Ring[T]) -> (T, bool) {
    if r.len == 0 {
        none: T
        return (none, false)
    }
    x := r.buf[r.head]
    r.head = __ring_slot(r, 1)
    r.len -= 1
    return (x, true)
}

// the i-th oldest element (0 = front), 0 <= i < r.len
at[T] :: (r: *Ring[T], i: i64) -> T {
    assert i >= 0 && i < r.len, "Ring.at: index out of range"
    return r.buf[__ring_slot(r, i)]
}

// true if push() would fail
is_full[T] :: (r: *Ring[T]) -> bool {
    return r.len == len(r.buf)
}

// removes all elements
clear[T] :: (r: *Ring[T]) {
    r.head = 0
    r.len = 0
}

// ---------- SparseSet ----------
// Set of small non-negative integers (entity indices, tile ids) with O(1) insert, remove and
// membership test and a dense, contiguous list of members for iteration.
//   len  number of members; the members are dense[0..len] in unspecified order
SparseSet :: struct { dense: []u32, sparse: []u32, len: i64 }

// an empty set sized for ids below `cap`; it grows (allocating) when a larger id is inserted
sparse_set :: (cap: i64) -> SparseSet {
    return SparseSet{dense: alloc[u32](cap), sparse: alloc[u32](cap)}
}

// position of id in the dense list, or -1 if it is not a member
index_of :: (s: *SparseSet, id: u32) -> i64 {
    if i64(id) >= len(s.sparse) {
        return -1
    }
    i := i64(s.sparse[i64(id)])
    return if i < s.len && s.dense[i] == id { i } else { -1 }
}

// true if id is a member
has :: (s: *SparseSet, id: u32) -> bool {
    return index_of(s, id) >= 0
}

__sparse_grow :: (a: []u32, need: i64) -> []u32 {
    b := alloc[u32](max(len(a) * 2, max(need, 8)))
    copy(b, a)
    return b
}

// adds id and returns its position in the dense list (also when it was a member already)
insert :: (s: *SparseSet, id: u32) -> i64 {
    i := index_of(s, id)
    if i >= 0 {
        return i
    }
    if i64(id) >= len(s.sparse) {
        s.sparse = __sparse_grow(s.sparse, i64(id) + 1)
    }
    if s.len == len(s.dense) {
        s.dense = __sparse_grow(s.dense, s.len + 1)
    }
    i = s.len
    s.dense[i] = id
    s.sparse[i64(id)] = u32(i)
    s.len += 1
    return i
}

// removes id by moving the last member into its place. Returns the dense position that was
// refilled, or -1 if id was not a member; data kept in a parallel array follows with
// `data[i] = data[s.len]`.
remove :: (s: *SparseSet, id: u32) -> i64 {
    i := index_of(s, id)
    if i < 0 {
        return -1
    }
    s.len -= 1
    last := s.dense[s.len]
    s.dense[i] = last
    s.sparse[i64(last)] = u32(i)
    return i
}

// the members as a slice (a view; valid until the set changes)
items :: (s: *SparseSet) -> []u32 {
    return s.dense[..s.len]
}

// removes all members
clear :: (s: *SparseSet) {
    s.len = 0
}
