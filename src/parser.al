// Parser for AL: tokens to AST. Results are (value, ok) pairs; ok = false after an error.

Parser :: struct {
    toks: Vec[Token]
    i: i64
    errs: *Vec[Diag]
    no_lit: bool
    // inside the header of `if`, `while` or `for` (not `match`); only looked at with `no_lit`
    hdr_stmt: bool
}

parser_new :: (toks: Vec[Token], errs: *Vec[Diag]) -> Parser {
    return Parser{toks: toks, i: 0, errs: errs, no_lit: false, hdr_stmt: false}
}

// the failure result of a parsing function: (zero value, false)
parser_fail[T] :: () -> (T, bool) {
    z: T
    return (z, false)
}

// Box::new
parser_box[T] :: (x: T) -> *T {
    b := new[T]()
    *b = x
    return b
}

parser_tk_p :: (t: Tk, p: str) -> bool {
    match t {
        TkP(q) => {
            return q == p
        }
        _ => {}
    }
    return false
}

parser_tk_kw :: (t: Tk, k: str) -> bool {
    match t {
        TkKw(q) => {
            return q == k
        }
        _ => {}
    }
    return false
}

parser_tk_nl :: (t: Tk) -> bool {
    match t {
        TkNl => {
            return true
        }
        _ => {}
    }
    return false
}

parser_tk_eof :: (t: Tk) -> bool {
    match t {
        TkEof => {
            return true
        }
        _ => {}
    }
    return false
}

parser_tk_id :: (t: Tk) -> bool {
    match t {
        TkId(s) => {
            return true
        }
        _ => {}
    }
    return false
}

// is `t` the identifier `w`?
parser_tk_word :: (t: Tk, w: str) -> bool {
    match t {
        TkId(s) => {
            return s == w
        }
        _ => {}
    }
    return false
}

parser_cont :: (s: str, i: i64, lo: u8, hi: u8) -> bool {
    return i < len(s) && s[i] >= lo && s[i] <= hi
}

