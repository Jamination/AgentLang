// Type table: interned semantic types, layout, scalar leaves.

enum TyK {
    Err,
    Unit,
    Bool,
    Int(i64, bool), // bits, signed
    F64,
    F32,
    Vec(i64), // vec2 / vec3 / vec4: f32 lanes
    Quat,
    Mat4, // four vec4 columns
    Ptr(i64),
    Slice(i64),
    Array(i64, i64),
    Struct(i64),
    Enum(i64),
    Tuple(Vec[i64]),
    Fn(Vec[i64], i64),
    Never,
}

const T_ERR = 0
const T_UNIT = 1
const T_BOOL = 2
const T_I8 = 3
const T_I16 = 4
const T_I32 = 5
const T_I64 = 6
const T_U8 = 7
const T_U16 = 8
const T_U32 = 9
const T_U64 = 10
const T_F64 = 11
const T_F32 = 12
const T_STR = 13
const T_NEVER = 14
const T_VEC2 = 15
const T_VEC3 = 16
const T_VEC4 = 17
const T_QUAT = 18
const T_MAT4 = 19

struct StructInfo {
    name: str
    decl: i64
    targs: Vec[i64]
    fields: Vec[(str, i64)]
    offsets: Vec[i64]
    size: i64
    align: i64
    // 0 = layout pending, 1 = in progress, 2 = done, 3 = the fields are not known yet
    // (the type is being instantiated; its size reads as 0 until then)
    state: i64
}

// The tag of an enum is a u32 (ENUM_TAG bytes, the IR type I32: the size of a C `int`); the
// payloads of a variant follow it at their natural alignment, as the fields of a struct whose
// first field is the tag. An enum without data is just the tag.
struct EnumInfo {
    name: str
    decl: i64
    targs: Vec[i64]
    variants: Vec[(str, Vec[i64])]
    simple: bool
    size: i64
    align: i64
    state: i64
    // an enum with data, once laid out: the runs of bytes its payloads occupy (start << 32 |
    // end), which a copy reads and writes besides the tag (`piece`)
    runs: Vec[i64]
}

struct Leaf {
    off: i64
    t: T
    alias: i64
}

struct Types {
    kinds: Vec[TyK]
    // kind -> type id: pointers and slices by their element type (ptr_of / slice_of: id, or
    // 0 for not yet), tuples and function types by their type lists (`lists`: the kind's tag,
    // then the types), every other kind by (tag, a, b) (`small`, see key3)
    ptr_of: Vec[i64]
    slice_of: Vec[i64]
    small: Map[(i64, i64, i64), i64]
    lists: Map[[]i64, i64]
    structs: Vec[StructInfo]
    enums: Vec[EnumInfo]
    field_ids: Map[(i64, i64), i64]
    next_field_id: i64
    layout_errors: Vec[str]
    // per type: nesting depth and size of the type expression (saturating), to stop
    // generic instantiations that build ever larger types
    shape: Vec[(i64, i64)]
    // tuple type -> (size, align): computed once (recomputing nested tuples is exponential)
    tuple_layout: Map[i64, (i64, i64)]
    // structs and enums whose fields are being resolved (state 3): while there are any,
    // layouts may still change and nothing is cached in the tables below
    instantiating: i64
    // per type: its leaves (leaf_list) and leaf_count, once known (leaf_known / -1)
    leaf_cache: Vec[Vec[Leaf]]
    leaf_known: Vec[bool]
    count_cache: Vec[i64]
}

const AK_ANY = 0
priv const AK_I16 = 1
priv const AK_I32 = 2
const AK_I64 = 3
priv const AK_F64 = 4
const AK_PTR = 5
priv const AK_F32 = 6
const AK_VEC = 7
// enum tags (enums without data; tags of enums with data are read with AK_ANY)
priv const AK_TAG = 8

fn types_may_alias_class(a: i64, b: i64) -> bool {
    ka := a & 15
    kb := b & 15
    if ka == AK_ANY || kb == AK_ANY {
        return true
    }
    if ka != kb {
        return false
    }
    fa := a >> 4
    fb := b >> 4
    return fa == fb || fa == 0 || fb == 0
}

