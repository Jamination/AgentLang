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
    Name(str, Vec[TypeAst], Pos),
    Ptr(*TypeAst),
    Slice(*TypeAst),
    Array(*Expr, *TypeAst),
    Fn(Vec[TypeAst], Opt[*TypeAst]),
    Tuple(Vec[TypeAst]),
}

enum UnOp {
    Neg,
    Not,
    BitNot,
    Addr,
    Deref,
}

enum BinOp {
    Add,
    Sub,
    Mul,
    Div,
    Rem,
    And,
    Or,
    Xor,
    Shl,
    Shr,
    Eq,
    Ne,
    Lt,
    Le,
    Gt,
    Ge,
    LAnd,
    LOr,
}

// Nodes are kept small (big parts are behind pointers): the parser and lowering copy and
// match them by value
struct Expr {
    k: EK
    pos: Pos
}

enum EK {
    Int(u64, bool), // value, written in decimal
    Float(f64, f32), // the value; the literal rounded once to f32
    Str(str),
    Bool(bool),
    Nil,
    Ident(str),
    Un(UnOp, *Expr),
    Bin(BinOp, *Expr, *Expr),
    Call(*Expr, Vec[Expr]),
    Index(*Expr, Vec[Expr]),
    Slice(*Expr, Opt[*Expr], Opt[*Expr]),
    Field(*Expr, str),
    Lit(*Expr, Vec[(Opt[str], Expr)]),
    TypeE(*TypeAst),
    If(*Expr, *Block, *Block),
    Tuple(Vec[Expr]),
    Match(*Expr, Vec[MatchArm]),
    // anonymous function `fn(a: A, b: B) -> R { body }` (the declaration has an empty name)
    Fn(*FnDecl),
}

struct MatchArm {
    pats: Vec[Pat]
    body: Block
    pos: Pos
    // `if cond` after the patterns: the arm is taken only if it holds
    guard: Opt[*Expr]
}

enum Pat {
    Wild,
    // an expression: a constant (int, string, named constant, ...). A bare name or
    // `Enum.Variant` is resolved when the match is lowered: a data-less variant of the
    // matched type, a constant, or (inside a variant / tuple pattern) a new binding.
    Const(Expr),
    // [Enum.]Variant(sub-patterns): variant name, one pattern per payload field, position,
    // and, if the pattern has a qualifier, the whole pattern as the expression it was
    // parsed from: a call of `Enum.Variant` or `Enum[T].Variant`
    Variant(str, Vec[Pat], Pos, Opt[*Expr]),
    // (p, p, ...)
    Tuple(Vec[Pat], Pos),
    // &name: binds a pointer to the matched part
    Ref(str, Pos),
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
    Expr(*Expr),
    Let(Vec[str], *Expr),
    MultiAssign(Vec[Expr], *Expr),
    Var(str, Opt[*TypeAst], Opt[*Expr]),
    Assign(*Expr, Opt[BinOp], *Expr),
    If(*Expr, *Block, Opt[*Block]),
    While(*Expr, *Block),
    Loop(*Block),
    For(*ForStmt),
    Return(Opt[*Expr]),
    Break,
    Continue,
    Assert(*Expr, Opt[*Expr]),
    Block(*Block),
    Defer(*Block),
    // `name: for/while/loop ...`: the loop statement with its label
    Labeled(str, *Stmt),
    // `break name` / `continue name`
    BreakTo(str),
    ContinueTo(str),
    // `fn name(params) -> R { body }` inside a block: a nested function
    Fn(*FnDecl),
}

// `for var1, var2 in lo..hi by step { body }` (`..=`: incl)
struct ForStmt {
    var1: str
    var2: Opt[str]
    lo: *Expr
    hi: Opt[*Expr]
    incl: bool
    step: Opt[*Expr]
    body: *Block
}

struct FnDecl {
    name: str
    tparams: Vec[str]
    params: Vec[(str, TypeAst)]
    ret: Opt[TypeAst]
    body: Block
    pos: Pos
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
    // `extern "lib" name: T`: a C variable of the named shared library (no initializer)
    ext: Opt[str]
}

struct TestDecl {
    name: str
    body: Block
    pos: Pos
}

enum Decl {
    Fn(FnDecl),
    Struct(StructDecl),
    Enum(EnumDecl),
    Const(ConstDecl),
    Global(GlobalDecl),
    Test(TestDecl),
    Use(str, Pos),
}

// the source forms of a list of types, separated by ", "
priv fn type_str_list(ts: *Vec[TypeAst]) -> str {
    parts := vec[str]()
    for i in 0..ts.len {
        parts.push(ast_type_str(&ts[i]))
    }
    return join(parts.items(), ", ")
}

