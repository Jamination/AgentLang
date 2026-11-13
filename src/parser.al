// Parser for AL: tokens to AST. Results are (value, ok) pairs; ok = false after an error.

priv struct Parser {
    toks: Vec[Token]
    i: i64
    errs: *Vec[Diag]
    // inside the header of `if`, `while`, `for` or `match`: `Name{` is not a literal
    no_lit: bool
    // index of the `{` after a header expression that ends in a name (`if x == Point {`), or -1
    hdr_name: i64
    // nesting of statements, expressions and `else if` chains (see `nest`): levels and the
    // stack they cost, the deepest values reached since the peaks were last reset, and the
    // stack budget (-1: unlimited)
    depth: i64
    cost: i64
    peak: i64
    cost_peak: i64
    budget: i64
    too_deep: bool
}

fn parser_new(toks: Vec[Token], errs: *Vec[Diag]) -> Parser {
    return Parser{toks: toks, errs: errs, hdr_name: -1, budget: stack_budget()}
}

// Deeper nesting is an error instead of a stack overflow of the parser and the later phases.
// The compiler gets a stack of 1 GB at startup (with_stack), enough for NEST_MAX levels of
// anything; where that is not possible, the stack each level costs (the largest frames of the
// parser and lowering on that path, measured) is counted against 3/4 of the stack there is.
priv const NEST_MAX = 2000
priv const COST_STMT = 112 * 1024
priv const COST_EXPR = 32 * 1024
priv const COST_LINK = 16 * 1024
priv const COST_ELSE_IF = 16 * 1024
priv const COST_SMALL = 8 * 1024

priv fn stack_budget() -> i64 {
    s := stack_size()
    if s < 0 {
        return -1
    }
    return s / 4 * 3
}

// enters one level of nesting that costs `c` bytes of stack; false (with an error, reported
// once per declaration) if it is too deep. A true result must be paired with `p.unnest(c)`
// (or restored counters).
priv fn nest(p: *Parser, c: i64) -> bool {
    if p.depth >= NEST_MAX || (p.budget >= 0 && p.cost + c > p.budget) {
        if !p.too_deep {
            p.too_deep = true
            limit := if p.depth >= NEST_MAX { fmt("than ", NEST_MAX) } else { fmt("than the stack limit of ", p.budget / 3 * 4 / 1024, " KB allows", if TARGET_OS == Windows { "" } else { " (raise it with `ulimit -s`)" }) }
            p.errs.push(Diag{pos: p.pos(), msg: fmt("nesting is too deep (more levels of blocks, statements, `else if`, operators, calls and parentheses ", limit, ")")})
        }
        return false
    }
    p.depth += 1
    p.cost += c
    p.peak = max(p.peak, p.depth)
    p.cost_peak = max(p.cost_peak, p.cost)
    return true
}

priv fn unnest(p: *Parser, c: i64) {
    p.depth -= 1
    p.cost -= c
}

// Before the first operand of a chain (`a + b + c`, `x.f(a)[i]`): the outer peaks, which the
// operand's own replace for a moment
priv fn operand_start(p: *Parser) -> (i64, i64) {
    saved := (p.peak, p.cost_peak)
    p.peak = p.depth
    p.cost_peak = p.cost
    return saved
}

