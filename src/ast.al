// AST for AL.

// line and column (1-based) are 32-bit: a source file is less than 2 GB (lexer_lex). The file
// index stays 64-bit: the struct is 16 bytes either way and the file is compared with i64s
struct Pos {
    file: i64
    line: i32
    col: i32
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

// ---------- symbols ----------
// Every identifier is interned: its text gets a number (a symbol) and one canonical copy of
// its bytes, which the lexer puts into the tokens. Lowering keys its tables by symbol.
// ast_sym finds the symbol of a canonical text without hashing: the 8 bytes in front of
// the text hold its number. Any other text of the same bytes is found through the hash table.

// FNV-1a: the start value and the factor per byte (the lexer hashes identifiers as it reads them)
const AST_SYM_H0: u64 = 0xcbf29ce484222325
const AST_SYM_HMUL: u64 = 0x100000001b3

priv sym_texts: Vec[str]
priv sym_hashes: Vec[u64]
// open addressing (linear probing), a power of two long: 0 for a free slot, else the upper
// half of the symbol's hash and the symbol + 1 in the lower half. The home slot of a hash is
// given by the top bits of hash * SYM_MIX (FNV alone leaves short texts clustered).
priv sym_slots: []u64
priv sym_shift: u64
priv const SYM_MIX: u64 = 0x9E3779B97F4A7C15
// the canonical texts are appended to the current chunk, each behind its number
priv sym_chunk: []u8
priv sym_chunk_used: i64

priv const SYM_CHUNK = 1 << 20

fn ast_sym_hash(s: str) -> u64 {
    h := AST_SYM_H0
    for c in s {
        h = (h ^ u64(c)) * AST_SYM_HMUL
    }
    return h
}

// the number of symbols so far (symbols are 0 .. ast_sym_count() - 1)
fn ast_sym_count() -> i64 {
    return sym_texts.len
}

// the canonical text of symbol `id`
fn ast_sym_name(id: i64) -> str {
    return sym_texts[id]
}

// the symbol of a canonical text, or -1 for any other text
priv fn canonical(s: str) -> i64 {
    p := cast[i64](ptr(s))
    base := cast[i64](ptr(sym_chunk))
    if p >= base + 8 && p < base + sym_chunk_used {
        id := *cast[*i64](p - 8)
        if id >= 0 && id < sym_texts.len {
            t := sym_texts[id]
            if cast[i64](ptr(t)) == p && len(t) == len(s) {
                return id
            }
        }
    }
    return -1
}

// the symbol of a text (a new text becomes one)
fn ast_sym(s: str) -> i64 {
    id := canonical(s)
    if id >= 0 {
        return id
    }
    return ast_sym_hashed(s, ast_sym_hash(s))
}

// the symbol of a text, or -1 if it is none
fn ast_sym_find(s: str) -> i64 {
    id := canonical(s)
    if id >= 0 || len(sym_slots) == 0 {
        return id
    }
    h := ast_sym_hash(s)
    mask := len(sym_slots) - 1
    i := i64((h * SYM_MIX) >> sym_shift)
    tag := h & 0xFFFFFFFF00000000
    loop {
        e := sym_slots[i]
        if e == 0 {
            return -1
        }
        if e & 0xFFFFFFFF00000000 == tag {
            t := sym_texts[i64(e & 0xFFFFFFFF) - 1]
            if len(t) == len(s) && t == s {
                return i64(e & 0xFFFFFFFF) - 1
            }
        }
        i = (i + 1) & mask
    }
}

// the canonical text of `s`
fn ast_intern(s: str) -> str {
    id := ast_sym(s)
    return sym_texts[id]
}

// the symbol of `s`, whose hash is `h`; a new text becomes a symbol
fn ast_sym_hashed(s: str, h: u64) -> i64 {
    if sym_texts.len * 2 >= len(sym_slots) {
        sym_grow()
    }
    mask := len(sym_slots) - 1
    i := i64((h * SYM_MIX) >> sym_shift)
    tag := h & 0xFFFFFFFF00000000
    loop {
        e := sym_slots[i]
        if e == 0 {
            break
        }
        if e & 0xFFFFFFFF00000000 == tag {
            t := sym_texts[i64(e & 0xFFFFFFFF) - 1]
            if len(t) == len(s) && t == s {
                return i64(e & 0xFFFFFFFF) - 1
            }
        }
        i = (i + 1) & mask
    }
    id := sym_texts.len
    // a slot keeps id + 1 in its low 32 bits
    assert id < 0x7FFFFFFF, "ast: too many symbols"
    n := len(s)
    if sym_chunk_used + n + 8 > len(sym_chunk) {
        sym_chunk = alloc[u8](max(SYM_CHUNK, n + 8))
        sym_chunk_used = 0
    }
    at := sym_chunk_used
    *cast[*i64](cast[i64](ptr(sym_chunk)) + at) = id
    copy(sym_chunk[at + 8..at + 8 + n], s)
    sym_chunk_used = at + 8 + n
    sym_texts.push(sym_chunk[at + 8..at + 8 + n])
    sym_hashes.push(h)
    sym_slots[i] = tag | u64(id + 1)
    return id
}

priv fn sym_grow() {
    n := max(len(sym_slots) * 2, 8192)
    sym_slots = alloc[u64](n)
    sym_shift = u64(64 - ctz(u64(n)))
    mask := n - 1
    for id in 0..sym_texts.len {
        h := sym_hashes[id]
        i := i64((h * SYM_MIX) >> sym_shift)
        while sym_slots[i] != 0 {
            i = (i + 1) & mask
        }
        sym_slots[i] = (h & 0xFFFFFFFF00000000) | u64(id + 1)
    }
}
