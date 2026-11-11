// Parser for AL: tokens to AST. Results are (value, ok) pairs; ok = false after an error.

priv struct Parser {
    toks: Vec[Token]
    i: i64
    errs: *Vec[Diag]
    // inside the header of `if`, `while`, `for` or `match`: `Name{` is not a literal
    no_lit: bool
    // index of the `{` after a header expression that ends in a name (`if x == Point {`), or -1
    hdr_name: i64
}

fn parser_new(toks: Vec[Token], errs: *Vec[Diag]) -> Parser {
    return Parser{toks: toks, i: 0, errs: errs, no_lit: false, hdr_name: -1}
}

// the failure result of a parsing function: (zero value, false)
priv fn fail[T]() -> (T, bool) {
    z: T
    return (z, false)
}

// a copy of x on the heap
fn parser_box[T](x: T) -> *T {
    b := new[T]()
    *b = x
    return b
}

priv fn tk_p(t: Tk, p: str) -> bool {
    match t {
        P(q) => q == p
        _ => false
    }
}

priv fn tk_kw(t: Tk, k: str) -> bool {
    match t {
        Kw(q) => q == k
        _ => false
    }
}

priv fn tk_nl(t: Tk) -> bool {
    match t {
        Nl => true
        _ => false
    }
}

priv fn tk_eof(t: Tk) -> bool {
    match t {
        Eof => true
        _ => false
    }
}

priv fn tk_id(t: Tk) -> bool {
    match t {
        Id(_) => true
        _ => false
    }
}

priv fn cont(s: str, i: i64, lo: u8, hi: u8) -> bool {
    return i < len(s) && s[i] >= lo && s[i] <= hi
}

// the text as valid UTF-8: every maximal invalid part becomes U+FFFD
priv fn utf8_lossy(s: str) -> str {
    valid := true
    for c in s {
        if c >= 0x80 {
            valid = false
            break
        }
    }
    if valid {
        return s
    }
    out := vec[u8]()
    i := 0
    while i < len(s) {
        b := s[i]
        n := 1
        ok := false
        if b < 0x80 {
            ok = true
        } else if b >= 0xC2 && b <= 0xDF {
            if cont(s, i + 1, 0x80, 0xBF) {
                n = 2
                ok = true
            }
        } else if b >= 0xE0 && b <= 0xEF {
            lo: u8 = 0x80
            hi: u8 = 0xBF
            if b == 0xE0 {
                lo = 0xA0
            } else if b == 0xED {
                hi = 0x9F
            }
            if cont(s, i + 1, lo, hi) {
                n = 2
                if cont(s, i + 2, 0x80, 0xBF) {
                    n = 3
                    ok = true
                }
            }
        } else if b >= 0xF0 && b <= 0xF4 {
            lo: u8 = 0x80
            hi: u8 = 0xBF
            if b == 0xF0 {
                lo = 0x90
            } else if b == 0xF4 {
                hi = 0x8F
            }
            if cont(s, i + 1, lo, hi) {
                n = 2
                if cont(s, i + 2, 0x80, 0xBF) {
                    n = 3
                    if cont(s, i + 3, 0x80, 0xBF) {
                        n = 4
                        ok = true
                    }
                }
            }
        }
        if ok {
            for k in i..i + n {
                out.push(s[k])
            }
        } else {
            out.push(0xEF)
            out.push(0xBF)
            out.push(0xBD)
        }
        i += n
    }
    return out[..out.len]
}

priv fn peek(p: *Parser) -> Tk {
    return p.toks[p.i].t
}

priv fn peek_at(p: *Parser, n: i64) -> Tk {
    j := min(p.i + n, p.toks.len - 1)
    return p.toks[j].t
}

priv fn pos(p: *Parser) -> Pos {
    return p.toks[p.i].pos
}

priv fn bump(p: *Parser) -> Tk {
    t := p.toks[p.i].t
    if p.i < p.toks.len - 1 {
        p.i += 1
    }
    return t
}

priv fn is_p(p: *Parser, s: str) -> bool {
    return tk_p(p.peek(), s)
}

priv fn is_kw(p: *Parser, k: str) -> bool {
    return tk_kw(p.peek(), k)
}

priv fn eat_p(p: *Parser, s: str) -> bool {
    if p.is_p(s) {
        p.bump()
        return true
    } else {
        return false
    }
}

priv fn eat_kw(p: *Parser, k: str) -> bool {
    if p.is_kw(k) {
        p.bump()
        return true
    } else {
        return false
    }
}

priv fn tok_desc(p: *Parser) -> str {
    match p.peek() {
        Id(s) => fmt("identifier `", s, "`")
        Int(_), Float(_) => "number"
        Str(_) => "string"
        Kw(k) => fmt("keyword `", k, "`")
        P(q) => fmt("`", q, "`")
        Nl => "end of line"
        Eof => "end of file"
    }
}

// declaration words of other languages
priv fn decl_habit(s: str) -> str {
    return match s {
        "let", "var", "mut", "auto", "val" => " (declare variables with `name := value` or `name: T = value`)"
        "func", "def", "function", "pub" => " (functions are declared `fn name(a: A) -> R { ... }`)"
        "type", "typedef", "using", "alias" => " (there are no type aliases: write the type out; a distinct type is a `struct`)"
        _ => ""
    }
}