// source form of a type (for signatures in diagnostics and `alc sigs`)
fn ast_type_str(t: *TypeAst) -> str {
    match *t {
        Name(n, args, _) if args.is_empty() => n
        Name(n, args, _) => fmt(n, "[", type_str_list(&args), "]")
        Ptr(e) => fmt("*", ast_type_str(e))
        Slice(e) => fmt("[]", ast_type_str(e))
        Array(n, e) => fmt("[", ast_expr_str(n), "]", ast_type_str(e))
        Fn(ps, Some(r)) => fmt("fn(", type_str_list(&ps), ") -> ", ast_type_str(r))
        Fn(ps, None) => fmt("fn(", type_str_list(&ps), ")")
        Tuple(ts) => fmt("(", type_str_list(&ts), ")")
    }
}

// binding strength of an operator, as in the parser (higher binds tighter)
priv fn bin_prec(op: BinOp) -> i64 {
    return match op {
        Mul, Div, Rem => 9
        Add, Sub => 8
        Shl, Shr => 7
        And => 6
        Xor => 5
        Or => 4
        Eq, Ne, Lt, Le, Gt, Ge => 3
        LAnd => 2
        LOr => 1
    }
}

priv fn bin_text(op: BinOp) -> str {
    return match op {
        Mul => "*"
        Div => "/"
        Rem => "%"
        Add => "+"
        Sub => "-"
        Shl => "<<"
        Shr => ">>"
        And => "&"
        Xor => "^"
        Or => "|"
        Eq => "=="
        Ne => "!="
        Lt => "<"
        Le => "<="
        Gt => ">"
        Ge => ">="
        LAnd => "&&"
        LOr => "||"
    }
}

// an operand of an operator of strength `prec`, in parentheses where the tree needs them
// (operators are left-associative: a right operand of the same strength needs them too)
priv fn operand_str(e: *Expr, prec: i64, right: bool) -> str {
    match e.k {
        Bin(op, _, _) if bin_prec(op) < prec || (right && bin_prec(op) == prec) => return fmt("(", ast_expr_str(e), ")")
        _ => {}
    }
    return ast_expr_str(e)
}

priv fn expr_list_str(es: *Vec[Expr]) -> str {
    parts := vec[str]()
    for i in 0..es.len {
        parts.push(ast_expr_str(&es[i]))
    }
    return join(parts.items(), ", ")
}

// source form of a constant expression such as an array length (`N + 1`, `sizeof[T]()`); a
// kind of expression that does not occur there is `...`
fn ast_expr_str(e: *Expr) -> str {
    return match e.k {
        Int(v, _) => fmt(v)
        Float(f, _) => fmt(f)
        Bool(b) => fmt(b)
        Nil => "nil"
        Str(s) => fmt("\"", s, "\"")
        Ident(n) => n
        Un(op, x) => {
            o := match op {
                Neg => "-"
                Not => "!"
                BitNot => "~"
                Addr => "&"
                Deref => "*"
            }
            inner := match x.k {
                Bin(_, _, _) => fmt("(", ast_expr_str(x), ")")
                _ => ast_expr_str(x)
            }
            fmt(o, inner)
        }
        Bin(op, a, b) => fmt(operand_str(a, bin_prec(op), false), " ", bin_text(op), " ", operand_str(b, bin_prec(op), true))
        Call(c, args) => fmt(operand_str(c, 10, false), "(", expr_list_str(&args), ")")
        Index(b, idx) => fmt(operand_str(b, 10, false), "[", expr_list_str(&idx), "]")
        Field(b, n) => fmt(operand_str(b, 10, false), ".", n)
        TypeE(t) => ast_type_str(t)
        Tuple(es) => fmt("(", expr_list_str(&es), ")")
        _ => "..."
    }
}

// the header of a function as it is declared: `fn name[T](a: A, b: B) -> R`; for an
// anonymous function `fn(a: A, b: B) -> R` (for diagnostics and `alc sigs`)
fn ast_sig_str(f: *FnDecl) -> str {
    parts := vec[str]()
    for i in 0..f.params.len {
        parts.push(fmt(f.params[i].0, ": ", ast_type_str(&f.params[i].1)))
    }
    r := match f.ret {
        Some(&t) => fmt(" -> ", ast_type_str(t))
        None => ""
    }
    head := if f.name == "" { "fn" } else { fmt("fn ", f.name, tparams_str(&f.tparams)) }
    return fmt(head, "(", join(parts.items(), ", "), ")", r)
}

// "[T, U]" of a declaration with type parameters, or nothing
priv fn tparams_str(t: *Vec[str]) -> str {
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
    return fmt("struct ", s.name, tparams_str(&s.tparams), " { ", join(parts.items(), ", "), " }")
}

// an enum as it is declared, on one line: `enum Name[T] { A, B(T) }`
fn ast_enum_str(e: *EnumDecl) -> str {
    vs := vec[str]()
    for i in 0..e.variants.len {
        v := &e.variants[i]
        if v.1.is_empty() {
            vs.push(v.0)
        } else {
            vs.push(fmt(v.0, "(", type_str_list(&v.1), ")"))
        }
    }
    return fmt("enum ", e.name, tparams_str(&e.tparams), " { ", join(vs.items(), ", "), " }")
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