// After the first operand of a chain: the chain's operators nest below everything inside
// that operand (`(x.f().f()).f()` is as deep as its three calls together), so counting
// continues at the operand's deepest level.
priv fn below_operand(p: *Parser, saved: (i64, i64)) {
    p.depth = p.peak
    p.cost = p.cost_peak
    p.peak = max(saved.0, p.peak)
    p.cost_peak = max(saved.1, p.cost_peak)
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

priv fn tk_id(t: Tk) -> bool {
    match t {
        Id(_) => true
        _ => false
    }
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
    fn cont(s: str, i: i64, lo: u8, hi: u8) -> bool {
        return i < len(s) && s[i] >= lo && s[i] <= hi
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
            out.extend(s[i..i + n])
        } else {
            out.extend("\xEF\xBF\xBD")
        }
        i += n
    }
    return out.items()
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

priv fn is_p(p: *Parser, c: i64) -> bool {
    match p.toks[p.i].t {
        P(q) => q == c
        _ => false
    }
}

// token i + n is the punctuation `c`
priv fn is_p_at(p: *Parser, n: i64, c: i64) -> bool {
    match p.peek_at(n) {
        P(q) => q == c
        _ => false
    }
}

priv fn is_kw(p: *Parser, k: i64) -> bool {
    match p.toks[p.i].t {
        Kw(q) => q == k
        _ => false
    }
}

priv fn eat_p(p: *Parser, c: i64) -> bool {
    if !p.is_p(c) {
        return false
    }
    p.bump()
    return true
}

priv fn eat_kw(p: *Parser, k: i64) -> bool {
    if !p.is_kw(k) {
        return false
    }
    p.bump()
    return true
}

priv fn tok_desc(p: *Parser) -> str {
    match p.peek() {
        Id(s) => fmt("identifier `", s, "`")
        Int(_, _), Float(_, _) => "number"
        Str(_) => "string"
        Kw(k) => fmt("keyword `", lexer_kw_text(k), "`")
        P(q) => fmt("`", lexer_p_text(q), "`")
        Nl => "end of line"
        Eof => "end of file"
    }
}

// words of other languages: the operators `and`, `or`, `not` anywhere, the others only where
// a statement or declaration starts (`let x = 5`, `switch x {`; a variable may be named `val`)
priv fn word_habit(p: *Parser, j: i64) -> str {
    s := match p.toks[j].t {
        Id(w) => w
        _ => return ""
    }
    match s {
        "and" => return " (use `&&`)"
        "or" => return " (use `||`)"
        "not" => return " (use `!`)"
        _ => {}
    }
    starts := j == 0
    if j > 0 {
        starts = match p.toks[j - 1].t {
            Nl, P('{'), P('}'), P(';'), Kw(KW_PRIV), Kw(KW_INLINE), Kw(KW_NOINLINE) => true
            _ => false
        }
    }
    if !starts {
        return ""
    }
    return match s {
        "let", "var", "mut", "auto", "val" => " (declare variables with `name := value` or `name: T = value`)"
        "func", "def", "function", "pub" => " (functions are declared `fn name(a: A) -> R { ... }`)"
        "type", "typedef", "using", "alias" => " (there are no type aliases: write the type out; a distinct type is a `struct`)"
        "import" => " (use `use \"file.al\"`)"
        "switch" => " (use `match`)"
        "elif", "elsif" => " (use `else if`)"
        _ => ""
    }
}

// tokens j and j + 1 are `++` or `--` written together
priv fn incr_at(p: *Parser, j: i64) -> bool {
    if j < 0 || j + 1 >= p.toks.len {
        return false
    }
    a := p.toks[j]
    b := p.toks[j + 1]
    same := match (a.t, b.t) {
        (P('+'), P('+')), (P('-'), P('-')) => true
        _ => false
    }
    return same && a.pos.line == b.pos.line && a.pos.col + 1 == b.pos.col
}

priv fn err[T](p: *Parser, msg: str) -> (T, bool) {
    d := p.tok_desc()
    // habits from other languages get a direct pointer to the AL spelling
    hint := ""
    match p.peek() {
        Id(_) => {
            hint = p.word_habit(p.i)
        }
        P(q) => {
            line_start := p.i >= 1 && p.toks[p.i - 1].t == Nl
            if p.incr_at(p.i - 1) || p.incr_at(p.i) {
                hint = " (there is no `++`/`--`: use `x += 1`)"
            } else if line_start && is_some(p.binop()) {
                hint = " (a line cannot start with a binary operator: to continue an expression on the next line, end the line with the operator)"
            } else if q == '.' && starts_with(msg, "expected expression") {
                match p.peek_at(1) {
                    Int(_, _) => { hint = " (a float literal has digits on both sides of the point: `0.5`, not `.5`)" }
                    Id(_) if line_start => { hint = " (a line cannot start with `.`: to continue a chain of calls on the next line, end the line with the `.`)" }
                    _ => {}
                }
            }
        }
        Kw(k) => {
            // a keyword where a name was meant: `by := 0`, `f(in, out)`, `x.type`,
            // `fn f(in: i64)`, `for match in ..`
            named := starts_with(msg, "expected identifier") || starts_with(msg, "expected field name")
            match p.peek_at(1) {
                P(P_DECL), P('='), P(':'), P(','), P(')'), P('.'), P(P_ADD_EQ), P(P_SUB_EQ) => { named = true }
                _ => {}
            }
            if named {
                hint = fmt(" (`", lexer_kw_text(k), "` is a keyword and cannot be used as a name)")
            }
        }
        _ => {}
    }
    // (`let x = 5`, `func main()`, `switch x`: the error is at the token after the foreign
    // word; `x--` at the end of a line: at the token after it)
    if hint == "" && p.i >= 1 {
        if tk_id(p.toks[p.i - 1].t) {
            hint = p.word_habit(p.i - 1)
        } else if p.incr_at(p.i - 2) {
            hint = " (there is no `++`/`--`: use `x += 1`)"
        }
    }
    p.errs.push(Diag{pos: p.pos(), msg: fmt(msg, ", found ", d, hint)})
    return fail[T]()
}

// consumes the punctuation `c` or reports that it was expected; false after an error
priv fn expect_p(p: *Parser, c: i64) -> bool {
    if p.eat_p(c) {
        return true
    }
    p.err[bool](fmt("expected `", lexer_p_text(c), "`"))
    return false
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
    while p.peek() == Nl || p.is_p(';') {
        p.bump()
    }
}

// ---------- declarations ----------
fn file(p: *Parser) -> Vec[Decl] {
    out := vec[Decl]()
    loop {
        p.skip_nl()
        if p.peek() == Eof {
            break
        }
        from := p.i
        p.too_deep = false
        d, ok := p.decl()
        if ok {
            out.push(d)
        } else {
            p.sync_decl(from, false)
        }
    }
    return out
}

// after an error in the declaration that starts at token `from`: skip to the next
// top-level declaration, a line that starts outside all braces with a declaration keyword
// or a name (a keyword in column 1 also inside braces: the declaration in error may lack
// a `}`). `inner`: the declaration is in the branch of a `when`, whose `}` ends the search.
priv fn sync_decl(p: *Parser, from: i64, inner: bool) {
    depth := 0
    for j in from..p.i {
        if p.toks[j].t == P('{') {
            depth += 1
        } else if p.toks[j].t == P('}') {
            depth -= 1
        }
    }
    if p.i == from {
        p.bump()
    }
    loop {
        starts := p.i > 0 && p.toks[p.i - 1].t == Nl
        match p.peek() {
            Eof => return
            P('{') => depth += 1
            P('}') => {
                if inner && depth <= 0 {
                    return
                }
                depth -= 1
            }
            Kw(KW_FN), Kw(KW_STRUCT), Kw(KW_ENUM), Kw(KW_CONST), Kw(KW_TEST), Kw(KW_USE), Kw(KW_INLINE), Kw(KW_NOINLINE), Kw(KW_EXTERN), Kw(KW_PRIV), Kw(KW_WHEN) if starts && (depth <= 0 || p.pos().col == 1) => return
            Id(_) if starts && depth <= 0 => return
            _ => {}
        }
        p.bump()
    }
}

priv fn tparams(p: *Parser) -> (Vec[str], bool) {
    v := vec[str]()
    if p.eat_p('[') {
        loop {
            name, ok := p.ident()
            if !ok {
                return fail[Vec[str]]()
            }
            v.push(name)
            if !p.eat_p(',') {
                break
            }
        }
        if !p.expect_p(']') {
            return fail[Vec[str]]()
        }
    }
    return (v, true)
}

// `priv` in front of a declaration: the declaration is visible only in its own file
priv fn priv_decl(p: *Parser) -> (Decl, bool) {
    ppos := p.pos()
    p.bump()
    if p.is_kw(KW_PRIV) {
        return p.err[Decl]("`priv` is written once in front of a declaration")
    }
    if p.is_kw(KW_TEST) {
        p.errs.push(Diag{pos: ppos, msg: "a `test` block cannot be `priv` (nothing refers to a test by name): remove `priv`"})
        return p.decl()
    }
    if p.is_kw(KW_USE) || p.is_kw(KW_WHEN) {
        what := if p.is_kw(KW_USE) { "`use` cannot be `priv` (a file is included into the whole program)" } else { "a `when` cannot be `priv` (write `priv` in front of the declarations inside it)" }
        p.errs.push(Diag{pos: ppos, msg: fmt(what, ": remove `priv`")})
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
        Global(g) => {
            if is_some(g.ext) {
                errs.push(Diag{pos: ppos, msg: fmt("an `extern` variable cannot be `priv`: `", g.name, "` is the library's global symbol, visible to the whole program; remove `priv`")})
            } else {
                g.is_priv = true
                g.pos = ppos
            }
            Global(g)
        }
        Test(_), Use(_, _), When(_) => d
    }
}

// ---------- functions ----------

// a function declaration without parameters, result and body
priv fn fn_head(name: str, tparams: Vec[str], pos: Pos, inl: i64, ext: Opt[str]) -> FnDecl {
    return FnDecl{name: name, tparams: tparams, body: Block{end: pos}, pos: pos, inl: inl, ext: ext}
}

// The result of a function or of a function type: `-> R`, or nothing. A function without a
// result has no arrow: `-> ()` is an error, and parsing goes on.
priv fn result(p: *Parser, ret: *Opt[TypeAst]) -> bool {
    rpos := p.pos()
    if !p.eat_p(P_ARROW) {
        return true
    }
    if p.is_p('(') && p.is_p_at(1, ')') {
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
    if !p.expect_p('(') {
        return false
    }
    while !p.is_p(')') {
        pn, ok1 := p.ident()
        if !ok1 {
            return false
        }
        if !p.eat_p(':') {
            p.err[bool]("expected `:` after the parameter name")
            return false
        }
        pt, ok2 := p.ty()
        if !ok2 {
            return false
        }
        d.params.push((pn, pt))
        if !p.eat_p(',') {
            break
        }
    }
    return p.expect_p(')') && p.result(&d.ret)
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
        if p.is_p('{') {
            return p.err[FnDecl](fmt("an `extern` function is a C function of the library and has no body: expected end of line after the declaration of `", d.name, "`"))
        }
        d.inl = -1
        return (d, true)
    }
    body := p.block()
    if body == nil {
        return fail[FnDecl]()
    }
    d.body = *body
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
    return p.fn_rest(fn_head(name, tparams, pos, inl, ext))
}

// At `fn` where an expression starts: an anonymous function `fn(a: A, b: B) -> R { ... }`
// (its parameters have names; without parameters a body follows), or a function type
// `fn(A, B) -> R` (a type argument, the type of a literal)
priv fn fn_expr(p: *Parser, pos: Pos) -> *Expr {
    if p.is_p_at(1, '[') {
        p.errs.push(Diag{pos: pos, msg: "an anonymous function cannot have type parameters of its own (it may use the type parameters of the enclosing function): write `fn(a: T) -> R { ... }`, or declare a generic function at the top level"})
        return nil
    }
    d := fn_head("", vec[str](), pos, 0, None)
    if tk_id(p.peek_at(2)) && p.is_p_at(3, ':') {
        p.bump()
        if !p.fn_sig(&d) {
            return nil
        }
    } else {
        t, ok := p.ty()
        if !ok {
            return nil
        }
        if !p.is_p('{') {
            return node(TypeE(parser_box(t)), pos)
        }
        // `fn() -> R { ... }`
        match t {
            Fn(ps, _) if !ps.is_empty() => {
                p.errs.push(Diag{pos: pos, msg: "an anonymous function names its parameters and gives each one a type, like any function: `fn(a: i64, b: i64) -> bool { a < b }` (`fn(A, B) -> R` alone is a function type)"})
                return nil
            }
            Fn(_, Some(rt)) => {
                d.ret = Some(*rt)
            }
            _ => {}
        }
    }
    body := p.block()
    if body == nil {
        return nil
    }
    d.body = *body
    return node(EK.Fn(parser_box(d)), pos)
}

// ---------- constants, types, variables ----------

// At `const`, `struct` or `enum`, where a declaration starts:
//   const NAME = value      const NAME: T = value      type Name = T
//   struct Name[T] { a: A, b: B }                      enum Name[T] { A, B(T) }
priv fn kw_decl(p: *Parser, pos: Pos) -> (Decl, bool) {
    if p.eat_kw(KW_CONST) {
        name, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        ty: Opt[TypeAst] = None
        if p.eat_p(':') {
            ct, ok2 := p.ty()
            if !ok2 {
                return fail[Decl]()
            }
            ty = Some(ct)
        }
        if !p.expect_p('=') {
            return fail[Decl]()
        }
        val := p.expr()
        if val == nil {
            return fail[Decl]()
        }
        return (Const(ConstDecl{name: name, ty: ty, val: *val, pos: pos}), true)
    }
    is_struct := p.is_kw(KW_STRUCT)
    if is_struct || p.is_kw(KW_ENUM) {
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
    if !p.expect_p('{') {
        return fail[Decl]()
    }
    fields := vec[(str, TypeAst)]()
    loop {
        p.skip_nl()
        if p.eat_p('}') {
            break
        }
        if p.is_kw(KW_PRIV) {
            return p.err[Decl]("a struct field cannot be `priv` (only top-level declarations can): write `priv struct` to make the whole struct private")
        }
        fname, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        if !p.eat_p(':') {
            return p.err[Decl]("expected `:` after the field name")
        }
        fty, ok2 := p.ty()
        if !ok2 {
            return fail[Decl]()
        }
        fields.push((fname, fty))
        p.eat_p(',')
    }
    return (Struct(StructDecl{name: name, tparams: tparams, fields: fields, pos: pos}), true)
}

// the body of an enum: `{ Variant, Variant(Type, ...), ... }`
priv fn enum_rest(p: *Parser, name: str, tparams: Vec[str], pos: Pos) -> (Decl, bool) {
    if !p.expect_p('{') {
        return fail[Decl]()
    }
    variants := vec[(str, Vec[TypeAst])]()
    loop {
        p.skip_nl()
        if p.eat_p('}') {
            break
        }
        if p.is_kw(KW_PRIV) {
            return p.err[Decl]("an enum variant cannot be `priv` (only top-level declarations can): write `priv enum` to make the enum type private")
        }
        vname, ok1 := p.ident()
        if !ok1 {
            return fail[Decl]()
        }
        tys := vec[TypeAst]()
        if p.eat_p('(') && !p.type_list(&tys) {
            return fail[Decl]()
        }
        variants.push((vname, tys))
        p.eat_p(',')
    }
    return (Enum(EnumDecl{name: name, tparams: tparams, variants: variants, pos: pos}), true)
}

// after the `:` of a variable (global or local): `T` or `T = value`
priv fn var_rest(p: *Parser) -> ((TypeAst, Opt[*Expr]), bool) {
    vt, ok1 := p.ty()
    if !ok1 {
        return fail[(TypeAst, Opt[*Expr])]()
    }
    init: Opt[*Expr] = None
    if p.eat_p('=') {
        ie := p.expr()
        if ie == nil {
            return fail[(TypeAst, Opt[*Expr])]()
        }
        init = Some(ie)
    }
    return ((vt, init), true)
}

// A declaration that starts with a name is a global variable: `name: T`, `name: T = value`,
// `name := value`
priv fn var_decl(p: *Parser, pos: Pos) -> (Decl, bool) {
    name, ok1 := p.ident()
    if p.eat_p(P_DECL) {
        ie := p.expr()
        if ie == nil {
            return fail[Decl]()
        }
        return (Global(GlobalDecl{name: name, ty: None, init: Some(*ie), pos: pos}), true)
    }
    if !p.eat_p(':') {
        return p.err[Decl](fmt("a declaration that starts with a name declares a variable, `", name, ": T` or `", name, " := value` (functions, types and constants start with `fn`, `struct`, `enum`, `const`): expected `:` or `:=`"))
    }
    v, ok3 := p.var_rest()
    if !ok3 {
        return fail[Decl]()
    }
    init: Opt[Expr] = match v.1 {
        Some(ie) => Some(*ie)
        None => None
    }
    return (Global(GlobalDecl{name: name, ty: Some(v.0), init: init, pos: pos}), true)
}

priv fn decl(p: *Parser) -> (Decl, bool) {
    if p.is_kw(KW_PRIV) {
        return p.priv_decl()
    }
    pos := p.pos()
    inl := 0
    if p.eat_kw(KW_INLINE) {
        inl = 1
    } else if p.eat_kw(KW_NOINLINE) {
        inl = -1
    }
    if p.is_kw(KW_PRIV) {
        return p.err[Decl]("`priv` is written first: `priv inline fn name(...)`")
    }
    ext: Opt[str] = None
    if p.eat_kw(KW_EXTERN) {
        // extern "libfoo.so.1" fn name(a: A) -> R     (a C function; no body)
        // extern "libfoo.so.1" name: T                (a C variable; no initializer)
        match p.peek() {
            Str(s) => {
                p.bump()
                ext = Some(utf8_lossy(s))
            }
            _ => return p.err[Decl]("expected a library name string after `extern`, e.g. `extern \"libc.so.6\" fn getpid() -> i32`")
        }
    }
    if p.is_kw(KW_FN) {
        f, ok := p.fn_decl(pos, inl, ext)
        if !ok {
            return fail[Decl]()
        }
        return (Fn(f), true)
    }
    if is_some(ext) && inl == 0 && tk_id(p.peek()) {
        d, ok := p.var_decl(pos)
        if !ok {
            return fail[Decl]()
        }
        return match d {
            Global(g) => {
                if is_some(g.init) {
                    p.errs.push(Diag{pos: pos, msg: fmt("the `extern` variable `", g.name, "` has no initializer: its value is in the library; write `extern \"lib\" ", g.name, ": T`")})
                }
                g.ext = ext
                (Global(g), true)
            }
            _ => (d, true)
        }
    }
    if inl != 0 {
        return p.err[Decl]("`inline`, `noinline` and `extern \"lib\"` stand in front of a function declaration: expected `fn`")
    }
    if is_some(ext) {
        return p.err[Decl]("`extern \"lib\"` stands in front of a C function or variable declaration (`extern \"lib\" fn name(a: A) -> R`, `extern \"lib\" name: T`): expected `fn` or a name")
    }
    if p.is_kw(KW_CONST) || p.is_kw(KW_STRUCT) || p.is_kw(KW_ENUM) {
        return p.kw_decl(pos)
    }
    if p.eat_kw(KW_TEST) {
        name := match p.peek() {
            Str(s) => utf8_lossy(s)
            _ => return p.err[Decl]("expected test name string")
        }
        p.bump()
        body := p.block()
        if body == nil {
            return fail[Decl]()
        }
        return (Test(TestDecl{name: name, body: *body, pos: pos}), true)
    }
    if p.eat_kw(KW_USE) {
        // use "file.al"   or   use std.name (a module bundled with the compiler)
        match (p.peek(), p.peek_at(1), p.peek_at(2)) {
            (Id("std"), P('.'), Id(b)) => {
                p.i += 3
                return (Use(fmt("std:", b), pos), true)
            }
            _ => {}
        }
        match p.peek() {
            Str(s) => {
                p.bump()
                return (Use(utf8_lossy(s), pos), true)
            }
            _ => return p.err[Decl]("expected a file path string or `std.<module>` after `use`")
        }
    }
    if p.eat_kw(KW_WHEN) {
        return p.when_decl(pos)
    }
    if tk_id(p.peek()) {
        return p.var_decl(pos)
    }
    return p.err[Decl]("expected a declaration: `fn`, `struct`, `enum`, `const`, a variable (`name: T`, `name := value`), `test`, `use`, `when`, `extern` or `priv`")
}

// ---------- when ----------

// after the `}` of a branch: `else` (also on the next line) is consumed
priv fn else_follows(p: *Parser) -> bool {
    j := p.i
    while p.toks[j].t == Nl {
        j += 1
    }
    match p.toks[j].t {
        Kw(KW_ELSE) => {
            p.i = j + 1
            return true
        }
        _ => return false
    }
}

// The branches of a `when` after the keyword: `cond { ... } else when cond { ... } else { ... }`.
// `top`: declarations (a top-level `when`), else statements.
priv fn when_arms(p: *Parser, top: bool) -> (Vec[WhenArm], bool) {
    arms := vec[WhenArm]()
    if !p.nest(COST_STMT) {
        return fail[Vec[WhenArm]]()
    }
    defer {
        p.unnest(COST_STMT)
    }
    cond: Opt[*Expr] = None
    last := false
    loop {
        if !last {
            c := p.header_expr()
            if c == nil {
                return fail[Vec[WhenArm]]()
            }
            cond = Some(c)
        }
        arm := WhenArm{cond: cond}
        if top {
            ds, ok := p.decl_block()
            if !ok {
                return fail[Vec[WhenArm]]()
            }
            arm.decls = ds
        } else {
            arm.body = p.block()
            if arm.body == nil {
                return fail[Vec[WhenArm]]()
            }
        }
        arms.push(arm)
        if last || !p.else_follows() {
            return (arms, true)
        }
        if !p.eat_kw(KW_WHEN) {
            if !p.is_p('{') {
                return p.err[Vec[WhenArm]]("expected `when` or `{` after `else` (a chain of compile-time choices is written `when a { } else when b { } else { }`)")
            }
            cond = None
            last = true
        }
    }
}

// `when cond { decls } ...` at top level
priv fn when_decl(p: *Parser, pos: Pos) -> (Decl, bool) {
    arms, ok := p.when_arms(true)
    if !ok {
        return fail[Decl]()
    }
    return (When(WhenDecl{arms: arms, pos: pos}), true)
}

// the declarations of a branch of a top-level `when`: `{ decl ... }`
priv fn decl_block(p: *Parser) -> (Vec[Decl], bool) {
    if !p.expect_p('{') {
        return fail[Vec[Decl]]()
    }
    save := p.no_lit
    p.no_lit = false
    out := vec[Decl]()
    loop {
        p.skip_nl()
        if p.is_p('}') || p.peek() == Eof {
            break
        }
        from := p.i
        d, ok := p.decl()
        if ok {
            out.push(d)
        } else {
            p.sync_decl(from, true)
        }
    }
    p.no_lit = save
    if !p.expect_p('}') {
        return fail[Vec[Decl]]()
    }
    return (out, true)
}

// ---------- types ----------

// types after a `(`, through the `)`
priv fn type_list(p: *Parser, v: *Vec[TypeAst]) -> bool {
    while !p.is_p(')') {
        t, ok := p.ty()
        if !ok {
            return false
        }
        v.push(t)
        if !p.eat_p(',') {
            break
        }
    }
    return p.expect_p(')')
}

priv fn ty(p: *Parser) -> (TypeAst, bool) {
    if !p.nest(COST_SMALL) {
        return fail[TypeAst]()
    }
    r := p.ty_in()
    p.unnest(COST_SMALL)
    return r
}

priv fn ty_in(p: *Parser) -> (TypeAst, bool) {
    pos := p.pos()
    if p.eat_p('*') {
        t, ok := p.ty()
        if !ok {
            return fail[TypeAst]()
        }
        return (Ptr(parser_box(t)), true)
    }
    if p.eat_p('[') {
        if p.eat_p(']') {
            t, ok := p.ty()
            if !ok {
                return fail[TypeAst]()
            }
            return (Slice(parser_box(t)), true)
        }
        save := p.no_lit
        p.no_lit = false
        n := p.expr()
        p.no_lit = save
        if n == nil {
            return fail[TypeAst]()
        }
        if p.is_p(',') {
            return p.err[TypeAst]("expected `]` (a slice literal is written `[]T{a, b}`, an array `[N]T{a, b}` or `[_]T{a, b}`)")
        }
        if !p.expect_p(']') {
            return fail[TypeAst]()
        }
        nb := n
        t, ok2 := p.ty()
        if !ok2 {
            return fail[TypeAst]()
        }
        return (Array(nb, parser_box(t)), true)
    }
    if p.eat_p('(') {
        v := vec[TypeAst]()
        if !p.type_list(&v) {
            return fail[TypeAst]()
        }
        return (Tuple(v), true)
    }
    if p.eat_kw(KW_FN) {
        // a function type: `fn(A, B) -> R`, without a result `fn(A, B)`
        v := vec[TypeAst]()
        rt: Opt[TypeAst] = None
        if !p.expect_p('(') || !p.type_list(&v) || !p.result(&rt) {
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
            if p.eat_p('[') {
                loop {
                    t, ok := p.ty()
                    if !ok {
                        return fail[TypeAst]()
                    }
                    args.push(t)
                    if !p.eat_p(',') {
                        break
                    }
                }
                if !p.expect_p(']') {
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
// Lists are collected on these stacks (each list on top of the ones that enclose it) and then
// copied into a Vec of their exact length
priv stmt_stack: Vec[Stmt]
priv expr_stack: Vec[Expr]
priv lit_stack: Vec[(Opt[str], Expr)]
priv arm_stack: Vec[MatchArm]
priv pat_stack: Vec[Pat]

// at the end of a statement: a newline, `;` or `}`
priv fn at_end(p: *Parser) -> bool {
    return match p.toks[p.i].t {
        Nl, P(';'), P('}') => true
        _ => false
    }
}

// a block on the heap; nil after an error
priv fn block(p: *Parser) -> *Block {
    // the body of a header that ends in a name: an error in its first statement is most
    // likely a `Name{...}` literal that was taken for the body
    after_name := p.hdr_name == p.i
    nerr := p.errs.len
    if !p.expect_p('{') {
        return nil
    }
    save := p.no_lit
    p.no_lit = false
    base := stmt_stack.len
    defer {
        stmt_stack.truncate(base)
    }
    loop {
        p.skip_nl()
        if p.is_p('}') || p.peek() == Eof {
            break
        }
        s, ok := p.stmt()
        if ok {
            stmt_stack.push(s)
            if !p.at_end() {
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
    if !p.expect_p('}') {
        return nil
    }
    b := new[Block]()
    b.stmts = vec_of(stmt_stack[base..])
    b.end = end
    return b
}

priv fn sync_stmt(p: *Parser) {
    depth := 0
    loop {
        match p.peek() {
            Eof => return
            Nl if depth == 0 => return
            P('{') => depth += 1
            P('}') => {
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

// `for cond {`: the tokens up to the `{` of the body (on the same line) contain no `in`
priv fn for_without_in(p: *Parser) -> bool {
    depth := 0
    for j in p.i..p.toks.len {
        match p.toks[j].t {
            Kw(KW_IN) => return false
            P('('), P('[') => { depth += 1 }
            P(')'), P(']') => { depth -= 1 }
            P('{') if depth == 0 => return j > p.i
            P('}'), Nl, Eof => return false
            _ => {}
        }
    }
    false
}

// the scrutinee of a `match`, the condition of an `if` or `while`, an expression of a `for` header
priv fn header_expr(p: *Parser) -> *Expr {
    save := p.no_lit
    p.no_lit = true
    e := p.expr()
    p.no_lit = save
    if e != nil && p.i >= 1 && p.is_p('{') && tk_id(p.toks[p.i - 1].t) {
        p.hdr_name = p.i
    }
    return e
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

// after `if`: the condition, the block and the `else` part; a nil condition after an error
priv fn if_stmt(p: *Parser) -> (*Expr, *Block, Opt[*Block]) {
    c := p.header_expr()
    if c == nil {
        return (nil, nil, None)
    }
    t := p.block()
    if t == nil {
        return (nil, nil, None)
    }
    if !p.else_follows() {
        return (c, t, None)
    }
    if p.is_kw(KW_IF) {
        pos := p.pos()
        p.bump()
        if !p.nest(COST_ELSE_IF) {
            return (nil, nil, None)
        }
        c2, t2, e2 := p.if_stmt()
        p.unnest(COST_ELSE_IF)
        if c2 == nil {
            return (nil, nil, None)
        }
        eb := new[Block]()
        eb.stmts = vec_one[Stmt](Stmt{k: If(c2, t2, e2), pos: pos})
        eb.end = t2.end
        return (c, t, Some(eb))
    }
    e := p.block()
    if e == nil {
        return (nil, nil, None)
    }
    return (c, t, Some(e))
}

priv fn stmt(p: *Parser) -> (Stmt, bool) {
    pos := p.pos()
    if !p.nest(COST_STMT) {
        return fail[Stmt]()
    }
    k, ok := p.stmt_k()
    p.unnest(COST_STMT)
    if !ok {
        return fail[Stmt]()
    }
    return (Stmt{k: k, pos: pos}, true)
}

priv fn stmt_k(p: *Parser) -> (SK, bool) {
    match p.peek() {
        Kw(KW_PRIV) => return p.err[SK]("`priv` applies to top-level declarations only; a local declaration is visible only in its block anyway")
        Kw(KW_EXTERN) => {
            p.errs.push(Diag{pos: p.pos(), msg: "`extern` declarations stand at top level: a C function or variable of a library cannot be declared inside a function"})
            return fail[SK]()
        }
        Kw(k) if k == KW_INLINE || k == KW_NOINLINE => {
            p.errs.push(Diag{pos: p.pos(), msg: fmt("`", lexer_kw_text(k), "` applies to top-level functions only: a nested function is declared as `fn name(a: A) -> R { ... }`")})
            return fail[SK]()
        }
        _ => {}
    }
    if p.is_kw(KW_FN) && tk_id(p.peek_at(1)) {
        f, ok := p.fn_decl(p.pos(), 0, None)
        if !ok {
            return fail[SK]()
        }
        return (Fn(parser_box(f)), true)
    }
    if p.is_kw(KW_CONST) || p.is_kw(KW_STRUCT) || p.is_kw(KW_ENUM) {
        p.errs.push(Diag{pos: p.pos(), msg: "constants and types (`const`, `struct`, `enum`) are declared at the top level, outside the function; inside a function there are variables (`name := value`) and nested functions (`fn name(...)`)"})
        return fail[SK]()
    }
    if p.eat_kw(KW_IF) {
        c, t, e := p.if_stmt()
        if c == nil {
            return fail[SK]()
        }
        return (If(c, t, e), true)
    }
    if p.eat_kw(KW_WHEN) {
        wpos := p.toks[p.i - 1].pos
        arms, ok := p.when_arms(false)
        if !ok {
            return fail[SK]()
        }
        return (When(parser_box(WhenDecl{arms: arms, pos: wpos})), true)
    }
    if p.eat_kw(KW_WHILE) {
        c := p.header_expr()
        if c == nil {
            return fail[SK]()
        }
        b := p.block()
        if b == nil {
            return fail[SK]()
        }
        return (While(c, b), true)
    }
    if p.eat_kw(KW_LOOP) {
        b := p.block()
        if b == nil {
            return fail[SK]()
        }
        return (Loop(b), true)
    }
    if p.eat_kw(KW_FOR) {
        if p.for_without_in() {
            p.errs.push(Diag{pos: p.toks[p.i - 1].pos, msg: "`for` without `in`: a loop on a condition is written `while cond { }`"})
            return fail[SK]()
        }
        v1, ok1 := p.ident()
        if !ok1 {
            return fail[SK]()
        }
        v2: Opt[str] = None
        if p.eat_p(',') {
            n2, ok2 := p.ident()
            if !ok2 {
                return fail[SK]()
            }
            v2 = Some(n2)
        }
        if !p.eat_kw(KW_IN) {
            return p.err[SK]("expected `in`")
        }
        lo := p.header_expr()
        if lo == nil {
            return fail[SK]()
        }
        hi: Opt[*Expr] = None
        incl := p.is_p(P_RANGE_EQ)
        if p.eat_p(P_RANGE) || p.eat_p(P_RANGE_EQ) {
            h := p.header_expr()
            if h == nil {
                return fail[SK]()
            }
            hi = Some(h)
        }
        step: Opt[*Expr] = None
        if p.eat_kw(KW_BY) {
            st := p.header_expr()
            if st == nil {
                return fail[SK]()
            }
            step = Some(st)
        }
        body := p.block()
        if body == nil {
            return fail[SK]()
        }
        return (For(parser_box(ForStmt{var1: v1, var2: v2, lo: lo, hi: hi, incl: incl, step: step, body: body})), true)
    }
    if p.eat_kw(KW_RETURN) {
        if p.at_end() {
            return (Return(None), true)
        }
        e := p.expr()
        if e == nil {
            return fail[SK]()
        }
        return (Return(Some(e)), true)
    }
    if p.eat_kw(KW_BREAK) {
        // a label must be on the same line (a newline after `break` ends the statement)
        match p.peek() {
            Id(label) => {
                p.bump()
                return (BreakTo(label), true)
            }
            _ => {}
        }
        if !p.at_end() {
            return p.err[SK]("`break` leaves a loop and takes at most a loop label (`break outer`): expected end of statement")
        }
        return (Break, true)
    }
    if p.eat_kw(KW_CONTINUE) {
        match p.peek() {
            Id(label) => {
                p.bump()
                return (ContinueTo(label), true)
            }
            _ => {}
        }
        if !p.at_end() {
            return p.err[SK]("`continue` takes at most a loop label (`continue outer`): expected end of statement")
        }
        return (Continue, true)
    }
    if p.eat_kw(KW_ASSERT) {
        c := p.expr()
        if c == nil {
            return fail[SK]()
        }
        m: Opt[*Expr] = None
        if p.eat_p(',') {
            me := p.expr()
            if me == nil {
                return fail[SK]()
            }
            m = Some(me)
        }
        return (Assert(c, m), true)
    }
    if p.eat_kw(KW_DEFER) {
        b := p.block()
        if b == nil {
            return fail[SK]()
        }
        return (Defer(b), true)
    }
    if p.is_p('{') {
        b := p.block()
        if b == nil {
            return fail[SK]()
        }
        return (Block(b), true)
    }
    // a labelled loop: `name: for ...`, `name: while ...`, `name: loop ...`
    if tk_id(p.peek()) && p.is_p_at(1, ':') {
        match p.peek_at(2) {
            Kw(KW_FOR), Kw(KW_WHILE), Kw(KW_LOOP) => {
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
            Kw(KW_IF), Kw(KW_MATCH), P('{') => {
                p.bump()
                p.bump()
                return p.err[SK]("a label names a loop: expected `for`, `while` or `loop` after the label")
            }
            _ => {}
        }
        // a variable: `name: T` (zero value) or `name: T = value`
        name, ok1 := p.ident()
        p.bump()
        v, ok2 := p.var_rest()
        if !ok2 {
            return fail[SK]()
        }
        return (Var(name, Some(parser_box(v.0)), v.1), true)
    }
    // multi-let: a, b := e
    start := p.i
    if tk_id(p.peek()) && p.is_p_at(1, ',') {
        pos := p.pos()
        names := vec[str]()
        n1, ok1 := p.ident()
        if !ok1 {
            return fail[SK]()
        }
        names.push(n1)
        only_names := true
        while p.eat_p(',') {
            if !tk_id(p.peek()) {
                only_names = false
                break
            }
            n2, _ := p.ident()
            names.push(n2)
        }
        if !only_names || !(p.is_p('=') || p.is_p(P_DECL)) {
            // not a list of names: places (`a.x, v[i] = f()`), handled below
            p.i = start
        } else if p.eat_p('=') {
            e := p.expr()
            if e == nil {
                return fail[SK]()
            }
            lhs := vec[Expr]()
            for n in names {
                lhs.push(Expr{k: Ident(n), pos: pos})
            }
            return (MultiAssign(lhs, e), true)
        } else {
            p.bump()
            e := p.expr()
            if e == nil {
                return fail[SK]()
            }
            return (Let(names, e), true)
        }
    }
    e := p.expr()
    if e == nil {
        return fail[SK]()
    }
    // `a.x, v[i] = f()`: the parts of a tuple go to several places
    if p.is_p(',') {
        lhs := vec_one[Expr](*e)
        while p.eat_p(',') {
            e2 := p.expr()
            if e2 == nil {
                return fail[SK]()
            }
            lhs.push(*e2)
        }
        if p.is_p(P_DECL) {
            return p.err[SK]("`:=` declares new variables, so its left side is a list of names; assign to existing places with `=`")
        }
        if !p.expect_p('=') {
            return fail[SK]()
        }
        v := p.expr()
        if v == nil {
            return fail[SK]()
        }
        return (MultiAssign(lhs, v), true)
    }
    if p.eat_p(P_DECL) {
        name := match e.k {
            Ident(n) => n
            _ => {
                p.errs.push(Diag{pos: e.pos, msg: "left side of `:=` must be an identifier"})
                return fail[SK]()
            }
        }
        v := p.expr()
        if v == nil {
            return fail[SK]()
        }
        return (Let(vec_one[str](name), v), true)
    }
    if p.eat_p('=') {
        v := p.expr()
        if v == nil {
            return fail[SK]()
        }
        return (Assign(e, None, v), true)
    }
    op: Opt[BinOp] = match p.peek() {
        P(P_ADD_EQ) => Some(Add)
        P(P_SUB_EQ) => Some(Sub)
        P(P_MUL_EQ) => Some(Mul)
        P(P_DIV_EQ) => Some(Div)
        P(P_REM_EQ) => Some(Rem)
        P(P_AND_EQ) => Some(And)
        P(P_OR_EQ) => Some(Or)
        P(P_XOR_EQ) => Some(Xor)
        P(P_SHL_EQ) => Some(Shl)
        P(P_SHR_EQ) => Some(Shr)
        _ => None
    }
    if is_some(op) {
        p.bump()
        v := p.expr()
        if v == nil {
            return fail[SK]()
        }
        return (Assign(e, op, v), true)
    }
    return (Expr(e), true)
}

// ---------- expressions ----------
// The expression parsers return the node on the heap, nil after an error.

priv fn node(k: EK, pos: Pos) -> *Expr {
    e := new[Expr]()
    e.k = k
    e.pos = pos
    return e
}

priv fn expr(p: *Parser) -> *Expr {
    if !p.nest(COST_EXPR) {
        return nil
    }
    r := p.bin(1)
    p.unnest(COST_EXPR)
    return r
}

priv fn binop(p: *Parser) -> Opt[(BinOp, i64)] {
    c := match p.toks[p.i].t {
        P(q) => q
        _ => return None
    }
    // precedence, tightest first: arithmetic, shifts, &, ^, |, comparisons, &&, ||
    return match c {
        '*' => Some((Mul, 9))
        '/' => Some((Div, 9))
        '%' => Some((Rem, 9))
        '+' => Some((Add, 8))
        '-' => Some((Sub, 8))
        P_SHL => Some((Shl, 7))
        P_SHR => Some((Shr, 7))
        '&' => Some((And, 6))
        '^' => Some((Xor, 5))
        '|' => Some((Or, 4))
        P_EQ => Some((Eq, 3))
        P_NE => Some((Ne, 3))
        '<' => Some((Lt, 3))
        P_LE => Some((Le, 3))
        '>' => Some((Gt, 3))
        P_GE => Some((Ge, 3))
        P_LAND => Some((LAnd, 2))
        P_LOR => Some((LOr, 1))
        _ => None
    }
}

priv fn bin(p: *Parser, min_prec: i64) -> *Expr {
    saved := (p.depth, p.cost)
    r := p.bin_chain(min_prec)
    p.depth, p.cost = saved
    return r
}

// each operator of a chain (`a + b + c`) nests the tree one level deeper, below the first
// operand
priv fn bin_chain(p: *Parser, min_prec: i64) -> *Expr {
    saved := p.operand_start()
    lhs := p.unary()
    if lhs == nil {
        return nil
    }
    p.below_operand(saved)
    loop {
        op, prec := match p.binop() {
            Some((o, pr)) if pr >= min_prec => (o, pr)
            _ => break
        }
        pos := p.pos()
        p.bump()
        if !p.nest(COST_SMALL) {
            return nil
        }
        rhs := p.bin(prec + 1)
        if rhs == nil {
            return nil
        }
        lhs = node(Bin(op, lhs, rhs), pos)
    }
    return lhs
}

priv fn unary(p: *Parser) -> *Expr {
    pos := p.pos()
    op: UnOp = match p.peek() {
        P('-') => Neg
        P('!') => Not
        P('~') => BitNot
        P('&') => Addr
        P('*') => Deref
        _ => return p.postfix()
    }
    p.bump()
    if !p.nest(COST_SMALL) {
        return nil
    }
    e := p.unary()
    p.unnest(COST_SMALL)
    if e == nil {
        return nil
    }
    return node(Un(op, e), pos)
}

priv fn typeish(e: *Expr) -> bool {
    match e.k {
        Ident(_), TypeE(_) => true
        Index(b, _) => match b.k { Ident(_) => true; _ => false }
        _ => false
    }
}

priv fn args(p: *Parser, close: i64) -> (Vec[Expr], bool) {
    save := p.no_lit
    p.no_lit = false
    base := expr_stack.len
    defer {
        expr_stack.truncate(base)
        p.no_lit = save
    }
    while !p.is_p(close) {
        e := p.expr()
        if e == nil {
            return fail[Vec[Expr]]()
        }
        expr_stack.push(*e)
        if !p.eat_p(',') {
            break
        }
    }
    if !p.expect_p(close) {
        return fail[Vec[Expr]]()
    }
    return (vec_of(expr_stack[base..]), true)
}

priv fn postfix(p: *Parser) -> *Expr {
    // each link of a chain (`x.f(a)[i].g`) nests the tree one level deeper
    saved := (p.depth, p.cost)
    r := p.postfix_links()
    p.depth, p.cost = saved
    return r
}

priv fn postfix_links(p: *Parser) -> *Expr {
    saved := p.operand_start()
    e := p.primary()
    if e == nil {
        return nil
    }
    p.below_operand(saved)
    loop {
        // (a method call `.f(a)` is one level)
        method := match e.k {
            Field(_, _) => p.is_p('(')
            _ => false
        }
        if (p.is_p('(') || p.is_p('[') || p.is_p('.')) && !method && !p.nest(COST_LINK) {
            return nil
        }
        pos := p.pos()
        if p.eat_p('(') {
            a, ok2 := p.args(')')
            if !ok2 {
                return nil
            }
            e = node(Call(e, a), pos)
        } else if p.eat_p('[') {
            save := p.no_lit
            p.no_lit = false
            r := p.index_tail(e, pos)
            p.no_lit = save
            if r == nil {
                return nil
            }
            e = r
        } else if p.eat_p('.') {
            // `1.` (a float without digits after the point): the `.` ends the line or is
            // not followed by a name (`5.double()` is a method call)
            match e.k {
                Int(n, _) if p.pos().line != pos.line || !tk_id(p.peek()) => {
                    p.errs.push(Diag{pos: pos, msg: fmt("a float literal has digits on both sides of the point: write `", n, ".0`, not `", n, ".`")})
                    return nil
                }
                _ => {}
            }
            match p.peek() {
                Id(n) => e = node(Field(e, n), pos)
                Int(n, _) => e = node(Field(e, fmt(n)), pos)
                _ => {
                    p.err[bool]("expected field name")
                    return nil
                }
            }
            p.bump()
        } else if p.is_p('{') && typeish(e) && (!p.no_lit || lit_in_header(e)) {
            p.bump()
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.lit_body()
            p.no_lit = save
            if !ok2 {
                return nil
            }
            // `[_]T{...}`: the length is the number of elements
            match e.k {
                TypeE(Array(n, t)) => match n.k {
                    Ident("_") => e.k = TypeE(parser_box(TypeAst.Array(node(Int(u64(r.len), true), n.pos), t)))
                    _ => {}
                }
                _ => {}
            }
            e = node(Lit(e, r), pos)
        } else {
            break
        }
    }
    return e
}

priv fn index_tail(p: *Parser, base: *Expr, pos: Pos) -> *Expr {
    lo: Opt[*Expr] = None
    if !p.eat_p(P_RANGE) {
        first := p.expr()
        if first == nil {
            return nil
        }
        if !p.eat_p(P_RANGE) {
            // an index: `a[i]`, `f[T, U]`
            sb := expr_stack.len
            defer {
                expr_stack.truncate(sb)
            }
            expr_stack.push(*first)
            while p.eat_p(',') {
                e := p.expr()
                if e == nil {
                    return nil
                }
                expr_stack.push(*e)
            }
            if !p.expect_p(']') {
                return nil
            }
            return node(Index(base, vec_of(expr_stack[sb..])), pos)
        }
        lo = Some(first)
    }
    hi: Opt[*Expr] = None
    if !p.is_p(']') {
        h := p.expr()
        if h == nil {
            return nil
        }
        hi = Some(h)
    }
    if !p.expect_p(']') {
        return nil
    }
    return node(Slice(base, lo, hi), pos)
}

priv fn lit_body(p: *Parser) -> (Vec[(Opt[str], Expr)], bool) {
    sb := lit_stack.len
    defer {
        lit_stack.truncate(sb)
    }
    loop {
        while p.peek() == Nl {
            p.bump()
        }
        if p.eat_p('}') {
            break
        }
        fname: Opt[str] = match p.peek() {
            Id(n) if p.is_p_at(1, ':') => Some(n)
            _ => None
        }
        if is_some(fname) {
            p.bump()
            p.bump()
        }
        e := p.expr()
        if e == nil {
            return fail[Vec[(Opt[str], Expr)]]()
        }
        lit_stack.push((fname, *e))
        while p.peek() == Nl {
            p.bump()
        }
        if !p.eat_p(',') {
            if !p.expect_p('}') {
                return fail[Vec[(Opt[str], Expr)]]()
            }
            break
        }
    }
    return (vec_of(lit_stack[sb..]), true)
}

// a parenthesized expression or a tuple, after the `(`
priv fn paren(p: *Parser, pos: Pos) -> *Expr {
    save := p.no_lit
    p.no_lit = false
    defer {
        p.no_lit = save
    }
    first := p.expr()
    if first == nil {
        return nil
    }
    if p.is_p(',') {
        sb := expr_stack.len
        defer {
            expr_stack.truncate(sb)
        }
        expr_stack.push(*first)
        while p.eat_p(',') {
            if p.is_p(')') {
                break
            }
            e := p.expr()
            if e == nil {
                return nil
            }
            expr_stack.push(*e)
        }
        if !p.expect_p(')') {
            return nil
        }
        return node(Tuple(vec_of(expr_stack[sb..])), pos)
    }
    if !p.expect_p(')') {
        return nil
    }
    return first
}

priv fn primary(p: *Parser) -> *Expr {
    pos := p.pos()
    k: EK = match p.peek() {
        Int(n, dec) => EK.Int(n, dec)
        Float(f, g) => EK.Float(f, g)
        Str(s) => EK.Str(s)
        Id(n) => Ident(n)
        Kw(KW_TRUE) => Bool(true)
        Kw(KW_FALSE) => Bool(false)
        Kw(KW_NIL) => Nil
        Kw(KW_IF) => {
            p.bump()
            c, t, eo := p.if_stmt()
            if c == nil {
                return nil
            }
            match eo {
                Some(e) => return node(If(c, t, e), pos)
                None => {
                    p.errs.push(Diag{pos: pos, msg: "`if` used as an expression needs an `else` branch"})
                    return nil
                }
            }
        }
        Kw(KW_MATCH) => {
            p.bump()
            scrut := p.header_expr()
            if scrut == nil {
                return nil
            }
            if !p.expect_p('{') {
                return nil
            }
            save := p.no_lit
            p.no_lit = false
            r, ok2 := p.match_arms()
            p.no_lit = save
            if !ok2 {
                return nil
            }
            return node(Match(scrut, r), pos)
        }
        Kw(KW_FN) => return p.fn_expr(pos)
        P('(') => {
            p.bump()
            return p.paren(pos)
        }
        P('[') => {
            t, ok := p.ty()
            if !ok {
                return nil
            }
            return node(TypeE(parser_box(t)), pos)
        }
        _ => {
            p.err[bool]("expected expression")
            return nil
        }
    }
    p.bump()
    return node(k, pos)
}

// where an expression starts in the source (its `pos` may be that of an operator)
fn parser_expr_start(e: *Expr) -> Pos {
    match e.k {
        Call(b, _), Field(b, _), Index(b, _), Bin(_, b, _) => parser_expr_start(b)
        _ => e.pos
    }
}

// the patterns of a list of expressions (a Vec of exactly their number)
priv fn pats(es: *Vec[Expr]) -> Vec[Pat] {
    subs := alloc[Pat](es.len)
    for i in 0..es.len {
        subs[i] = pat(&es[i])
    }
    return Vec[Pat]{buf: subs, len: es.len}
}

// A pattern is parsed as an expression and then read as a pattern: `_`, `Variant(p, ..)`,
// `Enum.Variant(p, ..)`, `Enum[T].Variant(p, ..)`, `(p, p)`, `&name`; anything else stays
// an expression (a constant, or a name that lowering resolves).
priv fn pat(e: *Expr) -> Pat {
    match e.k {
        Ident("_") => return Wild
        Call(c, args) => {
            match c.k {
                Ident(n) => return Variant(n, pats(&args), parser_expr_start(c), None)
                // lowering reads the qualifier from the whole expression (if it is not an
                // enum, `x.f(a)` is an ordinary call)
                Field(q, n) if typeish(q) && !lit_in_header(q) => return Variant(n, pats(&args), parser_expr_start(c), Some(e))
                _ => {}
            }
        }
        Tuple(es) => return Pat.Tuple(pats(&es), e.pos)
        Un(Addr, x) => {
            match x.k {
                Ident(n) => return Ref(n, e.pos)
                _ => {}
            }
        }
        _ => {}
    }
    return Const(*e)
}

priv fn match_arms(p: *Parser) -> (Vec[MatchArm], bool) {
    ab := arm_stack.len
    defer {
        arm_stack.truncate(ab)
    }
    loop {
        p.skip_nl()
        if p.eat_p('}') {
            break
        }
        pos := p.pos()
        pb := pat_stack.len
        defer {
            pat_stack.truncate(pb)
        }
        loop {
            e := p.expr()
            if e == nil {
                return fail[Vec[MatchArm]]()
            }
            pat_stack.push(pat(e))
            if !p.eat_p(',') {
                break
            }
        }
        ps := vec_of(pat_stack[pb..])
        guard: Opt[*Expr] = None
        if p.eat_kw(KW_IF) {
            g := p.expr()
            if g == nil {
                return fail[Vec[MatchArm]]()
            }
            guard = Some(g)
        }
        if !p.expect_p(P_FAT_ARROW) {
            return fail[Vec[MatchArm]]()
        }
        body: Block
        if p.is_p('{') {
            b := p.block()
            if b == nil {
                return fail[Vec[MatchArm]]()
            }
            body = *b
        } else {
            s, ok := p.stmt()
            if !ok {
                return fail[Vec[MatchArm]]()
            }
            body = Block{stmts: vec_one[Stmt](s), end: p.pos()}
        }
        arm_stack.push(MatchArm{pats: ps, body: body, pos: pos, guard: guard})
        if !p.at_end() {
            return p.err[Vec[MatchArm]]("expected end of match arm")
        }
    }
    return (vec_of(arm_stack[ab..]), true)
}
