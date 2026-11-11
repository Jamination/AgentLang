// Parser for AL: tokens to AST. Results are (value, ok) pairs; ok = false after an error.

struct Parser {
    toks Vec[Token]
    i i64
    errs *Vec[Diag]
    no_lit bool
    // > 0 inside the `|...|` of a closure type or literal: there a `|` closes the list, so a
    // function or closure type cannot be followed by a result type that starts with `|`
    bars i64
}

fn parser_new(toks Vec[Token], errs *Vec[Diag]) Parser {
    return Parser{toks: toks, i: 0, errs: errs, no_lit: false}
}

// the failure result of a parsing function: (zero value, false)
fn parser_fail[T]() (T, bool) {
    var z T
    return (z, false)
}

// Box::new
fn parser_box[T](x T) *T {
    b := new[T]()
    *b = x
    return b
}

fn parser_tk_p(t Tk, p str) bool {
    match t {
        TkP(q) => {
            return q == p
        }
        _ => {}
    }
    return false
}

fn parser_tk_kw(t Tk, k str) bool {
    match t {
        TkKw(q) => {
            return q == k
        }
        _ => {}
    }
    return false
}

fn parser_tk_nl(t Tk) bool {
    match t {
        TkNl => {
            return true
        }
        _ => {}
    }
    return false
}

fn parser_tk_eof(t Tk) bool {
    match t {
        TkEof => {
            return true
        }
        _ => {}
    }
    return false
}

fn parser_tk_id(t Tk) bool {
    match t {
        TkId(s) => {
            return true
        }
        _ => {}
    }
    return false
}

fn parser_cont(s str, i i64, lo u8, hi u8) bool {
    return i < len(s) && s[i] >= lo && s[i] <= hi
}

// String::from_utf8_lossy: every maximal invalid part becomes U+FFFD
fn parser_utf8_lossy(s str) str {
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
            var lo u8 = 0x80
            var hi u8 = 0xBF
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
            var lo u8 = 0x80
            var hi u8 = 0xBF
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
    return out.buf[..out.len]
}

fn peek(p *Parser) Tk {
    return p.toks.buf[p.i].t
}

fn peek_at(p *Parser, n i64) Tk {
    j := min(p.i + n, p.toks.len - 1)
    return p.toks.buf[j].t
}

fn pos(p *Parser) Pos {
    return p.toks.buf[p.i].pos
}

fn bump(p *Parser) Tk {
    t := p.toks.buf[p.i].t
    if p.i < p.toks.len - 1 {
        p.i += 1
    }
    return t
}

fn is_p(p *Parser, s str) bool {
    return parser_tk_p(p.peek(), s)
}

fn is_kw(p *Parser, k str) bool {
    return parser_tk_kw(p.peek(), k)
}

fn eat_p(p *Parser, s str) bool {
    if p.is_p(s) {
        p.bump()
        return true
    } else {
        return false
    }
}

fn eat_kw(p *Parser, k str) bool {
    if p.is_kw(k) {
        p.bump()
        return true
    } else {
        return false
    }
}

fn tok_desc(p *Parser) str {
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

fn err[T](p *Parser, msg str) (T, bool) {
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
                hint = " (there is no `++`/`--`/`->`: use `x += 1`, and write result types without an arrow)"
            } else if q == ":" {
                hint = " (types follow names without a colon: `x i64`)"
            }
        }
        _ => {}
    }
    if hint == "" && p.i >= 1 {
        match p.toks.buf[p.i - 1].t {
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
    var z T
    return (z, false)
}

// (R<()> in the Rust source: only the ok flag)
fn expect_p(p *Parser, s str) bool {
    if p.eat_p(s) {
        return true
    } else {
        z, ok := p.err[bool](fmt("expected `", s, "`"))
        return ok
    }
}

fn ident(p *Parser) (str, bool) {
    match p.peek() {
        TkId(s) => {
            p.bump()
            return (s, true)
        }
        _ => {}
    }
    return p.err[str]("expected identifier")
}

fn skip_nl(p *Parser) {
    while parser_tk_nl(p.peek()) || p.is_p(";") {
        p.bump()
    }
}

// ---------- declarations ----------
fn file(p *Parser) Vec[Decl] {
    out := vec[Decl]()
    loop {
        p.skip_nl()
        if parser_tk_eof(p.peek()) {
            break
        }
        d, ok := p.decl()
        if ok {
            out.push(d)
        } else {
            p.sync_decl()
        }
    }
    return out
}

fn sync_decl(p *Parser) {
    // skip to the next top-level declaration keyword at line start
    depth := 0
    loop {
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
                if depth <= 0 && (k == "fn" || k == "struct" || k == "enum" || k == "const" || k == "var" || k == "test" || k == "use" || k == "inline" || k == "noinline" || k == "extern") {
                    if p.i > 0 && parser_tk_nl(p.toks.buf[p.i - 1].t) {
                        return
                    }
                }
            }
            _ => {}
        }
        p.bump()
    }
}

