// Lowering of the built-in f32 vector types: vec2 / vec3 / vec4 / quat (one xmm value each)
// and mat4 (four vec4 columns in memory).

priv fn lane_of(c: u8) -> Opt[i64] {
    match c {
        'x', 'r' => Some(0)
        'y', 'g' => Some(1)
        'z', 'b' => Some(2)
        'w', 'a' => Some(3)
        _ => None
    }
}

fn is_vecish(self: *Fx, t: i64) -> bool {
    return is_some(self.cx.types.vec_lanes(t)) || t == T_MAT4
}

// the float type an untyped literal takes in a context expecting `expect`: f64 only where
// f64 is expected, else f32 (the default)
fn float_expect(self: *Fx, expect: Opt[i64]) -> i64 {
    match expect {
        Some(T_F64) => T_F64
        _ => T_F32
    }
}

fn fconst_ty(self: *Fx, ty: i64, f: f64) -> Val {
    if ty == T_F32 {
        v := self.ins(FConst, F32, vec[i64](), i64(cast[u32](f32(f))))
        return self.sval(T_F32, v)
    } else {
        v := self.ins(FConst, F64, vec[i64](), cast[i64](f))
        return self.sval(T_F64, v)
    }
}

priv fn fx_vec_ty(n: i64) -> i64 {
    match n {
        2 => T_VEC2
        3 => T_VEC3
        _ => T_VEC4
    }
}

// like `expr`, but a variable / field / element of scalar type stays a place (not loaded)
fn lvalue_base(self: *Fx, b: *Expr) -> Val {
    match b.k {
        Ident(n) => {
            match self.lookup(n) {
                Some(x) => {
                    if x.0 >= 0 {
                        return self.mval(x.0, x.1)
                    }
                    // a nested function
                    return self.expr(b, None)
                }
                None => {}
            }
            if !self.cx.has_const(n) {
                match self.global_place(n) {
                    Some(m) => return m
                    None => {}
                }
            }
        }
        Field(bb, name) if name != "len" => {
            x := self.lvalue_base(bb)
            match self.field_of(x, name, b.pos) {
                Some(p) => return p
                None => return val_err()
            }
        }
        Index(bb, idx) if idx.len == 1 => {
            match self.index_place(bb, &idx[0], b.pos) {
                Some(p) => return p
                None => return val_err()
            }
        }
        Un(Deref, p) => {
            pv := self.expr(p, None)
            match self.cx.types.k(pv.ty) {
                Ptr(t) => {
                    a := self.scalar(pv)
                    return self.mval(t, a)
                }
                _ => {}
            }
        }
        _ => {}
    }
    return self.expr(b, None)
}

// `.x`, `.xyz`, ... on a vector; None when `bv` is not a vector
fn vec_field(self: *Fx, bv0: Val, name: str, pos: Pos) -> Opt[Opt[Val]] {
    bv := bv0
    no_val: Opt[Val] = None
    match self.cx.types.k(bv.ty) {
        Ptr(t) if is_some(self.cx.types.vec_lanes(t)) => {
            a := self.scalar(bv)
            bv = self.mval(t, a)
        }
        _ => {}
    }
    n := match self.cx.types.vec_lanes(bv.ty) {
        Some(vn) => vn
        None => return None
    }
    vt := self.irt(bv.ty)
    lanes := vec[i64]()
    good := true
    for c in name {
        match lane_of(c) {
            Some(k) => {
                lanes.push(k)
            }
            None => {
                good = false
            }
        }
    }
    if good {
        good = !lanes.is_empty() && lanes.len <= 4
        for i in 0..lanes.len {
            if lanes[i] >= n {
                good = false
            }
        }
    }
    if !good {
        tn := self.tyname(bv.ty)
        self.err(pos, fmt(tn, " has no component `", name, "` (components: ", "xyzw"[..n], "; swizzles like `.xy` or `.zyx` are allowed)"))
        return Some(no_val)
    }
    if lanes.len == 1 {
        if is_some(bv.lane) {
            return Some(no_val)
        }
        if bv.mem {
            return Some(Some(Val{ty: T_F32, v: bv.v, mem: true, alias: bv.alias, lane: Some((lanes[0], vt))}))
        }
        x := self.ins(VExt, F32, vec_one(bv.v), lanes[0])
        return Some(Some(self.sval(T_F32, x)))
    }
    x := self.scalar(bv)
    imm := 0
    for i in 0..lanes.len {
        imm |= lanes[i] << (2 * i)
    }
    rt := fx_vec_ty(lanes.len)
    it := self.irt(rt)
    r := self.ins(VShuf, it, vec_two(x, x), imm)
    return Some(Some(self.sval(rt, r)))
}