// the key of a kind without a type list in `Types.small`: its variant and payload
priv fn key3(k: *TyK) -> (i64, i64, i64) {
    return match *k {
        Err => (0, 0, 0)
        Unit => (1, 0, 0)
        Bool => (2, 0, 0)
        Int(b, s) => (3, b, i64(s))
        F64 => (4, 0, 0)
        F32 => (5, 0, 0)
        Vec(n) => (6, n, 0)
        Quat => (7, 0, 0)
        Mat4 => (8, 0, 0)
        Ptr(t) => (9, t, 0)
        Slice(t) => (10, t, 0)
        Array(t, n) => (11, t, n)
        Struct(s) => (12, s, 0)
        Enum(e) => (13, e, 0)
        Never => (16, 0, 0)
        Tuple(_), Fn(_, _) => (-1, 0, 0)
    }
}

// the key of a tuple or function type in `Types.lists`
priv fn key_list(k: *TyK) -> []i64 {
    match *k {
        Tuple(v) => {
            l := alloc[i64](v.len + 1)
            l[0] = 14
            copy(l[1..], v.items())
            return l
        }
        Fn(p, r) => {
            l := alloc[i64](p.len + 2)
            l[0] = 15
            copy(l[1..], p.items())
            l[p.len + 1] = r
            return l
        }
        _ => return nil
    }
}

fn types_new() -> Types {
    t := Types{
        kinds: vec[TyK](),
        small: map[(i64, i64, i64), i64](),
        lists: map[[]i64, i64](),
        structs: vec[StructInfo](),
        enums: vec[EnumInfo](),
        field_ids: map[(i64, i64), i64](),
        next_field_id: 1,
        layout_errors: vec[str](),
        shape: vec[(i64, i64)](),
        tuple_layout: map[i64, (i64, i64)](),
    }
    t.intern(Err)
    t.intern(Unit)
    t.intern(Bool)
    t.intern(Int(8, true))
    t.intern(Int(16, true))
    t.intern(Int(32, true))
    t.intern(Int(64, true))
    t.intern(Int(8, false))
    t.intern(Int(16, false))
    t.intern(Int(32, false))
    t.intern(Int(64, false))
    t.intern(F64)
    t.intern(F32)
    s := t.intern(Slice(T_U8))
    assert s == T_STR
    n := t.intern(Never)
    assert n == T_NEVER
    t.intern(Vec(2))
    t.intern(Vec(3))
    t.intern(Vec(4))
    t.intern(Quat)
    t.intern(Mat4)
    assert t.intern(Mat4) == T_MAT4
    return t
}

fn intern(self: *Types, k: TyK) -> i64 {
    match k {
        Ptr(e) if e < self.ptr_of.len && self.ptr_of[e] != 0 => return self.ptr_of[e]
        Slice(e) if e < self.slice_of.len && self.slice_of[e] != 0 => return self.slice_of[e]
        _ => {}
    }
    k3 := key3(&k)
    kl: []i64 = nil
    if k3.0 < 0 {
        kl = key_list(&k)
        t, found := self.lists.get(kl)
        if found {
            return t
        }
    } else {
        t, found := self.small.get(k3)
        if found {
            return t
        }
    }
    id := self.kinds.len
    // type numbers fit in 32 bits (like every other id space of the compiler)
    assert id < 0x7FFFFFFF, "types: too many types"
    self.kinds.push(clone(k))
    if k3.0 < 0 {
        self.lists.set(kl, id)
    } else {
        self.small.set(k3, id)
    }
    match k {
        Ptr(e) => {
            if self.ptr_of.len <= e {
                self.ptr_of.resize(e + 1 + self.kinds.len, 0)
            }
            self.ptr_of[e] = id
        }
        Slice(e) => {
            if self.slice_of.len <= e {
                self.slice_of.resize(e + 1 + self.kinds.len, 0)
            }
            self.slice_of[e] = id
        }
        _ => {}
    }
    kids := vec[i64]()
    match k {
        Ptr(t), Slice(t), Array(t, _) => kids.push(t)
        Tuple(v) => kids.extend(v.items())
        Fn(p, r) => {
            kids.extend(p.items())
            kids.push(r)
        }
        Struct(s) => kids.extend(self.structs[s].targs.items())
        Enum(e) => kids.extend(self.enums[e].targs.items())
        _ => {}
    }
    depth := 0
    size := 1
    for c in kids {
        depth = max(depth, self.shape[c].0 + 1)
        size = min(size + self.shape[c].1, 1 << 30)
    }
    self.shape.push((depth, size))
    return id
}

