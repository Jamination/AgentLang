// Type table: interned semantic types, layout, scalar leaves.

TyK :: enum {
    TyKErr,
    TyKUnit,
    TyKBool,
    TyKInt(i64, bool), // bits, signed
    TyKF64,
    TyKF32,
    TyKVec(i64), // vec2 / vec3 / vec4: f32 lanes
    TyKQuat,
    TyKMat4, // four vec4 columns
    TyKPtr(i64),
    TyKSlice(i64),
    TyKArray(i64, i64),
    TyKStruct(i64),
    TyKEnum(i64),
    TyKTuple(Vec[i64]),
    TyKFn(Vec[i64], i64),
    TyKNever,
}

T_ERR :: 0
T_UNIT :: 1
T_BOOL :: 2
T_I8 :: 3
T_I16 :: 4
T_I32 :: 5
T_I64 :: 6
T_U8 :: 7
T_U16 :: 8
T_U32 :: 9
T_U64 :: 10
T_F64 :: 11
T_F32 :: 12
T_STR :: 13
T_NEVER :: 14
T_VEC2 :: 15
T_VEC3 :: 16
T_VEC4 :: 17
T_QUAT :: 18
T_MAT4 :: 19

StructInfo :: struct {
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

EnumInfo :: struct {
    name: str
    decl: i64
    targs: Vec[i64]
    variants: Vec[(str, Vec[i64])]
    simple: bool
    size: i64
    state: i64
}

Leaf :: struct {
    off: i64
    t: T
    alias: i64
}

Types :: struct {
    kinds: Vec[TyK]
    // HashMap<TyK, Ty> in the Rust source: keyed by the canonical text of the kind (types_key)
    map: Map[str, i64]
    structs: Vec[StructInfo]
    enums: Vec[EnumInfo]
    field_ids: Map[(i64, i64), i64]
    next_field_id: i64
    layout_errors: Vec[str]
}

AK_ANY :: 0
AK_I16 :: 1
AK_I32 :: 2
AK_I64 :: 3
AK_F64 :: 4
AK_PTR :: 5
AK_F32 :: 6
AK_VEC :: 7

types_may_alias_class :: (a: i64, b: i64) -> bool {
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
types_key :: (k: TyK) -> str {
    match k {
        TyKErr => return "E"
        TyKUnit => return "U"
        TyKBool => return "B"
        TyKInt(b, s) => return fmt(if s { "i" } else { "u" }, b)
        TyKF64 => return "D"
        TyKF32 => return "G"
        TyKVec(n) => return fmt("V", n)
        TyKQuat => return "Q"
        TyKMat4 => return "M"
        TyKPtr(t) => return fmt("P", t)
        TyKSlice(t) => return fmt("S", t)
        TyKArray(t, n) => return fmt("A", t, ",", n)
        TyKStruct(s) => return fmt("R", s)
        TyKEnum(e) => return fmt("N", e)
        TyKTuple(v) => {
            parts := vec[str]()
            for t in v.items() {
                parts.push(fmt(t))
            }
            return concat("T", join(parts.items(), ","))
        }
        TyKFn(p, r) => {
            parts := vec[str]()
            for t in p.items() {
                parts.push(fmt(t))
            }
            return fmt("F", join(parts.items(), ","), ">", r)
        }
        TyKNever => return "!"
    }
}

types_new :: () -> Types {
    t := Types{
        kinds: vec[TyK](),
        map: map[str, i64](),
        structs: vec[StructInfo](),
        enums: vec[EnumInfo](),
        field_ids: map[(i64, i64), i64](),
        next_field_id: 1,
        layout_errors: vec[str](),
    }
    t.intern(TyKErr)
    t.intern(TyKUnit)
    t.intern(TyKBool)
    t.intern(TyKInt(8, true))
    t.intern(TyKInt(16, true))
    t.intern(TyKInt(32, true))
    t.intern(TyKInt(64, true))
    t.intern(TyKInt(8, false))
    t.intern(TyKInt(16, false))
    t.intern(TyKInt(32, false))
    t.intern(TyKInt(64, false))
    t.intern(TyKF64)
    t.intern(TyKF32)
    s := t.intern(TyKSlice(T_U8))
    assert s == T_STR
    n := t.intern(TyKNever)
    assert n == T_NEVER
    t.intern(TyKVec(2))
    t.intern(TyKVec(3))
    t.intern(TyKVec(4))
    t.intern(TyKQuat)
    t.intern(TyKMat4)
    assert t.intern(TyKMat4) == T_MAT4
    return t
}

intern :: (self: *Types, k: TyK) -> i64 {
    key := types_key(k)
    t, found := self.map.get(key)
    if found {
        return t
    }
    id := self.kinds.len
    self.kinds.push(types_kind_copy(k))
    self.map.set(key, id)
    return id
}

// the kind with its own type lists (the table must not share a buffer with the caller)
types_kind_copy :: (k: TyK) -> TyK {
    match k {
        TyKTuple(v) => return TyKTuple(clone(&v))
        TyKFn(p, r) => return TyKFn(clone(&p), r)
        _ => return k
    }
}

k :: (self: *Types, t: i64) -> TyK {
    return self.kinds[t]
}

is_float :: (self: *Types, t: i64) -> bool {
    return t == T_F64 || t == T_F32
}

// vec2 / vec3 / vec4 / quat: the number of f32 lanes
vec_lanes :: (self: *Types, t: i64) -> Opt[i64] {
    match self.k(t) {
        TyKVec(n) => return Some(n)
        TyKQuat => return Some(4)
        _ => return None
    }
}

// `Types::ptr` in the Rust source (a function named `ptr` would hide the builtin)
ptr_to :: (self: *Types, t: i64) -> i64 {
    return self.intern(TyKPtr(t))
}

slice :: (self: *Types, t: i64) -> i64 {
    return self.intern(TyKSlice(t))
}

is_int :: (self: *Types, t: i64) -> bool {
    match self.k(t) {
        TyKInt(b, s) => return true
        _ => return false
    }
}

is_signed :: (self: *Types, t: i64) -> bool {
    match self.k(t) {
        TyKInt(b, s) => return s
        _ => return false
    }
}

is_scalar :: (self: *Types, t: i64) -> bool {
    match self.k(t) {
        TyKBool, TyKF64, TyKF32, TyKQuat => return true
        TyKInt(b, s) => return true
        TyKVec(n) => return true
        TyKPtr(e) => return true
        TyKFn(p, r) => return true
        TyKEnum(e) => return self.enums[e].simple
        _ => return false
    }
}

types_names :: (self: *Types, v: Vec[i64]) -> str {
    parts := vec[str]()
    for t in v.items() {
        parts.push(self.name(t))
    }
    return join(parts.items(), ", ")
}

name :: (self: *Types, t: i64) -> str {
    match self.k(t) {
        TyKErr => return "<error>"
        TyKUnit => return "()"
        TyKNever => return "never"
        TyKBool => return "bool"
        TyKInt(b, s) => return fmt(if s { "i" } else { "u" }, b)
        TyKF64 => return "f64"
        TyKF32 => return "f32"
        TyKVec(n) => return fmt("vec", n)
        TyKQuat => return "quat"
        TyKMat4 => return "mat4"
        TyKPtr(e) => return concat("*", self.name(e))
        TyKSlice(e) => {
            if e == T_U8 {
                return "str"
            } else {
                return concat("[]", self.name(e))
            }
        }
        TyKArray(e, n) => return fmt("[", n, "]", self.name(e))
        TyKStruct(s) => return self.structs[s].name
        TyKEnum(s) => return self.enums[s].name
        TyKTuple(v) => return fmt("(", types_names(self, v), ")")
        TyKFn(p, r) => {
            ps := types_names(self, p)
            if r == T_UNIT {
                return fmt("(", ps, ") -> ()")
            } else {
                return fmt("(", ps, ") -> ", self.name(r))
            }
        }
    }
}

layout_fields :: (self: *Types, tys: []i64) -> (Vec[i64], i64, i64) {
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

layout_struct :: (self: *Types, sid: i64) {
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

layout_enum :: (self: *Types, eid: i64) {
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
        vars.push(clone(&self.enums[eid].variants[i].1))
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
variant_offsets :: (self: *Types, eid: i64, var_: i64) -> Vec[i64] {
    tys := clone(&self.enums[eid].variants[var_].1)
    offs, s, a := self.layout_fields(tys.items())
    out := vec[i64]()
    for o in offs.items() {
        out.push(o + 8)
    }
    return out
}

tuple_offsets :: (self: *Types, tys: []i64) -> Vec[i64] {
    return self.layout_fields(tys).0
}

size_of :: (self: *Types, t: i64) -> i64 {
    match self.k(t) {
        TyKErr, TyKUnit, TyKNever => return 0
        TyKBool => return 1
        TyKInt(b, s) => return b / 8
        TyKF64 => return 8
        TyKPtr(e) => return 8
        TyKFn(p, r) => return 8
        TyKF32 => return 4
        TyKVec(n) => return 4 * n
        TyKQuat => return 16
        TyKMat4 => return 64
        TyKSlice(e) => return 16
        TyKArray(e, n) => {
            // (size as u64 * n).min(u32::MAX): unsigned, wrapping like the Rust
            total := u64(self.size_of(e)) * u64(n)
            if total > u64(0xFFFFFFFF) {
                return 0xFFFFFFFF
            }
            return i64(total)
        }
        TyKStruct(s) => {
            self.layout_struct(s)
            return self.structs[s].size
        }
        TyKEnum(e) => {
            self.layout_enum(e)
            return self.enums[e].size
        }
        TyKTuple(v) => return self.layout_fields(v.items()).1
    }
}

align_of :: (self: *Types, t: i64) -> i64 {
    match self.k(t) {
        TyKErr, TyKUnit, TyKNever => return 1
        TyKBool => return 1
        TyKInt(b, s) => return b / 8
        TyKF64 => return 8
        TyKPtr(e) => return 8
        TyKFn(p, r) => return 8
        TyKSlice(e) => return 8
        TyKEnum(e) => return 8
        TyKF32, TyKQuat, TyKMat4 => return 4
        TyKVec(n) => return 4
        TyKArray(e, n) => return self.align_of(e)
        TyKStruct(s) => {
            self.layout_struct(s)
            return self.structs[s].align
        }
        TyKTuple(v) => return self.layout_fields(v.items()).2
    }
}

field_id :: (self: *Types, owner: i64, idx: i64) -> i64 {
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
scalar_ir :: (self: *Types, t: i64) -> (T, i64) {
    match self.k(t) {
        TyKBool => return (TI8, AK_ANY)
        TyKInt(b, s) => {
            if b == 8 {
                return (TI8, AK_ANY)
            }
            if b == 16 {
                return (TI16, AK_I16)
            }
            if b == 32 {
                return (TI32, AK_I32)
            }
            return (TI64, AK_I64)
        }
        TyKF64 => return (TF64, AK_F64)
        TyKF32 => return (TF32, AK_F32)
        TyKVec(n) => {
            if n == 2 {
                return (TV2, AK_VEC)
            }
            if n == 3 {
                return (TV3, AK_VEC)
            }
            return (TV4, AK_VEC)
        }
        TyKQuat => return (TV4, AK_VEC)
        TyKPtr(e) => return (TI64, AK_PTR)
        TyKFn(p, r) => return (TI64, AK_PTR)
        TyKEnum(e) => return (TI64, AK_I64)
        _ => return (TI64, AK_ANY)
    }
}

// alias class for a scalar of type `t` that is field `idx` of aggregate `owner`
field_alias :: (self: *Types, owner: i64, idx: i64, t: i64) -> i64 {
    it, k := self.scalar_ir(t)
    if k == AK_ANY {
        return 0
    }
    return k | (self.field_id(owner, idx) << 4)
}

// a scalar type: one leaf at `base`
types_leaves_scalar :: (self: *Types, t: i64, base: i64, out: *Vec[Leaf]) {
    it, k := self.scalar_ir(t)
    out.push(Leaf{off: base, t: it, alias: k})
}

// the fields `tys` (at offsets `offs`) of the struct or tuple `t`
types_leaves_fields :: (self: *Types, t: i64, tys: []i64, offs: []i64, base: i64, out: *Vec[Leaf]) {
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

leaves :: (self: *Types, t: i64, base: i64, out: *Vec[Leaf]) {
    match self.k(t) {
        TyKErr, TyKUnit, TyKNever => {}
        TyKMat4 => {
            for c in 0..4 {
                out.push(Leaf{off: base + 16 * c, t: TV4, alias: AK_VEC})
            }
        }
        TyKBool, TyKF64, TyKF32, TyKQuat => types_leaves_scalar(self, t, base, out)
        TyKInt(b, s) => types_leaves_scalar(self, t, base, out)
        TyKVec(n) => types_leaves_scalar(self, t, base, out)
        TyKPtr(e) => types_leaves_scalar(self, t, base, out)
        TyKFn(p, r) => types_leaves_scalar(self, t, base, out)
        TyKSlice(e) => {
            f0 := self.field_id(t, 0)
            f1 := self.field_id(t, 1)
            out.push(Leaf{off: base, t: TI64, alias: AK_PTR | (f0 << 4)})
            out.push(Leaf{off: base + 8, t: TI64, alias: AK_I64 | (f1 << 4)})
        }
        TyKArray(e, n) => {
            es := self.size_of(e)
            for i in 0..n {
                self.leaves(e, base + i * es, out)
                if out.len > 4096 {
                    return
                }
            }
        }
        TyKStruct(s) => {
            self.layout_struct(s)
            tys := vec[i64]()
            for i in 0..self.structs[s].fields.len {
                tys.push(self.structs[s].fields[i].1)
            }
            offs := clone(&self.structs[s].offsets)
            types_leaves_fields(self, t, tys.items(), offs.items(), base, out)
        }
        TyKTuple(v) => {
            offs := self.tuple_offsets(v.items())
            types_leaves_fields(self, t, v.items(), offs.items(), base, out)
        }
        TyKEnum(e) => {
            if self.enums[e].simple {
                out.push(Leaf{off: base, t: TI64, alias: AK_I64})
            } else {
                sz := self.size_of(t)
                o := 0
                while o < sz {
                    out.push(Leaf{off: base + o, t: TI64, alias: AK_ANY})
                    o += 8
                }
            }
        }
    }
}

TYPES_COUNT_MAX :: 0x7FFFFFFFFFFFFFFF

// saturating arithmetic on non-negative counts (u64 saturating_mul / saturating_add in the
// Rust source; here the ceiling is the largest i64)
types_sat_mul :: (a: i64, b: i64) -> i64 {
    if a == 0 || b == 0 {
        return 0
    }
    if a > TYPES_COUNT_MAX / b {
        return TYPES_COUNT_MAX
    }
    return a * b
}

types_sat_add :: (a: i64, b: i64) -> i64 {
    if a > TYPES_COUNT_MAX - b {
        return TYPES_COUNT_MAX
    }
    return a + b
}

// number of leaves without materializing huge arrays
leaf_count :: (self: *Types, t: i64) -> i64 {
    match self.k(t) {
        TyKArray(e, n) => return types_sat_mul(self.leaf_count(e), n)
        TyKStruct(s) => {
            tys := vec[i64]()
            for i in 0..self.structs[s].fields.len {
                tys.push(self.structs[s].fields[i].1)
            }
            total := 0
            for ft in tys.items() {
                total = types_sat_add(total, self.leaf_count(ft))
            }
            return total
        }
        TyKTuple(v) => {
            total := 0
            for ft in v.items() {
                total = types_sat_add(total, self.leaf_count(ft))
            }
            return total
        }
        TyKSlice(e) => return 2
        TyKMat4 => return 4
        TyKEnum(e) => return self.size_of(t) / 8
        TyKErr, TyKUnit, TyKNever => return 0
        _ => return 1
    }
}