priv fn err[T](p: *Parser, msg: str) -> (T, bool) {
    d := p.tok_desc()
    // habits from other languages get a direct pointer to the AL spelling
    hint := ""
    match p.peek() {
        Id(s) => {
            hint = decl_habit(s)
            if hint == "" {
                hint = match s {
                    "and" => " (use `&&`)"
                    "or" => " (use `||`)"
                    "not" => " (use `!`)"
                    "import" => " (use `use \"file.al\"`)"
                    "switch" => " (use `match`)"
                    "elif", "elsif" => " (use `else if`)"
                    _ => ""
                }
            }
        }
        P("+"), P("-") => {
            hint = " (there is no `++`/`--`: use `x += 1`)"
        }
        Kw(k) => {
            // a keyword where a name was meant: `by := 0`, `f(in, out)`, `x.type`
            match p.peek_at(1) {
                P(q) => {
                    if q == ":=" || q == "=" || q == ":" || q == "," || q == ")" || q == "." || q == "+=" || q == "-=" {
                        hint = fmt(" (`", k, "` is a keyword and cannot be used as a name)")
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
    // (`let x = 5`, `func main()`: the error is at the token after the foreign word)
    if hint == "" && p.i >= 1 {
        match p.toks[p.i - 1].t {
            Id(prev) => {
                hint = decl_habit(prev)
            }
            _ => {}
        }
    }
    p.errs.push(Diag{pos: p.pos(), msg: fmt(msg, ", found ", d, hint)})
    z: T
    return (z, false)
}

// consumes the punctuation `s` or reports that it was expected; false after an error
priv fn expect_p(p: *Parser, s: str) -> bool {
    if p.eat_p(s) {
        return true
    } else {
        z, ok := p.err[bool](fmt("expected `", s, "`"))
        return ok
    }
}

priv fn ident(p: *Parser) -> (str, bool) {
    match p.peek() {
        Id(s) => {
            p.bump()
            (s, true)
        }
        _ => p.err[str]("expected identifier")
    }
}

priv fn skip_nl(p: *Parser) {
    while tk_nl(p.peek()) || p.is_p(";") {
        p.bump()
    }
}

// ---------- declarations ----------
fn file(p: *Parser) -> Vec[Decl] {
    out := vec[Decl]()
    loop {
        p.skip_nl()
        if tk_eof(p.peek()) {
            break
        }
        from := p.i
        d, ok := p.decl()
        if ok {
            out.push(d)
        } else {
            p.sync_decl(from)
        }
    }
    return out
}

// after an error in the declaration that starts at token `from`: skip to the next
// top-level declaration, a line that starts outside all braces with a declaration keyword
// or a name (a keyword in column 1 also inside braces: the declaration in error may lack
// a `}`)
priv fn sync_decl(p: *Parser, from: i64) {
    depth := 0
    for j in from..p.i {
        if tk_p(p.toks[j].t, "{") {
            depth += 1
        } else if tk_p(p.toks[j].t, "}") {
            depth -= 1
        }
    }
    if p.i == from {
        p.bump()
    }
    loop {
        starts := p.i > 0 && tk_nl(p.toks[p.i - 1].t)
        match p.peek() {
            Eof => return
            P("{") => depth += 1
            P("}") => depth -= 1
            Kw(k) => {
                if starts && (depth <= 0 || p.pos().col == 1) && (k == "fn" || k == "struct" || k == "enum" || k == "const" || k == "test" || k == "use" || k == "inline" || k == "noinline" || k == "extern" || k == "priv") {
                    return
                }
            }
            Id(_) if starts && depth <= 0 => return
            _ => {}
        }
        p.bump()
    }
}

fn tparams(p: *Parser) -> (Vec[str], bool) {
    v := vec[str]()
    if p.eat_p("[") {
        loop {
            name, ok := p.ident()
            if !ok {
                return fail[Vec[str]]()
            }
            v.push(name)
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p("]") {
            return fail[Vec[str]]()
        }
    }
    return (v, true)
}

// `priv` in front of a declaration: the declaration is visible only in its own file
priv fn priv_decl(p: *Parser) -> (Decl, bool) {
    ppos := p.pos()
    p.bump()
    if p.is_kw("priv") {
        return p.err[Decl]("`priv` is written once in front of a declaration")
    }
    if p.is_kw("test") {
        p.errs.push(Diag{pos: ppos, msg: "a `test` block cannot be `priv` (nothing refers to a test by name): remove `priv`"})
        return p.decl()
    }
    if p.is_kw("use") {
        p.errs.push(Diag{pos: ppos, msg: "`use` cannot be `priv` (a file is included into the whole program): remove `priv`"})
        return p.decl()
    }
    d, ok := p.decl()
    if !ok {
        return fail[Decl]()
    }
    return (set_priv(d, ppos, p.errs), true)
}

// the declaration marked as private. Every kind of declaration is listed: a new kind must
// decide here whether it can be private.
priv fn set_priv(d: Decl, ppos: Pos, errs: *Vec[Diag]) -> Decl {
    return match d {
        Fn(f) => {
            if f.name == "main" {
                errs.push(Diag{pos: ppos, msg: "`main` cannot be `priv`: it is where the program starts, which is outside this file; remove `priv`"})
            } else {
                f.is_priv = true
                f.pos = ppos
            }
            Fn(f)
        }
        Struct(s) => {
            s.is_priv = true
            s.pos = ppos
            Struct(s)
        }
        Enum(e) => {
            e.is_priv = true
            e.pos = ppos
            Enum(e)
        }
        Const(c) => {
            c.is_priv = true
            c.pos = ppos
            Const(c)
        }
        Glob(g) => {
            g.is_priv = true
            g.pos = ppos
            Glob(g)
        }
        Test(t) => d
        Use(path, upos) => d
    }
}

// ---------- functions ----------

// a function declaration without parameters, result and body
priv fn parser_fn(name: str, tparams: Vec[str], pos: Pos, inl: i64, ext: Opt[str]) -> FnDecl {
    return FnDecl{name: name, tparams: tparams, params: vec[(str, TypeAst)](), ret: None, body: Block{stmts: vec[Stmt](), end: pos}, pos: pos, inl: inl, ext: ext}
}

// The result of a function or of a function type: `-> R`, or nothing. A function without a
// result has no arrow: `-> ()` is an error, and parsing goes on.
priv fn result(p: *Parser, ret: *Opt[TypeAst]) -> bool {
    rpos := p.pos()
    if !p.eat_p("->") {
        return true
    }
    if p.is_p("(") && tk_p(p.peek_at(1), ")") {
        p.errs.push(Diag{pos: rpos, msg: "a function without a result has no arrow: leave out `-> ()`"})
        p.bump()
        p.bump()
        return true
    }
    rt, ok := p.ty()
    if !ok {
        return false
    }
    *ret = Some(rt)
    return true
}

// `(a: A, b: B) [-> R]`: the parameters and the result of the function `d`
priv fn fn_sig(p: *Parser, d: *FnDecl) -> bool {
    if !p.expect_p("(") {
        return false
    }
    while !p.is_p(")") {
        pn, ok1 := p.ident()
        if !ok1 {
            return false
        }
        if !p.eat_p(":") {
            p.err[bool]("expected `:` after the parameter name")
            return false
        }
        pt, ok2 := p.ty()
        if !ok2 {
            return false
        }
        d.params.push((pn, pt))
        if !p.eat_p(",") {
            break
        }
    }
    return p.expect_p(")") && p.result(&d.ret)
}

// the parameters, the result and the body of the function `d`; a C function has no body
priv fn fn_rest(p: *Parser, d: FnDecl) -> (FnDecl, bool) {
    if !p.fn_sig(&d) {
        return fail[FnDecl]()
    }
    if is_some(d.ext) {
        if !d.tparams.is_empty() {
            p.errs.push(Diag{pos: d.pos, msg: fmt("the C function `", d.name, "` cannot have type parameters")})
            return fail[FnDecl]()
        }
        if p.is_p("{") {
            return p.err[FnDecl](fmt("an `extern` function is a C function of the library and has no body: expected end of line after the declaration of `", d.name, "`"))
        }
        d.inl = -1
        return (d, true)
    }
    body, ok := p.block()
    if !ok {
        return fail[FnDecl]()
    }
    d.body = body
    return (d, true)
}

// At `fn` where a declaration starts (top level, after `extern "lib"`, or a statement):
// `fn name[T](a: A, b: B) -> R { ... }`
priv fn fn_decl(p: *Parser, pos: Pos, inl: i64, ext: Opt[str]) -> (FnDecl, bool) {
    p.bump()
    name, ok1 := p.ident()
    if !ok1 {
        return fail[FnDecl]()
    }
    tparams, ok2 := p.tparams()
    if !ok2 {
        return fail[FnDecl]()
    }
    return p.fn_rest(parser_fn(name, tparams, pos, inl, ext))
}

// At `fn` where an expression starts: an anonymous function `fn(a: A, b: B) -> R { ... }`
// (its parameters have names; without parameters a body follows), or a function type
// `fn(A, B) -> R` (a type argument, the type of a literal)
priv fn fn_expr(p: *Parser, pos: Pos) -> (Expr, bool) {
    if tk_p(p.peek_at(1), "[") {
        p.errs.push(Diag{pos: pos, msg: "an anonymous function cannot have type parameters of its own (it may use the type parameters of the enclosing function): write `fn(a: T) -> R { ... }`, or declare a generic function at the top level"})
        return fail[Expr]()
    }
    d := parser_fn("", vec[str](), pos, 0, None)
    if tk_id(p.peek_at(2)) && tk_p(p.peek_at(3), ":") {
        p.bump()
        if !p.fn_sig(&d) {
            return fail[Expr]()
        }
    } else {
        t, ok := p.ty()
        if !ok {
            return fail[Expr]()
        }
        if !p.is_p("{") {
            return (Expr{k: TypeE(t), pos: pos}, true)
        }
        // `fn() -> R { ... }`
        match t {
            Fn(ps, _) if !ps.is_empty() => {
                p.errs.push(Diag{pos: pos, msg: "an anonymous function names its parameters and gives each one a type, like any function: `fn(a: i64, b: i64) -> bool { a < b }` (`fn(A, B) -> R` alone is a function type)"})
                return fail[Expr]()
            }
            Fn(_, Some(rt)) => {
                d.ret = Some(*rt)
            }
            _ => {}
        }
    }
    body, ok := p.block()
    if !ok {
        return fail[Expr]()
    }
    d.body = body
    return (Expr{k: EK.Fn(parser_box(d)), pos: pos}, true)
}

// ---------- constants, types, variables ----------

// At `const`, `struct` or `enum`, where a declaration starts:
//   const NAME = value      const NAME: T = value      type Name = T
//   struct Name[T] { a: A, b: B }                      enum Name[T] { A, B(T) }
priv fn kw_decl(p: *Parser, pos: Pos) -> (Decl, bool) {
    if p.eat_kw("const") {
        name, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        ty: Opt[TypeAst] = None
        if p.eat_p(":") {
            ct, ok2 := p.ty()
            if !ok2 {
                return fail[Decl]()
            }
            ty = Some(ct)
        }
        if !p.expect_p("=") {
            return fail[Decl]()
        }
        val, ok3 := p.expr()
        if !ok3 {
            return fail[Decl]()
        }
        return (Const(ConstDecl{name: name, ty: ty, val: val, pos: pos}), true)
    }
    is_struct := p.is_kw("struct")
    if is_struct || p.is_kw("enum") {
        p.bump()
        name, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        tparams, ok2 := p.tparams()
        if !ok2 {
            return fail[Decl]()
        }
        if is_struct {
            return p.struct_rest(name, tparams, pos)
        }
        return p.enum_rest(name, tparams, pos)
    }
    return p.err[Decl]("expected a declaration")
}

// the body of a struct: `{ name: Type, ... }` (fields separated by `,` or newlines)
priv fn struct_rest(p: *Parser, name: str, tparams: Vec[str], pos: Pos) -> (Decl, bool) {
    if !p.expect_p("{") {
        return fail[Decl]()
    }
    fields := vec[(str, TypeAst)]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        if p.is_kw("priv") {
            return p.err[Decl]("a struct field cannot be `priv` (only top-level declarations can): write `priv struct` to make the whole struct private")
        }
        fname, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        if !p.eat_p(":") {
            return p.err[Decl]("expected `:` after the field name")
        }
        fty, ok2 := p.ty()
        if !ok2 {
            return fail[Decl]()
        }
        fields.push((fname, fty))
        p.eat_p(",")
    }
    return (Struct(StructDecl{name: name, tparams: tparams, fields: fields, pos: pos}), true)
}

// the body of an enum: `{ Variant, Variant(Type, ...), ... }`
priv fn enum_rest(p: *Parser, name: str, tparams: Vec[str], pos: Pos) -> (Decl, bool) {
    if !p.expect_p("{") {
        return fail[Decl]()
    }
    variants := vec[(str, Vec[TypeAst])]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        if p.is_kw("priv") {
            return p.err[Decl]("an enum variant cannot be `priv` (only top-level declarations can): write `priv enum` to make the enum type private")
        }
        vname, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        tys := vec[TypeAst]()
        if p.eat_p("(") && !p.type_list(&tys) {
            return fail[Decl]()
        }
        variants.push((vname, tys))
        p.eat_p(",")
    }
    return (Enum(EnumDecl{name: name, tparams: tparams, variants: variants, pos: pos}), true)
}

// after the `:` of a variable (global or local): `T` or `T = value`
priv fn var_rest(p: *Parser) -> ((TypeAst, Opt[Expr]), bool) {
    vt, ok1 := p.ty()
    if !ok1 {
        return fail[(TypeAst, Opt[Expr])]()
    }
    init: Opt[Expr] = None
    if p.eat_p("=") {
        ie, ok2 := p.expr()
        if !ok2 {
            return fail[(TypeAst, Opt[Expr])]()
        }
        init = Some(ie)
    }
    return ((vt, init), true)
}

// A declaration that starts with a name is a global variable: `name: T`, `name: T = value`,
// `name := value`
priv fn var_decl(p: *Parser, pos: Pos) -> (Decl, bool) {
    name, ok1 := p.ident()
    if p.eat_p(":=") {
        ie, ok2 := p.expr()
        if !ok2 {
            return fail[Decl]()
        }
        return (Glob(GlobalDecl{name: name, ty: None, init: Some(ie), pos: pos}), true)
    }
    if !p.eat_p(":") {
        return p.err[Decl](fmt("a declaration that starts with a name declares a variable, `", name, ": T` or `", name, " := value` (functions, types and constants start with `fn`, `struct`, `enum`, `const`): expected `:` or `:=`"))
    }
    v, ok3 := p.var_rest()
    if !ok3 {
        return fail[Decl]()
    }
    return (Glob(GlobalDecl{name: name, ty: Some(v.0), init: v.1, pos: pos}), true)
}

priv fn decl(p: *Parser) -> (Decl, bool) {
    if p.is_kw("priv") {
        return p.priv_decl()
    }
    pos := p.pos()
    inl := 0
    if p.eat_kw("inline") {
        inl = 1
    } else if p.eat_kw("noinline") {
        inl = -1
    }
    if p.is_kw("priv") {
        return p.err[Decl]("`priv` is written first: `priv inline fn name(...)`")
    }
    ext: Opt[str] = None
    if p.eat_kw("extern") {
        // extern "libfoo.so.1" fn name(a: A) -> R     (a C function; no body)
        match p.bump() {
            Str(s) => {
                ext = Some(utf8_lossy(s))
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected a library name string after `extern`, e.g. `extern \"libc.so.6\" fn getpid() -> i32`")
            }
        }
    }
    if p.is_kw("fn") {
        f, ok := p.fn_decl(pos, inl, ext)
        if !ok {
            return fail[Decl]()
        }
        return (Fn(f), true)
    }
    if inl != 0 || is_some(ext) {
        return p.err[Decl]("`inline`, `noinline` and `extern \"lib\"` stand in front of a function declaration: expected `fn`")
    }
    if p.is_kw("const") || p.is_kw("struct") || p.is_kw("enum") {
        return p.kw_decl(pos)
    }
    if p.eat_kw("test") {
        name := match p.bump() {
            Str(s) => utf8_lossy(s)
            _ => {
                p.i -= 1
                return p.err[Decl]("expected test name string")
            }
        }
        body, ok1 := p.block()
        if !ok1 {
            return fail[Decl]()
        }
        return (Test(TestDecl{name: name, body: body, pos: pos}), true)
    }
    if p.eat_kw("use") {
        // use "file.al"   or   use std.name (a module bundled with the compiler)
        match (p.peek(), p.peek_at(1), p.peek_at(2)) {
            (Id("std"), P("."), Id(b)) => {
                p.i += 3
                return (Use(fmt("std:", b), pos), true)
            }
            _ => {}
        }
        match p.bump() {
            Str(s) => {
                return (Use(utf8_lossy(s), pos), true)
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected a file path string or `std.<module>` after `use`")
            }
        }
    }
    if tk_id(p.peek()) {
        return p.var_decl(pos)
    }
    return p.err[Decl]("expected a declaration: `fn`, `struct`, `enum`, `const`, a variable (`name: T`, `name := value`), `test`, `use`, `extern` or `priv`")
}

// ---------- types ----------

// types after a `(`, through the `)`
priv fn type_list(p: *Parser, v: *Vec[TypeAst]) -> bool {
    while !p.is_p(")") {
        t, ok := p.ty()
        if !ok {
            return false
        }
        v.push(t)
        if !p.eat_p(",") {
            break
        }
    }
    return p.expect_p(")")
}

priv fn ty(p: *Parser) -> (TypeAst, bool) {
    pos := p.pos()
    if p.eat_p("*") {
        t, ok := p.ty()
        if !ok {
            return fail[TypeAst]()
        }
        return (Ptr(parser_box(t)), true)
    }
    if p.eat_p("[") {
        if p.eat_p("]") {
            t, ok := p.ty()
            if !ok {
                return fail[TypeAst]()
            }
            return (Slice(parser_box(t)), true)
        }
        save := p.no_lit
        p.no_lit = false
        n, ok1 := p.expr()
        p.no_lit = save
        if !ok1 {
            return fail[TypeAst]()
        }
        if !p.expect_p("]") {
            return fail[TypeAst]()
        }
        nb := parser_box(n)
        t, ok2 := p.ty()
        if !ok2 {
            return fail[TypeAst]()
        }
        return (Array(nb, parser_box(t)), true)
    }
    if p.eat_p("(") {
        v := vec[TypeAst]()
        if !p.type_list(&v) {
            return fail[TypeAst]()
        }
        return (Tuple(v), true)
    }
    if p.eat_kw("fn") {
        // a function type: `fn(A, B) -> R`, without a result `fn(A, B)`
        v := vec[TypeAst]()
        rt: Opt[TypeAst] = None
        if !p.expect_p("(") || !p.type_list(&v) || !p.result(&rt) {
            return fail[TypeAst]()
        }
        ret: Opt[*TypeAst] = match rt {
            Some(r) => Some(parser_box(r))
            None => None
        }
        return (Fn(v, ret), true)
    }
    match p.peek() {
        Id(name) => {
            p.bump()
            args := vec[TypeAst]()
            if p.eat_p("[") {
                loop {
                    t, ok := p.ty()
                    if !ok {
                        return fail[TypeAst]()
                    }
                    args.push(t)
                    if !p.eat_p(",") {
                        break
                    }
                }
                if !p.expect_p("]") {
                    return fail[TypeAst]()
                }
            }
            return (Name(name, args, pos), true)
        }
        _ => {}
    }
    return p.err[TypeAst]("expected type")
}

// ---------- statements ----------
priv fn block(p: *Parser) -> (Block, bool) {
    // the body of a header that ends in a name: an error in its first statement is most
    // likely a `Name{...}` literal that was taken for the body
    after_name := p.hdr_name == p.i
    nerr := p.errs.len
    if !p.expect_p("{") {
        return fail[Block]()
    }
    save := p.no_lit
    p.no_lit = false
    stmts := vec[Stmt]()
    loop {
        p.skip_nl()
        if p.is_p("}") || tk_eof(p.peek()) {
            break
        }
        s, ok := p.stmt()
        if ok {
            stmts.push(s)
            if !(tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
                p.err[bool]("expected end of statement")
                p.sync_stmt()
            }
        } else {
            p.sync_stmt()
        }
        if after_name && p.errs.len > nerr {
            p.errs[nerr].msg = fmt(p.errs[nerr].msg, " (if this `{` was meant to start a struct literal: in the header of `if`, `while`, `for` and `match` a literal needs parentheses, `(Name{...})`)")
        }
        after_name = false
    }
    p.no_lit = save
    end := p.pos()
    if !p.expect_p("}") {
        return fail[Block]()
    }
    return (Block{stmts: stmts, end: end}, true)
}

priv fn sync_stmt(p: *Parser) {
    depth := 0
    loop {
        match p.peek() {
            Eof => return
            Nl if depth == 0 => return
            P("{") => depth += 1
            P("}") => {
                if depth == 0 {
                    return
                }
                depth -= 1
            }
            _ => {}
        }
        p.bump()
    }
}

// the scrutinee of a `match`, the condition of an `if` or `while`, an expression of a `for` header
priv fn header_expr(p: *Parser) -> (Expr, bool) {
    save := p.no_lit
    p.no_lit = true
    e, ok := p.expr()
    p.no_lit = save
    if ok && p.i >= 1 && p.is_p("{") && tk_id(p.toks[p.i - 1].t) {
        p.hdr_name = p.i
    }
    return (e, ok)
}

// In a header (`if`, `while`, `for`, `match`) a `{` starts the body, so `Name{...}` there
// needs parentheses. Only after an expression written as a type (`[]T`, `[N]T`) it is a
// literal: a type alone is not a value.
priv fn lit_in_header(e: *Expr) -> bool {
    match e.k {
        TypeE(_) => true
        _ => false
    }
}

priv fn if_stmt(p: *Parser) -> ((Expr, Block, Opt[Block]), bool) {
    // `if` already consumed
    c, ok1 := p.header_expr()
    if !ok1 {
        return fail[(Expr, Block, Opt[Block])]()
    }
    t, ok2 := p.block()
    if !ok2 {
        return fail[(Expr, Block, Opt[Block])]()
    }
    j := p.i
    while tk_nl(p.toks[j].t) {
        j += 1
    }
    if tk_kw(p.toks[j].t, "else") {
        p.i = j + 1
        if p.is_kw("if") {
            pos := p.pos()
            p.bump()
            r, ok3 := p.if_stmt()
            if !ok3 {
                return fail[(Expr, Block, Opt[Block])]()
            }
            end := r.1.end
            inner := Stmt{k: If(r.0, r.1, r.2), pos: pos}
            eb: Opt[Block] = Some(Block{stmts: vec_of([]Stmt{inner}), end: end})
            return ((c, t, eb), true)
        }
        e, ok4 := p.block()
        if !ok4 {
            return fail[(Expr, Block, Opt[Block])]()
        }
        eb: Opt[Block] = Some(e)
        return ((c, t, eb), true)
    }
    none: Opt[Block] = None
    return ((c, t, none), true)
}

priv fn stmt(p: *Parser) -> (Stmt, bool) {
    pos := p.pos()
    k, ok := p.stmt_k()
    if !ok {
        return fail[Stmt]()
    }
    return (Stmt{k: k, pos: pos}, true)
}

priv fn stmt_k(p: *Parser) -> (SK, bool) {
    if p.is_kw("priv") {
        return p.err[SK]("`priv` applies to top-level declarations only; a local declaration is visible only in its block anyway")
    }
    match p.peek() {
        Kw(k) => {
            if k == "inline" || k == "noinline" || k == "extern" {
                p.errs.push(Diag{pos: p.pos(), msg: fmt("`", k, "` applies to top-level functions only: a nested function is declared as `fn name(a: A) -> R { ... }`")})
                return fail[SK]()
            }
        }
        _ => {}
    }
    if p.is_kw("fn") && tk_id(p.peek_at(1)) {
        f, ok := p.fn_decl(p.pos(), 0, None)
        if !ok {
            return fail[SK]()
        }
        return (Fn(parser_box(f)), true)
    }
    if p.is_kw("const") || p.is_kw("struct") || p.is_kw("enum") {
        p.errs.push(Diag{pos: p.pos(), msg: "constants and types (`const`, `struct`, `enum`) are declared at the top level, outside the function; inside a function there are variables (`name := value`) and nested functions (`fn name(...)`)"})
        return fail[SK]()
    }
    if p.eat_kw("if") {
        r, ok := p.if_stmt()
        if !ok {
            return fail[SK]()
        }
        return (If(r.0, r.1, r.2), true)
    }
    if p.eat_kw("while") {
        c, ok1 := p.header_expr()
        if !ok1 {
            return fail[SK]()
        }
        b, ok2 := p.block()
        if !ok2 {
            return fail[SK]()
        }
        return (While(c, b), true)
    }
    if p.eat_kw("loop") {
        b, ok := p.block()
        if !ok {
            return fail[SK]()
        }
        return (LoopStmt(b), true)
    }
    if p.eat_kw("for") {
        v1, ok1 := p.ident()
        if !ok1 {
            return fail[SK]()
        }
        v2: Opt[str] = None
        if p.eat_p(",") {
            n2, ok2 := p.ident()
            if !ok2 {
                return fail[SK]()
            }
            v2 = Some(n2)
        }
        if !p.eat_kw("in") {
            return p.err[SK]("expected `in`")
        }
        lo, ok3 := p.header_expr()
        if !ok3 {
            return fail[SK]()
        }
        hi: Opt[Expr] = None
        incl := false
        if p.eat_p("..") {
            h, ok4 := p.header_expr()
            if !ok4 {
                return fail[SK]()
            }
            hi = Some(h)
        } else if p.eat_p("..=") {
            h, ok4 := p.header_expr()
            if !ok4 {
                return fail[SK]()
            }
            hi = Some(h)
            incl = true
        }
        step: Opt[Expr] = None
        if p.eat_kw("by") {
            st, ok5 := p.header_expr()
            if !ok5 {
                return fail[SK]()
            }
            step = Some(st)
        }
        body, ok6 := p.block()
        if !ok6 {
            return fail[SK]()
        }
        return (For(v1, v2, lo, hi, incl, step, body), true)
    }
    if p.eat_kw("return") {
        if tk_nl(p.peek()) || p.is_p("}") || p.is_p(";") {
            return (Return(None), true)
        }
        e, ok := p.expr()
        if !ok {
            return fail[SK]()
        }
        return (Return(Some(e)), true)
    }
    if p.eat_kw("break") {
        // a label must be on the same line (a newline after `break` ends the statement)
        match p.peek() {
            Id(label) => {
                p.bump()
                return (BreakTo(label), true)
            }
            _ => {}
        }
        if !(tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[SK]("`break` leaves a loop and takes at most a loop label (`break outer`): expected end of statement")
        }
        return (Break, true)
    }
    if p.eat_kw("continue") {
        match p.peek() {
            Id(label) => {
                p.bump()
                return (ContinueTo(label), true)
            }
            _ => {}
        }
        if !(tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[SK]("`continue` takes at most a loop label (`continue outer`): expected end of statement")
        }
        return (Continue, true)
    }
    if p.eat_kw("assert") {
        c, ok1 := p.expr()
        if !ok1 {
            return fail[SK]()
        }
        m: Opt[Expr] = None
        if p.eat_p(",") {
            me, ok2 := p.expr()
            if !ok2 {
                return fail[SK]()
            }
            m = Some(me)
        }
        return (Assert(c, m), true)
    }
    if p.eat_kw("defer") {
        b, ok := p.block()
        if !ok {
            return fail[SK]()
        }
        return (Defer(b), true)
    }
    if p.is_p("{") {
        b, ok := p.block()
        if !ok {
            return fail[SK]()
        }
        return (BlockStmt(b), true)
    }
    // a labelled loop: `name: for ...`, `name: while ...`, `name: loop ...`
    if tk_id(p.peek()) && tk_p(p.peek_at(1), ":") {
        after := p.peek_at(2)
        if tk_kw(after, "for") || tk_kw(after, "while") || tk_kw(after, "loop") {
            label, ok1 := p.ident()
            if !ok1 {
                return fail[SK]()
            }
            p.bump()
            inner, ok2 := p.stmt()
            if !ok2 {
                return fail[SK]()
            }
            return (Labeled(label, parser_box(inner)), true)
        }
        if tk_kw(after, "if") || tk_kw(after, "match") || tk_p(after, "{") {
            p.bump()
            p.bump()
            return p.err[SK]("a label names a loop: expected `for`, `while` or `loop` after the label")
        }
        // a variable: `name: T` (zero value) or `name: T = value`
        name, ok1 := p.ident()
        p.bump()
        v, ok2 := p.var_rest()
        if !ok2 {
            return fail[SK]()
        }
        return (Var(name, Some(v.0), v.1), true)
    }
    // multi-let: a, b := e
    if tk_id(p.peek()) && tk_p(p.peek_at(1), ",") {
        pos := p.pos()
        names := vec[str]()
        n1, ok1 := p.ident()
        if !ok1 {
            return fail[SK]()
        }
        names.push(n1)
        while p.eat_p(",") {
            n2, ok2 := p.ident()
            if !ok2 {
                return fail[SK]()
            }
            names.push(n2)
        }
        if p.eat_p("=") {
            e, ok3 := p.expr()
            if !ok3 {
                return fail[SK]()
            }
            lhs := vec[Expr]()
            for n in names {
                lhs.push(Expr{k: Ident(n), pos: pos})
            }
            return (MultiAssign(lhs, e), true)
        }
        if !p.expect_p(":=") {
            return fail[SK]()
        }
        e, ok4 := p.expr()
        if !ok4 {
            return fail[SK]()
        }
        return (Let(names, e), true)
    }
    e, ok1 := p.expr()
    if !ok1 {
        return fail[SK]()
    }
    if p.eat_p(":=") {
        name := match e.k {
            Ident(n) => n
            _ => {
                p.errs.push(Diag{pos: e.pos, msg: "left side of `:=` must be an identifier"})
                return fail[SK]()
            }
        }
        v, ok2 := p.expr()
        if !ok2 {
            return fail[SK]()
        }
        return (Let(vec_of([]str{name}), v), true)
    }
    if p.eat_p("=") {
        v, ok2 := p.expr()
        if !ok2 {
            return fail[SK]()
        }
        return (Assign(e, None, v), true)
    }
    op: Opt[BinOp] = match p.peek() {
        P("+=") => Some(Add)
        P("-=") => Some(Sub)
        P("*=") => Some(Mul)
        P("/=") => Some(Div)
        P("%=") => Some(Rem)
        P("&=") => Some(And)
        P("|=") => Some(Or)
        P("^=") => Some(Xor)
        P("<<=") => Some(Shl)
        P(">>=") => Some(Shr)
        _ => None
    }
    if is_some(op) {
        p.bump()
        v, ok2 := p.expr()
        if !ok2 {
            return fail[SK]()
        }
        return (Assign(e, op, v), true)
    }
    return (ExprStmt(e), true)
}

// ---------- expressions ----------
priv fn expr(p: *Parser) -> (Expr, bool) {
    return p.bin(1)
}

priv fn binop(p: *Parser) -> Opt[(BinOp, i64)] {
    // precedence, tightest first: arithmetic, shifts, &, ^, |, comparisons, &&, ||
    match p.peek() {
        P("*") => Some((Mul, 9))
        P("/") => Some((Div, 9))
        P("%") => Some((Rem, 9))
        P("+") => Some((Add, 8))
        P("-") => Some((Sub, 8))
        P("<<") => Some((Shl, 7))
        P(">>") => Some((Shr, 7))
        P("&") => Some((And, 6))
        P("^") => Some((Xor, 5))
        P("|") => Some((Or, 4))
        P("==") => Some((Eq, 3))
        P("!=") => Some((Ne, 3))
        P("<") => Some((Lt, 3))
        P("<=") => Some((Le, 3))
        P(">") => Some((Gt, 3))
        P(">=") => Some((Ge, 3))
        P("&&") => Some((LAnd, 2))
        P("||") => Some((LOr, 1))
        _ => None
    }
}

priv fn bin(p: *Parser, min_prec: i64) -> (Expr, bool) {
    lhs, ok1 := p.unary()
    if !ok1 {
        return fail[Expr]()
    }
    loop {
        op, prec := match p.binop() {
            Some((o, pr)) if pr >= min_prec => (o, pr)
            _ => break
        }
        pos := p.pos()
        p.bump()
        rhs, ok2 := p.bin(prec + 1)
        if !ok2 {
            return fail[Expr]()
        }
        lhs = Expr{k: Bin(op, parser_box(lhs), parser_box(rhs)), pos: pos}
    }
    return (lhs, true)
}

priv fn unary(p: *Parser) -> (Expr, bool) {
    pos := p.pos()
    op: UnOp = match p.peek() {
        P("-") => Neg
        P("!") => Not
        P("~") => BitNot
        P("&") => AddrOf
        P("*") => Deref
        _ => return p.postfix()
    }
    p.bump()
    e, ok := p.unary()
    if !ok {
        return fail[Expr]()
    }
    return (Expr{k: Un(op, parser_box(e)), pos: pos}, true)
}

priv fn typeish(e: *Expr) -> bool {
    match e.k {
        Ident(_), TypeE(_) => true
        Index(b, _) => {
            match b.k {
                Ident(_) => true
                _ => false
            }
        }
        _ => false
    }
}

// the closure in `args`
priv fn args_r(p: *Parser, close: str, v: *Vec[Expr]) -> bool {
    while !p.is_p(close) {
        e, ok := p.expr()
        if !ok {
            return false
        }
        v.push(e)
        if !p.eat_p(",") {
            break
        }
    }
    return p.expect_p(close)
}

fn args(p: *Parser, close: str) -> (Vec[Expr], bool) {
    save := p.no_lit
    p.no_lit = false
    v := vec[Expr]()
    r := args_r(p, close, &v)
    p.no_lit = save
    if !r {
        return fail[Vec[Expr]]()
    }
    return (v, true)
}

priv fn postfix(p: *Parser) -> (Expr, bool) {
    e, ok1 := p.primary()
    if !ok1 {
        return fail[Expr]()
    }
    loop {
        pos := p.pos()
        if p.eat_p("(") {
            a, ok2 := p.args(")")
            if !ok2 {
                return fail[Expr]()
            }
            e = Expr{k: Call(parser_box(e), a), pos: pos}
        } else if p.eat_p("[") {
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.index_tail(e, pos)
            p.no_lit = save
            if !ok2 {
                return fail[Expr]()
            }
            e = r
        } else if p.eat_p(".") {
            match p.bump() {
                Id(n) => {
                    e = Expr{k: Field(parser_box(e), n), pos: pos}
                }
                Int(n) => {
                    e = Expr{k: Field(parser_box(e), fmt(n)), pos: pos}
                }
                _ => {
                    p.i -= 1
                    return p.err[Expr]("expected field name")
                }
            }
        } else if p.is_p("{") && typeish(&e) && (!p.no_lit || lit_in_header(&e)) {
            p.bump()
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.lit_body()
            p.no_lit = save
            if !ok2 {
                return fail[Expr]()
            }
            e = Expr{k: Lit(parser_box(e), r), pos: pos}
        } else {
            break
        }
    }
    return (e, true)
}

priv fn index_tail(p: *Parser, base: Expr, pos: Pos) -> (Expr, bool) {
    if p.eat_p("..") {
        hi: Opt[*Expr] = None
        if !p.is_p("]") {
            h, ok := p.expr()
            if !ok {
                return fail[Expr]()
            }
            hi = Some(parser_box(h))
        }
        if !p.expect_p("]") {
            return fail[Expr]()
        }
        return (Expr{k: Slice(parser_box(base), None, hi), pos: pos}, true)
    }
    first, ok1 := p.expr()
    if !ok1 {
        return fail[Expr]()
    }
    if p.eat_p("..") {
        hi: Opt[*Expr] = None
        if !p.is_p("]") {
            h, ok := p.expr()
            if !ok {
                return fail[Expr]()
            }
            hi = Some(parser_box(h))
        }
        if !p.expect_p("]") {
            return fail[Expr]()
        }
        return (Expr{k: Slice(parser_box(base), Some(parser_box(first)), hi), pos: pos}, true)
    }
    v := vec_of([]Expr{first})
    while p.eat_p(",") {
        e, ok := p.expr()
        if !ok {
            return fail[Expr]()
        }
        v.push(e)
    }
    if !p.expect_p("]") {
        return fail[Expr]()
    }
    return (Expr{k: Index(parser_box(base), v), pos: pos}, true)
}

priv fn lit_body(p: *Parser) -> (Vec[(Opt[str], Expr)], bool) {
    v := vec[(Opt[str], Expr)]()
    loop {
        while tk_nl(p.peek()) {
            p.bump()
        }
        if p.eat_p("}") {
            break
        }
        fname: Opt[str] = match p.peek() {
            Id(n) if tk_p(p.peek_at(1), ":") => Some(n)
            _ => None
        }
        if is_some(fname) {
            p.bump()
            p.bump()
            e, ok := p.expr()
            if !ok {
                return fail[Vec[(Opt[str], Expr)]]()
            }
            v.push((fname, e))
        } else {
            e, ok := p.expr()
            if !ok {
                return fail[Vec[(Opt[str], Expr)]]()
            }
            v.push((fname, e))
        }
        while tk_nl(p.peek()) {
            p.bump()
        }
        if !p.eat_p(",") {
            while tk_nl(p.peek()) {
                p.bump()
            }
            if !p.expect_p("}") {
                return fail[Vec[(Opt[str], Expr)]]()
            }
            break
        }
    }
    return (v, true)
}

// the closure in `primary` for a parenthesized expression or tuple
priv fn primary_r(p: *Parser, pos: Pos) -> (Expr, bool) {
    first, ok1 := p.expr()
    if !ok1 {
        return fail[Expr]()
    }
    if p.is_p(",") {
        v := vec_of([]Expr{first})
        while p.eat_p(",") {
            if p.is_p(")") {
                break
            }
            e, ok2 := p.expr()
            if !ok2 {
                return fail[Expr]()
            }
            v.push(e)
        }
        if !p.expect_p(")") {
            return fail[Expr]()
        }
        return (Expr{k: Tuple(v), pos: pos}, true)
    }
    if !p.expect_p(")") {
        return fail[Expr]()
    }
    return (first, true)
}

priv fn primary(p: *Parser) -> (Expr, bool) {
    pos := p.pos()
    match p.peek() {
        Int(n) => {
            p.bump()
            return (Expr{k: EK.Int(n), pos: pos}, true)
        }
        Float(f) => {
            p.bump()
            return (Expr{k: EK.Float(f), pos: pos}, true)
        }
        Str(s) => {
            p.bump()
            return (Expr{k: EK.Str(s), pos: pos}, true)
        }
        Id(n) => {
            p.bump()
            return (Expr{k: Ident(n), pos: pos}, true)
        }
        Kw("true") => {
            p.bump()
            return (Expr{k: Bool(true), pos: pos}, true)
        }
        Kw("false") => {
            p.bump()
            return (Expr{k: Bool(false), pos: pos}, true)
        }
        Kw("nil") => {
            p.bump()
            return (Expr{k: Nil, pos: pos}, true)
        }
        Kw("if") => {
            p.bump()
            r, ok := p.if_stmt()
            if !ok {
                return fail[Expr]()
            }
            match r.2 {
                Some(e) => {
                    return (Expr{k: If(parser_box(r.0), r.1, e), pos: pos}, true)
                }
                None => {
                    p.errs.push(Diag{pos: pos, msg: "`if` used as an expression needs an `else` branch"})
                    return fail[Expr]()
                }
            }
        }
        Kw("match") => {
            p.bump()
            scrut, ok1 := p.header_expr()
            if !ok1 {
                return fail[Expr]()
            }
            if !p.expect_p("{") {
                return fail[Expr]()
            }
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.match_arms()
            p.no_lit = save
            sb := parser_box(scrut)
            if !ok2 {
                return fail[Expr]()
            }
            return (Expr{k: Match(sb, r), pos: pos}, true)
        }
        Kw("fn") => {
            return p.fn_expr(pos)
        }
        P("(") => {
            p.bump()
            save := p.no_lit
            p.no_lit = false
            r, ok := primary_r(p, pos)
            p.no_lit = save
            return (r, ok)
        }
        P("[") => {
            t, ok := p.ty()
            if !ok {
                return fail[Expr]()
            }
            return (Expr{k: TypeE(t), pos: pos}, true)
        }
        _ => {}
    }
    return p.err[Expr]("expected expression")
}

// where an expression starts in the source (its `pos` may be that of an operator)
fn parser_expr_start(e: *Expr) -> Pos {
    match e.k {
        Call(b, _), Field(b, _), Index(b, _), Bin(_, b, _) => parser_expr_start(b)
        _ => e.pos
    }
}

// A pattern is parsed as an expression and then read as a pattern: `_`, `Variant(p, ..)`,
// `Enum.Variant(p, ..)`, `Enum[T].Variant(p, ..)`, `(p, p)`, `&name`; anything else stays
// an expression (a constant, or a name that lowering resolves).
priv fn pat(e: Expr) -> Pat {
    match e.k {
        Ident("_") => {
            return Wild
        }
        Call(c, args) => {
            name := ""
            qual: Opt[*Expr] = None
            is_variant := false
            match c.k {
                Ident(n) => {
                    name = n
                    is_variant = true
                }
                Field(q, n) => {
                    match q.k {
                        TypeE(_) => {}
                        _ => {
                            if typeish(q) {
                                name = n
                                // lowering reads the qualifier from the whole expression
                                // (if it is not an enum, `x.f(a)` is an ordinary call)
                                qual = Some(parser_box(e))
                                is_variant = true
                            }
                        }
                    }
                }
                _ => {}
            }
            if is_variant {
                subs := vec[Pat]()
                for i in 0..args.len {
                    subs.push(pat(args[i]))
                }
                return Variant(name, subs, parser_expr_start(c), qual)
            }
        }
        Tuple(es) => {
            subs := vec[Pat]()
            for i in 0..es.len {
                subs.push(pat(es[i]))
            }
            return Pat.Tuple(subs, e.pos)
        }
        Un(AddrOf, x) => {
            match x.k {
                Ident(n) => {
                    return Ref(n, e.pos)
                }
                _ => {}
            }
        }
        _ => {}
    }
    return Const(e)
}

priv fn match_arms(p: *Parser) -> (Vec[MatchArm], bool) {
    arms := vec[MatchArm]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        pos := p.pos()
        pats := vec[Pat]()
        loop {
            e, ok := p.expr()
            if !ok {
                return fail[Vec[MatchArm]]()
            }
            pats.push(pat(e))
            if !p.eat_p(",") {
                break
            }
        }
        guard: Opt[*Expr] = None
        if p.eat_kw("if") {
            g, ok := p.expr()
            if !ok {
                return fail[Vec[MatchArm]]()
            }
            guard = Some(parser_box(g))
        }
        if !p.expect_p("=>") {
            return fail[Vec[MatchArm]]()
        }
        body: Block
        if p.is_p("{") {
            b, ok := p.block()
            if !ok {
                return fail[Vec[MatchArm]]()
            }
            body = b
        } else {
            s, ok := p.stmt()
            if !ok {
                return fail[Vec[MatchArm]]()
            }
            body = Block{stmts: vec_of([]Stmt{s}), end: p.pos()}
        }
        arms.push(MatchArm{pats: pats, body: body, pos: pos, guard: guard})
        if !(tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[Vec[MatchArm]]("expected end of match arm")
        }
    }
    return (arms, true)
}