// the type is nested too deeply to be a type argument (a generic that instantiates itself
// with ever larger types)
fn too_deep(self: *Types, t: i64) -> bool {
    return self.shape[t].0 > 40 || self.shape[t].1 > 4000
}

fn k(self: *Types, t: i64) -> TyK {
    return self.kinds[t]
}

fn is_float(self: *Types, t: i64) -> bool {
    return t == T_F64 || t == T_F32
}

// vec2 / vec3 / vec4 / quat: the number of f32 lanes
fn vec_lanes(self: *Types, t: i64) -> Opt[i64] {
    match self.k(t) {
        Vec(n) => Some(n)
        Quat => Some(4)
        _ => None
    }
}

// the pointer type to `t` (not named `ptr`: that would hide the builtin for a *Types)
fn ptr_to(self: *Types, t: i64) -> i64 {
    return self.intern(Ptr(t))
}

fn slice(self: *Types, t: i64) -> i64 {
    return self.intern(Slice(t))
}

fn is_int(self: *Types, t: i64) -> bool {
    match self.k(t) {
        Int(_, _) => true
        _ => false
    }
}

fn is_signed(self: *Types, t: i64) -> bool {
    match self.k(t) {
        Int(_, s) => s
        _ => false
    }
}

fn is_scalar(self: *Types, t: i64) -> bool {
    match self.k(t) {
        Bool, F64, F32, Quat, Int(_, _), Vec(_), Ptr(_), Fn(_, _) => true
        Enum(e) => self.enums[e].simple
        _ => false
    }
}

priv fn names(self: *Types, v: Vec[i64]) -> str {
    parts := vec[str]()
    for t in v {
        parts.push(self.name(t))
    }
    return join(parts.items(), ", ")
}

fn name(self: *Types, t: i64) -> str {
    match self.k(t) {
        Err => "<error>"
        Unit => "()"
        Never => "never"
        Bool => "bool"
        Int(b, s) => fmt(if s { "i" } else { "u" }, b)
        F64 => "f64"
        F32 => "f32"
        Vec(n) => fmt("vec", n)
        Quat => "quat"
        Mat4 => "mat4"
        Ptr(e) => concat("*", self.name(e))
        Slice(T_U8) => "str"
        Slice(e) => concat("[]", self.name(e))
        Array(e, n) => fmt("[", n, "]", self.name(e))
        Struct(s) => self.structs[s].name
        Enum(s) => self.enums[s].name
        Tuple(v) => fmt("(", names(self, v), ")")
        Fn(p, T_UNIT) => fmt("fn(", names(self, p), ")")
        Fn(p, r) => fmt("fn(", names(self, p), ") -> ", self.name(r))
    }
}

priv fn layout_fields(self: *Types, tys: []i64) -> (Vec[i64], i64, i64) {
    off := 0
    align := 1
    offs := vec[i64]()
    for t in tys {
        a := self.align_of(t)
        s := self.size_of(t)
        off = (off + a - 1) / a * a
        offs.push(off)
        off += s
        align = max(align, a)
    }
    size := (off + align - 1) / align * align
    return (offs, size, align)
}

fn layout_struct(self: *Types, sid: i64) {
    st := self.structs[sid].state
    if st == 2 || st == 3 {
        return
    }
    if st == 1 {
        n := self.structs[sid].name
        self.layout_errors.push(fmt("struct `", n, "` contains itself by value (use a pointer)"))
        s := &self.structs[sid]
        s.state = 2
        // the fields are dropped: everything that walks a type by its fields would not end
        s.fields.truncate(0)
        s.offsets = vec_fill(0, 0)
        s.size = 8
        s.align = 8
        return
    }
    self.structs[sid].state = 1
    tys := vec[i64]()
    for i in 0..self.structs[sid].fields.len {
        tys.push(self.structs[sid].fields[i].1)
    }
    offs, size, align := self.layout_fields(tys.items())
    s := &self.structs[sid]
    if s.state == 2 {
        return
    }
    s.offsets = offs
    s.size = size
    s.align = align
    s.state = 2
}

