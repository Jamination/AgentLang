// Checks on the AST that need the types of the function being lowered.
//
// Writes to a copy: `x := v[i]` copies the element. If afterwards fields of `x` are assigned
// and `x` is never used in any other way, the writes are lost; almost always the element
// itself was meant. `lint_copy_writes` finds that pattern for one `:=` statement.

struct LintUse {
    name str
    // direct field assignments `name.f = e` / `name.f op= e`
    writes i64
    first Pos
    field str
    // every other occurrence of the name
    others i64
}

// is `e` a place that is copied when read: a field or element of something (not a call)
fn lint_is_place(e *Expr) bool {
    match e.k {
        EKIndex(b, idx) => return lint_is_root(b)
        EKField(b, f) => return lint_is_root(b)
        _ => return false
    }
}

fn lint_is_root(e *Expr) bool {
    match e.k {
        EKIdent(n) => return true
        EKIndex(b, idx) => return lint_is_root(b)
        EKField(b, f) => return lint_is_root(b)
        EKUn(op, x) => {
            match op {
                UnOpDeref => return lint_is_root(x)
                _ => return false
            }
        }
        _ => return false
    }
}

// source text of a place expression (an index that is not a name or number is shown as `..`)
fn lint_place_str(e *Expr) str {
    match e.k {
        EKIdent(n) => return ast_plain(n)
        EKInt(v) => return fmt(v)
        EKField(b, f) => return fmt(lint_place_str(b), ".", f)
        EKIndex(b, idx) => {
            parts := vec[str]()
            for i in 0..idx.len {
                parts.push(lint_place_str(&idx.buf[i]))
            }
            return fmt(lint_place_str(b), "[", join(parts.items(), ", "), "]")
        }
        EKUn(op, x) => {
            match op {
                UnOpDeref => return fmt("(*", lint_place_str(x), ")")
                _ => return ".."
            }
        }
        _ => return ".."
    }
}

fn lint_exprs(u *LintUse, es *Vec[Expr]) bool {
    for i in 0..es.len {
        lint_expr(u, &es.buf[i])
    }
    return true
}

fn lint_opt(u *LintUse, e Opt[*Expr]) bool {
    match e {
        Some(x) => return lint_expr(u, x)
        None => return true
    }
}

fn lint_block(u *LintUse, b *Block) bool {
    for i in 0..b.stmts.len {
        lint_stmt(u, &b.stmts.buf[i])
    }
    return true
}

fn lint_expr(u *LintUse, e *Expr) bool {
    return match e.k {
        EKInt(v) => true
        EKFloat(v) => true
        EKStr(s) => true
        EKBool(b) => true
        EKNil => true
        EKIdent(n) => {
            if n == u.name {
                u.others += 1
            }
            true
        }
        EKUn(op, x) => lint_expr(u, x)
        EKBin(op, a, b) => {
            lint_expr(u, a)
            lint_expr(u, b)
        }
        EKCall(c, args) => {
            lint_expr(u, c)
            lint_exprs(u, &args)
        }
        EKIndex(b, idx) => {
            lint_expr(u, b)
            lint_exprs(u, &idx)
        }
        EKSlice(b, lo, hi) => {
            lint_expr(u, b)
            lint_opt(u, lo)
            lint_opt(u, hi)
        }
        EKField(b, f) => lint_expr(u, b)
        EKLit(t, fields) => {
            lint_expr(u, t)
            for i in 0..fields.len {
                lint_expr(u, &fields.buf[i].1)
            }
            true
        }
        EKTypeE(t) => true
        EKIf(c, a, b) => {
            lint_expr(u, c)
            lint_block(u, &a)
            lint_block(u, &b)
        }
        EKTuple(es) => lint_exprs(u, &es)
        EKMatch(sc, arms) => {
            lint_expr(u, sc)
            for i in 0..arms.len {
                lint_block(u, &arms.buf[i].body)
            }
            true
        }
        EKClosure(ps, r, body) => lint_block(u, body)
    }
}

fn lint_stmt(u *LintUse, s *Stmt) bool {
    return match s.k {
        SKExpr(e) => lint_expr(u, &e)
        SKLet(names, e) => lint_expr(u, &e)
        SKMultiAssign(lhs, e) => {
            lint_exprs(u, &lhs)
            lint_expr(u, &e)
        }
        SKVar(name, ty, init) => {
            match init {
                Some(e) => lint_expr(u, &e)
                None => true
            }
        }
        SKAssign(lhs, op, rhs) => {
            lint_expr(u, &rhs)
            direct := false
            match lhs.k {
                EKField(b, f) => {
                    match b.k {
                        EKIdent(n) => {
                            if n == u.name {
                                direct = true
                                if u.writes == 0 {
                                    u.first = lhs.pos
                                    u.field = f
                                }
                                u.writes += 1
                            }
                        }
                        _ => {}
                    }
                }
                _ => {}
            }
            if direct {
                true
            } else {
                lint_expr(u, &lhs)
            }
        }
        SKIf(c, t, eo) => {
            lint_expr(u, &c)
            lint_block(u, &t)
            match eo {
                Some(e) => lint_block(u, &e)
                None => true
            }
        }
        SKWhile(c, body) => {
            lint_expr(u, &c)
            lint_block(u, &body)
        }
        SKLoop(body) => lint_block(u, &body)
        SKFor(var1, var2, lo, hi, incl, step, body) => {
            lint_expr(u, &lo)
            match hi {
                Some(h) => {
                    lint_expr(u, &h)
                }
                None => {}
            }
            match step {
                Some(st) => {
                    lint_expr(u, &st)
                }
                None => {}
            }
            lint_block(u, &body)
        }
        SKReturn(e) => {
            match e {
                Some(x) => lint_expr(u, &x)
                None => true
            }
        }
        SKBreak => true
        SKContinue => true
        SKAssert(c, m) => {
            lint_expr(u, &c)
            match m {
                Some(x) => lint_expr(u, &x)
                None => true
            }
        }
        SKBlock(b) => lint_block(u, &b)
        SKDefer(b) => lint_block(u, &b)
        SKLabeled(label, st) => lint_stmt(u, st)
        SKBreakTo(label) => true
        SKContinueTo(label) => true
    }
}

// Statement `i` of `b` has just been lowered. If it is `x := <field or element>` of a struct
// type and the rest of the block only assigns fields of `x`, that is reported.
fn lint_copy_writes(self *Fx, b *Block, i i64) {
    s := &b.stmts.buf[i]
    match s.k {
        SKLet(names, e) => {
            if names.len != 1 || names.buf[0] == "_" || !lint_is_place(&e) {
                return
            }
            name := names.buf[0]
            match self.lookup(name) {
                Some(v) => {
                    match self.cx.types.k(v.0) {
                        TyKStruct(sid) => {}
                        _ => return
                    }
                }
                None => return
            }
            u := LintUse{name: name, writes: 0, first: s.pos, field: "", others: 0}
            for j in i + 1..b.stmts.len {
                lint_stmt(&u, &b.stmts.buf[j])
                if u.others > 0 {
                    return
                }
            }
            if u.writes > 0 {
                src := lint_place_str(&e)
                plain := ast_plain(name)
                self.err(u.first, fmt("`", plain, "` is a copy of `", src, "` (`:=` copies a struct), so this assignment changes only the copy, and the copy is never read afterwards. To change the original write `", src, ".", u.field, " = ...`, or take a pointer: `", plain, " := &", src, "`"))
            }
        }
        _ => {}
    }
}
