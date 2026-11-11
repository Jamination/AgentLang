// Type table: interned semantic types, layout, scalar leaves.

enum TyK {
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
    // closure `|A, B| R`: code pointer + environment pointer (16 bytes)
    TyKClosure(Vec[i64], i64),
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
    name str
    decl i64
    targs Vec[i64]
    fields Vec[(str, i64)]
    offsets Vec[i64]
    size i64
    align i64
    state i64 // 0 = layout pending, 1 = in progress, 2 = done
}

struct EnumInfo {
    name str
    decl i64
    targs Vec[i64]
    variants Vec[(str, Vec[i64])]
    simple bool
    size i64
    state i64
}

struct Leaf {
    off i64
    t T
    alias i64
}

struct Types {
    kinds Vec[TyK]
    // HashMap<TyK, Ty> in the Rust source: keyed by the canonical text of the kind (types_key)
    map Map[str, i64]
    structs Vec[StructInfo]
    enums Vec[EnumInfo]
    field_ids Map[(i64, i64), i64]
    next_field_id i64
    layout_errors Vec[str]
}

const AK_ANY = 0
const AK_I16 = 1
const AK_I32 = 2
const AK_I64 = 3
const AK_F64 = 4
const AK_PTR = 5
const AK_F32 = 6
const AK_VEC = 7

fn types_may_alias_class(a i64, b i64) bool {
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
fn types_key(k TyK) str {
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
        TyKClosure(p, r) => {
            parts := vec[str]()
            for t in p.items() {
                parts.push(fmt(t))
            }
            return fmt("C", join(parts.items(), ","), ">", r)
        }
    }
}

fn types_new() Types {
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

fn intern(self *Types, k TyK) i64 {
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
fn types_kind_copy(k TyK) TyK {
    match k {
        TyKTuple(v) => return TyKTuple(clone(&v))
        TyKFn(p, r) => return TyKFn(clone(&p), r)
        TyKClosure(p, r) => return TyKClosure(clone(&p), r)
        _ => return k
    }
}

fn k(self *Types, t i64) TyK {
    return self.kinds.buf[t]
}

fn is_float(self *Types, t i64) bool {
    return t == T_F64 || t == T_F32
}

// vec2 / vec3 / vec4 / quat: the number of f32 lanes
fn vec_lanes(self *Types, t i64) Opt[i64] {
    match self.k(t) {
        TyKVec(n) => return Some(n)
        TyKQuat => return Some(4)
        _ => return None
    }
}

// `Types::ptr` in the Rust source (a function named `ptr` would hide the builtin)
fn ptr_to(self *Types, t i64) i64 {
    return self.intern(TyKPtr(t))
}

fn slice(self *Types, t i64) i64 {
    return self.intern(TyKSlice(t))
}

// the closure type `|P...| R`
fn closure(self *Types, ptys Vec[i64], rty i64) i64 {
    return self.intern(TyKClosure(ptys, rty))
}

// (parameter types, result type) of a function type or a closure type
fn callable_sig(self *Types, t i64) Opt[(Vec[i64], i64)] {
    match self.k(t) {
        TyKFn(p, r) => return Some((p, r))
        TyKClosure(p, r) => return Some((p, r))
        _ => return None
    }
}

fn is_closure(self *Types, t i64) bool {
    match self.k(t) {
        TyKClosure(p, r) => return true
        _ => return false
    }
}

// is `from` a function type with the parameter and result types of the closure type `to`?
// (such a value converts to the closure implicitly)
fn fn_to_closure(self *Types, from i64, to i64) bool {
    match self.k(to) {
        TyKClosure(cp, cr) => {
            match self.k(from) {
                TyKFn(fp, fr) => return fr == cr && fp.items() == cp.items()
                _ => return false
            }
        }
        _ => return false
    }
}

fn is_int(self *Types, t i64) bool {
    match self.k(t) {
        TyKInt(b, s) => return true
        _ => return false
    }
}

fn is_signed(self *Types, t i64) bool {
    match self.k(t) {
        TyKInt(b, s) => return s
        _ => return false
    }
}

fn is_scalar(self *Types, t i64) bool {
    match self.k(t) {
        TyKBool, TyKF64, TyKF32, TyKQuat => return true
        TyKInt(b, s) => return true
        TyKVec(n) => return true
        TyKPtr(e) => return true
        TyKFn(p, r) => return true
        TyKEnum(e) => return self.enums.buf[e].simple
        _ => return false
    }
}

fn types_names(self *Types, v Vec[i64]) str {
    parts := vec[str]()
    for t in v.items() {
        parts.push(self.name(t))
    }
    return join(parts.items(), ", ")
}

fn name(self *Types, t i64) str {
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
        TyKStruct(s) => return self.structs.buf[s].name
        TyKEnum(s) => return self.enums.buf[s].name
        TyKTuple(v) => return fmt("(", types_names(self, v), ")")
        TyKFn(p, r) => {
            ps := types_names(self, p)
            if r == T_UNIT {
                return fmt("fn(", ps, ")")
            } else {
                return fmt("fn(", ps, ") ", self.name(r))
            }
        }
        TyKClosure(p, r) => {
            ps := types_names(self, p)
            if starts_with(ps, "|") {
                // `||` would be read as an empty parameter list
                ps = concat(" ", ps)
            }
            if r == T_UNIT {
                return fmt("|", ps, "|")
            } else {
                return fmt("|", ps, "| ", self.name(r))
            }
        }
    }
}

fn layout_fields(self *Types, tys []i64) (Vec[i64], i64, i64) {
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

fn layout_struct(self *Types, sid i64) {
    st := self.structs.buf[sid].state
    if st == 2 {
        return
    }
    if st == 1 {
        n := self.structs.buf[sid].name
        self.layout_errors.push(fmt("struct `", n, "` contains itself by value (use a pointer)"))
        s := &self.structs.buf[sid]
        s.state = 2
        s.offsets = vec_fill(s.fields.len, 0)
        s.size = 8
        s.align = 8
        return
    }
    self.structs.buf[sid].state = 1
    tys := vec[i64]()
    for i in 0..self.structs.buf[sid].fields.len {
        tys.push(self.structs.buf[sid].fields.buf[i].1)
    }
    offs, size, align := self.layout_fields(tys.items())
    s := &self.structs.buf[sid]
    if s.state == 2 {
        return
    }
    s.offsets = offs
    s.size = size
    s.align = align
    s.state = 2
}

fn layout_enum(self *Types, eid i64) {
    st := self.enums.buf[eid].state
    if st == 2 {
        return
    }
    if st == 1 {
        n := self.enums.buf[eid].name
        self.layout_errors.push(fmt("enum `", n, "` contains itself by value (use a pointer)"))
        self.enums.buf[eid].state = 2
        self.enums.buf[eid].size = 8
        return
    }
    self.enums.buf[eid].state = 1
    vars := vec[Vec[i64]]()
    for i in 0..self.enums.buf[eid].variants.len {
        vars.push(clone(&self.enums.buf[eid].variants.buf[i].1))
    }
    size := 8
    for i in 0..vars.len {
        o, s0, a := self.layout_fields(vars.buf[i].items())
        s := (s0 + 7) / 8 * 8
        size = max(size, 8 + s)
    }
    e := &self.enums.buf[eid]
    if e.state == 2 {
        return
    }
    e.size = size
    e.state = 2
}

// offsets of payload fields of a variant, relative to the enum start
fn variant_offsets(self *Types, eid i64, var_ i64) Vec[i64] {
    tys := clone(&self.enums.buf[eid].variants.buf[var_].1)
    offs, s, a := self.layout_fields(tys.items())
    out := vec[i64]()
    for o in offs.items() {
        out.push(o + 8)
    }
    return out
}

fn tuple_offsets(self *Types, tys []i64) Vec[i64] {
    return self.layout_fields(tys).0
}

fn size_of(self *Types, t i64) i64 {
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
            return self.structs.buf[s].size
        }
        TyKEnum(e) => {
            self.layout_enum(e)
            return self.enums.buf[e].size
        }
        TyKTuple(v) => return self.layout_fields(v.items()).1
        TyKClosure(p, r) => return 16
    }
}