priv fn layout_enum(self: *Types, eid: i64) {
    st := self.enums[eid].state
    if st == 2 || st == 3 {
        return
    }
    if st == 1 {
        n := self.enums[eid].name
        self.layout_errors.push(fmt("enum `", n, "` contains itself by value (use a pointer)"))
        self.enums[eid].state = 2
        self.enums[eid].size = 8
        self.enums[eid].align = 8
        return
    }
    self.enums[eid].state = 1
    nv := self.enums[eid].variants.len
    size := ENUM_TAG
    align := ENUM_TAG
    // the bytes the payloads occupy, as start << 32 | end
    spans := vec[i64]()
    for i in 0..nv {
        tys := variant_fields(self, eid, i)
        offs, s, a := self.layout_fields(tys.items())
        size = max(size, s)
        align = max(align, a)
        for j in 1..tys.len {
            n := self.size_of(tys[j])
            if n > 0 {
                spans.push(offs[j] << 32 | min(offs[j] + n, 0xFFFFFFFF))
            }
        }
    }
    e := &self.enums[eid]
    if e.state == 2 {
        return
    }
    e.size = (size + align - 1) / align * align
    e.align = align
    e.state = 2
    e.runs = merge_spans(spans.items())
}

// the spans (start << 32 | end) sorted and merged where they overlap or touch
priv fn merge_spans(spans: []i64) -> Vec[i64] {
    sort(spans)
    out := vec[i64]()
    for s in spans {
        if out.len > 0 && (s >> 32) <= (out[out.len - 1] & 0xFFFFFFFF) {
            last := out[out.len - 1]
            out[out.len - 1] = ((last >> 32) << 32) | max(last & 0xFFFFFFFF, s & 0xFFFFFFFF)
        } else {
            out.push(s)
        }
    }
    return out
}

// the size of the copy piece at offset `o` of a run that ends at `e`: the largest naturally
// aligned 8, 4, 2 or 1 bytes within the run
priv fn piece(o: i64, e: i64) -> i64 {
    c := 8
    while o % c != 0 || o + c > e {
        c /= 2
    }
    return c
}

// the number of pieces of the run from `o` to `e` (without walking a long one)
priv fn run_pieces(o0: i64, e: i64) -> i64 {
    o := o0
    n := 0
    while o < e && o % 8 != 0 {
        o += piece(o, e)
        n += 1
    }
    if o < e {
        k := (e - o) / 8
        n += k
        o += 8 * k
    }
    while o < e {
        o += piece(o, e)
        n += 1
    }
    return n
}

// bytes of the tag of every enum (its IR type is I32)
const ENUM_TAG = 4

// the fields of variant `var_` laid out like a struct: the tag, then the payload types
priv fn variant_fields(self: *Types, eid: i64, var_: i64) -> Vec[i64] {
    tys := vec_one(T_U32)
    tys.extend(self.enums[eid].variants[var_].1.items())
    return tys
}

// offsets of payload fields of a variant, relative to the enum start
fn variant_offsets(self: *Types, eid: i64, var_: i64) -> Vec[i64] {
    offs := self.layout_fields(variant_fields(self, eid, var_).items()).0
    return vec_of(offs.items()[1..])
}

fn tuple_offsets(self: *Types, tys: []i64) -> Vec[i64] {
    return self.layout_fields(tys).0
}

fn size_of(self: *Types, t: i64) -> i64 {
    match self.k(t) {
        Err, Unit, Never => return 0
        Bool => return 1
        Int(b, _) => return b / 8
        F64, Ptr(_), Fn(_, _) => return 8
        F32 => return 4
        Vec(n) => return 4 * n
        Quat => return 16
        Mat4 => return 64
        Slice(_) => return 16
        Array(e, n) => {
            // min(size * n, 2^32 - 1), computed unsigned and wrapping
            total := u64(self.size_of(e)) * u64(n)
            if total > u64(0xFFFFFFFF) {
                return 0xFFFFFFFF
            }
            return i64(total)
        }
        Struct(s) => {
            self.layout_struct(s)
            return self.structs[s].size
        }
        Enum(e) => {
            self.layout_enum(e)
            return self.enums[e].size
        }
        Tuple(_) => return self.tuple_size_align(t).0
    }
}