fn tparams(p *Parser) (Vec[str], bool) {
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

fn decl(p *Parser) (Decl, bool) {
    pos := p.pos()
    inl := 0
    if p.eat_kw("inline") {
        inl = 1
    } else if p.eat_kw("noinline") {
        inl = -1
    }
    if p.eat_kw("extern") {
        // extern "libfoo.so.1" fn name(args) Result     (a C function; no body)
        lib := ""
        match p.bump() {
            TkStr(s) => {
                lib = parser_utf8_lossy(s)
            }
            _ => {
                p.i -= 1
                return p.err[Decl]("expected a library name string after `extern`, e.g. `extern \"libc.so.6\" fn getpid() i32`")
            }
        }
        if !p.eat_kw("fn") {
            return p.err[Decl]("expected `fn` after the library name")
        }
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
        var ret Opt[TypeAst] = None
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
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[Decl]()
        }
        tparams, ok2 := p.tparams()
        if !ok2 {
            return parser_fail[Decl]()
        }
        if !p.expect_p("(") {
            return parser_fail[Decl]()
        }
        params := vec[(str, TypeAst)]()
        while !p.is_p(")") {
            pn, ok3 := p.ident()
            if !ok3 {
                return parser_fail[Decl]()
            }
            pt, ok4 := p.ty()
            if !ok4 {
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
        var ret Opt[TypeAst] = None
        if !p.is_p("{") {
            rt, ok5 := p.ty()
            if !ok5 {
                return parser_fail[Decl]()
            }
            ret = Some(rt)
        }
        body, ok6 := p.block()
        if !ok6 {
            return parser_fail[Decl]()
        }
        return (DeclFn(FnDecl{name: name, tparams: tparams, params: params, ret: ret, body: body, pos: pos, inl: inl, ext: None}), true)
    }
    if inl != 0 {
        return p.err[Decl]("expected `fn` after inline/noinline")
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
        var ty Opt[TypeAst] = None
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
        var ty Opt[TypeAst] = None
        if !p.is_p("=") {
            gt, ok2 := p.ty()
            if !ok2 {
                return parser_fail[Decl]()
            }
            ty = Some(gt)
        }
        var init Opt[Expr] = None
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
    return p.err[Decl]("expected declaration (fn, struct, enum, const, var, test, use, extern)")
}

// ---------- types ----------
fn starts_type(p *Parser) bool {
    match p.peek() {
        TkId(s) => {
            return true
        }
        TkP(q) => {
            return q == "*" || q == "[" || q == "(" || q == "|" || q == "||"
        }
        TkKw(k) => {
            return k == "fn"
        }
        _ => {}
    }
    return false
}

// does a result type follow a function or closure type?
fn starts_result(p *Parser) bool {
    if p.bars > 0 && (p.is_p("|") || p.is_p("||")) {
        return false
    }
    return p.starts_type()
}

// the `|` that closes the parameter list of a closure type or literal; a `||` token is
// split in two (`|f |i64||`)
fn close_bar(p *Parser) bool {
    if p.is_p("||") {
        t := p.toks.buf[p.i]
        p.toks.buf[p.i] = Token{t: TkP("|"), pos: t.pos, nl: false}
        p.toks.insert(p.i + 1, Token{t: TkP("|"), pos: Pos{file: t.pos.file, line: t.pos.line, col: t.pos.col + 1}, nl: t.nl})
    }
    return p.expect_p("|")
}

// A closure type can end a line (`var f |i64|`), but the lexer does not end a statement
// after `|`: it only marks the token, and the newline token is added here.
fn bar_newline(p *Parser) {
    if p.i > 0 && p.toks.buf[p.i - 1].nl && !parser_tk_nl(p.peek()) {
        p.toks.insert(p.i, Token{t: TkNl, pos: p.toks.buf[p.i - 1].pos, nl: false})
    }
}

// the parameter types of a closure type after the opening `|`, and the closing `|`
fn parser_closure_types(p *Parser, v *Vec[TypeAst]) bool {
    // (a `|` here starts a parameter that is itself a closure type: `| |i64| bool, i64|`)
    loop {
        t, ok := p.ty()
        if !ok {
            return false
        }
        v.push(t)
        if !p.eat_p(",") {
            break
        }
    }
    if !(p.is_p("|") || p.is_p("||")) && p.starts_type() {
        z, ok := p.err[bool]("a closure type lists only the parameter types, without names (`|i64, i64| bool`): expected `,` or `|`")
        return ok
    }
    return p.close_bar()
}

// the parameters `a A, b B` of a closure literal after the opening `|`, and the closing `|`
fn parser_closure_params(p *Parser, params *Vec[(str, TypeAst)]) bool {
    while !(p.is_p("|") || p.is_p("||")) {
        name, ok1 := p.ident()
        if !ok1 {
            return false
        }
        t, ok2 := p.ty()
        if !ok2 {
            return false
        }
        params.push((name, t))
        if !p.eat_p(",") {
            break
        }
    }
    return p.close_bar()
}

// `|a A, b B| R` of a closure literal; true if a `{` follows
fn closure_header(p *Parser, params *Vec[(str, TypeAst)], ret *Opt[*TypeAst]) bool {
    if !p.eat_p("||") {
        p.bump()
        save := p.bars
        p.bars = save + 1
        ok := parser_closure_params(p, params)
        p.bars = save
        if !ok {
            return false
        }
    }
    if !p.is_p("{") {
        rt, ok := p.ty()
        if !ok {
            return false
        }
        *ret = Some(parser_box(rt))
    }
    return p.is_p("{")
}

// At `|` or `||` where an expression starts: a closure literal `|a A| R { ... }`, or a
// closure type used as a type argument (`vec[|i64| bool]()`).
fn closure_expr(p *Parser, pos Pos) (Expr, bool) {
    start := p.i
    nerr := p.errs.len
    save := p.bars
    params := vec[(str, TypeAst)]()
    var ret Opt[*TypeAst] = None
    if p.closure_header(&params, &ret) {
        p.bars = 0
        body, ok := p.block()
        p.bars = save
        if !ok {
            return parser_fail[Expr]()
        }
        return (Expr{k: EKClosure(params, ret, parser_box(body)), pos: pos}, true)
    }
    p.i = start
    p.bars = save
    p.errs.truncate(nerr)
    if start > 0 && (parser_tk_nl(p.toks.buf[start - 1].t) || parser_tk_p(p.toks.buf[start - 1].t, "{") || parser_tk_p(p.toks.buf[start - 1].t, ";")) {
        // a statement that starts with `|` or `||` and is not a closure literal
        op := if p.is_p("||") { "||" } else { "|" }
        p.errs.push(Diag{pos: pos, msg: fmt("a line cannot start with the binary operator `", op, "` (end the previous line with it); a closure literal is written `|a i64, b i64| bool { a < b }`")})
        return parser_fail[Expr]()
    }
    t, ok := p.ty()
    p.bars = save
    if ok && !p.is_p("{") {
        return (Expr{k: EKTypeE(t), pos: pos}, true)
    }
    p.i = start
    p.errs.truncate(nerr)
    p.errs.push(Diag{pos: pos, msg: "expected a closure literal `|a i64, b i64| bool { a < b }` (every parameter has a name and a type, the result type follows the second `|`, the body is a block in braces) or a closure type `|i64, i64| bool`"})
    return parser_fail[Expr]()
}

fn ty(p *Parser) (TypeAst, bool) {
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
        // (inside brackets a `|` cannot close an enclosing closure parameter list)
        save_bars := p.bars
        p.bars = 0
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
        p.bars = save_bars
        return (TypeAstTuple(v), true)
    }
    if p.eat_kw("fn") {
        if !p.expect_p("(") {
            return parser_fail[TypeAst]()
        }
        save_bars := p.bars
        p.bars = 0
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
        p.bars = save_bars
        var ret Opt[*TypeAst] = None
        if p.starts_result() {
            rt, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            ret = Some(parser_box(rt))
        }
        return (TypeAstFn(v, ret), true)
    }
    if p.is_p("|") || p.is_p("||") {
        // closure type: |A, B| R
        v := vec[TypeAst]()
        if !p.eat_p("||") {
            p.bump()
            save_bars := p.bars
            p.bars = save_bars + 1
            ok := parser_closure_types(p, &v)
            p.bars = save_bars
            if !ok {
                return parser_fail[TypeAst]()
            }
        }
        p.bar_newline()
        var ret Opt[*TypeAst] = None
        if p.starts_result() {
            rt, ok := p.ty()
            if !ok {
                return parser_fail[TypeAst]()
            }
            ret = Some(parser_box(rt))
        }
        return (TypeAstClosure(v, ret), true)
    }
    match p.peek() {
        TkId(name) => {
            p.bump()
            args := vec[TypeAst]()
            if p.eat_p("[") {
                save_bars := p.bars
                p.bars = 0
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
                p.bars = save_bars
            }
            return (TypeAstName(name, args, pos), true)
        }
        _ => {}
    }
    return p.err[TypeAst]("expected type")
}

// ---------- statements ----------
fn block(p *Parser) (Block, bool) {
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

fn sync_stmt(p *Parser) {
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

fn header_expr(p *Parser) (Expr, bool) {
    save := p.no_lit
    p.no_lit = true
    e, ok := p.expr()
    p.no_lit = save
    return (e, ok)
}

fn if_stmt(p *Parser) ((Expr, Block, Opt[Block]), bool) {
    // `if` already consumed
    c, ok1 := p.header_expr()
    if !ok1 {
        return parser_fail[(Expr, Block, Opt[Block])]()
    }
    t, ok2 := p.block()
    if !ok2 {
        return parser_fail[(Expr, Block, Opt[Block])]()
    }
    j := p.i
    while parser_tk_nl(p.toks.buf[j].t) {
        j += 1
    }
    if parser_tk_kw(p.toks.buf[j].t, "else") {
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
            var eb Opt[Block] = Some(Block{stmts: vec_of([]Stmt{inner}), end: end})
            return ((c, t, eb), true)
        }
        e, ok4 := p.block()
        if !ok4 {
            return parser_fail[(Expr, Block, Opt[Block])]()
        }
        var eb Opt[Block] = Some(e)
        return ((c, t, eb), true)
    }
    var none Opt[Block] = None
    return ((c, t, none), true)
}

fn stmt(p *Parser) (Stmt, bool) {
    pos := p.pos()
    k, ok := p.stmt_k()
    if !ok {
        return parser_fail[Stmt]()
    }
    return (Stmt{k: k, pos: pos}, true)
}

fn stmt_k(p *Parser) (SK, bool) {
    if p.eat_kw("var") {
        name, ok1 := p.ident()
        if !ok1 {
            return parser_fail[SK]()
        }
        var ty Opt[TypeAst] = None
        if !p.is_p("=") {
            vt, ok2 := p.ty()
            if !ok2 {
                return parser_fail[SK]()
            }
            ty = Some(vt)
        }
        var init Opt[Expr] = None
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
        c, ok1 := p.header_expr()
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
        var v2 Opt[str] = None
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
        lo, ok3 := p.header_expr()
        if !ok3 {
            return parser_fail[SK]()
        }
        var hi Opt[Expr] = None
        incl := false
        if p.eat_p("..") {
            h, ok4 := p.header_expr()
            if !ok4 {
                return parser_fail[SK]()
            }
            hi = Some(h)
        } else if p.eat_p("..=") {
            h, ok4 := p.header_expr()
            if !ok4 {
                return parser_fail[SK]()
            }
            hi = Some(h)
            incl = true
        }
        var step Opt[Expr] = None
        if p.eat_kw("by") {
            st, ok5 := p.header_expr()
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
        return (SKBreak, true)
    }
    if p.eat_kw("continue") {
        return (SKContinue, true)
    }
    if p.eat_kw("assert") {
        c, ok1 := p.expr()
        if !ok1 {
            return parser_fail[SK]()
        }
        var m Opt[Expr] = None
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
    var op Opt[BinOp] = None
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
fn expr(p *Parser) (Expr, bool) {
    return p.bin(1)
}

fn binop(p *Parser) Opt[(BinOp, i64)] {
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

fn bin(p *Parser, min_prec i64) (Expr, bool) {
    lhs, ok1 := p.unary()
    if !ok1 {
        return parser_fail[Expr]()
    }
    loop {
        var op BinOp = BinOpAdd
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

fn unary(p *Parser) (Expr, bool) {
    pos := p.pos()
    var op Opt[UnOp] = None
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

fn parser_typeish(e *Expr) bool {
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
fn parser_args_r(p *Parser, close str, v *Vec[Expr]) bool {
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

fn args(p *Parser, close str) (Vec[Expr], bool) {
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

fn postfix(p *Parser) (Expr, bool) {
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
        } else if p.is_p("{") && !p.no_lit && parser_typeish(&e) {
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

fn index_tail(p *Parser, base Expr, pos Pos) (Expr, bool) {
    if p.eat_p("..") {
        var hi Opt[*Expr] = None
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
        var hi Opt[*Expr] = None
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

fn lit_body(p *Parser) (Vec[(Opt[str], Expr)], bool) {
    v := vec[(Opt[str], Expr)]()
    loop {
        while parser_tk_nl(p.peek()) {
            p.bump()
        }
        if p.eat_p("}") {
            break
        }
        var fname Opt[str] = None
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
fn parser_primary_r(p *Parser, pos Pos) (Expr, bool) {
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

fn primary(p *Parser) (Expr, bool) {
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
                if parser_tk_p(p.peek_at(1), "(") && parser_tk_id(p.peek_at(2)) && (parser_tk_id(p.peek_at(3)) || parser_tk_p(p.peek_at(3), "*") || parser_tk_kw(p.peek_at(3), "fn")) {
                    p.errs.push(Diag{pos: pos, msg: "an anonymous function is written as a closure literal: `|a i64, b i64| bool { a < b }` (`fn(A, B) R` is a function type)"})
                    return parser_fail[Expr]()
                }
                t, ok := p.ty()
                if !ok {
                    return parser_fail[Expr]()
                }
                return (Expr{k: EKTypeE(t), pos: pos}, true)
            }
        }
        TkP(q) => {
            if q == "|" || q == "||" {
                return p.closure_expr(pos)
            }
            if q == "(" {
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

fn match_arms(p *Parser) (Vec[MatchArm], bool) {
    arms := vec[MatchArm]()
    loop {
        p.skip_nl()
        if p.eat_p("}") {
            break
        }
        pos := p.pos()
        pats := vec[Pat]()
        loop {
            ppos := p.pos()
            is_id := false
            match p.peek() {
                TkId(n) => {
                    is_id = true
                    if n == "_" {
                        p.bump()
                        pats.push(PatWild)
                    } else if parser_tk_p(p.peek_at(1), "(") {
                        p.bump()
                        p.bump()
                        binds := vec[str]()
                        while !p.is_p(")") {
                            b, ok := p.ident()
                            if !ok {
                                return parser_fail[Vec[MatchArm]]()
                            }
                            binds.push(b)
                            if !p.eat_p(",") {
                                break
                            }
                        }
                        if !p.expect_p(")") {
                            return parser_fail[Vec[MatchArm]]()
                        }
                        pats.push(PatVariant(n, binds, ppos))
                    } else {
                        e, ok := p.expr()
                        if !ok {
                            return parser_fail[Vec[MatchArm]]()
                        }
                        pats.push(PatConst(e))
                    }
                }
                _ => {}
            }
            if !is_id {
                e, ok := p.expr()
                if !ok {
                    return parser_fail[Vec[MatchArm]]()
                }
                pats.push(PatConst(e))
            }
            if !p.eat_p(",") {
                break
            }
        }
        if !p.expect_p("=>") {
            return parser_fail[Vec[MatchArm]]()
        }
        var body Block
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
        arms.push(MatchArm{pats: pats, body: body, pos: pos})
        if !(parser_tk_nl(p.peek()) || p.is_p(";") || p.is_p("}")) {
            return p.err[Vec[MatchArm]]("expected end of match arm")
        }
    }
    return (arms, true)
}
