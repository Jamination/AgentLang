// Type table: interned semantic types, layout, scalar leaves.
use crate::ir::T;
use std::collections::HashMap;

pub type Ty = u32;

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TyK {
    Err,
    Unit,
    Bool,
    Int(u8, bool), // bits, signed
    F64,
    F32,
    Vec(u8), // vec2 / vec3 / vec4: f32 lanes
    Quat,
    Mat4, // four vec4 columns
    Ptr(Ty),
    Slice(Ty),
    Array(Ty, u64),
    Struct(u32),
    Enum(u32),
    Tuple(Vec<Ty>),
    Fn(Vec<Ty>, Ty),
    Never,
}

pub const T_ERR: Ty = 0;
pub const T_UNIT: Ty = 1;
pub const T_BOOL: Ty = 2;
pub const T_I8: Ty = 3;
pub const T_I16: Ty = 4;
pub const T_I32: Ty = 5;
pub const T_I64: Ty = 6;
pub const T_U8: Ty = 7;
pub const T_U16: Ty = 8;
pub const T_U32: Ty = 9;
pub const T_U64: Ty = 10;
pub const T_F64: Ty = 11;
pub const T_F32: Ty = 12;
pub const T_STR: Ty = 13;
pub const T_NEVER: Ty = 14;
pub const T_VEC2: Ty = 15;
pub const T_VEC3: Ty = 16;
pub const T_VEC4: Ty = 17;
pub const T_QUAT: Ty = 18;
pub const T_MAT4: Ty = 19;

#[derive(Clone, Debug)]
pub struct StructInfo {
    pub name: String,
    pub decl: usize,
    pub targs: Vec<Ty>,
    pub fields: Vec<(String, Ty)>,
    pub offsets: Vec<u32>,
    pub size: u32,
    pub align: u32,
    pub state: u8, // 0 = layout pending, 1 = in progress, 2 = done
}

#[derive(Clone, Debug)]
pub struct EnumInfo {
    pub name: String,
    pub decl: usize,
    pub targs: Vec<Ty>,
    pub variants: Vec<(String, Vec<Ty>)>,
    pub simple: bool,
    pub size: u32,
    pub state: u8,
}

#[derive(Clone, Copy, Debug)]
pub struct Leaf {
    pub off: u32,
    pub t: T,
    pub alias: u32,
}

pub struct Types {
    pub kinds: Vec<TyK>,
    map: HashMap<TyK, Ty>,
    pub structs: Vec<StructInfo>,
    pub enums: Vec<EnumInfo>,
    field_ids: HashMap<(Ty, u32), u32>,
    next_field_id: u32,
    pub layout_errors: Vec<String>,
}

pub const AK_ANY: u32 = 0;
pub const AK_I16: u32 = 1;
pub const AK_I32: u32 = 2;
pub const AK_I64: u32 = 3;
pub const AK_F64: u32 = 4;
pub const AK_PTR: u32 = 5;
pub const AK_F32: u32 = 6;
pub const AK_VEC: u32 = 7;

pub fn may_alias_class(a: u32, b: u32) -> bool {
    let (ka, kb) = (a & 15, b & 15);
    if ka == AK_ANY || kb == AK_ANY {
        return true;
    }
    if ka != kb {
        return false;
    }
    let (fa, fb) = (a >> 4, b >> 4);
    fa == fb || fa == 0 || fb == 0
}

impl Types {
    pub fn new() -> Self {
        let mut t = Types {
            kinds: Vec::new(),
            map: HashMap::new(),
            structs: Vec::new(),
            enums: Vec::new(),
            field_ids: HashMap::new(),
            next_field_id: 1,
            layout_errors: Vec::new(),
        };
        for k in [
            TyK::Err,
            TyK::Unit,
            TyK::Bool,
            TyK::Int(8, true),
            TyK::Int(16, true),
            TyK::Int(32, true),
            TyK::Int(64, true),
            TyK::Int(8, false),
            TyK::Int(16, false),
            TyK::Int(32, false),
            TyK::Int(64, false),
            TyK::F64,
            TyK::F32,
        ] {
            t.intern(k);
        }
        let s = t.intern(TyK::Slice(T_U8));
        assert_eq!(s, T_STR);
        let n = t.intern(TyK::Never);
        assert_eq!(n, T_NEVER);
        for k in [TyK::Vec(2), TyK::Vec(3), TyK::Vec(4), TyK::Quat, TyK::Mat4] {
            t.intern(k);
        }
        assert_eq!(t.intern(TyK::Mat4), T_MAT4);
        t
    }

