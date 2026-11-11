// Enum variant names (bare and qualified) and `match`: patterns, guards, exhaustiveness.

// ---------- variant names ----------
// Variants are looked up per layer: the code of the prelude sees the prelude's enums first,
// user code the user's. A function, type, constant or global of the layer that is being
// compiled hides a variant of the other layer with the same name.

// index of the variant `n` of enum declaration `ei`, or -1
fn variant_of(self: *Cx, ei: i64, n: str) -> i64 {
    l: Vec[(i64, i64)]
    has := false
    if self.enum_decls[ei].pos.file < self.n_prelude {
        l, has = self.p_variants.get(n)
    } else {
        l, has = self.variants.get(n)
    }
    if has {
        for i in 0..l.len {
            if l[i].0 == ei {
                return l[i].1
            }
        }
    }
    return -1
}

// "A, B, C": the variants of an enum declaration, for diagnostics
priv fn variant_list(cx: *Cx, ei: i64) -> str {
    d := cx.enum_decls[ei]
    parts := vec[str]()
    for i in 0..d.variants.len {
        if i == 8 {
            parts.push("...")
            break
        }
        parts.push(d.variants[i].0)
    }
    return join(parts.items(), ", ")
}

// The enum that the name `n` denotes as the qualifier of `n.Variant`, or -1. An enum of the
// other layer is hidden by a declaration of this layer with the same name.
priv fn qual_enum_name(self: *Cx, n: str) -> i64 {
    match self.find_enum(n) {
        Some(ei) => {
            own := (self.enum_decls[ei].pos.file < self.n_prelude) == self.scope_prelude
            if !own {
                bit := if self.scope_prelude { 1 } else { 2 }
                if self.decl_layers.get_or(n, 0) & bit != 0 {
                    return -1
                }
            }
            return ei
        }
        None => {}
    }
    return -1
}

