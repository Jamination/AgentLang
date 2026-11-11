// AST for AL.

struct Pos {
    file: i64
    line: i64
    col: i64
}

struct Diag {
    pos: Pos
    msg: str
}

enum TypeAst {
    TypeAstName(str, Vec[TypeAst], Pos),
    TypeAstPtr(*TypeAst),
    TypeAstSlice(*TypeAst),
    TypeAstArray(*Expr, *TypeAst),
    TypeAstFn(Vec[TypeAst], Opt[*TypeAst]),
    TypeAstTuple(Vec[TypeAst]),
}

enum UnOp {
    UnOpNeg,
    UnOpNot,
    UnOpBitNot,
    UnOpAddr,
    UnOpDeref,
}

enum BinOp {
    BinOpAdd,
    BinOpSub,
    BinOpMul,
    BinOpDiv,
    BinOpRem,
    BinOpAnd,
    BinOpOr,
    BinOpXor,
    BinOpShl,
    BinOpShr,
    BinOpEq,
    BinOpNe,
    BinOpLt,
    BinOpLe,
    BinOpGt,
    BinOpGe,
    BinOpLAnd,
    BinOpLOr,
}

struct Expr {
    k: EK
    pos: Pos
}

enum EK {
    EKInt(u64),
    EKFloat(f64),
    EKStr(str),
    EKBool(bool),
    EKNil,
    EKIdent(str),
    EKUn(UnOp, *Expr),
    EKBin(BinOp, *Expr, *Expr),
    EKCall(*Expr, Vec[Expr]),
    EKIndex(*Expr, Vec[Expr]),
    EKSlice(*Expr, Opt[*Expr], Opt[*Expr]),
    EKField(*Expr, str),
    EKLit(*Expr, Vec[(Opt[str], Expr)]),
    EKTypeE(TypeAst),
    EKIf(*Expr, Block, Block),
    EKTuple(Vec[Expr]),
    EKMatch(*Expr, Vec[MatchArm]),
    // anonymous function `fn(a: A, b: B) -> R { body }` (the declaration has an empty name)
    EKFn(*FnDecl),
}

struct MatchArm {
    pats: Vec[Pat]
    body: Block
    pos: Pos
    // `if cond` after the patterns: the arm is taken only if it holds
    guard: Opt[*Expr]
}

enum Pat {
    PatWild,
    // an expression: a constant (int, string, named constant, ...). A bare name or
    // `Enum.Variant` is resolved when the match is lowered: a data-less variant of the
    // matched type, a constant, or (inside a variant / tuple pattern) a new binding.
    PatConst(Expr),
    // [Enum.]Variant(sub-patterns): variant name, one pattern per payload field, position,
    // and, if the pattern has a qualifier, the whole pattern as the expression it was
    // parsed from: a call of `Enum.Variant` or `Enum[T].Variant`
    PatVariant(str, Vec[Pat], Pos, Opt[*Expr]),
    // (p, p, ...)
    PatTuple(Vec[Pat], Pos),
    // &name: binds a pointer to the matched part
    PatRef(str, Pos),
}

struct Block {
    stmts: Vec[Stmt]
    end: Pos
}

struct Stmt {
    k: SK
    pos: Pos
}

enum SK {
    SKExpr(Expr),
    SKLet(Vec[str], Expr),
    SKMultiAssign(Vec[Expr], Expr),
    SKVar(str, Opt[TypeAst], Opt[Expr]),
    SKAssign(Expr, Opt[BinOp], Expr),
    SKIf(Expr, Block, Opt[Block]),
    SKWhile(Expr, Block),
    SKLoop(Block),
    // fields (named in the Rust source): var, var2, lo, hi, incl, step, body
    SKFor(str, Opt[str], Expr, Opt[Expr], bool, Opt[Expr], Block),
    SKReturn(Opt[Expr]),
    SKBreak,
    SKContinue,
    SKAssert(Expr, Opt[Expr]),
    SKBlock(Block),
    SKDefer(Block),
    // `name: for/while/loop ...`: the loop statement with its label
    SKLabeled(str, *Stmt),
    // `break name` / `continue name`
    SKBreakTo(str),
    SKContinueTo(str),
    // `fn name(params) -> R { body }` inside a block: a nested function
    SKFn(*FnDecl),
}

struct FnDecl {
    name: str
    tparams: Vec[str]
    params: Vec[(str, TypeAst)]
    ret: Opt[TypeAst]
    body: Block
    pos: Pos
    // `inline` in the Rust source (a keyword in AL)
    inl: i64 // 1 = always inline, -1 = never, 0 = auto
    // `extern "lib" fn name(params) -> R`: a C function in the named shared library (no body)
    ext: Opt[str]
    // declared with `priv`: visible only in its own file (see priv.al)
    is_priv: bool
}

struct StructDecl {
    name: str
    tparams: Vec[str]
    fields: Vec[(str, TypeAst)]
    pos: Pos
    // declared with `priv`: visible only in its own file (see priv.al)
    is_priv: bool
}

struct EnumDecl {
    name: str
    tparams: Vec[str]
    variants: Vec[(str, Vec[TypeAst])]
    pos: Pos
    // declared with `priv`: visible only in its own file (see priv.al)
    is_priv: bool
}

struct ConstDecl {
    name: str
    ty: Opt[TypeAst]
    val: Expr
    pos: Pos
    // declared with `priv`: visible only in its own file (see priv.al)
    is_priv: bool
}