    pub fn intern(&mut self, k: TyK) -> Ty {
        if let Some(&t) = self.map.get(&k) {
            return t;
        }
        let id = self.kinds.len() as Ty;
        self.kinds.push(k.clone());
        self.map.insert(k, id);
        id
    }
    pub fn k(&self, t: Ty) -> &TyK {
        &self.kinds[t as usize]
    }
    pub fn is_float(&self, t: Ty) -> bool {
        t == T_F64 || t == T_F32
    }
    // vec2 / vec3 / vec4 / quat: the number of f32 lanes
    pub fn vec_lanes(&self, t: Ty) -> Option<u32> {
        match self.k(t) {
            TyK::Vec(n) => Some(*n as u32),
            TyK::Quat => Some(4),
            _ => None,
        }
    }
    pub fn ptr(&mut self, t: Ty) -> Ty {
        self.intern(TyK::Ptr(t))
    }
    pub fn slice(&mut self, t: Ty) -> Ty {
        self.intern(TyK::Slice(t))
    }
    pub fn is_int(&self, t: Ty) -> bool {
        matches!(self.k(t), TyK::Int(..))
    }
    pub fn is_signed(&self, t: Ty) -> bool {
        matches!(self.k(t), TyK::Int(_, true))
    }
    pub fn is_scalar(&self, t: Ty) -> bool {
        match self.k(t) {
            TyK::Bool | TyK::Int(..) | TyK::F64 | TyK::F32 | TyK::Vec(_) | TyK::Quat | TyK::Ptr(_) | TyK::Fn(..) => true,
            TyK::Enum(e) => self.enums[*e as usize].simple,
            _ => false,
        }
    }

    pub fn name(&self, t: Ty) -> String {
        match self.k(t) {
            TyK::Err => "<error>".into(),
            TyK::Unit => "()".into(),
            TyK::Never => "never".into(),
            TyK::Bool => "bool".into(),
            TyK::Int(b, s) => format!("{}{}", if *s { "i" } else { "u" }, b),
            TyK::F64 => "f64".into(),
            TyK::F32 => "f32".into(),
            TyK::Vec(n) => format!("vec{}", n),
            TyK::Quat => "quat".into(),
            TyK::Mat4 => "mat4".into(),
            TyK::Ptr(e) => format!("*{}", self.name(*e)),
            TyK::Slice(e) => {
                if *e == T_U8 {
                    "str".into()
                } else {
                    format!("[]{}", self.name(*e))
                }
            }
            TyK::Array(e, n) => format!("[{}]{}", n, self.name(*e)),
            TyK::Struct(s) => self.structs[*s as usize].name.clone(),
            TyK::Enum(s) => self.enums[*s as usize].name.clone(),
            TyK::Tuple(v) => format!("({})", v.iter().map(|t| self.name(*t)).collect::<Vec<_>>().join(", ")),
            TyK::Fn(p, r) => {
                let ps = p.iter().map(|t| self.name(*t)).collect::<Vec<_>>().join(", ");
                if *r == T_UNIT {
                    format!("fn({})", ps)
                } else {
                    format!("fn({}) {}", ps, self.name(*r))
                }
            }
        }
    }

    fn layout_fields(&mut self, tys: &[Ty]) -> (Vec<u32>, u32, u32) {
        let mut off = 0u32;
        let mut align = 1u32;
        let mut offs = Vec::new();
        for &t in tys {
            let a = self.align_of(t);
            let s = self.size_of(t);
            off = (off + a - 1) / a * a;
            offs.push(off);
            off += s;
            align = align.max(a);
        }
        let size = (off + align - 1) / align * align;
        (offs, size, align)
    }

    pub fn layout_struct(&mut self, sid: u32) {
        let st = self.structs[sid as usize].state;
        if st == 2 {
            return;
        }
        if st == 1 {
            let n = self.structs[sid as usize].name.clone();
            self.layout_errors.push(format!("struct `{}` contains itself by value (use a pointer)", n));
            let s = &mut self.structs[sid as usize];
            s.state = 2;
            s.offsets = vec![0; s.fields.len()];
            s.size = 8;
            s.align = 8;
            return;
        }
        self.structs[sid as usize].state = 1;
        let tys: Vec<Ty> = self.structs[sid as usize].fields.iter().map(|f| f.1).collect();
        let (offs, size, align) = self.layout_fields(&tys);
        let s = &mut self.structs[sid as usize];
        if s.state == 2 {
            return;
        }
        s.offsets = offs;
        s.size = size;
        s.align = align;
        s.state = 2;
    }