// String::from_utf8_lossy: every maximal invalid part becomes U+FFFD
parser_utf8_lossy :: (s: str) -> str {
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
            if parser_cont(s, i + 1, 0x80, 0xBF) {
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
            if parser_cont(s, i + 1, lo, hi) {
                n = 2
                if parser_cont(s, i + 2, 0x80, 0xBF) {
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
            if parser_cont(s, i + 1, lo, hi) {
                n = 2
                if parser_cont(s, i + 2, 0x80, 0xBF) {
                    n = 3
                    if parser_cont(s, i + 3, 0x80, 0xBF) {
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

peek :: (p: *Parser) -> Tk {
    return p.toks[p.i].t
}

peek_at :: (p: *Parser, n: i64) -> Tk {
    j := min(p.i + n, p.toks.len - 1)
    return p.toks[j].t
}

pos :: (p: *Parser) -> Pos {
    return p.toks[p.i].pos
}

bump :: (p: *Parser) -> Tk {
    t := p.toks[p.i].t
    if p.i < p.toks.len - 1 {
        p.i += 1
    }
    return t
}

is_p :: (p: *Parser, s: str) -> bool {
    return parser_tk_p(p.peek(), s)
}

is_kw :: (p: *Parser, k: str) -> bool {
    return parser_tk_kw(p.peek(), k)
}

eat_p :: (p: *Parser, s: str) -> bool {
    if p.is_p(s) {
        p.bump()
        return true
    } else {
        return false
    }
}

eat_kw :: (p: *Parser, k: str) -> bool {
    if p.is_kw(k) {
        p.bump()
        return true
    } else {
        return false
    }
}

tok_desc :: (p: *Parser) -> str {
    match p.peek() {
        TkId(s) => {
            return fmt("identifier `", s, "`")
        }
        TkInt(n) => {
            return "number"
        }
        TkFloat(f) => {
            return "number"
        }
        TkStr(s) => {
            return "string"
        }
        TkKw(k) => {
            return fmt("keyword `", k, "`")
        }
        TkP(q) => {
            return fmt("`", q, "`")
        }
        TkNl => {
            return "end of line"
        }
        TkEof => {
            return "end of file"
        }
    }
    return ""
}

err[T] :: (p: *Parser, msg: str) -> (T, bool) {
    d := p.tok_desc()
    // habits from other languages get a direct pointer to the AL spelling
    hint := ""
    match p.peek() {
        TkId(s) => {
            hint = match s {
                "let", "mut", "auto", "val" => " (declare variables with `name := value` or `var name T`)"
                "func", "def", "function", "pub" => " (functions are declared with `fn name(args) Result { }`)"
                "and" => " (use `&&`)"
                "or" => " (use `||`)"
                "not" => " (use `!`)"
                "import" => " (use `use \"file.al\"`)"
                "switch" => " (use `match`)"
                "elif", "elsif" => " (use `else if`)"
                _ => ""
            }
        }
        TkP(q) => {
            if q == "+" || q == "-" {
                hint = " (there is no `++`/`--`: use `x += 1`)"
            }
        }
        _ => {}
    }
    if hint == "" && p.i >= 1 {
        match p.toks[p.i - 1].t {
            TkId(prev) => {
                if prev == "let" || prev == "mut" || prev == "auto" || prev == "val" {
                    hint = " (declare variables with `name := value` or `var name T`)"
                } else if prev == "func" || prev == "def" || prev == "function" || prev == "pub" {
                    hint = " (functions are declared with `fn name(args) Result { }`)"
                }
            }
            _ => {}
        }
    }
    p.errs.push(Diag{pos: p.pos(), msg: fmt(msg, ", found ", d, hint)})
    z: T
    return (z, false)
}

// (R<()> in the Rust source: only the ok flag)
expect_p :: (p: *Parser, s: str) -> bool {
    if p.eat_p(s) {
        return true
    } else {
        z, ok := p.err[bool](fmt("expected `", s, "`"))
        return ok
    }
}

ident :: (p: *Parser) -> (str, bool) {
    match p.peek() {
        TkId(s) => {
            p.bump()
            return (s, true)
        }
        _ => {}
    }
    return p.err[str]("expected identifier")
}

skip_nl :: (p: *Parser) {
    while parser_tk_nl(p.peek()) || p.is_p(";") {
        p.bump()
    }
}

// ---------- declarations ----------
file :: (p: *Parser) -> Vec[Decl] {
    out := vec[Decl]()
    loop {
        p.skip_nl()
        if parser_tk_eof(p.peek()) {
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
// top-level declaration, a line that starts outside all braces with a name followed by
// `::`, `:` or `:=` or with a declaration keyword (also inside braces if it is at column 1:
// the declaration in error may lack a `}`)
sync_decl :: (p: *Parser, from: i64) {
    depth := 0
    for j in from..p.i {
        if parser_tk_p(p.toks[j].t, "{") {
            depth += 1
        } else if parser_tk_p(p.toks[j].t, "}") {
            depth -= 1
        }
    }
    if p.i == from {
        p.bump()
    }
    // the parser may have stopped at the first token of a line (`name ::` at the end of a line)
    starts := p.i > 0 && p.toks[p.i - 1].pos.line < p.pos().line && depth <= 0
    loop {
        if p.i > 0 && parser_tk_nl(p.toks[p.i - 1].t) {
            starts = depth <= 0 || p.pos().col == 1
        }
        match p.peek() {
            TkEof => {
                return
            }
            TkP(q) => {
                if q == "{" {
                    depth += 1
                } else if q == "}" {
                    depth -= 1
                }
            }
            TkKw(k) => {
                if starts && (k == "fn" || k == "struct" || k == "enum" || k == "const" || k == "var" || k == "test" || k == "use" || k == "inline" || k == "noinline" || k == "extern" || k == "priv") {
                    return
                }
            }
            TkId(s) => {
                if starts {
                    t1 := p.peek_at(1)
                    if parser_tk_p(t1, "::") || p.tparams_ahead() || (depth <= 0 && (parser_tk_p(t1, ":") || parser_tk_p(t1, ":=") || s == "type")) {
                        return
                    }
                }
            }
            _ => {}
        }
        p.bump()
        starts = false
    }
}

// With the parser at a name: do type parameters and `::` follow (`name[T, U] ::`)?
tparams_ahead :: (p: *Parser) -> bool {
    if !parser_tk_p(p.peek_at(1), "[") {
        return false
    }
    j := p.i + 2
    loop {
        if j >= p.toks.len || !parser_tk_id(p.toks[j].t) {
            return false
        }
        j += 1
        if !parser_tk_p(p.toks[j].t, ",") {
            break
        }
        j += 1
    }
    return parser_tk_p(p.toks[j].t, "]") && parser_tk_p(p.toks[min(j + 1, p.toks.len - 1)].t, "::")
}

tparams :: (p: *Parser) -> (Vec[str], bool) {
    v := vec[str]()
    if p.eat_p("[") {
        loop {
            name, ok := p.ident()
            if !ok {
                return parser_fail[Vec[str]]()
            }
            v.push(name)
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p("]") {
            return parser_fail[Vec[str]]()
        }
    }
    return (v, true)
}

// `priv` in front of a declaration: the declaration is visible only in its own file
priv_decl :: (p: *Parser) -> (Decl, bool) {
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
        return parser_fail[Decl]()
    }
    return (parser_set_priv(d, ppos, p.errs), true)
}

// the declaration marked as private. Every kind of declaration is listed: a new kind must
// decide here whether it can be private.
parser_set_priv :: (d: Decl, ppos: Pos, errs: *Vec[Diag]) -> Decl {
    return match d {
        DeclFn(f) => {
            if f.name == "main" {
                errs.push(Diag{pos: ppos, msg: "`fn main` cannot be `priv`: it is where the program starts, which is outside this file; remove `priv`"})
            } else {
                f.is_priv = true
                f.pos = ppos
            }
            DeclFn(f)
        }
        DeclStruct(s) => {
            s.is_priv = true
            s.pos = ppos
            DeclStruct(s)
        }
        DeclEnum(e) => {
            e.is_priv = true
            e.pos = ppos
            DeclEnum(e)
        }
        DeclConst(c) => {
            c.is_priv = true
            c.pos = ppos
            DeclConst(c)
        }
        DeclGlobal(g) => {
            g.is_priv = true
            g.pos = ppos
            DeclGlobal(g)
        }
        DeclType(t) => {
            t.is_priv = true
            t.pos = ppos
            DeclType(t)
        }
        DeclTest(t) => d
        DeclUse(path, upos) => d
    }
}

// a function after its `fn`: name [type parameters] (parameters) [result] body
fn_rest :: (p: *Parser, pos: Pos, inl: i64) -> (FnDecl, bool) {
    name, ok1 := p.ident()
    if !ok1 {
        return parser_fail[FnDecl]()
    }
    tparams, ok2 := p.tparams()
    if !ok2 {
        return parser_fail[FnDecl]()
    }
    if !p.expect_p("(") {
        return parser_fail[FnDecl]()
    }
    params := vec[(str, TypeAst)]()
    while !p.is_p(")") {
        pn, ok3 := p.ident()
        if !ok3 {
            return parser_fail[FnDecl]()
        }
        pt, ok4 := p.ty()
        if !ok4 {
            return parser_fail[FnDecl]()
        }
        params.push((pn, pt))
        if !p.eat_p(",") {
            break
        }
    }
    if !p.expect_p(")") {
        return parser_fail[FnDecl]()
    }
    ret: Opt[TypeAst] = None
    if !p.is_p("{") {
        rt, ok5 := p.ty()
        if !ok5 {
            return parser_fail[FnDecl]()
        }
        ret = Some(rt)
    }
    body, ok6 := p.block()
    if !ok6 {
        return parser_fail[FnDecl]()
    }
    return (FnDecl{name: name, tparams: tparams, params: params, ret: ret, body: body, pos: pos, inl: inl, ext: None}, true)
}

// `fn (a A, b B) R` of an anonymous function; true if a `{` follows
fn_header :: (p: *Parser, params: *Vec[(str, TypeAst)], ret: *Opt[TypeAst]) -> bool {
    p.bump()
    if !p.eat_p("(") {
        return false
    }
    while !p.is_p(")") {
        if !parser_tk_id(p.peek()) {
            return false
        }
        pn, ok1 := p.ident()
        pt, ok2 := p.ty()
        if !ok1 || !ok2 {
            return false
        }
        params.push((pn, pt))
        if !p.eat_p(",") {
            break
        }
    }
    if !p.eat_p(")") {
        return false
    }
    if !p.is_p("{") {
        if !p.starts_type() {
            return false
        }
        rt, ok := p.ty()
        if !ok {
            return false
        }
        *ret = Some(rt)
    }
    return p.is_p("{")
}

// At `fn` where an expression starts: an anonymous function `fn(a A, b B) R { ... }`, or the
// function type `fn(A, B) R` (a type argument, the type of a literal). It is an anonymous
// function if the parameters have names and a body follows.
fn_expr :: (p: *Parser, pos: Pos) -> (Expr, bool) {
    if parser_tk_p(p.peek_at(1), "[") {
        p.errs.push(Diag{pos: pos, msg: "an anonymous function cannot have type parameters of its own (it may use the type parameters of the enclosing function): write `fn(a T) R { ... }`, or declare a generic function at the top level"})
        return parser_fail[Expr]()
    }
    start := p.i
    nerr := p.errs.len
    params := vec[(str, TypeAst)]()
    ret: Opt[TypeAst] = None
    if p.fn_header(&params, &ret) {
        body, ok := p.block()
        if !ok {
            return parser_fail[Expr]()
        }
        d := FnDecl{name: "", tparams: vec[str](), params: params, ret: ret, body: body, pos: pos, inl: 0, ext: None}
        return (Expr{k: EKFn(parser_box(d)), pos: pos}, true)
    }
    p.i = start
    p.errs.truncate(nerr)
    t, ok := p.ty()
    if !ok {
        return parser_fail[Expr]()
    }
    if p.is_p("{") {
        p.errs.push(Diag{pos: pos, msg: "an anonymous function names its parameters and gives each one a type, like any function: `fn(a i64, b i64) bool { a < b }` (`fn(A, B) R` alone is a function type)"})
        return parser_fail[Expr]()
    }
    return (Expr{k: EKTypeE(t), pos: pos}, true)
}

// With the parser at `(`: do the parameters of a function start here (in a declaration after
// `::`, or an anonymous function)? `(` `)` followed by `->` or `{`, or `(` name `:`.
at_fn :: (p: *Parser) -> bool {
    if !p.is_p("(") {
        return false
    }
    if parser_tk_p(p.peek_at(1), ")") {
        after := p.peek_at(2)
        return parser_tk_p(after, "->") || parser_tk_p(after, "{")
    }
    return parser_tk_id(p.peek_at(1)) && parser_tk_p(p.peek_at(2), ":")
}

// With the parser at `(`: is the matching `)` followed by `what`? (`->`: a function type)
parens_then :: (p: *Parser, what: str) -> bool {
    if !p.is_p("(") {
        return false
    }
    j := p.i + 1
    depth := 1
    while depth > 0 {
        match p.toks[j].t {
            TkEof => {
                return false
            }
            TkP(q) => {
                if q == "(" {
                    depth += 1
                } else if q == ")" {
                    depth -= 1
                }
            }
            _ => {}
        }
        j += 1
    }
    return parser_tk_p(p.toks[j].t, what)
}

// With the parser after the `::` of a declaration: is a function declared? The parameters
// start as `at_fn` says; a `(...)` followed by `->` or `{` and a first parameter without
// its colon are taken as a function too, for the error message.
fn_ahead :: (p: *Parser) -> bool {
    return p.at_fn() || p.parens_then("->") || p.parens_then("{") || p.at_old_params()
}

// With the parser after a `->`: is `()` written for "no result"? (`() -> R` is a function type)
at_no_result :: (p: *Parser) -> bool {
    return p.is_p("(") && parser_tk_p(p.peek_at(1), ")") && !parser_tk_p(p.peek_at(2), "->")
}

// `(a: A, b: B) [-> R]`: the parameters and the result of a function declaration or of an
// anonymous function
fn_sig :: (p: *Parser, params: *Vec[(str, TypeAst)], ret: *Opt[TypeAst]) -> bool {
    if !p.expect_p("(") {
        return false
    }
    while !p.is_p(")") {
        pn, ok1 := p.ident()
        if !ok1 {
            return false
        }
        if !p.eat_p(":") {
            p.err[bool](fmt("a parameter is written `", pn, ": Type`: expected `:` after the name"))
            return false
        }
        pt, ok2 := p.ty()
        if !ok2 {
            return false
        }
        params.push((pn, pt))
        if !p.eat_p(",") {
            break
        }
    }
    if !p.expect_p(")") {
        return false
    }
    if p.eat_p("->") {
        if p.at_no_result() {
            p.errs.push(Diag{pos: p.pos(), msg: "a function without a result is declared without an arrow: leave out `-> ()` (only a function type is written with it: `(i64) -> ()`)"})
            p.bump()
            p.bump()
            return true
        }
        rt, ok3 := p.ty()
        if !ok3 {
            return false
        }
        *ret = Some(rt)
    } else if p.starts_type() {
        p.err[bool]("the result type of a function follows an arrow (`name :: (a: A) -> R { ... }`): expected `->` or `{`")
        return false
    }
    return true
}

// At `(` where `at_fn` holds and an expression starts: an anonymous function
// `(a: A, b: B) -> R { ... }`, or the function type `() -> R` (no body follows)
anon_fn :: (p: *Parser, pos: Pos) -> (Expr, bool) {
    if parser_tk_p(p.peek_at(1), ")") && parser_tk_p(p.peek_at(2), "->") {
        start := p.i
        nerr := p.errs.len
        t, ok := p.ty()
        if !ok {
            return parser_fail[Expr]()
        }
        if !p.is_p("{") {
            return (Expr{k: EKTypeE(t), pos: pos}, true)
        }
        p.i = start
        p.errs.truncate(nerr)
    }
    params := vec[(str, TypeAst)]()
    ret: Opt[TypeAst] = None
    if !p.fn_sig(&params, &ret) {
        return parser_fail[Expr]()
    }
    body, ok := p.block()
    if !ok {
        return parser_fail[Expr]()
    }
    d := FnDecl{name: "", tparams: vec[str](), params: params, ret: ret, body: body, pos: pos, inl: 0, ext: None}
    return (Expr{k: EKFn(parser_box(d)), pos: pos}, true)
}

// the body of a struct after `struct`: `{ name: Type, ... }` (fields separated by `,` or
// newlines)
struct_rest :: (p: *Parser, name: str, tparams: Vec[str], pos: Pos) -> (Decl, bool) {
    if !p.expect_p("{") {
        return parser_fail[Decl]()
    }
    fields := vec[(str, TypeAst)]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        if p.is_kw("priv") {
            return p.err[Decl]("a struct field cannot be `priv` (only top-level declarations can): write `priv` in front of the declaration to make the whole struct private")
        }
        fname, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        if !p.eat_p(":") {
            return p.err[Decl](fmt("a field is written `", fname, ": Type`: expected `:` after the name"))
        }
        fty, ok2 := p.ty()
        if !ok2 {
            return parser_fail[Decl]()
        }
        fields.push((fname, fty))
        p.eat_p(",")
    }
    return (DeclStruct(StructDecl{name: name, tparams: tparams, fields: fields, pos: pos}), true)
}

// the body of an enum after `enum`: `{ Variant, Variant(Type, ...), ... }`
enum_rest :: (p: *Parser, name: str, tparams: Vec[str], pos: Pos) -> (Decl, bool) {
    if !p.expect_p("{") {
        return parser_fail[Decl]()
    }
    variants := vec[(str, Vec[TypeAst])]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        if p.is_kw("priv") {
            return p.err[Decl]("an enum variant cannot be `priv` (only top-level declarations can): write `priv` in front of the declaration to make the enum type private")
        }
        vname, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        tys := vec[TypeAst]()
        if p.eat_p("(") {
            while !p.is_p(")") {
                vt, ok2 := p.ty()
                if !ok2 {
                    return parser_fail[Decl]()
                }
                tys.push(vt)
                if !p.eat_p(",") {
                    break
                }
            }
            if !p.expect_p(")") {
                return parser_fail[Decl]()
            }
        }
        variants.push((vname, tys))
        p.eat_p(",")
    }
    return (DeclEnum(EnumDecl{name: name, tparams: tparams, variants: variants, pos: pos}), true)
}

// `inline` / `noinline` / `extern` in front of a declaration that is not a function
not_fn :: (p: *Parser, pos: Pos, inl: i64, ext: *Opt[str], what: str) -> bool {
    word := ""
    if is_some(*ext) {
        word = "extern"
    } else if inl > 0 {
        word = "inline"
    } else if inl < 0 {
        word = "noinline"
    }
    if word == "" {
        return false
    }
    p.errs.push(Diag{pos: pos, msg: fmt("`", word, "` applies to functions only, and this declares ", what, ": remove `", word, "`")})
    return true
}

// A declaration that starts with its name (after the modifiers `inline` / `noinline` /
// `extern "lib"`):
//   name[T] :: (a: A) -> R { ... }    name[T] :: struct { ... }    name[T] :: enum { ... }
//   name :: type T                    name :: value                name : T : value
//   name : T                          name : T = value             name := value
name_decl :: (p: *Parser, pos: Pos, inl: i64, ext: Opt[str]) -> (Decl, bool) {
    name, ok1 := p.ident()
    if !ok1 {
        return parser_fail[Decl]()
    }
    tparams, ok2 := p.tparams()
    if !ok2 {
        return parser_fail[Decl]()
    }
    if p.is_p("::") {
        cpos := p.pos()
        p.bump()
        if p.pos().line != cpos.line || parser_tk_eof(p.peek()) {
            p.errs.push(Diag{pos: cpos, msg: fmt("`", name, " ::` is followed on the same line by what it declares: `(a: A) -> R { ... }` (a function), `struct { ... }`, `enum { ... }`, `type T`, or the value of a constant")})
            return parser_fail[Decl]()
        }
        if p.eat_kw("struct") {
            if p.not_fn(pos, inl, &ext, "a struct") {
                return parser_fail[Decl]()
            }
            return p.struct_rest(name, tparams, pos)
        }
        if p.eat_kw("enum") {
            if p.not_fn(pos, inl, &ext, "an enum") {
                return parser_fail[Decl]()
            }
            return p.enum_rest(name, tparams, pos)
        }
        if parser_tk_word(p.peek(), "type") {
            p.bump()
            if p.not_fn(pos, inl, &ext, "a type alias") {
                return parser_fail[Decl]()
            }
            if !tparams.is_empty() {
                p.errs.push(Diag{pos: pos, msg: fmt("a type alias cannot have type parameters: write `", name, " :: type ...`")})
                return parser_fail[Decl]()
            }
            at, ok3 := p.ty()
            if !ok3 {
                return parser_fail[Decl]()
            }
            return (DeclType(TypeDecl{name: name, ty: at, pos: pos}), true)
        }
        // (an `extern` declaration is always a function: `extern "lib" f :: ()` has no `->`
        // or `{` after its empty parameter list)
        if p.fn_ahead() || (is_some(ext) && p.is_p("(")) {
            params := vec[(str, TypeAst)]()
            ret: Opt[TypeAst] = None
            if !p.fn_sig(&params, &ret) {
                return parser_fail[Decl]()
            }
            match ext {
                Some(lib) => {
                    if !tparams.is_empty() {
                        p.errs.push(Diag{pos: pos, msg: fmt("the C function `", name, "` cannot have type parameters")})
                        return parser_fail[Decl]()
                    }
                    if p.is_p("{") {
                        return p.err[Decl](fmt("an `extern` function is a C function of the library and has no body: expected end of line after the declaration of `", name, "`"))
                    }
                    return (DeclFn(FnDecl{name: name, tparams: tparams, params: params, ret: ret, body: Block{stmts: vec[Stmt](), end: pos}, pos: pos, inl: -1, ext: ext}), true)
                }
                None => {}
            }
            body, ok3 := p.block()
            if !ok3 {
                return parser_fail[Decl]()
            }
            return (DeclFn(FnDecl{name: name, tparams: tparams, params: params, ret: ret, body: body, pos: pos, inl: inl, ext: None}), true)
        }
        if p.not_fn(pos, inl, &ext, "a constant") {
            return parser_fail[Decl]()
        }
        if !tparams.is_empty() {
            p.errs.push(Diag{pos: pos, msg: fmt("only functions, structs and enums have type parameters: `", name, "[", join(tparams.items(), ", "), "] ::` must be followed by `(`, `struct` or `enum`")})
            return parser_fail[Decl]()
        }
        val, ok3 := p.expr()
        if !ok3 {
            return parser_fail[Decl]()
        }
        if p.is_p("{") || p.is_p("->") {
            return p.err[Decl](fmt("expected the end of the constant `", name, "` (a function is declared `", name, " :: (a: A) -> R { ... }`, a type alias `", name, " :: type T`)"))
        }
        return (DeclConst(ConstDecl{name: name, ty: None, val: val, pos: pos}), true)
    }
    if !tparams.is_empty() {
        return p.err[Decl]("expected `::` after the type parameters of a declaration")
    }
    if p.eat_p(":=") {
        if p.not_fn(pos, inl, &ext, "a variable") {
            return parser_fail[Decl]()
        }
        ie, ok3 := p.expr()
        if !ok3 {
            return parser_fail[Decl]()
        }
        return (DeclGlobal(GlobalDecl{name: name, ty: None, init: Some(ie), pos: pos}), true)
    }
    if p.eat_p(":") {
        vt, ok3 := p.ty()
        if !ok3 {
            return parser_fail[Decl]()
        }
        if p.is_p(":") {
            cpos := p.pos()
            p.bump()
            if p.not_fn(pos, inl, &ext, "a constant") {
                return parser_fail[Decl]()
            }
            if p.pos().line != cpos.line || parser_tk_eof(p.peek()) {
                p.errs.push(Diag{pos: cpos, msg: fmt("the constant `", name, "` needs a value: `", name, " : ", ast_type_str(&vt), " : value`")})
                return parser_fail[Decl]()
            }
            val, ok4 := p.expr()
            if !ok4 {
                return parser_fail[Decl]()
            }
            return (DeclConst(ConstDecl{name: name, ty: Some(vt), val: val, pos: pos}), true)
        }
        if p.not_fn(pos, inl, &ext, "a variable") {
            return parser_fail[Decl]()
        }
        init: Opt[Expr] = None
        if p.eat_p("=") {
            ie, ok4 := p.expr()
            if !ok4 {
                return parser_fail[Decl]()
            }
            init = Some(ie)
        }
        return (DeclGlobal(GlobalDecl{name: name, ty: Some(vt), init: init, pos: pos}), true)
    }
    return p.err[Decl](fmt("expected `::`, `:` or `:=` after the name `", name, "` (`", name, " :: (a: A) -> R { ... }` declares a function, `", name, " :: value` a constant, `", name, ": T = value` a variable)"))
}

// With the parser at `(`: a parameter written without its colon (`(name Type`)?
at_old_params :: (p: *Parser) -> bool {
    return p.is_p("(") && parser_tk_id(p.peek_at(1)) && (parser_tk_id(p.peek_at(2)) || parser_tk_kw(p.peek_at(2), "fn"))
}

// A function declared inside a block: `name :: (a: A) -> R { ... }`
nested_fn :: (p: *Parser) -> (SK, bool) {
    pos := p.pos()
    name, ok1 := p.ident()
    if !ok1 {
        return parser_fail[SK]()
    }
    tparams, ok2 := p.tparams()
    if !ok2 || !p.expect_p("::") {
        return parser_fail[SK]()
    }
    if !p.fn_ahead() {
        what := "a constant is"
        if p.is_kw("struct") {
            what = "a struct is"
        } else if p.is_kw("enum") {
            what = "an enum is"
        } else if parser_tk_word(p.peek(), "type") {
            what = "a type alias is"
        }
        p.errs.push(Diag{pos: pos, msg: fmt("inside a function only functions can be declared with `::` (`", name, " :: (a: A) -> R { ... }`): ", what, " declared at the top level")})
        return parser_fail[SK]()
    }
    params := vec[(str, TypeAst)]()
    ret: Opt[TypeAst] = None
    if !p.fn_sig(&params, &ret) {
        return parser_fail[SK]()
    }
    body, ok3 := p.block()
    if !ok3 {
        return parser_fail[SK]()
    }
    return (SKFn(parser_box(FnDecl{name: name, tparams: tparams, params: params, ret: ret, body: body, pos: pos, inl: 0, ext: None})), true)
}

decl :: (p: *Parser) -> (Decl, bool) {
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
        return p.err[Decl]("`priv` is written first: `priv inline name :: ...`")
    }
    ext: Opt[str] = None
    if p.eat_kw("extern") {
        // extern "libfoo.so.1" name :: (a: A) -> R     (a C function; no body)
        match p.bump() {
            TkStr(s) => {
                ext = Some(parser_utf8_lossy(s))
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected a library name string after `extern`, e.g. `extern \"libc.so.6\" getpid :: () -> i32`")
            }
        }
        if !p.is_kw("fn") && !parser_tk_id(p.peek()) {
            return p.err[Decl]("expected the name of the C function after the library name, e.g. `extern \"libc.so.6\" getpid :: () -> i32`")
        }
    }
    if parser_tk_id(p.peek()) && !(parser_tk_word(p.peek(), "type") && parser_tk_id(p.peek_at(1))) {
        return p.name_decl(pos, inl, ext)
    }
    if is_some(ext) {
        lib := ""
        match ext {
            Some(l) => {
                lib = l
            }
            None => {}
        }
        p.bump()
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        if !p.expect_p("(") {
            return parser_fail[Decl]()
        }
        params := vec[(str, TypeAst)]()
        while !p.is_p(")") {
            pn, ok2 := p.ident()
            if !ok2 {
                return parser_fail[Decl]()
            }
            pt, ok3 := p.ty()
            if !ok3 {
                return parser_fail[Decl]()
            }
            params.push((pn, pt))
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p(")") {
            return parser_fail[Decl]()
        }
        ret: Opt[TypeAst] = None
        if !(parser_tk_nl(p.peek()) || parser_tk_eof(p.peek())) {
            rt, ok4 := p.ty()
            if !ok4 {
                return parser_fail[Decl]()
            }
            ret = Some(rt)
        }
        body := Block{stmts: vec[Stmt](), end: pos}
        return (DeclFn(FnDecl{name: name, tparams: vec[str](), params: params, ret: ret, body: body, pos: pos, inl: -1, ext: Some(lib)}), true)
    }
    if p.eat_kw("fn") {
        f, ok := p.fn_rest(pos, inl)
        if !ok {
            return parser_fail[Decl]()
        }
        return (DeclFn(f), true)
    }
    if inl != 0 {
        return p.err[Decl]("`inline` / `noinline` stand in front of a function declaration: `inline name :: (a: A) -> R { ... }`")
    }
    if p.eat_kw("struct") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        tparams, ok2 := p.tparams()
        if !ok2 {
            return parser_fail[Decl]()
        }
        if !p.expect_p("{") {
            return parser_fail[Decl]()
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
            fname, ok3 := p.ident()
            if !ok3 {
                return parser_fail[Decl]()
            }
            fty, ok4 := p.ty()
            if !ok4 {
                return parser_fail[Decl]()
            }
            fields.push((fname, fty))
            p.eat_p(",")
        }
        return (DeclStruct(StructDecl{name: name, tparams: tparams, fields: fields, pos: pos}), true)
    }
    if p.eat_kw("enum") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        tparams, ok2 := p.tparams()
        if !ok2 {
            return parser_fail[Decl]()
        }
        if !p.expect_p("{") {
            return parser_fail[Decl]()
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
            vname, ok3 := p.ident()
            if !ok3 {
                return parser_fail[Decl]()
            }
            tys := vec[TypeAst]()
            if p.eat_p("(") {
                while !p.is_p(")") {
                    vt, ok4 := p.ty()
                    if !ok4 {
                        return parser_fail[Decl]()
                    }
                    tys.push(vt)
                    if !p.eat_p(",") {
                        break
                    }
                }
                if !p.expect_p(")") {
                    return parser_fail[Decl]()
                }
            }
            variants.push((vname, tys))
            p.eat_p(",")
        }
        return (DeclEnum(EnumDecl{name: name, tparams: tparams, variants: variants, pos: pos}), true)
    }
    if p.eat_kw("const") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        ty: Opt[TypeAst] = None
        if !p.is_p("=") {
            ct, ok2 := p.ty()
            if !ok2 {
                return parser_fail[Decl]()
            }
            ty = Some(ct)
        }
        if !p.expect_p("=") {
            return parser_fail[Decl]()
        }
        val, ok3 := p.expr()
        if !ok3 {
            return parser_fail[Decl]()
        }
        return (DeclConst(ConstDecl{name: name, ty: ty, val: val, pos: pos}), true)
    }
    if p.eat_kw("var") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        ty: Opt[TypeAst] = None
        if !p.is_p("=") {
            gt, ok2 := p.ty()
            if !ok2 {
                return parser_fail[Decl]()
            }
            ty = Some(gt)
        }
        init: Opt[Expr] = None
        if p.eat_p("=") {
            ie, ok3 := p.expr()
            if !ok3 {
                return parser_fail[Decl]()
            }
            init = Some(ie)
        }
        return (DeclGlobal(GlobalDecl{name: name, ty: ty, init: init, pos: pos}), true)
    }
    if p.eat_kw("test") {
        name := ""
        match p.bump() {
            TkStr(s) => {
                name = parser_utf8_lossy(s)
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected test name string")
            }
        }
        body, ok1 := p.block()
        if !ok1 {
            return parser_fail[Decl]()
        }
        return (DeclTest(TestDecl{name: name, body: body, pos: pos}), true)
    }
    if p.eat_kw("use") {
        // use "file.al"   or   use std.name (a module bundled with the compiler)
        match p.peek() {
            TkId(a) => {
                if parser_tk_p(p.peek_at(1), ".") {
                    match p.peek_at(2) {
                        TkId(b) => {
                            if a == "std" {
                                p.i += 3
                                return (DeclUse(fmt("std:", b), pos), true)
                            }
                        }
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        match p.bump() {
            TkStr(s) => {
                return (DeclUse(parser_utf8_lossy(s), pos), true)
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected a file path string or `std.<module>` after `use`")
            }
        }
    }
    // `type Name = T` (`type` is only special at the start of a declaration)
    if parser_tk_word(p.peek(), "type") {
        p.bump()
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        if p.is_p("[") {
            return p.err[Decl]("a type alias cannot have type parameters: expected `=`")
        }
        if !p.expect_p("=") {
            return parser_fail[Decl]()
        }
        at, ok2 := p.ty()
        if !ok2 {
            return parser_fail[Decl]()
        }
        return (DeclType(TypeDecl{name: name, ty: at, pos: pos}), true)
    }
    return p.err[Decl]("expected declaration (fn, struct, enum, type, const, var, test, use, extern, priv)")
}

// ---------- types ----------
starts_type :: (p: *Parser) -> bool {
    match p.peek() {
        TkId(s) => {
            return true
        }
        TkP(q) => {
            return q == "*" || q == "[" || q == "("
        }
        TkKw(k) => {
            return k == "fn"
        }
        _ => {}
    }
    return false
}

ty :: (p: *Parser) -> (TypeAst, bool) {
    pos := p.pos()
    if p.eat_p("*") {
        t, ok := p.ty()
        if !ok {
            return parser_fail[TypeAst]()
        }
        return (TypeAstPtr(parser_box(t)), true)
    }
    if p.eat_p("[") {
        if p.eat_p("]") {
            t, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            return (TypeAstSlice(parser_box(t)), true)
        }
        save := p.no_lit
        p.no_lit = false
        n, ok1 := p.expr()
        p.no_lit = save
        if !ok1 {
            return parser_fail[TypeAst]()
        }
        if !p.expect_p("]") {
            return parser_fail[TypeAst]()
        }
        nb := parser_box(n)
        t, ok2 := p.ty()
        if !ok2 {
            return parser_fail[TypeAst]()
        }
        return (TypeAstArray(nb, parser_box(t)), true)
    }
    if p.eat_p("(") {
        v := vec[TypeAst]()
        while !p.is_p(")") {
            t, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            v.push(t)
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p(")") {
            return parser_fail[TypeAst]()
        }
        if p.eat_p("->") {
            // a function type `(A, B) -> R`; `-> ()` for "no result"
            ret: Opt[*TypeAst] = None
            if p.at_no_result() {
                p.bump()
                p.bump()
            } else {
                rt, ok := p.ty()
                if !ok {
                    return parser_fail[TypeAst]()
                }
                ret = Some(parser_box(rt))
            }
            return (TypeAstFn(v, ret), true)
        }
        return (TypeAstTuple(v), true)
    }
    if p.eat_kw("fn") {
        if !p.expect_p("(") {
            return parser_fail[TypeAst]()
        }
        v := vec[TypeAst]()
        while !p.is_p(")") {
            t, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            v.push(t)
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p(")") {
            return parser_fail[TypeAst]()
        }
        ret: Opt[*TypeAst] = None
        if p.starts_type() {
            rt, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            ret = Some(parser_box(rt))
        }
        return (TypeAstFn(v, ret), true)
    }
    match p.peek() {
        TkId(name) => {
            p.bump()
            args := vec[TypeAst]()
            if p.eat_p("[") {
                loop {
                    t, ok := p.ty()
                    if !ok {
                        return parser_fail[TypeAst]()
                    }
                    args.push(t)
                    if !p.eat_p(",") {
                        break
                    }
                }
                if !p.expect_p("]") {
                    return parser_fail[TypeAst]()
                }
            }
            return (TypeAstName(name, args, pos), true)
        }
        _ => {}
    }
    return p.err[TypeAst]("expected type")
}

// ---------- statements ----------
block :: (p: *Parser) -> (Block, bool) {
    if !p.expect_p("{") {
        return parser_fail[Block]()
    }
    save := p.no_lit
    p.no_lit = false
    stmts := vec[Stmt]()
    loop {
        p.skip_nl()
        if p.is_p("}") || parser_tk_eof(p.peek()) {
            break
        }
        s, ok := p.stmt()
        if ok {
            stmts.push(s)
            if !(parser_tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
                p.err[bool]("expected end of statement")
                p.sync_stmt()
            }
        } else {
            p.sync_stmt()
        }
    }
    p.no_lit = save
    end := p.pos()
    if !p.expect_p("}") {
        return parser_fail[Block]()
    }
    return (Block{stmts: stmts, end: end}, true)
}

sync_stmt :: (p: *Parser) {
    depth := 0
    loop {
        match p.peek() {
            TkEof => {
                return
            }
            TkNl => {
                if depth == 0 {
                    return
                }
            }
            TkP(q) => {
                if q == "{" {
                    depth += 1
                } else if q == "}" {
                    if depth == 0 {
                        return
                    }
                    depth -= 1
                }
            }
            _ => {}
        }
        p.bump()
    }
}

// the scrutinee of a `match`
header_expr :: (p: *Parser) -> (Expr, bool) {
    save := p.no_lit
    save_stmt := p.hdr_stmt
    p.no_lit = true
    p.hdr_stmt = false
    e, ok := p.expr()
    p.no_lit = save
    p.hdr_stmt = save_stmt
    return (e, ok)
}

// the condition of an `if` or `while`, or an expression of a `for` header
stmt_header_expr :: (p: *Parser) -> (Expr, bool) {
    save := p.no_lit
    save_stmt := p.hdr_stmt
    p.no_lit = true
    p.hdr_stmt = true
    e, ok := p.expr()
    p.no_lit = save
    p.hdr_stmt = save_stmt
    return (e, ok)
}

parser_tk_binop :: (t: Tk) -> bool {
    match t {
        TkP(q) => {
            match q {
                "*", "/", "%", "+", "-", "<<", ">>", "&", "^", "|", "==", "!=", "<", "<=", ">", ">=", "&&", "||" => {
                    return true
                }
                _ => {}
            }
        }
        _ => {}
    }
    return false
}

// In a header (`if`, `while`, `for`, `match`) a `{` normally starts the body. With the
// parser at a `{` that follows the type-like expression `e`, is it a `T{...}` literal?
//  - yes if `e` is written as a type (`[]T`, `[N]T`): a type alone is not a value;
//  - in the header of `if`, `while` and `for`: yes if the matching `}` is directly followed
//    by `{` (that one starts the body), `.`, `[` or a binary operator; none of these can
//    follow the body of such a statement;
//  - after the scrutinee of a `match`: yes if the braces hold something but no `=>` of
//    their own, which every match arm has.
lit_in_header :: (p: *Parser, e: *Expr) -> bool {
    match e.k {
        EKTypeE(t) => {
            return true
        }
        _ => {}
    }
    j := p.i
    depth := 0
    arrow := false
    loop {
        match p.toks[j].t {
            TkEof => {
                return false
            }
            TkP(q) => {
                if q == "{" {
                    depth += 1
                } else if q == "}" {
                    depth -= 1
                    if depth == 0 {
                        break
                    }
                } else if q == "=>" && depth == 1 {
                    arrow = true
                }
            }
            _ => {}
        }
        j += 1
    }
    if !p.hdr_stmt {
        return !arrow && j > p.i + 1
    }
    after := p.toks[min(j + 1, p.toks.len - 1)].t
    return parser_tk_p(after, "{") || parser_tk_p(after, ".") || parser_tk_p(after, "[") || parser_tk_binop(after)
}

if_stmt :: (p: *Parser) -> ((Expr, Block, Opt[Block]), bool) {
    // `if` already consumed
    c, ok1 := p.stmt_header_expr()
    if !ok1 {
        return parser_fail[(Expr, Block, Opt[Block])]()
    }
    t, ok2 := p.block()
    if !ok2 {
        return parser_fail[(Expr, Block, Opt[Block])]()
    }
    j := p.i
    while parser_tk_nl(p.toks[j].t) {
        j += 1
    }
    if parser_tk_kw(p.toks[j].t, "else") {
        p.i = j + 1
        if p.is_kw("if") {
            pos := p.pos()
            p.bump()
            r, ok3 := p.if_stmt()
            if !ok3 {
                return parser_fail[(Expr, Block, Opt[Block])]()
            }
            end := r.1.end
            inner := Stmt{k: SKIf(r.0, r.1, r.2), pos: pos}
            eb: Opt[Block] = Some(Block{stmts: vec_of([]Stmt{inner}), end: end})
            return ((c, t, eb), true)
        }
        e, ok4 := p.block()
        if !ok4 {
            return parser_fail[(Expr, Block, Opt[Block])]()
        }
        eb: Opt[Block] = Some(e)
        return ((c, t, eb), true)
    }
    none: Opt[Block] = None
    return ((c, t, none), true)
}

stmt :: (p: *Parser) -> (Stmt, bool) {
    pos := p.pos()
    k, ok := p.stmt_k()
    if !ok {
        return parser_fail[Stmt]()
    }
    return (Stmt{k: k, pos: pos}, true)
}

stmt_k :: (p: *Parser) -> (SK, bool) {
    if p.is_kw("priv") {
        return p.err[SK]("`priv` applies to top-level declarations only (`priv fn`, `priv struct`, `priv enum`, `priv const`, `priv var`); a local declaration is visible only in its block anyway")
    }
    match p.peek() {
        TkKw(k) => {
            if k == "inline" || k == "noinline" || k == "extern" {
                p.errs.push(Diag{pos: p.pos(), msg: fmt("`", k, "` applies to top-level functions only: a nested function is declared as `fn name(...) { ... }`")})
                return parser_fail[SK]()
            }
        }
        _ => {}
    }
    if p.is_kw("fn") && parser_tk_id(p.peek_at(1)) {
        // a nested function
        pos := p.pos()
        p.bump()
        f, ok := p.fn_rest(pos, 0)
        if !ok {
            return parser_fail[SK]()
        }
        return (SKFn(parser_box(f)), true)
    }
    if p.eat_kw("var") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[SK]()
        }
        ty: Opt[TypeAst] = None
        if !p.is_p("=") {
            vt, ok2 := p.ty()
            if !ok2 {
                return parser_fail[SK]()
            }
            ty = Some(vt)
        }
        init: Opt[Expr] = None
        if p.eat_p("=") {
            ie, ok3 := p.expr()
            if !ok3 {
                return parser_fail[SK]()
            }
            init = Some(ie)
        }
        return (SKVar(name, ty, init), true)
    }
    if p.eat_kw("if") {
        r, ok := p.if_stmt()
        if !ok {
            return parser_fail[SK]()
        }
        return (SKIf(r.0, r.1, r.2), true)
    }
    if p.eat_kw("while") {
        c, ok1 := p.stmt_header_expr()
        if !ok1 {
            return parser_fail[SK]()
        }
        b, ok2 := p.block()
        if !ok2 {
            return parser_fail[SK]()
        }
        return (SKWhile(c, b), true)
    }
    if p.eat_kw("loop") {
        b, ok := p.block()
        if !ok {
            return parser_fail[SK]()
        }
        return (SKLoop(b), true)
    }
    if p.eat_kw("for") {
        v1, ok1 := p.ident()
        if !ok1 {
            return parser_fail[SK]()
        }
        v2: Opt[str] = None
        if p.eat_p(",") {
            n2, ok2 := p.ident()
            if !ok2 {
                return parser_fail[SK]()
            }
            v2 = Some(n2)
        }
        if !p.eat_kw("in") {
            return p.err[SK]("expected `in`")
        }
        lo, ok3 := p.stmt_header_expr()
        if !ok3 {
            return parser_fail[SK]()
        }
        hi: Opt[Expr] = None
        incl := false
        if p.eat_p("..") {
            h, ok4 := p.stmt_header_expr()
            if !ok4 {
                return parser_fail[SK]()
            }
            hi = Some(h)
        } else if p.eat_p("..=") {
            h, ok4 := p.stmt_header_expr()
            if !ok4 {
                return parser_fail[SK]()
            }
            hi = Some(h)
            incl = true
        }
        step: Opt[Expr] = None
        if p.eat_kw("by") {
            st, ok5 := p.stmt_header_expr()
            if !ok5 {
                return parser_fail[SK]()
            }
            step = Some(st)
        }
        body, ok6 := p.block()
        if !ok6 {
            return parser_fail[SK]()
        }
        return (SKFor(v1, v2, lo, hi, incl, step, body), true)
    }
    if p.eat_kw("return") {
        if parser_tk_nl(p.peek()) || p.is_p("}") || p.is_p(";") {
            return (SKReturn(None), true)
        }
        e, ok := p.expr()
        if !ok {
            return parser_fail[SK]()
        }
        return (SKReturn(Some(e)), true)
    }
    if p.eat_kw("break") {
        // a label must be on the same line (a newline after `break` ends the statement)
        match p.peek() {
            TkId(label) => {
                p.bump()
                return (SKBreakTo(label), true)
            }
            _ => {}
        }
        if !(parser_tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[SK]("`break` leaves a loop and takes at most a loop label (`break outer`): expected end of statement")
        }
        return (SKBreak, true)
    }
    if p.eat_kw("continue") {
        match p.peek() {
            TkId(label) => {
                p.bump()
                return (SKContinueTo(label), true)
            }
            _ => {}
        }
        if !(parser_tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[SK]("`continue` takes at most a loop label (`continue outer`): expected end of statement")
        }
        return (SKContinue, true)
    }
    if p.eat_kw("assert") {
        c, ok1 := p.expr()
        if !ok1 {
            return parser_fail[SK]()
        }
        m: Opt[Expr] = None
        if p.eat_p(",") {
            me, ok2 := p.expr()
            if !ok2 {
                return parser_fail[SK]()
            }
            m = Some(me)
        }
        return (SKAssert(c, m), true)
    }
    if p.eat_kw("defer") {
        b, ok := p.block()
        if !ok {
            return parser_fail[SK]()
        }
        return (SKDefer(b), true)
    }
    if p.is_p("{") {
        b, ok := p.block()
        if !ok {
            return parser_fail[SK]()
        }
        return (SKBlock(b), true)
    }
    // a labelled loop: `name: for ...`, `name: while ...`, `name: loop ...`
    if parser_tk_id(p.peek()) && parser_tk_p(p.peek_at(1), ":") {
        after := p.peek_at(2)
        if parser_tk_kw(after, "for") || parser_tk_kw(after, "while") || parser_tk_kw(after, "loop") {
            label, ok1 := p.ident()
            if !ok1 {
                return parser_fail[SK]()
            }
            p.bump()
            inner, ok2 := p.stmt()
            if !ok2 {
                return parser_fail[SK]()
            }
            return (SKLabeled(label, parser_box(inner)), true)
        }
        if parser_tk_kw(after, "if") || parser_tk_kw(after, "match") || parser_tk_p(after, "{") {
            p.bump()
            p.bump()
            return p.err[SK]("a label names a loop: expected `for`, `while` or `loop` after the label")
        }
        // a variable: `name: T` (zero value) or `name: T = value`
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[SK]()
        }
        p.bump()
        vt, ok2 := p.ty()
        if !ok2 {
            return parser_fail[SK]()
        }
        if p.is_p(":") {
            return p.err[SK](fmt("a constant is declared at the top level (`", name, " : ", ast_type_str(&vt), " : value` outside the function); a variable is `", name, ": ", ast_type_str(&vt), " = value`"))
        }
        init: Opt[Expr] = None
        if p.eat_p("=") {
            ie, ok3 := p.expr()
            if !ok3 {
                return parser_fail[SK]()
            }
            init = Some(ie)
        }
        return (SKVar(name, Some(vt), init), true)
    }
    // a nested function: `name :: (a: A) -> R { ... }`
    if parser_tk_id(p.peek()) && (parser_tk_p(p.peek_at(1), "::") || p.tparams_ahead()) {
        return p.nested_fn()
    }
    // multi-let: a, b := e
    if parser_tk_id(p.peek()) && parser_tk_p(p.peek_at(1), ",") {
        pos := p.pos()
        names := vec[str]()
        n1, ok1 := p.ident()
        if !ok1 {
            return parser_fail[SK]()
        }
        names.push(n1)
        while p.eat_p(",") {
            n2, ok2 := p.ident()
            if !ok2 {
                return parser_fail[SK]()
            }
            names.push(n2)
        }
        if p.eat_p("=") {
            e, ok3 := p.expr()
            if !ok3 {
                return parser_fail[SK]()
            }
            lhs := vec[Expr]()
            for n in names.items() {
                lhs.push(Expr{k: EKIdent(n), pos: pos})
            }
            return (SKMultiAssign(lhs, e), true)
        }
        if !p.expect_p(":=") {
            return parser_fail[SK]()
        }
        e, ok4 := p.expr()
        if !ok4 {
            return parser_fail[SK]()
        }
        return (SKLet(names, e), true)
    }
    e, ok1 := p.expr()
    if !ok1 {
        return parser_fail[SK]()
    }
    if p.eat_p(":=") {
        name := ""
        match e.k {
            EKIdent(n) => {
                name = n
            }
            _ => {
                p.errs.push(Diag{pos: e.pos, msg: "left side of `:=` must be an identifier"})
                return parser_fail[SK]()
            }
        }
        v, ok2 := p.expr()
        if !ok2 {
            return parser_fail[SK]()
        }
        return (SKLet(vec_of([]str{name}), v), true)
    }
    if p.eat_p("=") {
        v, ok2 := p.expr()
        if !ok2 {
            return parser_fail[SK]()
        }
        return (SKAssign(e, None, v), true)
    }
    op: Opt[BinOp] = None
    match p.peek() {
        TkP(q) => {
            match q {
                "+=" => {
                    op = Some(BinOpAdd)
                }
                "-=" => {
                    op = Some(BinOpSub)
                }
                "*=" => {
                    op = Some(BinOpMul)
                }
                "/=" => {
                    op = Some(BinOpDiv)
                }
                "%=" => {
                    op = Some(BinOpRem)
                }
                "&=" => {
                    op = Some(BinOpAnd)
                }
                "|=" => {
                    op = Some(BinOpOr)
                }
                "^=" => {
                    op = Some(BinOpXor)
                }
                "<<=" => {
                    op = Some(BinOpShl)
                }
                ">>=" => {
                    op = Some(BinOpShr)
                }
                _ => {}
            }
        }
        _ => {}
    }
    if is_some(op) {
        p.bump()
        v, ok2 := p.expr()
        if !ok2 {
            return parser_fail[SK]()
        }
        return (SKAssign(e, op, v), true)
    }
    return (SKExpr(e), true)
}

// ---------- expressions ----------
expr :: (p: *Parser) -> (Expr, bool) {
    return p.bin(1)
}

binop :: (p: *Parser) -> Opt[(BinOp, i64)] {
    q := ""
    match p.peek() {
        TkP(s) => {
            q = s
        }
        _ => {
            return None
        }
    }
    // precedence as in Rust: arithmetic, shifts, &, ^, |, comparisons, &&, ||
    match q {
        "*" => {
            return Some((BinOpMul, 9))
        }
        "/" => {
            return Some((BinOpDiv, 9))
        }
        "%" => {
            return Some((BinOpRem, 9))
        }
        "+" => {
            return Some((BinOpAdd, 8))
        }
        "-" => {
            return Some((BinOpSub, 8))
        }
        "<<" => {
            return Some((BinOpShl, 7))
        }
        ">>" => {
            return Some((BinOpShr, 7))
        }
        "&" => {
            return Some((BinOpAnd, 6))
        }
        "^" => {
            return Some((BinOpXor, 5))
        }
        "|" => {
            return Some((BinOpOr, 4))
        }
        "==" => {
            return Some((BinOpEq, 3))
        }
        "!=" => {
            return Some((BinOpNe, 3))
        }
        "<" => {
            return Some((BinOpLt, 3))
        }
        "<=" => {
            return Some((BinOpLe, 3))
        }
        ">" => {
            return Some((BinOpGt, 3))
        }
        ">=" => {
            return Some((BinOpGe, 3))
        }
        "&&" => {
            return Some((BinOpLAnd, 2))
        }
        "||" => {
            return Some((BinOpLOr, 1))
        }
        _ => {}
    }
    return None
}

bin :: (p: *Parser, min_prec: i64) -> (Expr, bool) {
    lhs, ok1 := p.unary()
    if !ok1 {
        return parser_fail[Expr]()
    }
    loop {
        op: BinOp = BinOpAdd
        prec := 0
        match p.binop() {
            Some(x) => {
                if x.1 >= min_prec {
                    op = x.0
                    prec = x.1
                } else {
                    break
                }
            }
            None => {
                break
            }
        }
        pos := p.pos()
        p.bump()
        rhs, ok2 := p.bin(prec + 1)
        if !ok2 {
            return parser_fail[Expr]()
        }
        lhs = Expr{k: EKBin(op, parser_box(lhs), parser_box(rhs)), pos: pos}
    }
    return (lhs, true)
}

unary :: (p: *Parser) -> (Expr, bool) {
    pos := p.pos()
    op: Opt[UnOp] = None
    match p.peek() {
        TkP(q) => {
            match q {
                "-" => {
                    op = Some(UnOpNeg)
                }
                "!" => {
                    op = Some(UnOpNot)
                }
                "~" => {
                    op = Some(UnOpBitNot)
                }
                "&" => {
                    op = Some(UnOpAddr)
                }
                "*" => {
                    op = Some(UnOpDeref)
                }
                _ => {}
            }
        }
        _ => {}
    }
    match op {
        Some(o) => {
            p.bump()
            e, ok := p.unary()
            if !ok {
                return parser_fail[Expr]()
            }
            return (Expr{k: EKUn(o, parser_box(e)), pos: pos}, true)
        }
        None => {}
    }
    return p.postfix()
}

parser_typeish :: (e: *Expr) -> bool {
    match e.k {
        EKIdent(n) => {
            return true
        }
        EKTypeE(t) => {
            return true
        }
        EKIndex(b, a) => {
            match b.k {
                EKIdent(n) => {
                    return true
                }
                _ => {}
            }
            return false
        }
        _ => {}
    }
    return false
}

// the closure in `args`
parser_args_r :: (p: *Parser, close: str, v: *Vec[Expr]) -> bool {
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

args :: (p: *Parser, close: str) -> (Vec[Expr], bool) {
    save := p.no_lit
    p.no_lit = false
    v := vec[Expr]()
    r := parser_args_r(p, close, &v)
    p.no_lit = save
    if !r {
        return parser_fail[Vec[Expr]]()
    }
    return (v, true)
}

postfix :: (p: *Parser) -> (Expr, bool) {
    e, ok1 := p.primary()
    if !ok1 {
        return parser_fail[Expr]()
    }
    loop {
        pos := p.pos()
        if p.eat_p("(") {
            a, ok2 := p.args(")")
            if !ok2 {
                return parser_fail[Expr]()
            }
            e = Expr{k: EKCall(parser_box(e), a), pos: pos}
        } else if p.eat_p("[") {
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.index_tail(e, pos)
            p.no_lit = save
            if !ok2 {
                return parser_fail[Expr]()
            }
            e = r
        } else if p.eat_p(".") {
            match p.bump() {
                TkId(n) => {
                    e = Expr{k: EKField(parser_box(e), n), pos: pos}
                }
                TkInt(n) => {
                    e = Expr{k: EKField(parser_box(e), fmt(n)), pos: pos}
                }
                _ => {
                    p.i -= 1
                    return p.err[Expr]("expected field name")
                }
            }
        } else if p.is_p("{") && parser_typeish(&e) && (!p.no_lit || p.lit_in_header(&e)) {
            p.bump()
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.lit_body()
            p.no_lit = save
            if !ok2 {
                return parser_fail[Expr]()
            }
            e = Expr{k: EKLit(parser_box(e), r), pos: pos}
        } else {
            break
        }
    }
    return (e, true)
}

index_tail :: (p: *Parser, base: Expr, pos: Pos) -> (Expr, bool) {
    if p.eat_p("..") {
        hi: Opt[*Expr] = None
        if !p.is_p("]") {
            h, ok := p.expr()
            if !ok {
                return parser_fail[Expr]()
            }
            hi = Some(parser_box(h))
        }
        if !p.expect_p("]") {
            return parser_fail[Expr]()
        }
        return (Expr{k: EKSlice(parser_box(base), None, hi), pos: pos}, true)
    }
    first, ok1 := p.expr()
    if !ok1 {
        return parser_fail[Expr]()
    }
    if p.eat_p("..") {
        hi: Opt[*Expr] = None
        if !p.is_p("]") {
            h, ok := p.expr()
            if !ok {
                return parser_fail[Expr]()
            }
            hi = Some(parser_box(h))
        }
        if !p.expect_p("]") {
            return parser_fail[Expr]()
        }
        return (Expr{k: EKSlice(parser_box(base), Some(parser_box(first)), hi), pos: pos}, true)
    }
    v := vec_of([]Expr{first})
    while p.eat_p(",") {
        e, ok := p.expr()
        if !ok {
            return parser_fail[Expr]()
        }
        v.push(e)
    }
    if !p.expect_p("]") {
        return parser_fail[Expr]()
    }
    return (Expr{k: EKIndex(parser_box(base), v), pos: pos}, true)
}

lit_body :: (p: *Parser) -> (Vec[(Opt[str], Expr)], bool) {
    v := vec[(Opt[str], Expr)]()
    loop {
        while parser_tk_nl(p.peek()) {
            p.bump()
        }
        if p.eat_p("}") {
            break
        }
        fname: Opt[str] = None
        match p.peek() {
            TkId(n) => {
                if parser_tk_p(p.peek_at(1), ":") {
                    fname = Some(n)
                }
            }
            _ => {}
        }
        if is_some(fname) {
            p.bump()
            p.bump()
            e, ok := p.expr()
            if !ok {
                return parser_fail[Vec[(Opt[str], Expr)]]()
            }
            v.push((fname, e))
        } else {
            e, ok := p.expr()
            if !ok {
                return parser_fail[Vec[(Opt[str], Expr)]]()
            }
            v.push((fname, e))
        }
        while parser_tk_nl(p.peek()) {
            p.bump()
        }
        if !p.eat_p(",") {
            while parser_tk_nl(p.peek()) {
                p.bump()
            }
            if !p.expect_p("}") {
                return parser_fail[Vec[(Opt[str], Expr)]]()
            }
            break
        }
    }
    return (v, true)
}

// the closure in `primary` for a parenthesized expression or tuple
parser_primary_r :: (p: *Parser, pos: Pos) -> (Expr, bool) {
    first, ok1 := p.expr()
    if !ok1 {
        return parser_fail[Expr]()
    }
    if p.is_p(",") {
        v := vec_of([]Expr{first})
        while p.eat_p(",") {
            if p.is_p(")") {
                break
            }
            e, ok2 := p.expr()
            if !ok2 {
                return parser_fail[Expr]()
            }
            v.push(e)
        }
        if !p.expect_p(")") {
            return parser_fail[Expr]()
        }
        return (Expr{k: EKTuple(v), pos: pos}, true)
    }
    if !p.expect_p(")") {
        return parser_fail[Expr]()
    }
    return (first, true)
}

primary :: (p: *Parser) -> (Expr, bool) {
    pos := p.pos()
    match p.peek() {
        TkInt(n) => {
            p.bump()
            return (Expr{k: EKInt(n), pos: pos}, true)
        }
        TkFloat(f) => {
            p.bump()
            return (Expr{k: EKFloat(f), pos: pos}, true)
        }
        TkStr(s) => {
            p.bump()
            return (Expr{k: EKStr(s), pos: pos}, true)
        }
        TkId(n) => {
            p.bump()
            return (Expr{k: EKIdent(n), pos: pos}, true)
        }
        TkKw(k) => {
            if k == "true" {
                p.bump()
                return (Expr{k: EKBool(true), pos: pos}, true)
            }
            if k == "false" {
                p.bump()
                return (Expr{k: EKBool(false), pos: pos}, true)
            }
            if k == "nil" {
                p.bump()
                return (Expr{k: EKNil, pos: pos}, true)
            }
            if k == "if" {
                p.bump()
                r, ok := p.if_stmt()
                if !ok {
                    return parser_fail[Expr]()
                }
                match r.2 {
                    Some(e) => {
                        return (Expr{k: EKIf(parser_box(r.0), r.1, e), pos: pos}, true)
                    }
                    None => {
                        p.errs.push(Diag{pos: pos, msg: "`if` used as an expression needs an `else` branch"})
                        return parser_fail[Expr]()
                    }
                }
            }
            if k == "match" {
                p.bump()
                scrut, ok1 := p.header_expr()
                if !ok1 {
                    return parser_fail[Expr]()
                }
                if !p.expect_p("{") {
                    return parser_fail[Expr]()
                }
                save := p.no_lit
                p.no_lit = false
                r, ok2 := p.match_arms()
                p.no_lit = save
                sb := parser_box(scrut)
                if !ok2 {
                    return parser_fail[Expr]()
                }
                return (Expr{k: EKMatch(sb, r), pos: pos}, true)
            }
            if k == "fn" {
                return p.fn_expr(pos)
            }
        }
        TkP(q) => {
            if q == "(" {
                if p.at_fn() {
                    return p.anon_fn(pos)
                }
                if p.at_old_params() {
                    p.bump()
                    pn, okn := p.ident()
                    return p.err[Expr](fmt("a parameter of an anonymous function is written `", pn, ": Type`: expected `:` after the name"))
                }
                if p.parens_then("->") {
                    t, ok := p.ty()
                    if !ok {
                        return parser_fail[Expr]()
                    }
                    return (Expr{k: EKTypeE(t), pos: pos}, true)
                }
                p.bump()
                save := p.no_lit
                p.no_lit = false
                r, ok := parser_primary_r(p, pos)
                p.no_lit = save
                return (r, ok)
            }
            if q == "[" {
                t, ok := p.ty()
                if !ok {
                    return parser_fail[Expr]()
                }
                return (Expr{k: EKTypeE(t), pos: pos}, true)
            }
        }
        _ => {}
    }
    return p.err[Expr]("expected expression")
}

// where an expression starts in the source (its `pos` may be that of an operator)
parser_expr_start :: (e: *Expr) -> Pos {
    match e.k {
        EKCall(c, _) => {
            return parser_expr_start(c)
        }
        EKField(b, _) => {
            return parser_expr_start(b)
        }
        EKIndex(b, _) => {
            return parser_expr_start(b)
        }
        EKBin(_, a, _) => {
            return parser_expr_start(a)
        }
        _ => {}
    }
    return e.pos
}

// A pattern is parsed as an expression and then read as a pattern: `_`, `Variant(p, ..)`,
// `Enum.Variant(p, ..)`, `Enum[T].Variant(p, ..)`, `(p, p)`, `&name`; anything else stays
// an expression (a constant, or a name that lowering resolves).
parser_pat :: (e: Expr) -> Pat {
    match e.k {
        EKIdent(n) => {
            if n == "_" {
                return PatWild
            }
        }
        EKCall(c, args) => {
            name := ""
            qual: Opt[*Expr] = None
            is_variant := false
            match c.k {
                EKIdent(n) => {
                    name = n
                    is_variant = true
                }
                EKField(q, n) => {
                    match q.k {
                        EKTypeE(_) => {}
                        _ => {
                            if parser_typeish(q) {
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
                    subs.push(parser_pat(args[i]))
                }
                return PatVariant(name, subs, parser_expr_start(c), qual)
            }
        }
        EKTuple(es) => {
            subs := vec[Pat]()
            for i in 0..es.len {
                subs.push(parser_pat(es[i]))
            }
            return PatTuple(subs, e.pos)
        }
        EKUn(op, x) => {
            if op == UnOpAddr {
                match x.k {
                    EKIdent(n) => {
                        return PatRef(n, e.pos)
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    return PatConst(e)
}

match_arms :: (p: *Parser) -> (Vec[MatchArm], bool) {
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
                return parser_fail[Vec[MatchArm]]()
            }
            pats.push(parser_pat(e))
            if !p.eat_p(",") {
                break
            }
        }
        guard: Opt[*Expr] = None
        if p.eat_kw("if") {
            g, ok := p.expr()
            if !ok {
                return parser_fail[Vec[MatchArm]]()
            }
            guard = Some(parser_box(g))
        }
        if !p.expect_p("=>") {
            return parser_fail[Vec[MatchArm]]()
        }
        body: Block
        if p.is_p("{") {
            b, ok := p.block()
            if !ok {
                return parser_fail[Vec[MatchArm]]()
            }
            body = b
        } else {
            s, ok := p.stmt()
            if !ok {
                return parser_fail[Vec[MatchArm]]()
            }
            body = Block{stmts: vec_of([]Stmt{s}), end: p.pos()}
        }
        arms.push(MatchArm{pats: pats, body: body, pos: pos, guard: guard})
        if !(parser_tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[Vec[MatchArm]]("expected end of match arm")
        }
    }
    return (arms, true)
}