fn align_of(self *Types, t i64) i64 {
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
            return self.structs.buf[s].align
        }
        TyKTuple(v) => return self.layout_fields(v.items()).2
        TyKClosure(p, r) => return 8
    }
}

fn field_id(self *Types, owner i64, idx i64) i64 {
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
fn scalar_ir(self *Types, t i64) (T, i64) {
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
fn field_alias(self *Types, owner i64, idx i64, t i64) i64 {
    it, k := self.scalar_ir(t)
    if k == AK_ANY {
        return 0
    }
    return k | (self.field_id(owner, idx) << 4)
}

// a scalar type: one leaf at `base`
fn types_leaves_scalar(self *Types, t i64, base i64, out *Vec[Leaf]) {
    it, k := self.scalar_ir(t)
    out.push(Leaf{off: base, t: it, alias: k})
}

// the fields `tys` (at offsets `offs`) of the struct or tuple `t`
fn types_leaves_fields(self *Types, t i64, tys []i64, offs []i64, base i64, out *Vec[Leaf]) {
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

fn leaves(self *Types, t i64, base i64, out *Vec[Leaf]) {
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
            for i in 0..self.structs.buf[s].fields.len {
                tys.push(self.structs.buf[s].fields.buf[i].1)
            }
            offs := clone(&self.structs.buf[s].offsets)
            types_leaves_fields(self, t, tys.items(), offs.items(), base, out)
        }
        TyKTuple(v) => {
            offs := self.tuple_offsets(v.items())
            types_leaves_fields(self, t, v.items(), offs.items(), base, out)
        }
        TyKEnum(e) => {
            if self.enums.buf[e].simple {
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
        TyKClosure(p, r) => {
            // code pointer, environment pointer
            f0 := self.field_id(t, 0)
            f1 := self.field_id(t, 1)
            out.push(Leaf{off: base, t: TI64, alias: AK_PTR | (f0 << 4)})
            out.push(Leaf{off: base + 8, t: TI64, alias: AK_PTR | (f1 << 4)})
        }
    }
}

const TYPES_COUNT_MAX = 0x7FFFFFFFFFFFFFFF

// saturating arithmetic on non-negative counts (u64 saturating_mul / saturating_add in the
// Rust source; here the ceiling is the largest i64)
fn types_sat_mul(a i64, b i64) i64 {
    if a == 0 || b == 0 {
        return 0
    }
    if a > TYPES_COUNT_MAX / b {
        return TYPES_COUNT_MAX
    }
    return a * b
}

fn types_sat_add(a i64, b i64) i64 {
    if a > TYPES_COUNT_MAX - b {
        return TYPES_COUNT_MAX
    }
    return a + b
}

// number of leaves without materializing huge arrays
fn leaf_count(self *Types, t i64) i64 {
    match self.k(t) {
        TyKArray(e, n) => return types_sat_mul(self.leaf_count(e), n)
        TyKStruct(s) => {
            tys := vec[i64]()
            for i in 0..self.structs.buf[s].fields.len {
                tys.push(self.structs.buf[s].fields.buf[i].1)
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
        TyKClosure(p, r) => return 2
        TyKMat4 => return 4
        TyKEnum(e) => return self.size_of(t) / 8
        TyKErr, TyKUnit, TyKNever => return 0
        _ => return 1
    }
}