fn align_of(self: *Types, t: i64) -> i64 {
    match self.k(t) {
        Err, Unit, Never, Bool => 1
        Int(b, _) => b / 8
        F64, Ptr(_), Fn(_, _), Slice(_) => 8
        Enum(e) => {
            self.layout_enum(e)
            self.enums[e].align
        }
        F32, Quat, Mat4, Vec(_) => 4
        Array(e, _) => self.align_of(e)
        Struct(s) => {
            self.layout_struct(s)
            self.structs[s].align
        }
        Tuple(_) => self.tuple_size_align(t).1
    }
}

priv fn tuple_size_align(self: *Types, t: i64) -> (i64, i64) {
    known, found := self.tuple_layout.get(t)
    if found {
        return known
    }
    r := (0, 1)
    match self.k(t) {
        Tuple(v) => {
            _, size, align := self.layout_fields(v.items())
            r = (size, align)
        }
        _ => {}
    }
    self.tuple_layout.set(t, r)
    return r
}

priv fn field_id(self: *Types, owner: i64, idx: i64) -> i64 {
    f0, found := self.field_ids.get((owner, idx))
    if found {
        return f0
    }
    f := self.next_field_id
    self.next_field_id += 1
    self.field_ids.set((owner, idx), f)
    return f
}

// IR type + alias kind of a scalar type
fn scalar_ir(self: *Types, t: i64) -> (T, i64) {
    match self.k(t) {
        Bool, Int(8, _) => (I8, AK_ANY)
        Int(16, _) => (I16, AK_I16)
        Int(32, _) => (I32, AK_I32)
        Int(_, _) => (I64, AK_I64)
        Enum(e) if self.enums[e].simple => (I32, AK_TAG)
        F64 => (T.F64, AK_F64)
        F32 => (T.F32, AK_F32)
        Vec(2) => (V2, AK_VEC)
        Vec(3) => (V3, AK_VEC)
        Vec(_), Quat => (V4, AK_VEC)
        Ptr(_), Fn(_, _) => (I64, AK_PTR)
        _ => (I64, AK_ANY)
    }
}

// alias class for a scalar of type `t` that is field `idx` of aggregate `owner`
fn field_alias(self: *Types, owner: i64, idx: i64, t: i64) -> i64 {
    it, k := self.scalar_ir(t)
    if k == AK_ANY {
        return 0
    }
    return k | (self.field_id(owner, idx) << 4)
}

// a scalar type: one leaf at `base`
priv fn leaves_scalar(self: *Types, t: i64, base: i64, out: *Vec[Leaf]) {
    it, k := self.scalar_ir(t)
    out.push(Leaf{off: base, t: it, alias: k})
}

// the fields `tys` (at offsets `offs`) of the struct or tuple `t`
priv fn leaves_fields(self: *Types, t: i64, tys: []i64, offs: []i64, base: i64, out: *Vec[Leaf]) {
    for i, ft in tys {
        if self.is_scalar(ft) {
            it, k := self.scalar_ir(ft)
            a := self.field_alias(t, i, ft)
            out.push(Leaf{off: base + offs[i], t: it, alias: a})
        } else {
            self.leaves(ft, base + offs[i], out)
        }
    }
}

