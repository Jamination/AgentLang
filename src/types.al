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

struct EnumInfo {
    name: str
    decl: i64
    targs: Vec[i64]
    variants: Vec[(str, Vec[i64])]
    simple: bool
    size: i64
    state: i64
}

struct Leaf {
    off: i64
    t: T
    alias: i64
}

struct Types {
    kinds: Vec[TyK]
    // HashMap<TyK, Ty> in the Rust source: keyed by the canonical text of the kind (types_key)
    map: Map[str, i64]
    structs: Vec[StructInfo]
    enums: Vec[EnumInfo]
    field_ids: Map[(i64, i64), i64]
    next_field_id: i64
    layout_errors: Vec[str]
}

const AK_ANY = 0
priv const AK_I16 = 1
priv const AK_I32 = 2
const AK_I64 = 3
priv const AK_F64 = 4
const AK_PTR = 5
priv const AK_F32 = 6
const AK_VEC = 7

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

// canonical text of a kind: equal kinds have equal keys and different kinds different keys
priv fn types_key(k: TyK) -> str {
    match k {
        Err => return "E"
        Unit => return "U"
        Bool => return "B"
        Int(b, s) => return fmt(if s { "i" } else { "u" }, b)
        F64 => return "D"
        F32 => return "G"
        Vec(n) => return fmt("V", n)
        Quat => return "Q"
        Mat4 => return "M"
        Ptr(t) => return fmt("P", t)
        Slice(t) => return fmt("S", t)
        Array(t, n) => return fmt("A", t, ",", n)
        Struct(s) => return fmt("R", s)
        Enum(e) => return fmt("N", e)
        Tuple(v) => {
            parts := vec[str]()
            for t in v {
                parts.push(fmt(t))
            }
            return concat("T", join(parts.items(), ","))
        }
        Fn(p, r) => {
            parts := vec[str]()
            for t in p {
                parts.push(fmt(t))
            }
            return fmt("F", join(parts.items(), ","), ">", r)
        }
        Never => return "!"
    }
}

fn types_new() -> Types {
    t := Types{
        kinds: vec[TyK](),
        map: map[str, i64](),
        structs: vec[StructInfo](),
        enums: vec[EnumInfo](),
        field_ids: map[(i64, i64), i64](),
        next_field_id: 1,
        layout_errors: vec[str](),
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
    key := types_key(k)
    t, found := self.map.get(key)
    if found {
        return t
    }
    id := self.kinds.len
    self.kinds.push(clone(k))
    self.map.set(key, id)
    return id
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

// `Types::ptr` in the Rust source (a function named `ptr` would hide the builtin)
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
        return
    }
    self.enums[eid].state = 1
    vars := vec[Vec[i64]]()
    for i in 0..self.enums[eid].variants.len {
        vars.push(clone(self.enums[eid].variants[i].1))
    }
    size := 8
    for i in 0..vars.len {
        o, s0, a := self.layout_fields(vars[i].items())
        s := (s0 + 7) / 8 * 8
        size = max(size, 8 + s)
    }
    e := &self.enums[eid]
    if e.state == 2 {
        return
    }
    e.size = size
    e.state = 2
}

// offsets of payload fields of a variant, relative to the enum start
fn variant_offsets(self: *Types, eid: i64, var_: i64) -> Vec[i64] {
    tys := clone(self.enums[eid].variants[var_].1)
    offs, s, a := self.layout_fields(tys.items())
    out := vec[i64]()
    for o in offs {
        out.push(o + 8)
    }
    return out
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
            // (size as u64 * n).min(u32::MAX): unsigned, wrapping like the Rust
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
        Tuple(v) => return self.layout_fields(v.items()).1
    }
}

fn align_of(self: *Types, t: i64) -> i64 {
    match self.k(t) {
        Err, Unit, Never, Bool => 1
        Int(b, _) => b / 8
        F64, Ptr(_), Fn(_, _), Slice(_), Enum(_) => 8
        F32, Quat, Mat4, Vec(_) => 4
        Array(e, _) => self.align_of(e)
        Struct(s) => {
            self.layout_struct(s)
            self.structs[s].align
        }
        Tuple(v) => self.layout_fields(v.items()).2
    }
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
        Int(_, _), Enum(_) => (I64, AK_I64)
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
                out.push(Leaf{off: base, t: I64, alias: AK_I64})
            } else {
                sz := self.size_of(t)
                o := 0
                while o < sz {
                    out.push(Leaf{off: base + o, t: I64, alias: AK_ANY})
                    o += 8
                }
            }
        }
    }
}

priv const COUNT_MAX = 0x7FFFFFFFFFFFFFFF

// saturating arithmetic on non-negative counts (u64 saturating_mul / saturating_add in the
// Rust source; here the ceiling is the largest i64)
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

// number of leaves without materializing huge arrays
fn leaf_count(self: *Types, t: i64) -> i64 {
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
        Enum(_) => return self.size_of(t) / 8
        Err, Unit, Never => return 0
        _ => return 1
    }
}