struct GlobalDecl {
    name: str
    ty: Opt[TypeAst]
    init: Opt[Expr]
    pos: Pos
    // declared with `priv`: visible only in its own file (see priv.al)
    is_priv: bool
}

struct TestDecl {
    name: str
    body: Block
    pos: Pos
}

enum Decl {
    DeclFn(FnDecl),
    DeclStruct(StructDecl),
    DeclEnum(EnumDecl),
    DeclConst(ConstDecl),
    DeclGlobal(GlobalDecl),
    DeclTest(TestDecl),
    DeclUse(str, Pos),
}

// the source forms of a list of types, separated by ", "
fn ast_type_str_list(ts: *Vec[TypeAst]) -> str {
    parts := vec[str]()
    for i in 0..ts.len {
        parts.push(ast_type_str(&ts[i]))
    }
    return join(parts.items(), ", ")
}

// source form of a type (for signatures in diagnostics and `alc sigs`)
fn ast_type_str(t: *TypeAst) -> str {
    match *t {
        TypeAstName(n, args, _) => {
            if args.is_empty() {
                return n
            } else {
                return fmt(n, "[", ast_type_str_list(&args), "]")
            }
        }
        TypeAstPtr(e) => {
            return fmt("*", ast_type_str(e))
        }
        TypeAstSlice(e) => {
            return fmt("[]", ast_type_str(e))
        }
        TypeAstArray(n, e) => {
            len: str = "_"
            match n.k {
                EKInt(k) => {
                    len = fmt(k)
                }
                EKIdent(name) => {
                    len = name
                }
                _ => {}
            }
            return fmt("[", len, "]", ast_type_str(e))
        }
        TypeAstFn(ps, r) => {
            p := ast_type_str_list(&ps)
            match r {
                Some(r2) => {
                    return fmt("fn(", p, ") -> ", ast_type_str(r2))
                }
                None => {
                    return fmt("fn(", p, ")")
                }
            }
        }
        TypeAstTuple(ts) => {
            return fmt("(", ast_type_str_list(&ts), ")")
        }
    }
    return ""
}

// the header of a function as it is declared: `fn name[T](a: A, b: B) -> R`; for an
// anonymous function `fn(a: A, b: B) -> R` (for diagnostics and `alc sigs`)
fn ast_sig_str(f: *FnDecl) -> str {
    parts := vec[str]()
    for i in 0..f.params.len {
        parts.push(fmt(f.params[i].0, ": ", ast_type_str(&f.params[i].1)))
    }
    r := ""
    match f.ret {
        Some(t) => {
            r = fmt(" -> ", ast_type_str(&t))
        }
        None => {}
    }
    head := if f.name == "" { "fn" } else { fmt("fn ", f.name, ast_tparams_str(&f.tparams)) }
    return fmt(head, "(", join(parts.items(), ", "), ")", r)
}

// "[T, U]" of a declaration with type parameters, or nothing
fn ast_tparams_str(t: *Vec[str]) -> str {
    if t.is_empty() {
        return ""
    }
    return fmt("[", join(t.items(), ", "), "]")
}

// a struct as it is declared, on one line: `struct Name[T] { a: A, b: B }`
fn ast_struct_str(s: *StructDecl) -> str {
    parts := vec[str]()
    for i in 0..s.fields.len {
        parts.push(fmt(s.fields[i].0, ": ", ast_type_str(&s.fields[i].1)))
    }
    return fmt("struct ", s.name, ast_tparams_str(&s.tparams), " { ", join(parts.items(), ", "), " }")
}

// an enum as it is declared, on one line: `enum Name[T] { A, B(T) }`
fn ast_enum_str(e: *EnumDecl) -> str {
    vs := vec[str]()
    for i in 0..e.variants.len {
        v := &e.variants[i]
        if v.1.is_empty() {
            vs.push(v.0)
        } else {
            vs.push(fmt(v.0, "(", ast_type_str_list(&v.1), ")"))
        }
    }
    return fmt("enum ", e.name, ast_tparams_str(&e.tparams), " { ", join(vs.items(), ", "), " }")
}

// A `priv` declaration `name` of file number `k` is known to the compiler as `name`, the byte
// 1 and `k` in decimal (see priv.al). ast_plain gives the name as it was written.
fn ast_plain(name: str) -> str {
    i := len(name)
    while i > 0 && name[i - 1] >= '0' && name[i - 1] <= '9' {
        i -= 1
    }
    if i > 0 && i < len(name) && name[i - 1] == 1 {
        return name[..i - 1]
    }
    return name
}

// is this the internal name of a `priv` declaration?
fn ast_is_private(name: str) -> bool {
    return len(ast_plain(name)) != len(name)
}

// a text for the user (a diagnostic, a signature): every internal name in it as it was written
fn ast_plain_text(s: str) -> str {
    first := -1
    for i in 0..len(s) {
        if s[i] == 1 {
            first = i
            break
        }
    }
    if first < 0 {
        return s
    }
    out := vec[u8]()
    out.extend(s[..first])
    i := first
    while i < len(s) {
        if s[i] == 1 {
            i += 1
            while i < len(s) && s[i] >= '0' && s[i] <= '9' {
                i += 1
            }
        } else {
            out.push(s[i])
            i += 1
        }
    }
    return out.items()
}