// v[i] on a vector: a lane place for constant i, an f32 in memory otherwise
fn vec_index(self: *Fx, bv: Val, idx: *Expr, pos: Pos) -> Opt[Val] {
    n := match self.cx.types.vec_lanes(bv.ty) {
        Some(vn) => vn
        None => return None
    }
    vt := self.irt(bv.ty)
    iv := self.expr(idx, Some(T_I64))
    if iv.ty == T_ERR {
        return None
    }
    if !self.cx.types.is_int(iv.ty) {
        tn := self.tyname(iv.ty)
        self.err(idx.pos, fmt("index must be an integer, found ", tn))
        return None
    }
    i := self.to_i64(iv)
    match self.f.is_const(i) {
        Some(k) => {
            if k < 0 || k >= n {
                self.err(idx.pos, fmt("index ", k, " is out of bounds for length ", n))
                return None
            }
            if bv.mem && !is_some(bv.lane) {
                // (k is 0..3 here)
                return Some(Val{ty: T_F32, v: bv.v, mem: true, alias: bv.alias, lane: Some((k, vt))})
            }
            x := self.scalar(bv)
            r := self.ins(VExt, F32, vec_one(x), k)
            return Some(self.sval(T_F32, r))
        }
        None => {}
    }
    if self.cx.opts.checks {
        ln := self.iconst(I64, n)
        c := self.ins(Ult, I8, vec_two(i, ln), 0)
        self.check(c, 0, pos)
    }
    // a run-time lane: go through memory
    base: i64
    if bv.mem && !is_some(bv.lane) {
        base = bv.v
    } else {
        t := self.temp(bv.ty)
        tv := self.mval(bv.ty, t)
        self.store(tv, bv)
        base = t
    }
    four := self.iconst(I64, 4)
    off := self.ins(Mul, I64, vec_two(i, four), 0)
    a := self.ins(Add, I64, vec_two(base, off), 0)
    p := self.mval(T_F32, a)
    p.alias = AK_ANY
    return Some(p)
}

priv fn vec_eq(self: *Fx, l: Val, r: Val, n: i64) -> i64 {
    x := self.scalar(l)
    y := self.scalar(r)
    acc := NOV
    for k in 0..n {
        a := self.ins(VExt, F32, vec_one(x), k)
        b := self.ins(VExt, F32, vec_one(y), k)
        e := self.ins(FEq, I8, vec_two(a, b), 0)
        if acc == NOV {
            acc = e
        } else {
            acc = self.ins(And, I8, vec_two(acc, e), 0)
        }
    }
    return acc
}

// the operator is not defined for these operand types
priv fn vec_binary_bad(s: *Fx, l: Val, r: Val, pos: Pos) -> Opt[Val] {
    a := s.tyname(l.ty)
    b := s.tyname(r.ty)
    s.err(pos, fmt("this operator is not defined for ", a, " and ", b))
    return Some(val_err())
}