    pub fn layout_enum(&mut self, eid: u32) {
        let st = self.enums[eid as usize].state;
        if st == 2 {
            return;
        }
        if st == 1 {
            let n = self.enums[eid as usize].name.clone();
            self.layout_errors.push(format!("enum `{}` contains itself by value (use a pointer)", n));
            self.enums[eid as usize].state = 2;
            self.enums[eid as usize].size = 8;
            return;
        }
        self.enums[eid as usize].state = 1;
        let vars: Vec<Vec<Ty>> = self.enums[eid as usize].variants.iter().map(|v| v.1.clone()).collect();
        let mut size = 8u32;
        for v in &vars {
            let (_, s, _) = self.layout_fields(v);
            let s = (s + 7) / 8 * 8;
            size = size.max(8 + s);
        }
        let e = &mut self.enums[eid as usize];
        if e.state == 2 {
            return;
        }
        e.size = size;
        e.state = 2;
    }

    // offsets of payload fields of a variant, relative to the enum start
    pub fn variant_offsets(&mut self, eid: u32, var: usize) -> Vec<u32> {
        let tys = self.enums[eid as usize].variants[var].1.clone();
        let (offs, _, _) = self.layout_fields(&tys);
        offs.iter().map(|o| o + 8).collect()
    }

    pub fn tuple_offsets(&mut self, tys: &[Ty]) -> Vec<u32> {
        self.layout_fields(tys).0
    }

    pub fn size_of(&mut self, t: Ty) -> u32 {
        match self.k(t).clone() {
            TyK::Err | TyK::Unit | TyK::Never => 0,
            TyK::Bool => 1,
            TyK::Int(b, _) => (b / 8) as u32,
            TyK::F64 | TyK::Ptr(_) | TyK::Fn(..) => 8,
            TyK::F32 => 4,
            TyK::Vec(n) => 4 * n as u32,
            TyK::Quat => 16,
            TyK::Mat4 => 64,
            TyK::Slice(_) => 16,
            TyK::Array(e, n) => (self.size_of(e) as u64 * n).min(u32::MAX as u64) as u32,
            TyK::Struct(s) => {
                self.layout_struct(s);
                self.structs[s as usize].size
            }
            TyK::Enum(e) => {
                self.layout_enum(e);
                self.enums[e as usize].size
            }
            TyK::Tuple(v) => self.layout_fields(&v).1,
        }
    }

    pub fn align_of(&mut self, t: Ty) -> u32 {
        match self.k(t).clone() {
            TyK::Err | TyK::Unit | TyK::Never => 1,
            TyK::Bool => 1,
            TyK::Int(b, _) => (b / 8) as u32,
            TyK::F64 | TyK::Ptr(_) | TyK::Fn(..) | TyK::Slice(_) | TyK::Enum(_) => 8,
            TyK::F32 | TyK::Vec(_) | TyK::Quat | TyK::Mat4 => 4,
            TyK::Array(e, _) => self.align_of(e),
            TyK::Struct(s) => {
                self.layout_struct(s);
                self.structs[s as usize].align
            }
            TyK::Tuple(v) => self.layout_fields(&v).2,
        }
    }

    pub fn field_id(&mut self, owner: Ty, idx: u32) -> u32 {
        if let Some(&f) = self.field_ids.get(&(owner, idx)) {
            return f;
        }
        let f = self.next_field_id;
        self.next_field_id += 1;
        self.field_ids.insert((owner, idx), f);
        f
    }

    // IR type + alias kind of a scalar type
    pub fn scalar_ir(&self, t: Ty) -> (T, u32) {
        match self.k(t) {
            TyK::Bool => (T::I8, AK_ANY),
            TyK::Int(8, _) => (T::I8, AK_ANY),
            TyK::Int(16, _) => (T::I16, AK_I16),
            TyK::Int(32, _) => (T::I32, AK_I32),
            TyK::Int(_, _) => (T::I64, AK_I64),
            TyK::F64 => (T::F64, AK_F64),
            TyK::F32 => (T::F32, AK_F32),
            TyK::Vec(2) => (T::V2, AK_VEC),
            TyK::Vec(3) => (T::V3, AK_VEC),
            TyK::Vec(_) | TyK::Quat => (T::V4, AK_VEC),
            TyK::Ptr(_) | TyK::Fn(..) => (T::I64, AK_PTR),
            TyK::Enum(_) => (T::I64, AK_I64),
            _ => (T::I64, AK_ANY),
        }
    }

