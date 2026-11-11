// Expression lowering: operators, places, literals, conversions, match.

fn lower_expr_is_arith(op BinOp) bool {
    return op == BinOpAdd || op == BinOpSub || op == BinOpMul || op == BinOpDiv || op == BinOpRem || op == BinOpAnd || op == BinOpOr || op == BinOpXor
}
fn lower_expr_is_cmp(op BinOp) bool {
    return op == BinOpEq || op == BinOpNe || op == BinOpLt || op == BinOpLe || op == BinOpGt || op == BinOpGe
}

// `a.or(b)` on optional types
fn lower_expr_or(a Opt[i64], b Opt[i64]) Opt[i64] {
    match a {
        Some(x) => { return a }
        None => { return b }
    }
    return b
}

// `o.unwrap()`
fn lower_expr_unwrap(o Opt[i64]) i64 {
    match o {
        Some(x) => { return x }
        None => {}
    }
    panic("called `Option::unwrap()` on a `None` value")
}

// `b as i64`
fn lower_expr_bool_i64(b bool) i64 {
    if b {
        return 1
    }
    return 0
}

// matches!(k, TyK::Ptr(_))
fn lower_expr_is_ptr(k TyK) bool {
    match k {
        TyKPtr(t) => { return true }
        _ => { return false }
    }
    return false
}

// matches!(o, Some(CV::Float(_)))
fn lower_expr_is_cv_float(o Opt[CV]) bool {
    match o {
        Some(cv) => {
            match cv {
                CVFloat(f) => { return true }
                _ => { return false }
            }
        }
        None => {}
    }
    return false
}

// matches!(x.k, EK::Ident(_) | EK::Field(..) | EK::Index(..) | EK::Un(UnOp::Deref, _))
fn lower_expr_addressable(x *Expr) bool {
    match x.k {
        EKIdent(n) => { return true }
        EKField(b, n) => { return true }
        EKIndex(b, idx) => { return true }
        EKUn(op, p) => { return op == UnOpDeref }
        _ => { return false }
    }
    return false
}

// `name.parse::<usize>()`: decimal digits with an optional leading `+`
fn lower_expr_parse_usize(s str) (i64, bool) {
    i := 0
    if len(s) > 0 && s[0] == '+' {
        i = 1
    }
    if i >= len(s) {
        return (0, false)
    }
    v := 0
    while i < len(s) {
        c := s[i]
        if c < '0' || c > '9' {
            return (0, false)
        }
        d := i64(c - '0')
        if v > (0x7FFFFFFFFFFFFFFF - d) / 10 {
            return (0, false)
        }
        v = v * 10 + d
        i += 1
    }
    return (v, true)
}

fn is_untyped(self *Fx, e *Expr) bool {
    match e.k {
        EKInt(n) => { return true }
        EKFloat(f) => { return true }
        EKNil => { return true }
        EKUn(op, x) => {
            if op == UnOpNeg || op == UnOpBitNot {
                return self.is_untyped(x)
            }
            return false
        }
        EKBin(op, a, b) => {
            if lower_expr_is_arith(op) || op == BinOpShl || op == BinOpShr {
                return self.is_untyped(a) && self.is_untyped(b)
            }
            return false
        }
        EKIdent(n) => {
            if is_some(self.lookup(n)) {
                return false
            }
            d, has := self.cx.const_decls.get(n)
            if has && !is_some(d.ty) {
                return !self.cx.const_is_mem(n)
            }
            return self.cx.variants.has(n) && !self.cx.const_decls.has(n)
        }
        _ => { return false }
    }
    return false
}

fn int_lit(self *Fx, n i64, neg bool, expect Opt[i64], pos Pos) Val {
    match expect {
        Some(ty) => {
            match self.cx.types.k(ty) {
                TyKInt(bits, signed) => {
                    if bits < 64 {
                        lo := -(1 << (bits - 1))
                        hi := if signed && neg { 1 << (bits - 1) } else { 1 << bits }
                        if n < lo || n >= hi {
                            tn := self.tyname(ty)
                            self.err(pos, fmt("integer literal ", n, " does not fit in ", tn))
                        }
                    }
                    it := self.irt(ty)
                    v := self.iconst(it, n)
                    return self.sval(ty, v)
                }
                TyKF64 => { return self.lower_expr_int_lit_float(n, expect) }
                TyKF32 => { return self.lower_expr_int_lit_float(n, expect) }
                TyKVec(l) => { return self.lower_expr_int_lit_float(n, expect) }
                TyKQuat => { return self.lower_expr_int_lit_float(n, expect) }
                TyKMat4 => { return self.lower_expr_int_lit_float(n, expect) }
                _ => {}
            }
        }
        None => {}
    }
    v := self.iconst(TI64, n)
    return self.sval(T_I64, v)
}

// the float arm of `int_lit`
fn lower_expr_int_lit_float(self *Fx, n i64, expect Opt[i64]) Val {
    ft := self.float_expect(expect)
    return self.fconst_ty(ft, f64(n))
}

fn const_val(self *Fx, ty Opt[i64], cv CV, expect Opt[i64], pos Pos) Val {
    match cv {
        CVInt(i) => { return self.int_lit(i, i < 0, lower_expr_or(ty, expect), pos) }
        CVFloat(f) => {
            ft := self.float_expect(lower_expr_or(ty, expect))
            return self.fconst_ty(ft, f)
        }
        CVBool(b) => {
            v := self.iconst(TI8, lower_expr_bool_i64(b))
            return self.sval(T_BOOL, v)
        }
        CVStr(s) => { return self.str_val(s) }
    }
    return val_err()
}