// A bare variant name `n` used as a value: (enum declaration, variant index, 1) if it denotes
// a variant, (_, _, 2) if several enums have it and the expected type does not decide,
// (_, _, 0) if `n` is not a variant here. Order: the expected enum; the enums of the layer
// being compiled; the enums of the other layer.
fn bare_variant(self: *Fx, n: str, expect: Opt[i64]) -> (i64, i64, i64) {
    cx := self.cx
    ul, uhas := cx.variants.get(n)
    pl, phas := cx.p_variants.get(n)
    if !uhas && !phas {
        return (0, 0, 0)
    }
    own: Vec[(i64, i64)]
    other: Vec[(i64, i64)]
    own_has := uhas
    other_has := phas
    bit := 2
    if cx.scope_prelude {
        own = pl
        other = ul
        own_has = phas
        other_has = uhas
        bit = 1
    } else {
        own = ul
        other = pl
    }
    hidden := !own_has && cx.decl_layers.get_or(n, 0) & bit != 0
    match expect {
        Some(t) => {
            match cx.types.k(t) {
                Enum(eid) => {
                    ed := cx.types.enums[eid].decl
                    if (cx.enum_decls[ed].pos.file < cx.n_prelude) == cx.scope_prelude {
                        if own_has {
                            for i in 0..own.len {
                                if own[i].0 == ed {
                                    return (ed, own[i].1, 1)
                                }
                            }
                        }
                    } else if other_has && !hidden {
                        for i in 0..other.len {
                            if other[i].0 == ed {
                                return (ed, other[i].1, 1)
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        None => {}
    }
    if own_has {
        return (own[0].0, own[0].1, if own.len == 1 { 1 } else { 2 })
    }
    if hidden {
        return (0, 0, 0)
    }
    return (other[0].0, other[0].1, if other.len == 1 { 1 } else { 2 })
}

// the diagnostic for a bare variant name that several enums have
fn variant_ambiguous(self: *Fx, n: str, pos: Pos) {
    cx := self.cx
    ul, uhas := cx.variants.get(n)
    pl, phas := cx.p_variants.get(n)
    l := ul
    if (cx.scope_prelude && phas) || !uhas {
        l = pl
    }
    names := vec[str]()
    forms := vec[str]()
    for i in 0..l.len {
        en := cx.enum_decls[l[i].0].name
        names.push(fmt("`", en, "`"))
        forms.push(fmt("`", en, ".", n, "`"))
    }
    self.err(pos, fmt("`", n, "` is a variant of several enums (", join(names.items(), ", "), ") and the expected type does not say which; write ", join(forms.items(), " or ")))
}

// If `e` is a variant written without the information that fixes its type (a bare data-less
// variant, `Enum.Variant` of a generic enum without type arguments, or `Variant(..)` of a
// name that several enums have), its name; otherwise "". Such an operand or argument is
// typed by its context, like a literal.
fn variant_ref(self: *Fx, e: *Expr) -> str {
    match e.k {
        Ident(n) => {
            if !is_some(self.lookup(n)) && self.bare_variant(n, None).2 != 0 {
                return n
            }
        }
        Field(b, n) => {
            match b.k {
                Ident(q) => {
                    ei := self.cx.qual_enum_name(q)
                    if ei >= 0 && self.cx.enum_decls[ei].tparams.len != 0 && !is_some(self.lookup(q)) {
                        return n
                    }
                }
                _ => {}
            }
        }
        Call(c, _) => {
            match c.k {
                Ident(n) => {
                    if !is_some(self.lookup(n)) && self.bare_variant(n, None).2 == 2 {
                        return n
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    return ""
}

// Does `b` name an enum, as in `Enum.Variant` / `Enum[T].Variant`? (enum declaration or -1,
// the enum type if the qualifier fixes it: -1 for a generic enum without type arguments)
fn qual_enum(self: *Fx, b: *Expr) -> (i64, i64) {
    match b.k {
        Ident(n) => {
            ei := self.cx.qual_enum_name(n)
            if ei < 0 || is_some(self.lookup(n)) {
                return (-1, -1)
            }
            if self.cx.enum_decls[ei].tparams.len == 0 {
                return (ei, self.cx.inst_enum(ei, vec[i64](), b.pos))
            }
            return (ei, -1)
        }
        Index(x, targs) => {
            match x.k {
                Ident(n) => {
                    ei := self.cx.qual_enum_name(n)
                    if ei < 0 || is_some(self.lookup(n)) {
                        return (-1, -1)
                    }
                    env := self.tenv
                    match self.cx.expr_type(b, &env) {
                        Some(t) => {
                            return (ei, t)
                        }
                        None => {
                            self.err(b.pos, fmt("expected type arguments in `", n, "[...]`: `", n, "` is an enum"))
                            return (ei, T_ERR)
                        }
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    return (-1, -1)
}

// `Enum.Variant` / `Enum.Variant(args)`: `ety` is the type the qualifier fixes, or -1
fn qual_variant(self: *Fx, ei: i64, ety: i64, name: str, args: []Expr, expect: Opt[i64], pos: Pos) -> Val {
    if ety == T_ERR {
        lower_call_eval_all(self, args)
        return val_err()
    }
    vi := self.cx.variant_of(ei, name)
    if vi < 0 {
        en := self.cx.enum_decls[ei].name
        self.err(pos, fmt("enum `", en, "` has no variant `", name, "` (variants: ", variant_list(self.cx, ei), ")"))
        lower_call_eval_all(self, args)
        return val_err()
    }
    exp := expect
    if ety >= 0 {
        exp = Some(ety)
    }
    return self.construct_variant(ei, vi, args, exp, pos)
}

// ---------- patterns ----------
priv const RP_ERR = 0
priv const RP_WILD = 1
priv const RP_BIND = 2
priv const RP_REF = 3
priv const RP_CONST = 4
priv const RP_VARIANT = 5
priv const RP_TUPLE = 6
// a variant or tuple pattern that looks through a pointer: one sub-pattern, for the target
priv const RP_DEREF = 7

// A pattern after it was checked against the type of the part of the value it looks at.
priv struct RPat {
    k: i64
    // type of the matched part
    ty: i64
    pos: Pos
    // RP_BIND, RP_REF: the variable
    name: str
    // RP_CONST: the constant
    e: *Expr
    // RP_VARIANT: index of the variant
    vi: i64
    // RP_VARIANT: one per payload field; RP_TUPLE: one per element
    subs: Vec[RPat]
    // can fail to match
    refutable: bool
    // number of variables it binds
    nbinds: i64
}

priv fn lower_match_err(ty: i64, pos: Pos) -> RPat {
    return RPat{k: RP_ERR, ty: ty, pos: pos}
}

// is a pattern expression a compile-time constant?
priv fn is_const(s: *Fx, e: *Expr) -> bool {
    match e.k {
        Int(_) => return true
        Float(_) => return true
        Str(_) => return true
        Bool(_) => return true
        Nil => return true
        _ => {}
    }
    saved := s.cx.errs.len
    r := is_some(s.cx.const_eval(e))
    s.cx.errs.truncate(saved)
    return r
}

// does the name `n` denote anything in an expression?
priv fn known(s: *Fx, n: str) -> bool {
    return is_some(s.lookup(n)) || s.cx.const_decls.has(n) || s.cx.global_decls.has(n) || s.cx.fn_names.has(n) || s.bare_variant(n, None).2 != 0
}

// the enum (index into the type table's enums) of a type, or -1
priv fn enum_of(s: *Fx, ty: i64) -> i64 {
    match s.cx.types.k(ty) {
        Enum(e) => return e
        _ => {}
    }
    return -1
}

// does a variant or tuple pattern have a sub-pattern that can fail?
priv fn subs_refutable(rp: *RPat) -> bool {
    for i in 0..rp.subs.len {
        if rp.subs[i].refutable {
            return true
        }
    }
    return false
}

// resolves the sub-patterns `subs` of `r` against the types `tys`
priv fn lower_match_subs(s: *Fx, r: RPat, subs: *Vec[Pat], tys: *Vec[i64]) -> RPat {
    out := r
    out.subs = Vec[RPat]{buf: alloc[RPat](subs.len), len: 0}
    bad := false
    for i in 0..subs.len {
        sp := s.pat_resolve(&subs[i], tys[i], false)
        if sp.k == RP_ERR {
            bad = true
        }
        if sp.refutable {
            out.refutable = true
        }
        out.nbinds += sp.nbinds
        out.subs.push(sp)
    }
    if bad {
        return lower_match_err(r.ty, r.pos)
    }
    return out
}

// `Variant`, `Variant(subs)`, `Enum.Variant`, `Enum.Variant(subs)` matched against `ty`
priv fn pat_variant(self: *Fx, name: str, subs: *Vec[Pat], parens: bool, qual: Opt[*Expr], ty: i64, pos: Pos) -> RPat {
    if ty == T_ERR {
        return lower_match_err(ty, pos)
    }
    eid := enum_of(self, ty)
    tn := self.tyname(ty)
    if eid < 0 {
        self.err(pos, fmt("`", name, if parens { "(..)" } else { "" }, "` is an enum variant pattern, but the matched value has type ", tn))
        return lower_match_err(ty, pos)
    }
    ed := self.cx.types.enums[eid].decl
    match qual {
        Some(q) => {
            qe := self.qual_enum(q)
            if qe.1 == T_ERR {
                return lower_match_err(ty, pos)
            }
            if qe.0 < 0 {
                self.err(pos, fmt("the qualifier of the pattern `.", name, "` is not an enum; write `", name, "` or `", self.cx.enum_decls[ed].name, ".", name, "`"))
                return lower_match_err(ty, pos)
            }
            if qe.0 != ed || (qe.1 >= 0 && qe.1 != ty) {
                qn := if qe.1 >= 0 { self.tyname(qe.1) } else { self.cx.enum_decls[qe.0].name }
                self.err(pos, fmt("the pattern names a variant of ", qn, ", but the matched value has type ", tn))
                return lower_match_err(ty, pos)
            }
        }
        None => {}
    }
    vi := -1
    nv := self.cx.types.enums[eid].variants.len
    for i in 0..nv {
        if self.cx.types.enums[eid].variants[i].0 == name {
            vi = i
            break
        }
    }
    if vi < 0 {
        self.err(pos, fmt("`", name, "` is not a variant of ", tn, " (variants: ", variant_list(self.cx, ed), ")"))
        return lower_match_err(ty, pos)
    }
    ptys := clone(self.cx.types.enums[eid].variants[vi].1)
    if !parens {
        if ptys.len != 0 {
            us := vec[str]()
            for i in 0..ptys.len {
                us.push("_")
            }
            self.err(pos, fmt("variant `", name, "` has ", ptys.len, " field(s); write `", name, "(", join(us.items(), ", "), ")` with one pattern per field"))
            return lower_match_err(ty, pos)
        }
        return RPat{k: RP_VARIANT, ty: ty, pos: pos, vi: vi, refutable: true}
    }
    if subs.len != ptys.len {
        self.err(pos, fmt("variant `", name, "` has ", ptys.len, " field(s), the pattern has ", subs.len))
        return lower_match_err(ty, pos)
    }
    return lower_match_subs(self, RPat{k: RP_VARIANT, ty: ty, pos: pos, vi: vi, refutable: true}, subs, &ptys)
}

// Would the pattern `p` look inside a value of type `ty` (pointers removed): a tuple
// pattern for a tuple, a variant pattern or the name of a variant for an enum?
priv fn structural(s: *Fx, p: *Pat, ty: i64) -> bool {
    t := ty
    loop {
        match s.cx.types.k(t) {
            Ptr(inner) => {
                t = inner
            }
            _ => {
                break
            }
        }
    }
    eid := enum_of(s, t)
    match *p {
        Tuple(_, _) => {
            match s.cx.types.k(t) {
                Tuple(_) => return true
                _ => {}
            }
        }
        Variant(_, _, _, _) => {
            return eid >= 0
        }
        Const(e) => {
            if eid < 0 {
                return false
            }
            match e.k {
                Ident(n) => {
                    nv := s.cx.types.enums[eid].variants.len
                    for i in 0..nv {
                        if s.cx.types.enums[eid].variants[i].0 == n {
                            return true
                        }
                    }
                }
                Field(q, _) => {
                    match q.k {
                        Ident(qn) => {
                            return s.cx.qual_enum_name(qn) >= 0 && !is_some(s.lookup(qn))
                        }
                        Index(x, _) => {
                            match x.k {
                                Ident(qn) => {
                                    return s.cx.qual_enum_name(qn) >= 0 && !is_some(s.lookup(qn))
                                }
                                _ => {}
                            }
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    return false
}

// Checks the pattern `p` against the type `ty` of the part it matches. `top`: the pattern
// is an alternative of an arm (not inside a variant or tuple pattern).
priv fn pat_resolve(self: *Fx, p: *Pat, ty: i64, top: bool) -> RPat {
    // a variant or tuple pattern matches through a pointer: the pointer must not be nil
    // and its target must match
    match self.cx.types.k(ty) {
        Ptr(inner) => {
            if structural(self, p, inner) {
                sub := self.pat_resolve(p, inner, top)
                if sub.k == RP_ERR {
                    return lower_match_err(ty, sub.pos)
                }
                r := RPat{k: RP_DEREF, ty: ty, pos: sub.pos, refutable: true, nbinds: sub.nbinds}
                r.subs = vec_one(sub)
                return r
            }
        }
        _ => {}
    }
    match *p {
        Wild => {
            return RPat{k: RP_WILD, ty: ty}
        }
        Ref(n, pos) => {
            if top {
                if is_some(self.lookup(n)) || self.cx.global_decls.has(n) {
                    // as before: the address of a variable, compared with a pointer
                    as_expr := Pat.Const(Expr{k: Un(AddrOf, parser_box(Expr{k: Ident(n), pos: pos})), pos: pos})
                    return self.pat_resolve(&as_expr, ty, top)
                }
                self.err(pos, fmt("`&", n, "` binds a part of the matched value; it is only allowed inside a variant or tuple pattern, e.g. `Some(&", n, ")`"))
                return lower_match_err(ty, pos)
            }
            if n == "_" {
                return RPat{k: RP_WILD, ty: ty}
            }
            return RPat{k: RP_REF, ty: ty, pos: pos, name: n, nbinds: 1}
        }
        Tuple(subs, pos) => {
            if ty == T_ERR {
                return lower_match_err(ty, pos)
            }
            tys: Vec[i64]
            is_tuple := false
            match self.cx.types.k(ty) {
                Tuple(ts) => {
                    tys = ts
                    is_tuple = true
                }
                _ => {}
            }
            if !is_tuple {
                self.err(pos, fmt("a tuple pattern cannot match a value of type ", self.tyname(ty)))
                return lower_match_err(ty, pos)
            }
            if tys.len != subs.len {
                self.err(pos, fmt("the tuple pattern has ", subs.len, " element(s), the matched value has ", tys.len, ": ", self.tyname(ty)))
                return lower_match_err(ty, pos)
            }
            return lower_match_subs(self, RPat{k: RP_TUPLE, ty: ty, pos: pos}, &subs, &tys)
        }
        Variant(name, subs, pos, full) => {
            qual: Opt[*Expr] = None
            match full {
                Some(fe) => {
                    // Enum.Variant(..): `fe` is a call of the field `Variant` of `Enum`
                    match fe.k {
                        Call(c, _) => {
                            match c.k {
                                Field(q, _) => {
                                    qual = Some(q)
                                    if top && self.qual_enum(q).0 < 0 {
                                        // not an enum: as before, an expression `x.f(a)`
                                        // that the matched value is compared with
                                        as_expr := Pat.Const(*fe)
                                        return self.pat_resolve(&as_expr, ty, top)
                                    }
                                }
                                _ => {}
                            }
                        }
                        _ => {}
                    }
                }
                None => {}
            }
            return self.pat_variant(name, &subs, true, qual, ty, pos)
        }
        Const(e) => {
            eid := enum_of(self, ty)
            const_name := false
            none: Vec[Pat]
            no_qual: Opt[*Expr] = None
            match e.k {
                Ident(n) => {
                    if eid >= 0 {
                        has := false
                        nv := self.cx.types.enums[eid].variants.len
                        for i in 0..nv {
                            if self.cx.types.enums[eid].variants[i].0 == n {
                                has = true
                                break
                            }
                        }
                        if has {
                            return self.pat_variant(n, &none, false, no_qual, ty, e.pos)
                        }
                    }
                    if !top {
                        if !self.cx.const_decls.has(n) {
                            return RPat{k: RP_BIND, ty: ty, pos: e.pos, name: n, nbinds: 1}
                        }
                        const_name = true
                    } else if eid >= 0 && !is_some(self.lookup(n)) && !self.cx.global_decls.has(n) {
                        // reports that `n` is not a variant
                        return self.pat_variant(n, &none, false, no_qual, ty, e.pos)
                    } else if !known(self, n) {
                        self.err(e.pos, fmt("unknown identifier `", n, "`: the pattern of an arm is a constant, not a new name for the matched value (write `_` and use the matched value itself, also in a guard)"))
                        return lower_match_err(ty, e.pos)
                    }
                }
                Field(q, n) => {
                    if self.qual_enum(q).0 >= 0 {
                        return self.pat_variant(n, &none, false, Some(q), ty, parser_expr_start(q))
                    }
                }
                _ => {}
            }
            if ty == T_ERR {
                return lower_match_err(ty, e.pos)
            }
            if !top && !const_name && !is_const(self, &e) {
                self.err(e.pos, "this part of the pattern is not a constant; inside a pattern write a literal, a named constant, a variant, `_` or a name to bind (compare with other values in a guard: `pattern if cond => ...`)")
                return lower_match_err(ty, e.pos)
            }
            if ty != T_STR && !self.cx.types.is_scalar(ty) {
                tn := self.tyname(ty)
                if eid >= 0 {
                    self.err(e.pos, "expected an enum variant pattern")
                } else if top {
                    self.err(e.pos, fmt("a constant cannot match a value of type ", tn, "; write a tuple pattern `(.., ..)` or `_`"))
                } else {
                    self.err(e.pos, fmt("a value of type ", tn, " cannot be compared with a constant in a pattern (bind it to a name and test it in a guard)"))
                }
                return lower_match_err(ty, e.pos)
            }
            return RPat{k: RP_CONST, ty: ty, pos: e.pos, e: parser_box(e), refutable: true}
        }
    }
    return lower_match_err(ty, Pos{file: 0, line: 0, col: 0})
}

// the variables a pattern binds, in source order: (name, type, position)
priv fn collect(s: *Fx, rp: *RPat, out: *Vec[(str, i64, Pos)]) {
    if rp.nbinds == 0 {
        return
    }
    if rp.k == RP_BIND || rp.k == RP_REF {
        for i in 0..out.len {
            if out[i].0 == rp.name {
                s.err(rp.pos, fmt("`", rp.name, "` is bound more than once in this pattern"))
                return
            }
        }
        t := rp.ty
        if rp.k == RP_REF {
            t = s.cx.types.ptr_to(t)
        }
        out.push((rp.name, t, rp.pos))
        return
    }
    for i in 0..rp.subs.len {
        collect(s, &rp.subs[i], out)
    }
}

// the names a pattern may bind, read off its source form (used after an error in the
// pattern, so that the arm's body does not report them as unknown)
priv fn lower_match_names(s: *Fx, p: *Pat, top: bool, out: *Vec[str]) {
    match *p {
        Ref(n, _) => {
            out.push(n)
        }
        Tuple(subs, _) => {
            for i in 0..subs.len {
                lower_match_names(s, &subs[i], false, out)
            }
        }
        Variant(_, subs, _, _) => {
            for i in 0..subs.len {
                lower_match_names(s, &subs[i], false, out)
            }
        }
        Const(e) => {
            match e.k {
                Ident(n) => {
                    if top {
                        if !known(s, n) {
                            out.push(n)
                        }
                    } else if !s.cx.const_decls.has(n) && s.bare_variant(n, None).2 == 0 {
                        out.push(n)
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
}

// does a pattern contain `&name`?
priv fn lower_match_has_ref(p: *Pat) -> bool {
    match *p {
        Ref(_, _) => return true
        Tuple(subs, _) => {
            for i in 0..subs.len {
                if lower_match_has_ref(&subs[i]) {
                    return true
                }
            }
        }
        Variant(_, subs, _, _) => {
            for i in 0..subs.len {
                if lower_match_has_ref(&subs[i]) {
                    return true
                }
            }
        }
        _ => {}
    }
    return false
}

// offsets of the parts that the sub-patterns of a variant or tuple pattern look at
priv fn pat_offsets(self: *Fx, rp: *RPat) -> Vec[i64] {
    if rp.k == RP_VARIANT {
        return self.cx.types.variant_offsets(enum_of(self, rp.ty), rp.vi)
    }
    match self.cx.types.k(rp.ty) {
        Tuple(ts) => {
            return self.cx.types.tuple_offsets(ts.items())
        }
        _ => {}
    }
    return vec[i64]()
}

// The part of `part` that sub-pattern `i` of `rp` looks at, and whether it lies in the
// payload of an enum (payload memory is read with the "any" alias class).
priv fn pat_part(self: *Fx, rp: *RPat, offs: *Vec[i64], part: Val, payload: bool, i: i64) -> (Val, bool) {
    sty := rp.subs[i].ty
    a := self.add_off(part.v, offs[i])
    v := self.mval(sty, a)
    in_payload := payload || rp.k == RP_VARIANT
    if self.cx.types.is_scalar(sty) {
        if in_payload {
            v.alias = AK_ANY
        } else {
            v.alias = self.cx.types.field_alias(rp.ty, i, sty)
        }
    }
    return (v, in_payload)
}

// the value of a constant pattern, with the type of the part it is compared with
priv fn pat_const_val(self: *Fx, rp: *RPat, top: bool) -> Val {
    pv: Val
    is_nil := false
    match rp.e.k {
        Nil => {
            is_nil = true
        }
        _ => {}
    }
    if top || is_nil {
        pv = self.expr(rp.e, Some(rp.ty))
    } else {
        // inside a pattern a name is a constant even if a local variable has the same name
        pv = val_err()
        match rp.e.k {
            Ident(n) => {
                match self.cx.const_named(n) {
                    Some(c) => {
                        pv = self.const_val(c.0, c.1, Some(rp.ty), rp.pos)
                    }
                    None => {}
                }
            }
            _ => {
                match self.cx.const_eval(rp.e) {
                    Some(cv) => {
                        pv = self.const_val(None, cv, Some(rp.ty), rp.pos)
                    }
                    None => {}
                }
            }
        }
    }
    return self.coerce(pv, rp.ty, rp.pos)
}

// Emits the tests of the refutable sub-patterns of a variant or tuple pattern.
priv fn pat_test_subs(self: *Fx, rp: *RPat, part: Val, payload: bool, ok_b: i64, fail_b: i64) {
    last := -1
    for i in 0..rp.subs.len {
        if rp.subs[i].refutable {
            last = i
        }
    }
    offs := self.pat_offsets(rp)
    for i in 0..rp.subs.len {
        if !rp.subs[i].refutable {
            continue
        }
        sp := self.pat_part(rp, &offs, part, payload, i)
        target := if i == last { ok_b } else { self.new_block() }
        self.pat_test(&rp.subs[i], sp.0, sp.1, NOV, false, target, fail_b)
        if i != last {
            self.switch_to(target)
        }
    }
}

// Emits the test of pattern `rp` against `part` and ends the current block: control goes to
// `ok_b` if the pattern matches and to `fail_b` if not. `key`: the tag or scalar value of
// the part if it is already loaded (the scrutinee), else NOV.
priv fn pat_test(self: *Fx, rp: *RPat, part: Val, payload: bool, key: i64, top: bool, ok_b: i64, fail_b: i64) {
    if rp.k == RP_ERR {
        self.jmp(fail_b)
        return
    }
    if rp.k == RP_CONST {
        pv := self.pat_const_val(rp, top)
        if rp.ty == T_STR {
            l := part
            if payload {
                l = self.load_any(part.v, T_STR)
            }
            r := self.call_rt("__str_eq", vec[i64](), vec_of([]Val{l, pv}), rp.pos)
            c := self.scalar(r)
            self.br(c, ok_b, fail_b)
            return
        }
        if key != NOV {
            p := self.scalar(pv)
            eq := self.ins(Op.Eq, I8, vec_of([]i64{key, p}), 0)
            self.br(eq, ok_b, fail_b)
            return
        }
        l := self.rvalue(part)
        r := self.binary_vals(BinOp.Eq, l, pv, rp.pos)
        c := self.scalar(r)
        self.br(c, ok_b, fail_b)
        return
    }
    if rp.k == RP_VARIANT {
        tag := key
        if tag == NOV {
            if self.cx.types.is_scalar(rp.ty) {
                tag = self.scalar(part)
            } else {
                tag = self.load_raw(part.v, I64, AK_ANY)
            }
        }
        c := self.iconst(I64, rp.vi)
        eq := self.ins(Op.Eq, I8, vec_of([]i64{tag, c}), 0)
        if !subs_refutable(rp) {
            self.br(eq, ok_b, fail_b)
            return
        }
        b := self.new_block()
        self.br(eq, b, fail_b)
        self.switch_to(b)
        self.pat_test_subs(rp, part, payload, ok_b, fail_b)
        return
    }
    if rp.k == RP_DEREF {
        p := key
        if p == NOV {
            p = self.scalar(part)
        }
        z := self.iconst(I64, 0)
        ne := self.ins(Ne, I8, vec_of([]i64{p, z}), 0)
        b := self.new_block()
        self.br(ne, b, fail_b)
        self.switch_to(b)
        sub := &rp.subs[0]
        self.pat_test(sub, self.mval(sub.ty, p), false, NOV, false, ok_b, fail_b)
        return
    }
    if rp.k == RP_TUPLE && rp.refutable {
        self.pat_test_subs(rp, part, payload, ok_b, fail_b)
        return
    }
    self.jmp(ok_b)
}

// copies `ty` out of enum payload memory at `src` to `dst`
priv fn copy_any(self: *Fx, dst: i64, src: i64, ty: i64) {
    lvs := vec[Leaf]()
    self.cx.types.leaves(ty, 0, &lvs)
    if lvs.len > 64 {
        sz := self.cx.types.size_of(ty)
        c := self.iconst(I64, sz)
        self.ins(MemCpy, Void, vec_of([]i64{dst, src, c}), 0)
        return
    }
    for i in 0..lvs.len {
        l := lvs[i]
        a := self.add_off(src, l.off)
        v := self.load_raw(a, l.t, AK_ANY)
        d := self.add_off(dst, l.off)
        self.store_raw(d, v, l.t, l.alias)
    }
}

// the variable of an arm with several alternatives that holds the binding `name`
priv fn lower_match_slot(slots: *Vec[(str, i64, i64)], name: str) -> i64 {
    for i in 0..slots.len {
        if slots[i].0 == name {
            return slots[i].2
        }
    }
    return NOV
}

// Creates the variables of the bindings of `rp` after it matched `part`: `name` is a copy
// of its part, `&name` a pointer to it. With `use_slots` the variables exist already (the
// arm has several alternatives) and only receive their values.
priv fn pat_bind(self: *Fx, rp: *RPat, part: Val, payload: bool, slots: *Vec[(str, i64, i64)], use_slots: bool) {
    if rp.nbinds == 0 || rp.k == RP_ERR {
        return
    }
    if rp.k == RP_BIND {
        if use_slots {
            a := lower_match_slot(slots, rp.name)
            if a == NOV {
                return
            }
            if payload {
                self.copy_any(a, part.v, rp.ty)
            } else {
                self.store(self.mval(rp.ty, a), part)
            }
            return
        }
        tmp: Val
        if payload {
            tmp = self.load_any(part.v, rp.ty)
        } else {
            t := self.temp(rp.ty)
            tmp = self.mval(rp.ty, t)
            self.store(tmp, part)
        }
        self.scopes[self.scopes.len - 1].vars.set(rp.name, (rp.ty, tmp.v))
        return
    }
    if rp.k == RP_REF {
        // the address escapes: a scalar field loses its private alias class
        if part.alias >> 4 != 0 {
            self.cx.exposed.set(part.alias >> 4, true)
        }
        pt := self.cx.types.ptr_to(rp.ty)
        a: i64
        if use_slots {
            a = lower_match_slot(slots, rp.name)
            if a == NOV {
                return
            }
        } else {
            a = self.temp(pt)
        }
        self.store(self.mval(pt, a), self.sval(pt, part.v))
        if !use_slots {
            self.scopes[self.scopes.len - 1].vars.set(rp.name, (pt, a))
        }
        return
    }
    if rp.k == RP_DEREF {
        p := self.scalar(part)
        sub := &rp.subs[0]
        self.pat_bind(sub, self.mval(sub.ty, p), false, slots, use_slots)
        return
    }
    offs := self.pat_offsets(rp)
    for i in 0..rp.subs.len {
        if rp.subs[i].nbinds == 0 {
            continue
        }
        sp := self.pat_part(rp, &offs, part, payload, i)
        self.pat_bind(&rp.subs[i], sp.0, sp.1, slots, use_slots)
    }
}

// is a pattern the constant `nil`?
priv fn lower_match_is_nil(rp: *RPat) -> bool {
    if rp.k != RP_CONST {
        return false
    }
    match rp.e.k {
        Nil => return true
        _ => {}
    }
    return false
}

// the value of a `true` / `false` pattern: 1 / 0, or -1 for anything else
priv fn bool_pat(s: *Fx, rp: *RPat) -> i64 {
    if rp.k != RP_CONST {
        return -1
    }
    saved := s.cx.errs.len
    r := -1
    match s.cx.const_eval(rp.e) {
        Some(cv) => {
            match cv {
                Bool(b) => {
                    r = if b { 1 } else { 0 }
                }
                _ => {}
            }
        }
        None => {}
    }
    s.cx.errs.truncate(saved)
    return r
}

// ---------- exhaustiveness ----------
// Patterns that always match the part they look at (a pattern with an error counts as one,
// so that it does not cause a second diagnostic).
priv fn is_wild(p: *RPat) -> bool {
    return p.k == RP_WILD || p.k == RP_BIND || p.k == RP_REF || p.k == RP_ERR
}

// the row `r` with its first pattern replaced by that pattern's sub-patterns (`n` wildcards
// if it is a wildcard)
priv fn expand(r: *Vec[*RPat], n: i64, wild: *RPat) -> Vec[*RPat] {
    p := r[0]
    out := vec[*RPat]()
    if is_wild(p) {
        for i in 0..n {
            out.push(wild)
        }
    } else {
        for i in 0..p.subs.len {
            out.push(&p.subs[i])
        }
    }
    for i in 1..r.len {
        out.push(r[i])
    }
    return out
}

// the witness `head(w[0], .., w[n-1])` followed by the rest of `w`
priv fn witness(head: str, w: *Vec[str], n: i64, parens: bool) -> Vec[str] {
    out := vec[str]()
    if parens {
        out.push(fmt(head, "(", join(w[..n], ", "), ")"))
    } else {
        out.push(head)
    }
    for i in n..w.len {
        out.push(w[i])
    }
    return out
}

// The rows of `rows` that can match a value whose first part is variant `vi` of enum `eid`,
// checked against that variant's fields and the remaining columns.
priv fn uncovered_variant(s: *Fx, rows: *Vec[Vec[*RPat]], rest: *Vec[i64], eid: i64, vi: i64, wild: *RPat) -> (Vec[str], bool) {
    ptys := clone(s.cx.types.enums[eid].variants[vi].1)
    sub := vec[Vec[*RPat]]()
    for i in 0..rows.len {
        r := &rows[i]
        p := r[0]
        if is_wild(p) || (p.k == RP_VARIANT && p.vi == vi) {
            sub.push(expand(r, ptys.len, wild))
        }
    }
    sub_tys := clone(ptys)
    sub_tys.extend(rest.items())
    w, unc := uncovered(s, &sub, &sub_tys, wild)
    if !unc {
        return (w, false)
    }
    name := s.cx.types.enums[eid].variants[vi].0
    return (witness(name, &w, ptys.len, ptys.len != 0), true)
}

// Is there a value (one part per column, of the types `tys`) that no row of patterns
// matches? If so, such a value is returned in pattern form, one text per column.
// (The usual algorithm: split on the constructors of the first column.)
priv fn uncovered(s: *Fx, rows: *Vec[Vec[*RPat]], tys: *Vec[i64], wild: *RPat) -> (Vec[str], bool) {
    if tys.len == 0 {
        return (vec[str](), rows.len == 0)
    }
    t := tys[0]
    rest := vec_of(tys[1..tys.len])
    eid := enum_of(s, t)
    if eid >= 0 {
        nv := s.cx.types.enums[eid].variants.len
        for vi in 0..nv {
            w, unc := uncovered_variant(s, rows, &rest, eid, vi, wild)
            if unc {
                return (w, true)
            }
        }
        return (vec[str](), false)
    }
    elems: Vec[i64]
    is_tuple := false
    match s.cx.types.k(t) {
        Tuple(ts) => {
            elems = ts
            is_tuple = true
        }
        _ => {}
    }
    if is_tuple {
        sub := vec[Vec[*RPat]]()
        for i in 0..rows.len {
            r := &rows[i]
            if is_wild(r[0]) || r[0].k == RP_TUPLE {
                sub.push(expand(r, elems.len, wild))
            }
        }
        sub_tys := clone(elems)
        sub_tys.extend(rest.items())
        w, unc := uncovered(s, &sub, &sub_tys, wild)
        if !unc {
            return (w, false)
        }
        return (witness("", &w, elems.len, true), true)
    }
    if t == T_BOOL {
        for bv in 1..=0 by -1 {
            sub := vec[Vec[*RPat]]()
            for i in 0..rows.len {
                r := &rows[i]
                if is_wild(r[0]) || bool_pat(s, r[0]) == bv {
                    sub.push(expand(r, 0, wild))
                }
            }
            w, unc := uncovered(s, &sub, &rest, wild)
            if unc {
                return (witness(if bv == 1 { "true" } else { "false" }, &w, 0, false), true)
            }
        }
        return (vec[str](), false)
    }
    // a pointer that some pattern looks through: nil, or a target
    is_ptr := false
    target := 0
    match s.cx.types.k(t) {
        Ptr(inner) => {
            target = inner
            for i in 0..rows.len {
                if rows[i][0].k == RP_DEREF {
                    is_ptr = true
                }
            }
        }
        _ => {}
    }
    if is_ptr {
        nil_rows := vec[Vec[*RPat]]()
        sub := vec[Vec[*RPat]]()
        for i in 0..rows.len {
            r := &rows[i]
            p := r[0]
            if is_wild(p) || lower_match_is_nil(p) {
                nil_rows.push(expand(r, 0, wild))
            }
            if is_wild(p) || p.k == RP_DEREF {
                sub.push(expand(r, 1, wild))
            }
        }
        w0, unc0 := uncovered(s, &nil_rows, &rest, wild)
        if unc0 {
            return (witness("nil", &w0, 0, false), true)
        }
        sub_tys := vec_one(target)
        sub_tys.extend(rest.items())
        w1, unc1 := uncovered(s, &sub, &sub_tys, wild)
        return (w1, unc1)
    }
    // integers, strings, ...: constants never cover the type; only wildcards count
    sub := vec[Vec[*RPat]]()
    for i in 0..rows.len {
        r := &rows[i]
        if is_wild(r[0]) {
            sub.push(expand(r, 0, wild))
        }
    }
    w, unc := uncovered(s, &sub, &rest, wild)
    if !unc {
        return (w, false)
    }
    return (witness("_", &w, 0, false), true)
}

// What a match on a value of type `ty` with the pattern rows `rows` (one pattern each) does
// not cover, in pattern form: for an enum one entry per variant that is not fully covered.
priv fn lower_match_missing(s: *Fx, rows: *Vec[Vec[*RPat]], ty: i64) -> Vec[str] {
    out := vec[str]()
    wild := new[RPat]()
    wild.k = RP_WILD
    eid := enum_of(s, ty)
    if eid >= 0 {
        none := vec[i64]()
        nv := s.cx.types.enums[eid].variants.len
        for vi in 0..nv {
            w, unc := uncovered_variant(s, rows, &none, eid, vi, wild)
            if unc {
                out.push(w[0])
            }
        }
        return out
    }
    match s.cx.types.k(ty) {
        Ptr(inner) => {
            // nil, then what is missing of the target
            any := false
            nil_rows := vec[Vec[*RPat]]()
            sub := vec[Vec[*RPat]]()
            for i in 0..rows.len {
                r := &rows[i]
                p := r[0]
                if p.k == RP_DEREF {
                    any = true
                }
                if is_wild(p) || lower_match_is_nil(p) {
                    nil_rows.push(expand(r, 0, wild))
                }
                if is_wild(p) || p.k == RP_DEREF {
                    sub.push(expand(r, 1, wild))
                }
            }
            if any {
                if nil_rows.len == 0 {
                    out.push("nil")
                }
                out.extend(lower_match_missing(s, &sub, inner).items())
                return out
            }
        }
        _ => {}
    }
    tys := vec_one(ty)
    w, unc := uncovered(s, rows, &tys, wild)
    if unc {
        out.push(w[0])
    }
    return out
}

// ---------- match ----------
fn match_expr(self: *Fx, sc: *Expr, arms: []MatchArm, want: bool, expect: Opt[i64], pos: Pos) -> Val {
    sv := self.expr(sc, None)
    if sv.ty == T_ERR {
        return val_err()
    }
    sk := self.cx.types.k(sv.ty)
    enum_id: Opt[i64] = None
    is_tuple := false
    match sk {
        Enum(e) => { enum_id = Some(e) }
        Tuple(_) => { is_tuple = true }
        _ => {}
    }
    payload_enum := false
    match enum_id {
        Some(e) => { payload_enum = !self.cx.types.enums[e].simple }
        None => {}
    }
    // scrutinee: scalar value, or tag for payload enums
    key: i64
    if payload_enum {
        key = self.load_raw(sv.v, I64, AK_ANY)
    } else if self.cx.types.is_scalar(sv.ty) {
        key = self.scalar(sv)
    } else if sv.ty == T_STR || is_tuple {
        key = NOV
    } else {
        tn := self.tyname(sv.ty)
        self.err(pos, fmt("cannot match on ", tn, " (a match looks at integers, bool, str, enums and tuples)"))
        return val_err()
    }
    // the value the patterns look at
    part := sv
    if sv.ty == T_STR {
        // keep a stable copy of a string scrutinee
        t := self.temp(T_STR)
        tv := self.mval(T_STR, t)
        self.store(tv, sv)
        part = tv
    } else if sv.mem {
        has_ref := false
        guard_call := false
        for ai in 0..len(arms) {
            for pi in 0..arms[ai].pats.len {
                if lower_match_has_ref(&arms[ai].pats[pi]) {
                    has_ref = true
                }
            }
            match arms[ai].guard {
                Some(g) => {
                    if lower_call_has_call(g) {
                        guard_call = true
                    }
                }
                None => {}
            }
        }
        place := lower_expr_addressable(sc)
        // `&name` must point into storage that outlives the match: a value that is not a
        // place is kept in a temporary of the function. A place is matched where it is,
        // except when a guard could change it between the tests (and no `&name` needs the
        // place itself): then the match looks at a copy.
        if (has_ref && !place) || (guard_call && place && !has_ref) {
            t := self.temp(sv.ty)
            tv := self.mval(sv.ty, t)
            self.store(tv, sv)
            part = tv
        }
    }
    bj := self.new_block()
    slot: Opt[Val] = None
    all_dead := true
    has_wild := false
    covered := vec[bool]()
    match enum_id {
        Some(e) => {
            covered = vec_fill(self.cx.types.enums[e].variants.len, false)
        }
        None => {}
    }
    // payload enums, tuples and pointers (which patterns can look through): the unguarded
    // patterns, for the exhaustiveness check
    deep := payload_enum || is_tuple || lower_expr_is_ptr(sk)
    rows := vec[Vec[*RPat]]()
    any_guard := false
    any_pat_err := false
    seen_true := false
    seen_false := false
    result_err := false
    for ai in 0..len(arms) {
        arm := &arms[ai]
        body_b := self.new_block()
        next_b := self.new_block()
        npats := arm.pats.len
        guarded := is_some(arm.guard)
        // check the alternatives; all of them must bind the same variables
        rps := Vec[RPat]{buf: alloc[RPat](npats), len: 0}
        binds := vec[(str, i64, Pos)]()
        pat_err := false
        for pi in 0..npats {
            rp := self.pat_resolve(&arm.pats[pi], sv.ty, true)
            if rp.k == RP_ERR {
                pat_err = true
            } else if pi == 0 {
                collect(self, &rp, &binds)
            } else if !pat_err {
                others := vec[(str, i64, Pos)]()
                collect(self, &rp, &others)
                for i in 0..binds.len {
                    found := false
                    for j in 0..others.len {
                        if others[j].0 == binds[i].0 {
                            found = true
                            if others[j].1 != binds[i].1 && !pat_err {
                                a := self.tyname(binds[i].1)
                                b := self.tyname(others[j].1)
                                self.err(others[j].2, fmt("`", binds[i].0, "` has type ", a, " in one alternative of this arm and ", b, " in another; every alternative must bind it with the same type"))
                                pat_err = true
                            }
                        }
                    }
                    if !found && !pat_err {
                        self.err(arm.pos, fmt("`", binds[i].0, "` is not bound by every alternative of this arm; all patterns of an arm must bind the same names"))
                        pat_err = true
                    }
                }
                for j in 0..others.len {
                    found := false
                    for i in 0..binds.len {
                        if others[j].0 == binds[i].0 {
                            found = true
                        }
                    }
                    if !found && !pat_err {
                        self.err(others[j].2, fmt("`", others[j].0, "` is not bound by every alternative of this arm; all patterns of an arm must bind the same names"))
                        pat_err = true
                    }
                }
            }
            rps.push(rp)
        }
        // with several alternatives the bindings live in variables that each alternative fills
        slots := vec[(str, i64, i64)]()
        use_slots := npats > 1 && binds.len != 0 && !pat_err
        if use_slots {
            for i in 0..binds.len {
                slots.push((binds[i].0, binds[i].1, self.temp(binds[i].1)))
            }
        }
        for pi in 0..npats {
            last := pi + 1 == npats
            fail_b := if last { next_b } else { self.new_block() }
            rp := &rps[pi]
            // what the arm covers (an arm with a guard covers nothing)
            if rp.k == RP_ERR {
                any_pat_err = true
            } else if guarded {
                any_guard = true
            } else if rp.k == RP_VARIANT {
                if !subs_refutable(rp) {
                    covered[rp.vi] = true
                }
            } else if !rp.refutable {
                has_wild = true
            } else if sv.ty == T_BOOL {
                bp := bool_pat(self, rp)
                if bp == 1 {
                    seen_true = true
                } else if bp == 0 {
                    seen_false = true
                }
            }
            if deep && !guarded {
                row := new[RPat]()
                *row = *rp
                rows.push(vec_one(row))
            }
            if use_slots {
                bind_b := self.new_block()
                self.pat_test(rp, part, false, key, true, bind_b, fail_b)
                self.switch_to(bind_b)
                self.pat_bind(rp, part, false, &slots, true)
                self.jmp(body_b)
            } else {
                self.pat_test(rp, part, false, key, true, body_b, fail_b)
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
        if use_slots {
            for i in 0..slots.len {
                self.scopes[self.scopes.len - 1].vars.set(slots[i].0, (slots[i].1, slots[i].2))
            }
        } else if pat_err {
            // the arm's variables are unknown: give them the error type, which is silent
            names := vec[str]()
            for pi in 0..npats {
                lower_match_names(self, &arm.pats[pi], true, &names)
            }
            for i in 0..names.len {
                if names[i] != "_" {
                    self.scopes[self.scopes.len - 1].vars.set(names[i], (T_ERR, self.temp(T_ERR)))
                }
            }
        } else if npats == 1 {
            self.pat_bind(&rps[0], part, false, &slots, false)
        }
        match arm.guard {
            Some(g) => {
                // the guard sees the bindings; if it is false the next arm is tried
                gb := self.new_block()
                self.cond_br(g, gb, next_b)
                self.switch_to(gb)
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
        if !covered[i] {
            all_covered = false
        }
    }
    exhaustive := has_wild || (is_some(enum_id) && all_covered) || (seen_true && seen_false)
    missing := vec[str]()
    if !exhaustive {
        if deep {
            // patterns with constants or variants inside can cover a value together
            missing = lower_match_missing(self, &rows, sv.ty)
            exhaustive = missing.len == 0
        } else if sv.ty == T_BOOL {
            if !seen_true {
                missing.push("true")
            }
            if !seen_false {
                missing.push("false")
            }
        } else {
            match enum_id {
                Some(e) => {
                    for i in 0..covered.len {
                        if !covered[i] {
                            missing.push(self.cx.types.enums[e].variants[i].0)
                        }
                    }
                }
                None => {}
            }
        }
    }
    if exhaustive {
        self.terminate(Trap)
    } else {
        if want && is_some(slot) && !any_pat_err {
            hint := if any_guard { " (an arm with a guard does not count: add an arm without a guard or `_ =>`)" } else { "" }
            if missing.len == 0 {
                self.err(pos, if any_guard { "match used as a value must be exhaustive (add a `_ =>` arm; an arm with a guard does not count)" } else { "match used as a value must be exhaustive (add a `_ =>` arm)" })
            } else {
                if missing.len > 8 {
                    missing.truncate(8)
                    missing.push("...")
                }
                self.err(pos, fmt("match used as a value must be exhaustive; missing: ", join(missing.items(), ", "), hint))
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

// A note for a mismatch between two different types that print the same: a type of the
// program has the name of a type of the standard library (for example its own `Opt`).
fn lower_match_same_name(a: str, b: str) -> str {
    if a != b {
        return ""
    }
    return " (two different types have this name: one declared in this program, one in the standard library; the library's functions take the library's type)"
}

// names that a call resolves before it looks for a variant: builtin functions and types
fn lower_match_builtin_name(n: str) -> bool {
    match n {
        "len", "sizeof", "cast", "mkslice", "ptr", "syscall", "sqrt", "fabs", "fmin", "fmax" => return true
        "popcnt", "ctz", "clz", "bswap", "rotl", "rotr", "memcopy", "memfill", "embed" => return true
        "panic", "fmt", "hash", "put", "print" => return true
        _ => {}
    }
    return is_some(lower_builtin_type(n))
}