// binary operators with a vector, quaternion or matrix operand; None for other types
fn vec_binary(self: *Fx, op: BinOp, l: Val, r: Val, pos: Pos) -> Opt[Val] {
    ln := self.cx.types.vec_lanes(l.ty)
    rn := self.cx.types.vec_lanes(r.ty)
    if !is_some(ln) && !is_some(rn) && l.ty != T_MAT4 && r.ty != T_MAT4 {
        return None
    }
    eq := op == Eq || op == Ne
    if l.ty == T_MAT4 || r.ty == T_MAT4 {
        if op == Mul && l.ty == T_MAT4 && r.ty == T_MAT4 {
            return Some(self.call_rt("__mat4_mul", vec[i64](), vec_two[Val](l, r), pos))
        }
        if op == Mul && l.ty == T_MAT4 && r.ty == T_VEC4 {
            return Some(self.call_rt("__mat4_mulv", vec[i64](), vec_two[Val](l, r), pos))
        }
        if l.ty == T_MAT4 && r.ty == T_MAT4 && eq {
            acc := NOV
            for c in 0..4 {
                a := self.add_off(l.v, 16 * c)
                b := self.add_off(r.v, 16 * c)
                x := self.mval(T_VEC4, a)
                y := self.mval(T_VEC4, b)
                e := self.vec_eq(x, y, 4)
                if acc == NOV {
                    acc = e
                } else {
                    acc = self.ins(And, I8, vec_two(acc, e), 0)
                }
            }
            if op == Ne {
                one := self.iconst(I8, 1)
                acc = self.ins(Xor, I8, vec_two(acc, one), 0)
            }
            return Some(self.sval(T_BOOL, acc))
        }
        return vec_binary_bad(self, l, r, pos)
    }
    if op == Mul && l.ty == T_QUAT && r.ty == T_QUAT {
        return Some(self.call_rt("__quat_mul", vec[i64](), vec_two[Val](l, r), pos))
    }
    if op == Mul && l.ty == T_QUAT && r.ty == T_VEC3 {
        return Some(self.call_rt("__quat_rotate", vec[i64](), vec_two[Val](l, r), pos))
    }
    if eq {
        if l.ty != r.ty {
            return vec_binary_bad(self, l, r, pos)
        }
        lanes := match ln {
            Some(k) => k
            None => panic("unwrap of None")
        }
        e := self.vec_eq(l, r, lanes)
        if op == Ne {
            one := self.iconst(I8, 1)
            e = self.ins(Xor, I8, vec_two(e, one), 0)
        }
        return Some(self.sval(T_BOOL, e))
    }
    o := match op {
        Add => FAdd
        Sub => FSub
        Mul => FMul
        Div => FDiv
        _ => return vec_binary_bad(self, l, r, pos)
    }
    // vector op vector, vector op f32, f32 op vector
    ty: i64
    a: i64
    b: i64
    if l.ty == r.ty {
        ty = l.ty
        a = self.scalar(l)
        b = self.scalar(r)
    } else if is_some(ln) && r.ty == T_F32 {
        it := self.irt(l.ty)
        a = self.scalar(l)
        s := self.scalar(r)
        ty = l.ty
        b = self.ins(VSplat, it, vec_one(s), 0)
    } else if is_some(rn) && l.ty == T_F32 {
        it := self.irt(r.ty)
        s := self.scalar(l)
        a = self.ins(VSplat, it, vec_one(s), 0)
        ty = r.ty
        b = self.scalar(r)
    } else {
        x := self.tyname(l.ty)
        y := self.tyname(r.ty)
        self.err(pos, fmt("operands have different types: ", x, " and ", y, " (vectors combine with the same vector type or with f32)"))
        return Some(val_err())
    }
    it := self.irt(ty)
    v := self.ins(o, it, vec_two(a, b), 0)
    return Some(self.sval(ty, v))
}