    // alias class for a scalar of type `t` that is field `idx` of aggregate `owner`
    pub fn field_alias(&mut self, owner: Ty, idx: u32, t: Ty) -> u32 {
        let (_, k) = self.scalar_ir(t);
        if k == AK_ANY {
            return 0;
        }
        k | (self.field_id(owner, idx) << 4)
    }

    pub fn leaves(&mut self, t: Ty, base: u32, out: &mut Vec<Leaf>) {
        match self.k(t).clone() {
            TyK::Err | TyK::Unit | TyK::Never => {}
            TyK::Mat4 => {
                for c in 0..4 {
                    out.push(Leaf { off: base + 16 * c, t: T::V4, alias: AK_VEC });
                }
            }
            TyK::Bool | TyK::Int(..) | TyK::F64 | TyK::F32 | TyK::Vec(_) | TyK::Quat | TyK::Ptr(_) | TyK::Fn(..) => {
                let (it, k) = self.scalar_ir(t);
                out.push(Leaf { off: base, t: it, alias: k });
            }
            TyK::Slice(_) => {
                let f0 = self.field_id(t, 0);
                let f1 = self.field_id(t, 1);
                out.push(Leaf { off: base, t: T::I64, alias: AK_PTR | (f0 << 4) });
                out.push(Leaf { off: base + 8, t: T::I64, alias: AK_I64 | (f1 << 4) });
            }
            TyK::Array(e, n) => {
                let es = self.size_of(e);
                for i in 0..n {
                    self.leaves(e, base + (i as u32) * es, out);
                    if out.len() > 4096 {
                        return;
                    }
                }
            }
            TyK::Struct(s) => {
                self.layout_struct(s);
                let fields = self.structs[s as usize].fields.clone();
                let offs = self.structs[s as usize].offsets.clone();
                for (i, (_, ft)) in fields.iter().enumerate() {
                    if self.is_scalar(*ft) {
                        let (it, _) = self.scalar_ir(*ft);
                        let a = self.field_alias(t, i as u32, *ft);
                        out.push(Leaf { off: base + offs[i], t: it, alias: a });
                    } else {
                        self.leaves(*ft, base + offs[i], out);
                    }
                }
            }
            TyK::Tuple(v) => {
                let offs = self.tuple_offsets(&v);
                for (i, ft) in v.iter().enumerate() {
                    if self.is_scalar(*ft) {
                        let (it, _) = self.scalar_ir(*ft);
                        let a = self.field_alias(t, i as u32, *ft);
                        out.push(Leaf { off: base + offs[i], t: it, alias: a });
                    } else {
                        self.leaves(*ft, base + offs[i], out);
                    }
                }
            }
            TyK::Enum(e) => {
                if self.enums[e as usize].simple {
                    out.push(Leaf { off: base, t: T::I64, alias: AK_I64 });
                } else {
                    let sz = self.size_of(t);
                    let mut o = 0;
                    while o < sz {
                        out.push(Leaf { off: base + o, t: T::I64, alias: AK_ANY });
                        o += 8;
                    }
                }
            }
        }
    }

    // number of leaves without materializing huge arrays
    pub fn leaf_count(&mut self, t: Ty) -> u64 {
        match self.k(t).clone() {
            TyK::Array(e, n) => self.leaf_count(e).saturating_mul(n),
            TyK::Struct(s) => {
                let fields = self.structs[s as usize].fields.clone();
                fields.iter().map(|f| self.leaf_count(f.1)).fold(0u64, |a, b| a.saturating_add(b))
            }
            TyK::Tuple(v) => v.iter().map(|f| self.leaf_count(*f)).fold(0u64, |a, b| a.saturating_add(b)),
            TyK::Slice(_) => 2,
            TyK::Mat4 => 4,
            TyK::Enum(_) => (self.size_of(t) / 8) as u64,
            TyK::Err | TyK::Unit | TyK::Never => 0,
            _ => 1,
        }
    }
}