fn expr(self *Fx, e *Expr, expect Opt[i64]) Val {
    match e.k {
        EKInt(n) => { return self.int_lit(i64(n), false, expect, e.pos) }
        EKFloat(f) => {
            match expect {
                Some(t) => {
                    if self.cx.types.is_int(t) {
                        tn := self.tyname(t)
                        self.err(e.pos, fmt("float literal used where ", tn, " is expected"))
                    }
                }
                None => {}
            }
            ft := self.float_expect(expect)
            return self.fconst_ty(ft, f)
        }
        EKBool(b) => {
            v := self.iconst(TI8, lower_expr_bool_i64(b))
            return self.sval(T_BOOL, v)
        }
        EKNil => {
            match expect {
                Some(et) => {
                    match self.cx.types.k(et) {
                        TyKPtr(t) => {
                            v := self.iconst(TI64, 0)
                            return self.sval(et, v)
                        }
                        TyKFn(ps, r) => {
                            v := self.iconst(TI64, 0)
                            return self.sval(et, v)
                        }
                        TyKSlice(t) => {
                            tmp := self.temp(et)
                            v := self.mval(et, tmp)
                            self.zero(v)
                            return v
                        }
                        TyKErr => { return val_err() }
                        _ => {}
                    }
                }
                None => {}
            }
            self.err(e.pos, "cannot infer the type of `nil` here")
            return val_err()
        }
        EKStr(s) => { return self.str_val(s) }
        EKIdent(n) => { return self.ident(n, expect, e.pos) }
        EKUn(op, x) => { return self.unary(op, x, expect, e.pos) }
        EKBin(op, a, b) => { return self.binary(op, a, b, expect, e.pos) }
        EKCall(c, args) => { return self.call(c, args.items(), expect, e.pos) }
        EKField(b, name) => {
            if name == "len" {
                // .len on slices and arrays
                bv := self.expr(b, None)
                match self.len_of(bv) {
                    Some(v) => { return v }
                    None => {}
                }
                match self.field_of(bv, name, e.pos) {
                    Some(p) => { return self.rvalue(p) }
                    None => { return val_err() }
                }
            }
            bv := self.expr(b, None)
            match self.field_of(bv, name, e.pos) {
                Some(p) => { return self.rvalue(p) }
                None => { return val_err() }
            }
        }
        EKIndex(b, idx) => {
            // f[T]: an instantiation of a generic function as a value
            match b.k {
                EKIdent(n) => {
                    if !is_some(self.lookup(n)) && self.cx.fn_candidates(n).len != 0 && !self.cx.global_decls.has(n) {
                        env := self.tenv
                        saved := self.cx.errs.len
                        // collecting into an Option stops at the first failure
                        tys := vec[i64]()
                        ok := true
                        for i in 0..idx.len {
                            match self.cx.expr_type(&idx.buf[i], &env) {
                                Some(x) => {
                                    if x != T_ERR {
                                        tys.push(x)
                                    } else {
                                        ok = false
                                    }
                                }
                                None => { ok = false }
                            }
                            if !ok {
                                break
                            }
                        }
                        self.cx.errs.truncate(saved)
                        if ok {
                            match self.fn_value(n, Some(tys), expect) {
                                Some(v) => { return v }
                                None => {
                                    self.err(e.pos, fmt("no definition of `", n, "` takes these type arguments"))
                                    return val_err()
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
            if idx.len != 1 {
                self.err(e.pos, "expected a single index")
                return val_err()
            }
            match self.index_place(b, &idx.buf[0], e.pos) {
                Some(p) => { return self.rvalue(p) }
                None => { return val_err() }
            }
        }
        EKSlice(b, lo, hi) => { return self.slice_expr(b, lo, hi, e.pos) }
        EKLit(te, items) => {
            var ty i64
            match self.lit_type(te, expect) {
                Some(t) => { ty = t }
                None => { return val_err() }
            }
            match self.cx.types.k(ty) {
                TyKSlice(et) => {
                    // heap-allocated slice literal
                    es := self.cx.types.size_of(et)
                    n := items.len
                    bytes := self.iconst(TI64, n * es)
                    bv := self.sval(T_I64, bytes)
                    p := self.call_rt("__alloc_raw", vec[i64](), vec_of([]Val{bv}), e.pos)
                    pv := self.scalar(p)
                    for i in 0..items.len {
                        item := &items.buf[i].1
                        if is_some(items.buf[i].0) {
                            self.err(item.pos, "slice literal elements cannot be named")
                        }
                        v0 := self.expr(item, Some(et))
                        v := self.coerce(v0, et, item.pos)
                        a := self.add_off(pv, i * es)
                        dst := self.mval(et, a)
                        self.store(dst, v)
                    }
                    t := self.temp(ty)
                    sv := self.mval(ty, t)
                    nv := self.iconst(TI64, n)
                    self.store_slice(sv, pv, nv)
                    return sv
                }
                _ => {}
            }
            t := self.temp(ty)
            dst := self.mval(ty, t)
            self.init_lit(dst, items.items(), e.pos)
            return dst
        }
        EKTypeE(ta) => {
            self.err(e.pos, "a type cannot be used as a value here")
            return val_err()
        }
        EKIf(c, t, el) => { return self.if_value(c, &t, &el, true, expect) }
        EKTuple(es) => {
            var exp_tys Opt[Vec[i64]] = None
            match expect {
                Some(t) => {
                    match self.cx.types.k(t) {
                        TyKTuple(ts) => {
                            if ts.len == es.len {
                                exp_tys = Some(ts)
                            }
                        }
                        _ => {}
                    }
                }
                None => {}
            }
            vals := vec[Val]()
            for i in 0..es.len {
                x := &es.buf[i]
                var xe Opt[i64] = None
                match exp_tys {
                    Some(t) => { xe = Some(t.buf[i]) }
                    None => {}
                }
                v0 := self.expr(x, xe)
                // stabilize scalars now; aggregates are copied below
                if v0.ty == T_ERR {
                    return val_err()
                }
                if v0.ty == T_UNIT || v0.ty == T_NEVER {
                    self.err(x.pos, "tuple element has no value")
                    return val_err()
                }
                v := v0
                if v0.mem {
                    t := self.temp(v0.ty)
                    tv := self.mval(v0.ty, t)
                    self.store(tv, v0)
                    v = tv
                }
                vals.push(v)
            }
            tys := vec[i64]()
            for i in 0..vals.len {
                tys.push(vals.buf[i].ty)
            }
            ty := self.cx.types.intern(TyKTuple(clone(tys)))
            offs := self.cx.types.tuple_offsets(tys.items())
            t := self.temp(ty)
            for i in 0..vals.len {
                a := self.add_off(t, offs.buf[i])
                dst := self.mval(tys.buf[i], a)
                if self.cx.types.is_scalar(tys.buf[i]) {
                    dst.alias = self.cx.types.field_alias(ty, i, tys.buf[i])
                }
                self.store(dst, vals.buf[i])
            }
            return self.mval(ty, t)
        }
        EKMatch(sc, arms) => { return self.match_expr(sc, arms.items(), true, expect, e.pos) }
    }
    return val_err()
}

// load scalars out of places; aggregates stay in memory
fn rvalue(self *Fx, p Val) Val {
    if p.mem && self.cx.types.is_scalar(p.ty) {
        v := self.scalar(p)
        return self.sval(p.ty, v)
    }
    return p
}

fn ident(self *Fx, n str, expect Opt[i64], pos Pos) Val {
    match self.lookup(n) {
        Some(x) => {
            m := self.mval(x.0, x.1)
            return self.rvalue(m)
        }
        None => {}
    }
    if self.cx.const_decls.has(n) {
        if self.cx.const_is_mem(n) {
            // an aggregate or vector constant: read from its read-only memory
            match self.cx.const_global(n) {
                Some(g) => {
                    a := self.ins(OpGAddr, TI64, vec[i64](), g.1)
                    m := self.mval(g.0, a)
                    m.ro = true
                    return self.rvalue(m)
                }
                None => { return val_err() }
            }
        }
        match self.cx.const_named(n) {
            Some(c) => { return self.const_val(c.0, c.1, expect, pos) }
            None => { return val_err() }
        }
    }
    match self.cx.global(n) {
        Some(g) => {
            a := self.ins(OpGAddr, TI64, vec[i64](), g.1)
            m := self.mval(g.0, a)
            return self.rvalue(m)
        }
        None => {}
    }
    if self.cx.fn_candidates(n).len != 0 {
        var no_targs Opt[Vec[i64]] = None
        match self.fn_value(n, no_targs, expect) {
            Some(v) => { return v }
            None => {
                self.err(pos, fmt("function `", n, "` cannot be used as a value here: it is generic or overloaded; write `", n, "[T]` or give the destination a function type"))
                return val_err()
            }
        }
    }
    vv, is_variant := self.cx.variants.get(n)
    if is_variant {
        var no_args []Expr
        return self.construct_variant(vv.0, vv.1, no_args, expect, pos)
    }
    if is_some(lower_builtin_type(n)) || self.tenv.has(n) || is_some(self.cx.find_struct(n)) || is_some(self.cx.find_alias(n)) {
        self.err(pos, fmt("type `", n, "` cannot be used as a value here"))
        return val_err()
    }
    hint := match n {
        "null", "NULL", "None", "nullptr" => " (the null pointer is `nil`)"
        "self", "this" => " (methods are plain functions: name the receiver parameter explicitly)"
        _ => ""
    }
    self.err(pos, fmt("unknown identifier `", n, "`", hint, self.cx.priv_hint(n)))
    return val_err()
}

// the name of the constant that the place expression `e` is (a part of), if any
fn const_root(self *Fx, e *Expr) Opt[str] {
    match e.k {
        EKIdent(n) => {
            if !is_some(self.lookup(n)) && self.cx.const_decls.has(n) {
                return Some(n)
            }
        }
        EKField(b, _) => { return self.const_root(b) }
        EKIndex(b, _) => { return self.const_root(b) }
        _ => {}
    }
    return None
}

// "`TABLE` is a constant" for an attempt to modify (a part of) a constant: the constant
// itself, its fields and elements, and what its strings point to are all read-only
fn const_place_err(self *Fx, e *Expr, what str) {
    match self.const_root(e) {
        Some(n) => {
            self.err(e.pos, fmt("`", n, "` is a constant: ", what, " (copy it to a variable, or declare it with `var` to make it a global variable)"))
        }
        None => {
            self.err(e.pos, fmt("this is part of a constant: ", what))
        }
    }
}

// a place to assign to
fn place(self *Fx, e *Expr) Opt[Val] {
    if is_some(self.const_root(e)) {
        self.const_place_err(e, "it cannot be assigned to")
        return None
    }
    match self.place_raw(e) {
        Some(p) => {
            if p.ro {
                self.const_place_err(e, "it cannot be assigned to")
                return None
            }
            return Some(p)
        }
        None => {}
    }
    return None
}

fn place_raw(self *Fx, e *Expr) Opt[Val] {
    match e.k {
        EKIdent(n) => {
            match self.lookup(n) {
                Some(x) => { return Some(self.mval(x.0, x.1)) }
                None => {}
            }
            if !self.cx.const_decls.has(n) {
                match self.cx.global(n) {
                    Some(g) => {
                        a := self.ins(OpGAddr, TI64, vec[i64](), g.1)
                        return Some(self.mval(g.0, a))
                    }
                    None => {}
                }
            }
            if self.cx.const_decls.has(n) || is_some(self.cx.find_fn(n)) {
                self.err(e.pos, fmt("`", n, "` is not assignable"))
            } else {
                self.err(e.pos, fmt("unknown variable `", n, "` (declare it with `:=`)", self.cx.priv_hint(n)))
            }
            return None
        }
        EKField(b, name) => {
            bv := self.lvalue_base(b)
            match self.field_of(bv, name, e.pos) {
                Some(p) => {
                    if !p.mem {
                        self.err(e.pos, "expression is not assignable")
                        return None
                    }
                    return Some(p)
                }
                None => { return None }
            }
        }
        EKIndex(b, idx) => {
            if idx.len == 1 {
                match self.index_place(b, &idx.buf[0], e.pos) {
                    Some(p) => {
                        if !p.mem {
                            self.err(e.pos, "expression is not assignable")
                            return None
                        }
                        return Some(p)
                    }
                    None => { return None }
                }
            }
        }
        EKUn(op, p) => {
            if op == UnOpDeref {
                pv := self.expr(p, None)
                match self.cx.types.k(pv.ty) {
                    TyKPtr(t) => {
                        a := self.scalar(pv)
                        return Some(self.mval(t, a))
                    }
                    TyKErr => { return None }
                    _ => {
                        tn := self.tyname(pv.ty)
                        self.err(e.pos, fmt("cannot dereference ", tn))
                        return None
                    }
                }
            }
        }
        _ => {}
    }
    self.err(e.pos, "expression is not assignable")
    return None
}

// auto-dereference pointers to aggregates
fn auto_deref(self *Fx, v0 Val) Val {
    v := v0
    loop {
        match self.cx.types.k(v.ty) {
            TyKPtr(t) => {
                if !lower_expr_is_ptr(self.cx.types.k(t)) && !self.cx.types.is_scalar(t) {
                    a := self.scalar(v)
                    v = self.mval(t, a)
                } else {
                    return v
                }
            }
            _ => { return v }
        }
    }
    return v
}

fn field_of(self *Fx, base Val, written str, pos Pos) Opt[Val] {
    // `x.f[..](..)` in a file with a private function `f` carries its internal name (priv.al)
    name := ast_plain(written)
    bv := self.auto_deref(base)
    match self.vec_field(bv, name, pos) {
        Some(r) => {
            if bv.ro {
                match r {
                    Some(lane_v) => {
                        rv := lane_v
                        rv.ro = true
                        return Some(rv)
                    }
                    None => {}
                }
            }
            return r
        }
        None => {}
    }
    match self.cx.types.k(bv.ty) {
        TyKStruct(sid) => {
            self.cx.types.layout_struct(sid)
            si := &self.cx.types.structs.buf[sid]
            fi := -1
            for i in 0..si.fields.len {
                if si.fields.buf[i].0 == name {
                    fi = i
                    break
                }
            }
            if fi >= 0 {
                fty := si.fields.buf[fi].1
                off := si.offsets.buf[fi]
                a := self.add_off(bv.v, off)
                v := self.mval(fty, a)
                if self.cx.types.is_scalar(fty) {
                    v.alias = self.cx.types.field_alias(bv.ty, fi, fty)
                }
                v.ro = bv.ro
                return Some(v)
            }
            tn := self.tyname(bv.ty)
            names := vec[str]()
            fields := self.cx.types.structs.buf[sid].fields
            for i in 0..fields.len {
                names.push(fields.buf[i].0)
            }
            self.err(pos, fmt(tn, " has no field `", name, "` (fields: ", join(names.items(), ", "), ")"))
            return None
        }
        TyKTuple(tys) => {
            i, ok := lower_expr_parse_usize(name)
            if ok && i < tys.len {
                offs := self.cx.types.tuple_offsets(tys.items())
                a := self.add_off(bv.v, offs.buf[i])
                v := self.mval(tys.buf[i], a)
                if self.cx.types.is_scalar(tys.buf[i]) {
                    v.alias = self.cx.types.field_alias(bv.ty, i, tys.buf[i])
                }
                v.ro = bv.ro
                return Some(v)
            }
            tn := self.tyname(bv.ty)
            self.err(pos, fmt(tn, " has no element `", name, "`"))
            return None
        }
        TyKErr => { return None }
        _ => {
            tn := self.tyname(bv.ty)
            self.err(pos, fmt(tn, " has no field `", name, "`"))
            return None
        }
    }
    return None
}

fn len_of(self *Fx, v0 Val) Opt[Val] {
    v := self.auto_deref(v0)
    match self.cx.types.k(v.ty) {
        TyKSlice(et) => {
            p, l := self.slice_parts(v)
            return Some(self.sval(T_I64, l))
        }
        TyKArray(et, n) => {
            l := self.iconst(TI64, i64(n))
            return Some(self.sval(T_I64, l))
        }
        _ => { return None }
    }
    return None
}

fn to_i64(self *Fx, v Val) i64 {
    s := self.scalar(v)
    it := self.irt(v.ty)
    if it == TI64 {
        return s
    }
    op := if self.cx.types.is_signed(v.ty) { OpSExt } else { OpZExt }
    return self.ins(op, TI64, vec_of([]i64{s}), 0)
}

// (ptr, len or NOV, elem type) of an indexable value
fn indexable(self *Fx, bv0 Val, pos Pos) Opt[(i64, i64, i64)] {
    bv := self.auto_deref(bv0)
    match self.cx.types.k(bv.ty) {
        TyKSlice(et) => {
            p, l := self.slice_parts(bv)
            return Some((p, l, et))
        }
        TyKMat4 => {
            l := self.iconst(TI64, 4)
            return Some((bv.v, l, T_VEC4))
        }
        TyKArray(et, n) => {
            l := self.iconst(TI64, i64(n))
            return Some((bv.v, l, et))
        }
        TyKPtr(t) => {
            p := self.scalar(bv)
            return Some((p, NOV, t))
        }
        TyKErr => { return None }
        _ => {
            tn := self.tyname(bv.ty)
            self.err(pos, fmt("cannot index ", tn))
            return None
        }
    }
    return None
}

fn index_place(self *Fx, b *Expr, idx *Expr, pos Pos) Opt[Val] {
    bv := self.lvalue_base(b)
    if is_some(self.cx.types.vec_lanes(bv.ty)) {
        match self.vec_index(bv, idx, pos) {
            Some(lane_v) => {
                rv := lane_v
                rv.ro = bv.ro
                return Some(rv)
            }
            None => { return None }
        }
    }
    var ptr_ i64
    var len_ i64
    var et i64
    match self.indexable(bv, pos) {
        Some(x) => {
            ptr_ = x.0
            len_ = x.1
            et = x.2
        }
        None => { return None }
    }
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
    if len_ != NOV {
        oci := self.f.is_const(i)
        ocl := self.f.is_const(len_)
        both := false
        match oci {
            Some(ci) => {
                match ocl {
                    Some(cl) => {
                        both = true
                        if ci < 0 || ci >= cl {
                            self.err(idx.pos, fmt("index ", ci, " is out of bounds for length ", cl))
                        }
                    }
                    None => {}
                }
            }
            None => {}
        }
        if !both && self.cx.opts.checks {
            c := self.ins(OpUlt, TI8, vec_of([]i64{i, len_}), 0)
            self.check(c, 0, pos)
        }
    }
    es := self.cx.types.size_of(et)
    off := i
    if es != 1 {
        c := self.iconst(TI64, es)
        off = self.ins(OpMul, TI64, vec_of([]i64{i, c}), 0)
    }
    a := self.ins(OpAdd, TI64, vec_of([]i64{ptr_, off}), 0)
    ev := self.mval(et, a)
    // the elements of an array (or matrix) constant are part of the constant
    if bv.ro {
        match self.cx.types.k(bv.ty) {
            TyKArray(_, _) => { ev.ro = true }
            TyKMat4 => { ev.ro = true }
            _ => {}
        }
    }
    return Some(ev)
}

fn slice_expr(self *Fx, b *Expr, lo Opt[*Expr], hi Opt[*Expr], pos Pos) Val {
    bv := self.expr(b, None)
    var ptr_ i64
    var len_ i64
    var et i64
    match self.indexable(bv, pos) {
        Some(x) => {
            ptr_ = x.0
            len_ = x.1
            et = x.2
        }
        None => { return val_err() }
    }
    var lo_v i64
    match lo {
        Some(l) => {
            v := self.expr(l, Some(T_I64))
            if !self.cx.types.is_int(v.ty) {
                if v.ty != T_ERR {
                    self.err(l.pos, "slice bound must be an integer")
                }
                return val_err()
            }
            lo_v = self.to_i64(v)
        }
        None => { lo_v = self.iconst(TI64, 0) }
    }
    var hi_v i64
    match hi {
        Some(h) => {
            v := self.expr(h, Some(T_I64))
            if !self.cx.types.is_int(v.ty) {
                if v.ty != T_ERR {
                    self.err(h.pos, "slice bound must be an integer")
                }
                return val_err()
            }
            hi_v = self.to_i64(v)
        }
        None => {
            if len_ == NOV {
                self.err(pos, "slicing a raw pointer needs an upper bound")
                return val_err()
            }
            hi_v = len_
        }
    }
    if self.cx.opts.checks {
        c := self.ins(OpUle, TI8, vec_of([]i64{lo_v, hi_v}), 0)
        self.check(c, 0, pos)
        if len_ != NOV && is_some(hi) {
            c2 := self.ins(OpUle, TI8, vec_of([]i64{hi_v, len_}), 0)
            self.check(c2, 0, pos)
        }
    }
    es := self.cx.types.size_of(et)
    c := self.iconst(TI64, es)
    off := self.ins(OpMul, TI64, vec_of([]i64{lo_v, c}), 0)
    p := self.ins(OpAdd, TI64, vec_of([]i64{ptr_, off}), 0)
    n := self.ins(OpSub, TI64, vec_of([]i64{hi_v, lo_v}), 0)
    sty := self.cx.types.slice(et)
    t := self.temp(sty)
    sv := self.mval(sty, t)
    self.store_slice(sv, p, n)
    return sv
}

fn unary(self *Fx, op UnOp, x *Expr, expect Opt[i64], pos Pos) Val {
    match op {
        UnOpNeg => {
            match x.k {
                EKInt(n) => { return self.int_lit(-i64(n), true, expect, pos) }
                _ => {}
            }
            v := self.expr(x, expect)
            if v.ty == T_ERR {
                return v
            }
            if self.cx.types.is_int(v.ty) {
                it := self.irt(v.ty)
                z := self.iconst(it, 0)
                s := self.scalar(v)
                r := self.ins(OpSub, it, vec_of([]i64{z, s}), 0)
                return self.sval(v.ty, r)
            } else if self.cx.types.is_float(v.ty) || is_some(self.cx.types.vec_lanes(v.ty)) {
                it := self.irt(v.ty)
                s := self.scalar(v)
                r := self.ins(OpFNeg, it, vec_of([]i64{s}), 0)
                return self.sval(v.ty, r)
            } else {
                tn := self.tyname(v.ty)
                self.err(pos, fmt("cannot negate ", tn))
                return val_err()
            }
        }
        UnOpNot => {
            v0 := self.expr(x, Some(T_BOOL))
            v := self.coerce(v0, T_BOOL, x.pos)
            if v.ty == T_ERR {
                return v
            }
            s := self.scalar(v)
            one := self.iconst(TI8, 1)
            r := self.ins(OpXor, TI8, vec_of([]i64{s, one}), 0)
            return self.sval(T_BOOL, r)
        }
        UnOpBitNot => {
            v := self.expr(x, expect)
            if v.ty == T_ERR {
                return v
            }
            if !self.cx.types.is_int(v.ty) {
                tn := self.tyname(v.ty)
                self.err(pos, fmt("`~` needs an integer, found ", tn))
                return val_err()
            }
            it := self.irt(v.ty)
            s := self.scalar(v)
            m := self.iconst(it, -1)
            r := self.ins(OpXor, it, vec_of([]i64{s, m}), 0)
            return self.sval(v.ty, r)
        }
        UnOpAddr => {
            match x.k {
                EKLit(te, items) => {
                    var inner_expect Opt[i64] = None
                    match expect {
                        Some(et) => {
                            match self.cx.types.k(et) {
                                TyKPtr(t) => { inner_expect = Some(t) }
                                _ => {}
                            }
                        }
                        None => {}
                    }
                    var ty i64
                    match self.lit_type(te, inner_expect) {
                        Some(t) => { ty = t }
                        None => { return val_err() }
                    }
                    sz := self.cx.types.size_of(ty)
                    bytes := self.iconst(TI64, sz)
                    bv := self.sval(T_I64, bytes)
                    p := self.call_rt("__alloc_raw", vec[i64](), vec_of([]Val{bv}), pos)
                    pv := self.scalar(p)
                    dst := self.mval(ty, pv)
                    self.init_lit(dst, items.items(), pos)
                    pt := self.cx.types.ptr_to(ty)
                    return self.sval(pt, pv)
                }
                _ => {}
            }
            if !lower_expr_addressable(x) {
                self.err(pos, "cannot take the address of this expression (only variables, fields, elements and `&T{...}` literals)")
                return val_err()
            }
            if is_some(self.const_root(x)) {
                self.const_place_err(x, "its address cannot be taken")
                return val_err()
            }
            match self.place_raw(x) {
                Some(p) => {
                    if p.ro {
                        self.const_place_err(x, "its address cannot be taken")
                        return val_err()
                    }
                    if is_some(p.lane) {
                        self.err(pos, "cannot take the address of a vector component (copy it to a variable first)")
                        return val_err()
                    }
                    if p.alias >> 4 != 0 {
                        self.cx.exposed.set(p.alias >> 4, true)
                    }
                    pt := self.cx.types.ptr_to(p.ty)
                    return self.sval(pt, p.v)
                }
                None => { return val_err() }
            }
        }
        UnOpDeref => {
            pv := self.expr(x, None)
            match self.cx.types.k(pv.ty) {
                TyKPtr(t) => {
                    a := self.scalar(pv)
                    m := self.mval(t, a)
                    return self.rvalue(m)
                }
                TyKErr => { return val_err() }
                _ => {
                    tn := self.tyname(pv.ty)
                    self.err(pos, fmt("cannot dereference ", tn))
                    return val_err()
                }
            }
        }
    }
    return val_err()
}

fn binary(self *Fx, op BinOp, a *Expr, b *Expr, expect Opt[i64], pos Pos) Val {
    if op == BinOpLAnd || op == BinOpLOr {
        slot := self.temp(T_BOOL)
        bt := self.new_block()
        bf := self.new_block()
        bj := self.new_block()
        mid := self.new_block()
        if op == BinOpLAnd {
            self.cond_br(a, mid, bf)
        } else {
            self.cond_br(a, bt, mid)
        }
        self.switch_to(mid)
        self.cond_br(b, bt, bf)
        self.switch_to(bt)
        one := self.iconst(TI8, 1)
        self.store_raw(slot, one, TI8, 0)
        self.jmp(bj)
        self.switch_to(bf)
        zero := self.iconst(TI8, 0)
        self.store_raw(slot, zero, TI8, 0)
        self.jmp(bj)
        self.switch_to(bj)
        v := self.load_raw(slot, TI8, 0)
        return self.sval(T_BOOL, v)
    }
    if op == BinOpShl || op == BinOpShr {
        l := self.expr(a, expect)
        r := self.expr(b, None)
        return self.binary_vals(op, l, r, pos)
    }
    var exp Opt[i64] = None
    if !lower_expr_is_cmp(op) {
        match expect {
            Some(t) => {
                if self.cx.types.is_int(t) || self.cx.types.is_float(t) || self.is_vecish(t) {
                    exp = Some(t)
                }
            }
            None => {}
        }
    }
    both_untyped := self.is_untyped(a) && self.is_untyped(b)
    if both_untyped && (lower_expr_is_cv_float(self.cx.const_eval(a)) || lower_expr_is_cv_float(self.cx.const_eval(b))) {
        exp = Some(self.float_expect(exp))
    }
    var l Val
    var r Val
    if self.is_untyped(a) && !self.is_untyped(b) {
        r = self.expr(b, exp)
        l = self.expr(a, Some(r.ty))
    } else {
        l = self.expr(a, exp)
        r = self.expr(b, Some(l.ty))
    }
    return self.binary_vals(op, l, r, pos)
}

fn binary_vals(self *Fx, op BinOp, l Val, r Val, pos Pos) Val {
    if l.ty == T_ERR || r.ty == T_ERR {
        return val_err()
    }
    lk := self.cx.types.k(l.ty)
    if op == BinOpShl || op == BinOpShr {
        if !self.cx.types.is_int(l.ty) || !self.cx.types.is_int(r.ty) {
            self.err(pos, "shift operands must be integers")
            return val_err()
        }
        it := self.irt(l.ty)
        rt := self.irt(r.ty)
        lv := self.scalar(l)
        rv := self.scalar(r)
        if rt.size() > it.size() {
            rv = self.ins(OpTrunc, it, vec_of([]i64{rv}), 0)
        } else if rt.size() < it.size() {
            rv = self.ins(OpZExt, it, vec_of([]i64{rv}), 0)
        }
        o := OpShl
        if op != BinOpShl {
            if self.cx.types.is_signed(l.ty) {
                o = OpAShr
            } else {
                o = OpLShr
            }
        }
        v := self.ins(o, it, vec_of([]i64{lv, rv}), 0)
        return self.sval(l.ty, v)
    }
    match self.vec_binary(op, l, r, pos) {
        Some(v) => { return v }
        None => {}
    }
    if l.ty != r.ty {
        a := self.tyname(l.ty)
        b := self.tyname(r.ty)
        ptr_or_fn := false
        match self.cx.types.k(l.ty) {
            TyKPtr(t) => { ptr_or_fn = true }
            TyKFn(ps, rt) => { ptr_or_fn = true }
            _ => {}
        }
        if self.cx.types.is_scalar(l.ty) && self.cx.types.is_scalar(r.ty) && !ptr_or_fn {
            self.err(pos, fmt("operands have different types: ", a, " and ", b, " (convert explicitly, e.g. `", a, "(x)`)"))
        } else {
            self.err(pos, fmt("operands have different types: ", a, " and ", b))
        }
        return val_err()
    }
    if lower_expr_is_cmp(op) {
        eq_only := op == BinOpEq || op == BinOpNe
        // which of the guarded arms the type selects
        is_f := false
        scalar_eq := false
        str_eq := false
        agg_eq := false
        match lk {
            TyKInt(bits, signed) => {
                o := OpUge
                if op == BinOpEq {
                    o = OpEq
                } else if op == BinOpNe {
                    o = OpNe
                } else if signed {
                    if op == BinOpLt {
                        o = OpSlt
                    } else if op == BinOpLe {
                        o = OpSle
                    } else if op == BinOpGt {
                        o = OpSgt
                    } else if op == BinOpGe {
                        o = OpSge
                    }
                } else {
                    if op == BinOpLt {
                        o = OpUlt
                    } else if op == BinOpLe {
                        o = OpUle
                    } else if op == BinOpGt {
                        o = OpUgt
                    }
                }
                a := self.scalar(l)
                b := self.scalar(r)
                v := self.ins(o, TI8, vec_of([]i64{a, b}), 0)
                return self.sval(T_BOOL, v)
            }
            TyKF64 => { is_f = true }
            TyKF32 => { is_f = true }
            TyKBool => { scalar_eq = true }
            TyKPtr(t) => { scalar_eq = true }
            TyKFn(ps, rt) => { scalar_eq = true }
            TyKEnum(eid) => { scalar_eq = true }
            TyKSlice(et) => {
                if et == T_U8 {
                    str_eq = true
                } else {
                    agg_eq = true
                }
            }
            TyKArray(et, n) => { agg_eq = true }
            TyKStruct(sid) => { agg_eq = true }
            TyKTuple(ts) => { agg_eq = true }
            _ => {}
        }
        if is_f {
            o := OpFGe
            if op == BinOpEq {
                o = OpFEq
            } else if op == BinOpNe {
                o = OpFNe
            } else if op == BinOpLt {
                o = OpFLt
            } else if op == BinOpLe {
                o = OpFLe
            } else if op == BinOpGt {
                o = OpFGt
            }
            a := self.scalar(l)
            b := self.scalar(r)
            v := self.ins(o, TI8, vec_of([]i64{a, b}), 0)
            return self.sval(T_BOOL, v)
        }
        if scalar_eq && eq_only && self.cx.types.is_scalar(l.ty) {
            a := self.scalar(l)
            b := self.scalar(r)
            o := if op == BinOpEq { OpEq } else { OpNe }
            v := self.ins(o, TI8, vec_of([]i64{a, b}), 0)
            return self.sval(T_BOOL, v)
        }
        if str_eq && eq_only {
            v := self.call_rt("__str_eq", vec[i64](), vec_of([]Val{l, r}), pos)
            if op == BinOpEq {
                return v
            }
            s := self.scalar(v)
            one := self.iconst(TI8, 1)
            x := self.ins(OpXor, TI8, vec_of([]i64{s, one}), 0)
            return self.sval(T_BOOL, x)
        }
        if agg_eq && eq_only {
            var e i64
            match self.eq_vals(l, r, pos) {
                Some(ev) => { e = ev }
                None => { return val_err() }
            }
            if op == BinOpEq {
                return self.sval(T_BOOL, e)
            }
            one := self.iconst(TI8, 1)
            x := self.ins(OpXor, TI8, vec_of([]i64{e, one}), 0)
            return self.sval(T_BOOL, x)
        }
        tn := self.tyname(l.ty)
        self.err(pos, fmt("cannot compare values of type ", tn, " with this operator"))
        return val_err()
    }
    is_f := false
    match lk {
        TyKInt(bits, signed) => {
            it := self.irt(l.ty)
            a := self.scalar(l)
            b := self.scalar(r)
            var o Op
            if op == BinOpAdd {
                o = OpAdd
            } else if op == BinOpSub {
                o = OpSub
            } else if op == BinOpMul {
                o = OpMul
            } else if op == BinOpAnd {
                o = OpAnd
            } else if op == BinOpOr {
                o = OpOr
            } else if op == BinOpXor {
                o = OpXor
            } else if op == BinOpDiv || op == BinOpRem {
                return self.int_div(op == BinOpDiv, signed, l.ty, it, a, b, pos)
            } else {
                panic("internal error: entered unreachable code")
            }
            v := self.ins(o, it, vec_of([]i64{a, b}), 0)
            return self.sval(l.ty, v)
        }
        TyKF64 => { is_f = true }
        TyKF32 => { is_f = true }
        _ => {}
    }
    if is_f {
        var o Op
        if op == BinOpAdd {
            o = OpFAdd
        } else if op == BinOpSub {
            o = OpFSub
        } else if op == BinOpMul {
            o = OpFMul
        } else if op == BinOpDiv {
            o = OpFDiv
        } else {
            self.err(pos, "this operator is not defined for f64")
            return val_err()
        }
        a := self.scalar(l)
        b := self.scalar(r)
        it := self.irt(l.ty)
        v := self.ins(o, it, vec_of([]i64{a, b}), 0)
        return self.sval(l.ty, v)
    }
    tn := self.tyname(l.ty)
    self.err(pos, fmt("arithmetic is not defined for ", tn))
    return val_err()
}

// structural equality of two values of the same type (as an i8 0/1)
fn eq_vals(self *Fx, l Val, r Val, pos Pos) Opt[i64] {
    names := vec[str]()
    fieldwise := false
    match self.cx.types.k(l.ty) {
        TyKSlice(et) => {
            if et != T_U8 {
                v := self.call_rt("__slice_eq", vec_of([]i64{et}), vec_of([]Val{l, r}), pos)
                return Some(self.scalar(v))
            }
        }
        TyKArray(et, n) => {
            sty := self.cx.types.slice(et)
            sl := vec[Val]()
            for x in ([]Val{l, r}) {
                t := self.temp(sty)
                sv := self.mval(sty, t)
                nv := self.iconst(TI64, i64(n))
                self.store_slice(sv, x.v, nv)
                sl.push(sv)
            }
            var v Val
            if et == T_U8 {
                v = self.call_rt("__str_eq", vec[i64](), sl, pos)
            } else {
                v = self.call_rt("__slice_eq", vec_of([]i64{et}), sl, pos)
            }
            return Some(self.scalar(v))
        }
        TyKStruct(sid) => {
            fieldwise = true
            fields := self.cx.types.structs.buf[sid].fields
            for i in 0..fields.len {
                names.push(fields.buf[i].0)
            }
        }
        TyKTuple(ts) => {
            fieldwise = true
            for i in 0..ts.len {
                names.push(fmt(i))
            }
        }
        _ => {}
    }
    if fieldwise {
        acc := self.iconst(TI8, 1)
        for ni in 0..names.len {
            n := names.buf[ni]
            var pl Val
            match self.field_of(l, n, pos) {
                Some(p) => { pl = p }
                None => { return None }
            }
            var pr Val
            match self.field_of(r, n, pos) {
                Some(p) => { pr = p }
                None => { return None }
            }
            fl := self.rvalue(pl)
            fr := self.rvalue(pr)
            e := self.binary_vals(BinOpEq, fl, fr, pos)
            if e.ty == T_ERR {
                return None
            }
            ev := self.scalar(e)
            acc = self.ins(OpAnd, TI8, vec_of([]i64{acc, ev}), 0)
        }
        return Some(acc)
    }
    v := self.binary_vals(BinOpEq, l, r, pos)
    if v.ty == T_ERR {
        return None
    }
    return Some(self.scalar(v))
}

fn int_div(self *Fx, is_div bool, signed bool, ty i64, it T, a i64, b i64, pos Pos) Val {
    o := OpURem
    if is_div && signed {
        o = OpSDiv
    } else if is_div {
        o = OpUDiv
    } else if signed {
        o = OpSRem
    }
    match self.f.is_const(b) {
        Some(k) => {
            if k == 0 {
                self.err(pos, "division by constant zero")
                return val_err()
            }
            if signed && k == -1 {
                z := self.iconst(it, 0)
                v := z
                if is_div {
                    v = self.ins(OpSub, it, vec_of([]i64{z, a}), 0)
                }
                return self.sval(ty, v)
            }
            v := self.ins(o, it, vec_of([]i64{a, b}), 0)
            return self.sval(ty, v)
        }
        None => {}
    }
    if !self.cx.opts.checks {
        v := self.ins(o, it, vec_of([]i64{a, b}), 0)
        return self.sval(ty, v)
    }
    z := self.iconst(it, 0)
    nz := self.ins(OpNe, TI8, vec_of([]i64{b, z}), 0)
    self.check(nz, 1, pos)
    if !signed {
        v := self.ins(o, it, vec_of([]i64{a, b}), 0)
        return self.sval(ty, v)
    }
    // signed: x / -1 wraps instead of trapping
    slot := self.alloca(it.size(), it.size())
    m1 := self.iconst(it, -1)
    is_m1 := self.ins(OpEq, TI8, vec_of([]i64{b, m1}), 0)
    b_m1 := self.new_block()
    b_div := self.new_block()
    bj := self.new_block()
    d := self.dead
    self.br(is_m1, b_m1, b_div)
    self.switch_to(b_m1)
    z2 := self.iconst(it, 0)
    v1 := z2
    if is_div {
        v1 = self.ins(OpSub, it, vec_of([]i64{z2, a}), 0)
    }
    self.store_raw(slot, v1, it, 0)
    self.jmp(bj)
    self.switch_to(b_div)
    v2 := self.ins(o, it, vec_of([]i64{a, b}), 0)
    self.store_raw(slot, v2, it, 0)
    self.jmp(bj)
    self.switch_to(bj)
    self.dead = d
    v := self.load_raw(slot, it, 0)
    return self.sval(ty, v)
}

// ---------- conversions ----------
fn convert(self *Fx, v Val, to i64, pos Pos) Val {
    if v.ty == to || v.ty == T_ERR || to == T_ERR {
        if to == T_ERR {
            return val_err()
        }
        return v
    }
    fk := self.cx.types.k(v.ty)
    tk := self.cx.types.k(to)
    tt := self.irt(to)
    match fk {
        TyKInt(fb, fs) => {
            match tk {
                TyKInt(tb, ts) => {
                    s := self.scalar(v)
                    r := s
                    if tb < fb {
                        r = self.ins(OpTrunc, tt, vec_of([]i64{s}), 0)
                    } else if tb > fb {
                        r = self.ins(if fs { OpSExt } else { OpZExt }, tt, vec_of([]i64{s}), 0)
                    }
                    return self.sval(to, r)
                }
                TyKF64 => {
                    s := self.scalar(v)
                    if fb < 64 {
                        s = self.ins(if fs { OpSExt } else { OpZExt }, TI64, vec_of([]i64{s}), 0)
                        r := self.ins(OpSIToF, TF64, vec_of([]i64{s}), 0)
                        return self.sval(to, r)
                    }
                    if fs {
                        r := self.ins(OpSIToF, TF64, vec_of([]i64{s}), 0)
                        return self.sval(to, r)
                    }
                    // u64: values >= 2^63 are halved (keeping the sticky bit), converted and doubled
                    slot := self.alloca(8, 8)
                    zero := self.iconst(TI64, 0)
                    nonneg := self.ins(OpSge, TI8, vec_of([]i64{s, zero}), 0)
                    b_lo := self.new_block()
                    b_hi := self.new_block()
                    bj := self.new_block()
                    d := self.dead
                    self.br(nonneg, b_lo, b_hi)
                    self.switch_to(b_lo)
                    r1 := self.ins(OpSIToF, TF64, vec_of([]i64{s}), 0)
                    self.store_raw(slot, r1, TF64, 0)
                    self.jmp(bj)
                    self.switch_to(b_hi)
                    one := self.iconst(TI64, 1)
                    half := self.ins(OpLShr, TI64, vec_of([]i64{s, one}), 0)
                    low := self.ins(OpAnd, TI64, vec_of([]i64{s, one}), 0)
                    h := self.ins(OpOr, TI64, vec_of([]i64{half, low}), 0)
                    hf := self.ins(OpSIToF, TF64, vec_of([]i64{h}), 0)
                    r2 := self.ins(OpFAdd, TF64, vec_of([]i64{hf, hf}), 0)
                    self.store_raw(slot, r2, TF64, 0)
                    self.jmp(bj)
                    self.switch_to(bj)
                    self.dead = d
                    r := self.load_raw(slot, TF64, 0)
                    return self.sval(to, r)
                }
                TyKF32 => {
                    if fb == 64 && !fs {
                        d := self.convert(v, T_F64, pos)
                        return self.convert(d, T_F32, pos)
                    }
                    s := self.scalar(v)
                    if fb < 64 {
                        s = self.ins(if fs { OpSExt } else { OpZExt }, TI64, vec_of([]i64{s}), 0)
                    }
                    r := self.ins(OpSIToF, TF32, vec_of([]i64{s}), 0)
                    return self.sval(to, r)
                }
                _ => {}
            }
        }
        TyKBool => {
            match tk {
                TyKInt(tb, ts) => {
                    s := self.scalar(v)
                    r := s
                    if tb > 8 {
                        r = self.ins(OpZExt, tt, vec_of([]i64{s}), 0)
                    }
                    return self.sval(to, r)
                }
                _ => {}
            }
        }
        TyKEnum(eid) => {
            match tk {
                TyKInt(tb, ts) => {
                    if self.cx.types.is_scalar(v.ty) {
                        s := self.scalar(v)
                        r := s
                        if tb < 64 {
                            r = self.ins(OpTrunc, tt, vec_of([]i64{s}), 0)
                        }
                        return self.sval(to, r)
                    }
                }
                _ => {}
            }
        }
        TyKF32 => {
            match tk {
                TyKF64 => {
                    s := self.scalar(v)
                    r := self.ins(OpFExt, TF64, vec_of([]i64{s}), 0)
                    return self.sval(to, r)
                }
                TyKInt(tb, ts) => { return self.lower_expr_float_to_int(v, to, tt, tb) }
                _ => {}
            }
        }
        TyKF64 => {
            match tk {
                TyKF32 => {
                    s := self.scalar(v)
                    r := self.ins(OpFTrunc, TF32, vec_of([]i64{s}), 0)
                    return self.sval(to, r)
                }
                TyKInt(tb, ts) => { return self.lower_expr_float_to_int(v, to, tt, tb) }
                _ => {}
            }
        }
        _ => {}
    }
    a := self.tyname(v.ty)
    b := self.tyname(to)
    self.err(pos, fmt("cannot convert ", a, " to ", b, " (use cast[T](x) for reinterpretation)"))
    return val_err()
}

// the `(TyK::F64 | TyK::F32, TyK::Int(tb, _))` arm of `convert`
fn lower_expr_float_to_int(self *Fx, v Val, to i64, tt T, tb i64) Val {
    s := self.scalar(v)
    r := self.ins(OpFToSI, TI64, vec_of([]i64{s}), 0)
    if tb < 64 {
        r = self.ins(OpTrunc, tt, vec_of([]i64{r}), 0)
    }
    return self.sval(to, r)
}

// ---------- composite literals ----------
fn lit_type(self *Fx, te *Expr, expect Opt[i64]) Opt[i64] {
    env := self.tenv
    match self.cx.expr_type(te, &env) {
        Some(t) => {
            if t == T_ERR {
                return None
            }
            return Some(t)
        }
        None => {}
    }
    // generic struct named without type arguments: take them from the expected type
    match te.k {
        EKIdent(n) => {
            match self.cx.find_struct(n) {
                Some(si) => {
                    match expect {
                        Some(t) => {
                            match self.cx.types.k(t) {
                                TyKStruct(sid) => {
                                    if self.cx.types.structs.buf[sid].decl == si {
                                        return expect
                                    }
                                }
                                _ => {}
                            }
                        }
                        None => {}
                    }
                    self.err(te.pos, fmt("generic struct `", n, "` needs type arguments here, e.g. `", n, "[i64]{...}`"))
                    return None
                }
                None => {
                    ph := self.cx.priv_hint(n)
                    if len(ph) != 0 {
                        self.err(te.pos, fmt("unknown type `", n, "`", ph))
                        return None
                    }
                }
            }
        }
        _ => {}
    }
    self.err(te.pos, "expected a type before `{`")
    return None
}

fn init_lit(self *Fx, dst Val, items [](Opt[str], Expr), pos Pos) {
    match self.cx.types.k(dst.ty) {
        TyKStruct(sid) => {
            self.cx.types.layout_struct(sid)
            fields := clone(self.cx.types.structs.buf[sid].fields)
            offs := clone(self.cx.types.structs.buf[sid].offsets)
            if len(items) < fields.len {
                self.zero(dst)
            }
            seen := vec_fill(fields.len, false)
            for i in 0..len(items) {
                item := &items[i].1
                fi := i
                match items[i].0 {
                    Some(n) => {
                        fi = -1
                        for j in 0..fields.len {
                            if fields.buf[j].0 == n {
                                fi = j
                                break
                            }
                        }
                        if fi < 0 {
                            tn := self.tyname(dst.ty)
                            self.err(item.pos, fmt(tn, " has no field `", n, "`"))
                            continue
                        }
                    }
                    None => {}
                }
                if fi >= fields.len {
                    self.err(item.pos, "too many values in struct literal")
                    break
                }
                if seen.buf[fi] {
                    self.err(item.pos, fmt("field `", fields.buf[fi].0, "` initialized twice"))
                }
                seen.buf[fi] = true
                fty := fields.buf[fi].1
                v0 := self.expr(item, Some(fty))
                v := self.coerce(v0, fty, item.pos)
                a := self.add_off(dst.v, offs.buf[fi])
                fd := self.mval(fty, a)
                if self.cx.types.is_scalar(fty) {
                    fd.alias = self.cx.types.field_alias(dst.ty, fi, fty)
                }
                self.store(fd, v)
            }
        }
        TyKArray(et, n) => {
            if len(items) > i64(n) {
                self.err(pos, fmt("too many elements in array literal (max ", i64(n), ")"))
                return
            }
            if len(items) < i64(n) {
                self.zero(dst)
            }
            es := self.cx.types.size_of(et)
            for i in 0..len(items) {
                item := &items[i].1
                if is_some(items[i].0) {
                    self.err(item.pos, "array literal elements cannot be named")
                }
                v0 := self.expr(item, Some(et))
                v := self.coerce(v0, et, item.pos)
                a := self.add_off(dst.v, i * es)
                ed := self.mval(et, a)
                self.store(ed, v)
            }
        }
        TyKTuple(tys) => {
            if len(items) != tys.len {
                self.err(pos, "wrong number of tuple elements")
                return
            }
            offs := self.cx.types.tuple_offsets(tys.items())
            for i in 0..len(items) {
                item := &items[i].1
                v0 := self.expr(item, Some(tys.buf[i]))
                v := self.coerce(v0, tys.buf[i], item.pos)
                a := self.add_off(dst.v, offs.buf[i])
                fd := self.mval(tys.buf[i], a)
                if self.cx.types.is_scalar(tys.buf[i]) {
                    fd.alias = self.cx.types.field_alias(dst.ty, i, tys.buf[i])
                }
                self.store(fd, v)
            }
        }
        _ => {
            tn := self.tyname(dst.ty)
            self.err(pos, fmt(tn, " cannot be built with a `{...}` literal"))
        }
    }
}

// ---------- enums ----------
fn construct_variant(self *Fx, ei i64, vi i64, args []Expr, expect Opt[i64], pos Pos) Val {
    d := self.cx.enum_decls.buf[ei]
    vname := d.variants.buf[vi].0
    var ety i64
    if d.tparams.len == 0 {
        ety = self.cx.inst_enum(ei, vec[i64](), pos)
    } else {
        from_expect := false
        match expect {
            Some(t) => {
                match self.cx.types.k(t) {
                    TyKEnum(eid) => {
                        if self.cx.types.enums.buf[eid].decl == ei {
                            from_expect = true
                            ety = t
                        }
                    }
                    _ => {}
                }
            }
            None => {}
        }
        if !from_expect {
            // infer type arguments from the payload
            env := map[str, i64]()
            ok := len(args) == d.variants.buf[vi].1.len
            if ok {
                for i in 0..len(args) {
                    v := self.expr(&args[i], None)
                    if !self.unify(&d.variants.buf[vi].1.buf[i], v.ty, d.tparams.items(), &env) {
                        ok = false
                    }
                }
            }
            targs := vec[i64]()
            for i in 0..d.tparams.len {
                t, has := env.get(d.tparams.buf[i])
                if has {
                    targs.push(t)
                }
            }
            if !ok || targs.len != d.tparams.len {
                self.err(pos, fmt("cannot infer type arguments of enum `", d.name, "` for `", vname, "`; annotate the destination type"))
                return val_err()
            }
            // re-evaluating args below duplicates their code, so only allow it for inferred cases
            ety = self.cx.inst_enum(ei, targs, pos)
        }
    }
    var eid i64
    match self.cx.types.k(ety) {
        TyKEnum(x) => { eid = x }
        _ => { return val_err() }
    }
    ptys := clone(self.cx.types.enums.buf[eid].variants.buf[vi].1)
    if len(args) != ptys.len {
        self.err(pos, fmt("variant `", vname, "` takes ", ptys.len, " value(s), got ", len(args)))
        return val_err()
    }
    if self.cx.types.enums.buf[eid].simple {
        v := self.iconst(TI64, vi)
        return self.sval(ety, v)
    }
    t := self.temp(ety)
    dst := self.mval(ety, t)
    self.zero(dst)
    tag := self.iconst(TI64, vi)
    self.store_raw(t, tag, TI64, AK_ANY)
    offs := self.cx.types.variant_offsets(eid, vi)
    for i in 0..len(args) {
        a := &args[i]
        v0 := self.expr(a, Some(ptys.buf[i]))
        v := self.coerce(v0, ptys.buf[i], a.pos)
        fa := self.add_off(t, offs.buf[i])
        fd := self.mval(ptys.buf[i], fa)
        fd.alias = if self.cx.types.is_scalar(ptys.buf[i]) { AK_ANY } else { 0 }
        self.store_any(fd, v)
    }
    return dst
}

// store into enum payload memory: all accesses use the "any" alias class
fn store_any(self *Fx, dst Val, src Val) {
    if src.ty == T_ERR || src.ty == T_NEVER {
        return
    }
    if self.cx.types.is_scalar(dst.ty) {
        v := self.scalar(src)
        t := self.irt(dst.ty)
        self.store_raw(dst.v, v, t, AK_ANY)
        return
    }
    lvs := vec[Leaf]()
    self.cx.types.leaves(dst.ty, 0, &lvs)
    if lvs.len > 64 {
        sz := self.cx.types.size_of(dst.ty)
        c := self.iconst(TI64, sz)
        self.ins(OpMemCpy, TVoid, vec_of([]i64{dst.v, src.v, c}), 0)
        return
    }
    vals := vec[i64]()
    for i in 0..lvs.len {
        l := lvs.buf[i]
        a := self.add_off(src.v, l.off)
        vals.push(self.load_raw(a, l.t, l.alias))
    }
    for i in 0..lvs.len {
        l := lvs.buf[i]
        a := self.add_off(dst.v, l.off)
        self.store_raw(a, vals.buf[i], l.t, AK_ANY)
    }
}

fn load_any(self *Fx, src i64, ty i64) Val {
    // copy a payload field out of enum memory into a fresh temp
    t := self.temp(ty)
    dst := self.mval(ty, t)
    lvs := vec[Leaf]()
    self.cx.types.leaves(ty, 0, &lvs)
    if lvs.len > 64 {
        sz := self.cx.types.size_of(ty)
        c := self.iconst(TI64, sz)
        self.ins(OpMemCpy, TVoid, vec_of([]i64{t, src, c}), 0)
        return dst
    }
    for i in 0..lvs.len {
        l := lvs.buf[i]
        a := self.add_off(src, l.off)
        v := self.load_raw(a, l.t, AK_ANY)
        d := self.add_off(t, l.off)
        self.store_raw(d, v, l.t, l.alias)
    }
    return dst
}

fn match_expr(self *Fx, sc *Expr, arms []MatchArm, want bool, expect Opt[i64], pos Pos) Val {
    sv := self.expr(sc, None)
    if sv.ty == T_ERR {
        return val_err()
    }
    sk := self.cx.types.k(sv.ty)
    var enum_id Opt[i64] = None
    match sk {
        TyKEnum(e) => { enum_id = Some(e) }
        _ => {}
    }
    payload_enum := false
    match enum_id {
        Some(e) => { payload_enum = !self.cx.types.enums.buf[e].simple }
        None => {}
    }
    // scrutinee: scalar value, or tag for payload enums
    var key i64
    var key_ty i64
    if payload_enum {
        key = self.load_raw(sv.v, TI64, AK_ANY)
        key_ty = T_I64
    } else if self.cx.types.is_scalar(sv.ty) {
        key = self.scalar(sv)
        key_ty = sv.ty
    } else if sv.ty == T_STR {
        key = NOV
        key_ty = T_STR
    } else {
        tn := self.tyname(sv.ty)
        self.err(pos, fmt("cannot match on ", tn))
        return val_err()
    }
    // keep a stable copy of string scrutinee
    var str_tmp Opt[Val] = None
    if sv.ty == T_STR {
        t := self.temp(T_STR)
        tv := self.mval(T_STR, t)
        self.store(tv, sv)
        str_tmp = Some(tv)
    }
    bj := self.new_block()
    var slot Opt[Val] = None
    all_dead := true
    has_wild := false
    covered := vec[bool]()
    match enum_id {
        Some(e) => { covered = vec_fill(self.cx.types.enums.buf[e].variants.len, false) }
        None => {}
    }
    result_err := false
    for ai in 0..len(arms) {
        arm := &arms[ai]
        body_b := self.new_block()
        next_b := self.new_block()
        var binds Opt[(i64, Vec[str])] = None
        npats := arm.pats.len
        for pi in 0..npats {
            last := pi + 1 == npats
            fail_b := if last { next_b } else { self.new_block() }
            match arm.pats.buf[pi] {
                PatWild => {
                    has_wild = true
                    self.jmp(body_b)
                }
                PatVariant(name, bnames, ppos) => {
                    vi := -1
                    match enum_id {
                        Some(eid) => {
                            vv, has := self.cx.variants.get(name)
                            if has && self.cx.types.enums.buf[eid].decl == vv.0 {
                                vi = vv.1
                            }
                        }
                        None => {}
                    }
                    if vi < 0 {
                        tn := self.tyname(sv.ty)
                        self.err(ppos, fmt("`", name, "` is not a variant of ", tn))
                        self.jmp(fail_b)
                        if !last {
                            self.switch_to(fail_b)
                        }
                        continue
                    }
                    covered.buf[vi] = true
                    nfields := self.cx.types.enums.buf[lower_expr_unwrap(enum_id)].variants.buf[vi].1.len
                    if bnames.len != nfields {
                        self.err(ppos, fmt("variant `", name, "` has ", nfields, " field(s), pattern binds ", bnames.len))
                    } else if npats > 1 && bnames.len != 0 {
                        self.err(ppos, "patterns with bindings cannot be combined with `,`")
                    } else {
                        binds = Some((vi, bnames))
                    }
                    c := self.iconst(TI64, vi)
                    eq := self.ins(OpEq, TI8, vec_of([]i64{key, c}), 0)
                    self.br(eq, body_b, fail_b)
                }
                PatConst(pe0) => {
                    pe := &pe0
                    // payload-less variant name?
                    done := false
                    match pe.k {
                        EKIdent(n) => {
                            match enum_id {
                                Some(eid) => {
                                    vv, has := self.cx.variants.get(n)
                                    if has {
                                        vi := vv.1
                                        if self.cx.types.enums.buf[eid].decl == vv.0 {
                                            covered.buf[vi] = true
                                            if self.cx.types.enums.buf[eid].variants.buf[vi].1.len != 0 {
                                                self.err(pe.pos, fmt("variant `", n, "` has fields; write `", n, "(..)` with bindings"))
                                            }
                                            c := self.iconst(TI64, vi)
                                            eq := self.ins(OpEq, TI8, vec_of([]i64{key, c}), 0)
                                            self.br(eq, body_b, fail_b)
                                            done = true
                                        }
                                    }
                                }
                                None => {}
                            }
                        }
                        _ => {}
                    }
                    if !done {
                        if payload_enum {
                            self.err(pe.pos, "expected an enum variant pattern")
                            self.jmp(fail_b)
                        } else {
                            match str_tmp {
                                Some(st) => {
                                    pv0 := self.expr(pe, Some(T_STR))
                                    pv := self.coerce(pv0, T_STR, pe.pos)
                                    r := self.call_rt("__str_eq", vec[i64](), vec_of([]Val{st, pv}), pe.pos)
                                    c := self.scalar(r)
                                    self.br(c, body_b, fail_b)
                                }
                                None => {
                                    pv0 := self.expr(pe, Some(key_ty))
                                    pv := self.coerce(pv0, key_ty, pe.pos)
                                    p := self.scalar(pv)
                                    eq := self.ins(OpEq, TI8, vec_of([]i64{key, p}), 0)
                                    self.br(eq, body_b, fail_b)
                                }
                            }
                        }
                    }
                }
            }
            if !last {
                self.switch_to(fail_b)
            }
        }
        if npats == 0 {
            self.jmp(next_b)
        }
        self.switch_to(body_b)
        self.push_scope()
        match binds {
            Some(bd) => {
                vi := bd.0
                bnames := bd.1
                eid := lower_expr_unwrap(enum_id)
                ptys := clone(self.cx.types.enums.buf[eid].variants.buf[vi].1)
                offs := self.cx.types.variant_offsets(eid, vi)
                for i in 0..bnames.len {
                    bn := bnames.buf[i]
                    src := self.add_off(sv.v, offs.buf[i])
                    tmp := self.load_any(src, ptys.buf[i])
                    if bn != "_" {
                        self.scopes.buf[self.scopes.len - 1].vars.set(bn, (ptys.buf[i], tmp.v))
                    }
                }
            }
            None => {}
        }
        exp := expect
        match slot {
            Some(s) => { exp = Some(s.ty) }
            None => {}
        }
        v := self.block_value(&arm.body, want, exp)
        d := self.dead
        if want && !d {
            if v.ty == T_ERR {
                result_err = true
            } else if v.ty == T_UNIT {
                if is_some(slot) {
                    self.err(arm.pos, "match arm has no value but other arms do")
                }
            } else {
                match slot {
                    Some(s) => {
                        cv := self.coerce(v, s.ty, arm.pos)
                        self.store(s, cv)
                    }
                    None => {
                        if !all_dead {
                            self.err(arm.pos, "match arms have different types")
                        } else {
                            a := self.temp(v.ty)
                            s := self.mval(v.ty, a)
                            self.store(s, v)
                            slot = Some(s)
                        }
                    }
                }
            }
        }
        if !d {
            all_dead = false
        }
        self.pop_scope()
        self.jmp(bj)
        self.switch_to(next_b)
    }
    // fallthrough when no arm matched
    all_covered := true
    for i in 0..covered.len {
        if !covered.buf[i] {
            all_covered = false
        }
    }
    npats_total := 0
    for ai in 0..len(arms) {
        npats_total += arms[ai].pats.len
    }
    exhaustive := has_wild || (is_some(enum_id) && all_covered) || (sv.ty == T_BOOL && npats_total >= 2)
    if exhaustive {
        self.terminate(TermTrap)
    } else {
        if want && is_some(slot) {
            missing := vec[str]()
            match enum_id {
                Some(e) => {
                    for i in 0..covered.len {
                        if !covered.buf[i] {
                            missing.push(self.cx.types.enums.buf[e].variants.buf[i].0)
                        }
                    }
                }
                None => {}
            }
            if missing.len == 0 {
                self.err(pos, "match used as a value must be exhaustive (add a `_ =>` arm)")
            } else {
                self.err(pos, fmt("match used as a value must be exhaustive; missing: ", join(missing.items(), ", ")))
            }
        }
        all_dead = false
        self.jmp(bj)
    }
    self.switch_to(bj)
    self.dead = all_dead
    if all_dead {
        return val_never()
    }
    if result_err {
        return val_err()
    }
    match slot {
        Some(s) => { return s }
        None => {}
    }
    return val_unit()
}