fn leaves(self: *Types, t: i64, base: i64, out: *Vec[Leaf]) {
    match self.k(t) {
        Err, Unit, Never => {}
        Mat4 => {
            for c in 0..4 {
                out.push(Leaf{off: base + 16 * c, t: V4, alias: AK_VEC})
            }
        }
        Bool, F64, F32, Quat, Int(_, _), Vec(_), Ptr(_), Fn(_, _) => leaves_scalar(self, t, base, out)
        Slice(e) => {
            f0 := self.field_id(t, 0)
            f1 := self.field_id(t, 1)
            out.push(Leaf{off: base, t: I64, alias: AK_PTR | (f0 << 4)})
            out.push(Leaf{off: base + 8, t: I64, alias: AK_I64 | (f1 << 4)})
        }
        Array(e, n) => {
            es := self.size_of(e)
            for i in 0..n {
                self.leaves(e, base + i * es, out)
                if out.len > 4096 {
                    return
                }
            }
        }
        Struct(s) => {
            self.layout_struct(s)
            tys := vec[i64]()
            for i in 0..self.structs[s].fields.len {
                tys.push(self.structs[s].fields[i].1)
            }
            offs := clone(self.structs[s].offsets)
            leaves_fields(self, t, tys.items(), offs.items(), base, out)
        }
        Tuple(v) => {
            offs := self.tuple_offsets(v.items())
            leaves_fields(self, t, v.items(), offs.items(), base, out)
        }
        Enum(e) => {
            if self.enums[e].simple {
                out.push(Leaf{off: base, t: I32, alias: AK_TAG})
                return
            }
            self.layout_enum(e)
            out.push(Leaf{off: base, t: I32, alias: AK_ANY})
            for r in self.enums[e].runs {
                o := r >> 32
                end := r & 0xFFFFFFFF
                while o < end {
                    c := piece(o, end)
                    pt := if c == 8 { I64 } else if c == 4 { I32 } else if c == 2 { I16 } else { I8 }
                    out.push(Leaf{off: base + o, t: pt, alias: AK_ANY})
                    o += c
                    if out.len > 4096 {
                        return
                    }
                }
            }
        }
    }
}

priv const COUNT_MAX = 0x7FFFFFFFFFFFFFFF

// saturating arithmetic on non-negative counts (the ceiling is the largest i64)
priv fn sat_mul(a: i64, b: i64) -> i64 {
    if a == 0 || b == 0 {
        return 0
    }
    if a > COUNT_MAX / b {
        return COUNT_MAX
    }
    return a * b
}

priv fn sat_add(a: i64, b: i64) -> i64 {
    if a > COUNT_MAX - b {
        return COUNT_MAX
    }
    return a + b
}

// The leaves of `t` at offset 0, for reading only: kept per type once no type is being
// instantiated (a later call would give the same list and assign no new field ids)
fn leaf_list(self: *Types, t: i64) -> Vec[Leaf] {
    if t < self.leaf_known.len && self.leaf_known[t] {
        return self.leaf_cache[t]
    }
    out := vec[Leaf]()
    self.leaves(t, 0, &out)
    if self.instantiating == 0 {
        while self.leaf_known.len <= t {
            self.leaf_known.push(false)
            self.leaf_cache.push(vec[Leaf]())
        }
        self.leaf_known[t] = true
        self.leaf_cache[t] = out
    }
    return out
}

// number of leaves without materializing huge arrays (cached like leaf_list)
fn leaf_count(self: *Types, t: i64) -> i64 {
    if t < self.count_cache.len && self.count_cache[t] >= 0 {
        return self.count_cache[t]
    }
    n := count_leaves(self, t)
    if self.instantiating == 0 {
        while self.count_cache.len <= t {
            self.count_cache.push(-1)
        }
        self.count_cache[t] = n
    }
    return n
}

priv fn count_leaves(self: *Types, t: i64) -> i64 {
    match self.k(t) {
        Array(e, n) => return sat_mul(self.leaf_count(e), n)
        Struct(s) => {
            tys := vec[i64]()
            for i in 0..self.structs[s].fields.len {
                tys.push(self.structs[s].fields[i].1)
            }
            total := 0
            for ft in tys {
                total = sat_add(total, self.leaf_count(ft))
            }
            return total
        }
        Tuple(v) => {
            total := 0
            for ft in v {
                total = sat_add(total, self.leaf_count(ft))
            }
            return total
        }
        Slice(_) => return 2
        Mat4 => return 4
        Enum(e) => {
            if self.enums[e].simple {
                return 1
            }
            self.layout_enum(e)
            n := 1
            for r in self.enums[e].runs {
                n = sat_add(n, run_pieces(r >> 32, r & 0xFFFFFFFF))
            }
            return n
        }
        Err, Unit, Never => return 0
        _ => return 1
    }
}