// vec2(..) / vec3(..) / vec4(..) / quat(..) / mat4(..)
fn vec_construct(self: *Fx, to: i64, args: []Expr, pos: Pos) -> Val {
    tn := self.tyname(to)
    vals := vec[(Val, Pos)]()
    for i in 0..len(args) {
        v := self.expr(&args[i], Some(T_F32))
        if v.ty == T_ERR {
            return val_err()
        }
        vals.push((v, args[i].pos))
    }
    if to == T_MAT4 {
        if vals.len == 1 && vals[0].0.ty == T_MAT4 {
            return vals[0].0
        }
        if vals.len == 1 && vals[0].0.ty == T_F32 {
            return self.call_rt("__mat4_diag", vec[i64](), vec_one[Val](vals[0].0), pos)
        }
        all_vec4 := true
        for i in 0..vals.len {
            if vals[i].0.ty != T_VEC4 {
                all_vec4 = false
                break
            }
        }
        if vals.len != 4 || !all_vec4 {
            self.err(pos, "mat4(...) takes four vec4 columns, or one f32 for a diagonal matrix")
            return val_err()
        }
        cols := vec[i64]()
        for i in 0..vals.len {
            cols.push(self.scalar(vals[i].0))
        }
        t := self.temp(T_MAT4)
        for c in 0..cols.len {
            a := self.add_off(t, 16 * c)
            self.store_raw(a, cols[c], V4, AK_VEC)
        }
        return self.mval(T_MAT4, t)
    }
    n := match self.cx.types.vec_lanes(to) {
        Some(vn) => vn
        None => panic("unwrap of None")
    }
    it := self.irt(to)
    if vals.len == 1 {
        v := vals[0].0
        if v.ty == to {
            return v
        }
        if v.ty == T_F32 {
            s := self.scalar(v)
            r := self.ins(VSplat, it, vec_one(s), 0)
            return self.sval(to, r)
        }
        match self.cx.types.vec_lanes(v.ty) {
            Some(m) if m >= n => {
                // drop trailing lanes (or reinterpret vec4 <-> quat)
                x := self.scalar(v)
                r := self.ins(VShuf, it, vec_two(x, x), 0xE4)
                return self.sval(to, r)
            }
            _ => {}
        }
    }
    lanes := vec[i64]()
    for i in 0..vals.len {
        v := vals[i].0
        apos := vals[i].1
        if v.ty == T_F32 {
            lanes.push(self.scalar(v))
        } else {
            match self.cx.types.vec_lanes(v.ty) {
                Some(m) => {
                    x := self.scalar(v)
                    for k in 0..m {
                        lanes.push(self.ins(VExt, F32, vec_one(x), k))
                    }
                }
                None => {
                    an := self.tyname(v.ty)
                    self.err(apos, fmt(tn, "(...) takes f32 components or smaller vectors, found ", an, " (convert with `f32(x)`)"))
                    return val_err()
                }
            }
        }
    }
    if lanes.len != n {
        self.err(pos, fmt(tn, "(...) needs ", n, " components (or a single f32 for all of them), got ", lanes.len))
        return val_err()
    }
    r := self.ins(VBuild, it, lanes, 0)
    return self.sval(to, r)
}

// print a vector / matrix
fn put_vec(self: *Fx, v: Val, pos: Pos) {
    if v.ty == T_MAT4 {
        self.put_lit_pub("mat4(", pos)
        for c in 0..4 {
            if c > 0 {
                self.put_lit_pub(", ", pos)
            }
            a := self.add_off(v.v, 16 * c)
            col := self.mval(T_VEC4, a)
            self.put_vec(col, pos)
        }
        self.put_lit_pub(")", pos)
        return
    }
    n := match self.cx.types.vec_lanes(v.ty) {
        Some(vn) => vn
        None => panic("unwrap of None")
    }
    tn := self.tyname(v.ty)
    x := self.scalar(v)
    self.put_lit_pub(fmt(tn, "("), pos)
    for k in 0..n {
        if k > 0 {
            self.put_lit_pub(", ", pos)
        }
        l := self.ins(VExt, F32, vec_one(x), k)
        lv := self.sval(T_F32, l)
        self.call_rt("__put_f32", vec[i64](), vec_one[Val](lv), pos)
    }
    self.put_lit_pub(")", pos)
}
