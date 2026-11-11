// AST for AL.

struct Pos {
    file i64
    line i64
    col i64
}

struct Diag {
    pos Pos
    msg str
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
    k EK
    pos Pos
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
}

struct MatchArm {
    pats Vec[Pat]
    body Block
    pos Pos
    // `if cond` after the patterns: the arm is taken only if it holds
    guard Opt[*Expr]
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
    stmts Vec[Stmt]
    end Pos
}

struct Stmt {
    k SK
    pos Pos
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
}

struct FnDecl {
    name str
    tparams Vec[str]
    params Vec[(str, TypeAst)]
    ret Opt[TypeAst]
    body Block
    pos Pos
    // `inline` in the Rust source (a keyword in AL)
    inl i64 // 1 = always inline, -1 = never, 0 = auto
    // `extern "lib" fn`: a C function in the named shared library (no body)
    ext Opt[str]
}

struct StructDecl {
    name str
    tparams Vec[str]
    fields Vec[(str, TypeAst)]
    pos Pos
}

struct EnumDecl {
    name str
    tparams Vec[str]
    variants Vec[(str, Vec[TypeAst])]
    pos Pos
}

struct ConstDecl {
    name str
    ty Opt[TypeAst]
    val Expr
    pos Pos
}

struct GlobalDecl {
    name str
    ty Opt[TypeAst]
    init Opt[Expr]
    pos Pos
}

struct TestDecl {
    name str
    body Block
    pos Pos
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
fn ast_type_str_list(ts *Vec[TypeAst]) str {
    parts := vec[str]()
    for i in 0..ts.len {
        parts.push(ast_type_str(&ts.buf[i]))
    }
    return join(parts.items(), ", ")
}

// source form of a type (for signatures in diagnostics and `alc sigs`)
fn ast_type_str(t *TypeAst) str {
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
            var len str = "_"
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
                    return fmt("fn(", p, ") ", ast_type_str(r2))
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
