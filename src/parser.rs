use crate::ast::*;
use crate::lexer::{Tk, Token};

type R<T> = Result<T, ()>;

pub struct Parser<'a> {
    toks: Vec<Token>,
    i: usize,
    errs: &'a mut Vec<Diag>,
    no_lit: bool,
}

impl<'a> Parser<'a> {
    pub fn new(toks: Vec<Token>, errs: &'a mut Vec<Diag>) -> Self {
        Parser { toks, i: 0, errs, no_lit: false }
    }

    fn peek(&self) -> &Tk {
        &self.toks[self.i].t
    }
    fn peek_at(&self, n: usize) -> &Tk {
        let j = (self.i + n).min(self.toks.len() - 1);
        &self.toks[j].t
    }
    fn pos(&self) -> Pos {
        self.toks[self.i].pos
    }
    fn bump(&mut self) -> Tk {
        let t = self.toks[self.i].t.clone();
        if self.i < self.toks.len() - 1 {
            self.i += 1;
        }
        t
    }
    fn is_p(&self, p: &str) -> bool {
        matches!(self.peek(), Tk::P(q) if *q == p)
    }
    fn is_kw(&self, k: &str) -> bool {
        matches!(self.peek(), Tk::Kw(q) if *q == k)
    }
    fn eat_p(&mut self, p: &str) -> bool {
        if self.is_p(p) {
            self.bump();
            true
        } else {
            false
        }
    }
    fn eat_kw(&mut self, k: &str) -> bool {
        if self.is_kw(k) {
            self.bump();
            true
        } else {
            false
        }
    }
    fn tok_desc(&self) -> String {
        match self.peek() {
            Tk::Id(s) => format!("identifier `{}`", s),
            Tk::Int(_) | Tk::Float(_) => "number".into(),
            Tk::Str(_) => "string".into(),
            Tk::Kw(k) => format!("keyword `{}`", k),
            Tk::P(p) => format!("`{}`", p),
            Tk::Nl => "end of line".into(),
            Tk::Eof => "end of file".into(),
        }
    }
    fn err<T>(&mut self, msg: &str) -> R<T> {
        let d = self.tok_desc();
        // habits from other languages get a direct pointer to the AL spelling
        let hint = match self.peek() {
            Tk::Id(s) => match s.as_str() {
                "let" | "mut" | "auto" | "val" => " (declare variables with `name := value` or `var name T`)",
                "func" | "def" | "function" | "pub" => " (functions are declared with `fn name(args) Result { }`)",
                "and" => " (use `&&`)",
                "or" => " (use `||`)",
                "not" => " (use `!`)",
                "import" => " (use `use \"file.al\"`)",
                "switch" => " (use `match`)",
                "elif" | "elsif" => " (use `else if`)",
                _ => "",
            },
            Tk::P(p) if *p == "+" || *p == "-" => " (there is no `++`/`--`/`->`: use `x += 1`, and write result types without an arrow)",
            Tk::P(p) if *p == ":" => " (types follow names without a colon: `x i64`)",
            _ => "",
        };
        self.errs.push(Diag { pos: self.pos(), msg: format!("{}, found {}{}", msg, d, hint) });
        Err(())
    }
    fn expect_p(&mut self, p: &str) -> R<()> {
        if self.eat_p(p) {
            Ok(())
        } else {
            self.err(&format!("expected `{}`", p))
        }
    }
    fn ident(&mut self) -> R<String> {
        if let Tk::Id(s) = self.peek().clone() {
            self.bump();
            Ok(s)
        } else {
            self.err("expected identifier")
        }
    }
    fn skip_nl(&mut self) {
        while matches!(self.peek(), Tk::Nl) || self.is_p(";") {
            self.bump();
        }
    }

    // ---------- declarations ----------
    pub fn file(&mut self) -> Vec<Decl> {
        let mut out = Vec::new();
        loop {
            self.skip_nl();
            if matches!(self.peek(), Tk::Eof) {
                break;
            }
            match self.decl() {
                Ok(d) => out.push(d),
                Err(()) => self.sync_decl(),
            }
        }
        out
    }

    fn sync_decl(&mut self) {
        // skip to the next top-level declaration keyword at line start
        let mut depth = 0i32;
        loop {
            match self.peek() {
                Tk::Eof => return,
                Tk::P("{") => depth += 1,
                Tk::P("}") => depth -= 1,
                Tk::Kw(k) if depth <= 0 && matches!(*k, "fn" | "struct" | "enum" | "const" | "var" | "test" | "use" | "inline" | "noinline") => {
                    if self.i > 0 && matches!(self.toks[self.i - 1].t, Tk::Nl) {
                        return;
                    }
                }
                _ => {}
            }
            self.bump();
        }
    }

    fn tparams(&mut self) -> R<Vec<String>> {
        let mut v = Vec::new();
        if self.eat_p("[") {
            loop {
                v.push(self.ident()?);
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p("]")?;
        }
        Ok(v)
    }

    fn decl(&mut self) -> R<Decl> {
        let pos = self.pos();
        let mut inline = 0i8;
        if self.eat_kw("inline") {
            inline = 1;
        } else if self.eat_kw("noinline") {
            inline = -1;
        }
        if self.eat_kw("fn") {
            let name = self.ident()?;
            let tparams = self.tparams()?;
            self.expect_p("(")?;
            let mut params = Vec::new();
            while !self.is_p(")") {
                let pn = self.ident()?;
                let pt = self.ty()?;
                params.push((pn, pt));
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p(")")?;
            let ret = if self.is_p("{") { None } else { Some(self.ty()?) };
            let body = self.block()?;
            return Ok(Decl::Fn(FnDecl { name, tparams, params, ret, body, pos, inline }));
        }
        if inline != 0 {
            return self.err("expected `fn` after inline/noinline");
        }
        if self.eat_kw("struct") {
            let name = self.ident()?;
            let tparams = self.tparams()?;
            self.expect_p("{")?;
            let mut fields = Vec::new();
            loop {
                self.skip_nl();
                if self.eat_p("}") {
                    break;
                }
                let fname = self.ident()?;
                let fty = self.ty()?;
                fields.push((fname, fty));
                self.eat_p(",");
            }
            return Ok(Decl::Struct(StructDecl { name, tparams, fields, pos }));
        }
        if self.eat_kw("enum") {
            let name = self.ident()?;
            let tparams = self.tparams()?;
            self.expect_p("{")?;
            let mut variants = Vec::new();
            loop {
                self.skip_nl();
                if self.eat_p("}") {
                    break;
                }
                let vname = self.ident()?;
                let mut tys = Vec::new();
                if self.eat_p("(") {
                    while !self.is_p(")") {
                        tys.push(self.ty()?);
                        if !self.eat_p(",") {
                            break;
                        }
                    }
                    self.expect_p(")")?;
                }
                variants.push((vname, tys));
                self.eat_p(",");
            }
            return Ok(Decl::Enum(EnumDecl { name, tparams, variants, pos }));
        }
        if self.eat_kw("const") {
            let name = self.ident()?;
            let ty = if self.is_p("=") { None } else { Some(self.ty()?) };
            self.expect_p("=")?;
            let val = self.expr()?;
            return Ok(Decl::Const(ConstDecl { name, ty, val, pos }));
        }
        if self.eat_kw("var") {
            let name = self.ident()?;
            let ty = if self.is_p("=") { None } else { Some(self.ty()?) };
            let init = if self.eat_p("=") { Some(self.expr()?) } else { None };
            return Ok(Decl::Global(GlobalDecl { name, ty, init, pos }));
        }
        if self.eat_kw("test") {
            let name = match self.bump() {
                Tk::Str(s) => String::from_utf8_lossy(&s).to_string(),
                _ => {
                    self.i -= 1;
                    return self.err("expected test name string");
                }
            };
            let body = self.block()?;
            return Ok(Decl::Test(TestDecl { name, body, pos }));
        }
        if self.eat_kw("use") {
            return match self.bump() {
                Tk::Str(s) => Ok(Decl::Use(String::from_utf8_lossy(&s).to_string(), pos)),
                _ => {
                    self.i -= 1;
                    self.err("expected file path string after `use`")
                }
            };
        }
        self.err("expected declaration (fn, struct, enum, const, var, test, use)")
    }

    // ---------- types ----------
    fn starts_type(&self) -> bool {
        match self.peek() {
            Tk::Id(_) => true,
            Tk::P(p) => matches!(*p, "*" | "[" | "("),
            Tk::Kw(k) => *k == "fn",
            _ => false,
        }
    }

    pub fn ty(&mut self) -> R<TypeAst> {
        let pos = self.pos();
        if self.eat_p("*") {
            return Ok(TypeAst::Ptr(Box::new(self.ty()?)));
        }
        if self.eat_p("[") {
            if self.eat_p("]") {
                return Ok(TypeAst::Slice(Box::new(self.ty()?)));
            }
            let save = self.no_lit;
            self.no_lit = false;
            let n = self.expr();
            self.no_lit = save;
            let n = n?;
            self.expect_p("]")?;
            return Ok(TypeAst::Array(Box::new(n), Box::new(self.ty()?)));
        }
        if self.eat_p("(") {
            let mut v = Vec::new();
            while !self.is_p(")") {
                v.push(self.ty()?);
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p(")")?;
            return Ok(TypeAst::Tuple(v));
        }
        if self.eat_kw("fn") {
            self.expect_p("(")?;
            let mut v = Vec::new();
            while !self.is_p(")") {
                v.push(self.ty()?);
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p(")")?;
            let ret = if self.starts_type() { Some(Box::new(self.ty()?)) } else { None };
            return Ok(TypeAst::Fn(v, ret));
        }
        if let Tk::Id(name) = self.peek().clone() {
            self.bump();
            let mut args = Vec::new();
            if self.eat_p("[") {
                loop {
                    args.push(self.ty()?);
                    if !self.eat_p(",") {
                        break;
                    }
                }
                self.expect_p("]")?;
            }
            return Ok(TypeAst::Name(name, args, pos));
        }
        self.err("expected type")
    }

    // ---------- statements ----------
    pub fn block(&mut self) -> R<Block> {
        self.expect_p("{")?;
        let save = self.no_lit;
        self.no_lit = false;
        let mut stmts = Vec::new();
        loop {
            self.skip_nl();
            if self.is_p("}") || matches!(self.peek(), Tk::Eof) {
                break;
            }
            match self.stmt() {
                Ok(s) => {
                    stmts.push(s);
                    if !(matches!(self.peek(), Tk::Nl) || self.is_p(";") || self.is_p("}")) {
                        let _: R<()> = self.err("expected end of statement");
                        self.sync_stmt();
                    }
                }
                Err(()) => self.sync_stmt(),
            }
        }
        self.no_lit = save;
        let end = self.pos();
        self.expect_p("}")?;
        Ok(Block { stmts, end })
    }

    fn sync_stmt(&mut self) {
        let mut depth = 0i32;
        loop {
            match self.peek() {
                Tk::Eof => return,
                Tk::Nl if depth == 0 => return,
                Tk::P("{") => depth += 1,
                Tk::P("}") => {
                    if depth == 0 {
                        return;
                    }
                    depth -= 1;
                }
                _ => {}
            }
            self.bump();
        }
    }

    fn header_expr(&mut self) -> R<Expr> {
        let save = self.no_lit;
        self.no_lit = true;
        let e = self.expr();
        self.no_lit = save;
        e
    }

    fn if_stmt(&mut self) -> R<(Expr, Block, Option<Block>)> {
        // `if` already consumed
        let c = self.header_expr()?;
        let t = self.block()?;
        let mut j = self.i;
        while matches!(self.toks[j].t, Tk::Nl) {
            j += 1;
        }
        if matches!(self.toks[j].t, Tk::Kw("else")) {
            self.i = j + 1;
            if self.is_kw("if") {
                let pos = self.pos();
                self.bump();
                let (c2, t2, e2) = self.if_stmt()?;
                let end = t2.end;
                let inner = Stmt { k: SK::If(c2, t2, e2), pos };
                return Ok((c, t, Some(Block { stmts: vec![inner], end })));
            }
            let e = self.block()?;
            return Ok((c, t, Some(e)));
        }
        Ok((c, t, None))
    }

    fn stmt(&mut self) -> R<Stmt> {
        let pos = self.pos();
        let k = self.stmt_k()?;
        Ok(Stmt { k, pos })
    }

    fn stmt_k(&mut self) -> R<SK> {
        if self.eat_kw("var") {
            let name = self.ident()?;
            let ty = if self.is_p("=") { None } else { Some(self.ty()?) };
            let init = if self.eat_p("=") { Some(self.expr()?) } else { None };
            return Ok(SK::Var(name, ty, init));
        }
        if self.eat_kw("if") {
            let (c, t, e) = self.if_stmt()?;
            return Ok(SK::If(c, t, e));
        }
        if self.eat_kw("while") {
            let c = self.header_expr()?;
            let b = self.block()?;
            return Ok(SK::While(c, b));
        }
        if self.eat_kw("loop") {
            return Ok(SK::Loop(self.block()?));
        }
        if self.eat_kw("for") {
            let var = self.ident()?;
            let var2 = if self.eat_p(",") { Some(self.ident()?) } else { None };
            if !self.eat_kw("in") {
                return self.err("expected `in`");
            }
            let lo = self.header_expr()?;
            let mut hi = None;
            let mut incl = false;
            if self.eat_p("..") {
                hi = Some(self.header_expr()?);
            } else if self.eat_p("..=") {
                hi = Some(self.header_expr()?);
                incl = true;
            }
            let step = if self.eat_kw("by") { Some(self.header_expr()?) } else { None };
            let body = self.block()?;
            return Ok(SK::For { var, var2, lo, hi, incl, step, body });
        }
        if self.eat_kw("return") {
            if matches!(self.peek(), Tk::Nl) || self.is_p("}") || self.is_p(";") {
                return Ok(SK::Return(None));
            }
            return Ok(SK::Return(Some(self.expr()?)));
        }
        if self.eat_kw("break") {
            return Ok(SK::Break);
        }
        if self.eat_kw("continue") {
            return Ok(SK::Continue);
        }
        if self.eat_kw("assert") {
            let c = self.expr()?;
            let m = if self.eat_p(",") { Some(self.expr()?) } else { None };
            return Ok(SK::Assert(c, m));
        }
        if self.eat_kw("defer") {
            return Ok(SK::Defer(self.block()?));
        }
        if self.is_p("{") {
            return Ok(SK::Block(self.block()?));
        }
        // multi-let: a, b := e
        if let (Tk::Id(_), Tk::P(",")) = (self.peek(), self.peek_at(1)) {
            let pos = self.pos();
            let mut names = vec![self.ident()?];
            while self.eat_p(",") {
                names.push(self.ident()?);
            }
            if self.eat_p("=") {
                let e = self.expr()?;
                let lhs = names.into_iter().map(|n| Expr { k: EK::Ident(n), pos }).collect();
                return Ok(SK::MultiAssign(lhs, e));
            }
            self.expect_p(":=")?;
            let e = self.expr()?;
            return Ok(SK::Let(names, e));
        }
        let e = self.expr()?;
        if self.eat_p(":=") {
            let name = match e.k {
                EK::Ident(n) => n,
                _ => {
                    self.errs.push(Diag { pos: e.pos, msg: "left side of `:=` must be an identifier".into() });
                    return Err(());
                }
            };
            let v = self.expr()?;
            return Ok(SK::Let(vec![name], v));
        }
        if self.eat_p("=") {
            let v = self.expr()?;
            return Ok(SK::Assign(e, None, v));
        }
        let op = match self.peek() {
            Tk::P("+=") => Some(BinOp::Add),
            Tk::P("-=") => Some(BinOp::Sub),
            Tk::P("*=") => Some(BinOp::Mul),
            Tk::P("/=") => Some(BinOp::Div),
            Tk::P("%=") => Some(BinOp::Rem),
            Tk::P("&=") => Some(BinOp::And),
            Tk::P("|=") => Some(BinOp::Or),
            Tk::P("^=") => Some(BinOp::Xor),
            Tk::P("<<=") => Some(BinOp::Shl),
            Tk::P(">>=") => Some(BinOp::Shr),
            _ => None,
        };
        if let Some(op) = op {
            self.bump();
            let v = self.expr()?;
            return Ok(SK::Assign(e, Some(op), v));
        }
        Ok(SK::Expr(e))
    }

    // ---------- expressions ----------
    pub fn expr(&mut self) -> R<Expr> {
        self.bin(1)
    }

    fn binop(&self) -> Option<(BinOp, u8)> {
        let p = match self.peek() {
            Tk::P(p) => *p,
            _ => return None,
        };
        // precedence as in Rust: arithmetic, shifts, &, ^, |, comparisons, &&, ||
        Some(match p {
            "*" => (BinOp::Mul, 9),
            "/" => (BinOp::Div, 9),
            "%" => (BinOp::Rem, 9),
            "+" => (BinOp::Add, 8),
            "-" => (BinOp::Sub, 8),
            "<<" => (BinOp::Shl, 7),
            ">>" => (BinOp::Shr, 7),
            "&" => (BinOp::And, 6),
            "^" => (BinOp::Xor, 5),
            "|" => (BinOp::Or, 4),
            "==" => (BinOp::Eq, 3),
            "!=" => (BinOp::Ne, 3),
            "<" => (BinOp::Lt, 3),
            "<=" => (BinOp::Le, 3),
            ">" => (BinOp::Gt, 3),
            ">=" => (BinOp::Ge, 3),
            "&&" => (BinOp::LAnd, 2),
            "||" => (BinOp::LOr, 1),
            _ => return None,
        })
    }

    fn bin(&mut self, min: u8) -> R<Expr> {
        let mut lhs = self.unary()?;
        loop {
            let (op, prec) = match self.binop() {
                Some(x) if x.1 >= min => x,
                _ => break,
            };
            let pos = self.pos();
            self.bump();
            let rhs = self.bin(prec + 1)?;
            lhs = Expr { k: EK::Bin(op, Box::new(lhs), Box::new(rhs)), pos };
        }
        Ok(lhs)
    }

    fn unary(&mut self) -> R<Expr> {
        let pos = self.pos();
        let op = match self.peek() {
            Tk::P("-") => Some(UnOp::Neg),
            Tk::P("!") => Some(UnOp::Not),
            Tk::P("~") => Some(UnOp::BitNot),
            Tk::P("&") => Some(UnOp::Addr),
            Tk::P("*") => Some(UnOp::Deref),
            _ => None,
        };
        if let Some(op) = op {
            self.bump();
            let e = self.unary()?;
            return Ok(Expr { k: EK::Un(op, Box::new(e)), pos });
        }
        self.postfix()
    }

    fn typeish(e: &Expr) -> bool {
        match &e.k {
            EK::Ident(_) | EK::TypeE(_) => true,
            EK::Index(b, _) => matches!(b.k, EK::Ident(_)),
            _ => false,
        }
    }

    fn args(&mut self, close: &str) -> R<Vec<Expr>> {
        let save = self.no_lit;
        self.no_lit = false;
        let mut v = Vec::new();
        let r = (|| {
            while !self.is_p(close) {
                v.push(self.expr()?);
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p(close)
        })();
        self.no_lit = save;
        r?;
        Ok(v)
    }

    fn postfix(&mut self) -> R<Expr> {
        let mut e = self.primary()?;
        loop {
            let pos = self.pos();
            if self.eat_p("(") {
                let a = self.args(")")?;
                e = Expr { k: EK::Call(Box::new(e), a), pos };
            } else if self.eat_p("[") {
                let save = self.no_lit;
                self.no_lit = false;
                let r = self.index_tail(e, pos);
                self.no_lit = save;
                e = r?;
            } else if self.eat_p(".") {
                match self.bump() {
                    Tk::Id(n) => e = Expr { k: EK::Field(Box::new(e), n), pos },
                    Tk::Int(n) => e = Expr { k: EK::Field(Box::new(e), n.to_string()), pos },
                    _ => {
                        self.i -= 1;
                        return self.err("expected field name");
                    }
                }
            } else if self.is_p("{") && !self.no_lit && Self::typeish(&e) {
                self.bump();
                let save = self.no_lit;
                self.no_lit = false;
                let r = self.lit_body();
                self.no_lit = save;
                e = Expr { k: EK::Lit(Box::new(e), r?), pos };
            } else {
                break;
            }
        }
        Ok(e)
    }

    fn index_tail(&mut self, base: Expr, pos: Pos) -> R<Expr> {
        if self.eat_p("..") {
            let hi = if self.is_p("]") { None } else { Some(Box::new(self.expr()?)) };
            self.expect_p("]")?;
            return Ok(Expr { k: EK::Slice(Box::new(base), None, hi), pos });
        }
        let first = self.expr()?;
        if self.eat_p("..") {
            let hi = if self.is_p("]") { None } else { Some(Box::new(self.expr()?)) };
            self.expect_p("]")?;
            return Ok(Expr { k: EK::Slice(Box::new(base), Some(Box::new(first)), hi), pos });
        }
        let mut v = vec![first];
        while self.eat_p(",") {
            v.push(self.expr()?);
        }
        self.expect_p("]")?;
        Ok(Expr { k: EK::Index(Box::new(base), v), pos })
    }

    fn lit_body(&mut self) -> R<Vec<(Option<String>, Expr)>> {
        let mut v = Vec::new();
        loop {
            while matches!(self.peek(), Tk::Nl) {
                self.bump();
            }
            if self.eat_p("}") {
                break;
            }
            if let (Tk::Id(n), Tk::P(":")) = (self.peek().clone(), self.peek_at(1)) {
                self.bump();
                self.bump();
                let e = self.expr()?;
                v.push((Some(n), e));
            } else {
                let e = self.expr()?;
                v.push((None, e));
            }
            while matches!(self.peek(), Tk::Nl) {
                self.bump();
            }
            if !self.eat_p(",") {
                while matches!(self.peek(), Tk::Nl) {
                    self.bump();
                }
                self.expect_p("}")?;
                break;
            }
        }
        Ok(v)
    }

    fn primary(&mut self) -> R<Expr> {
        let pos = self.pos();
        match self.peek().clone() {
            Tk::Int(n) => {
                self.bump();
                Ok(Expr { k: EK::Int(n), pos })
            }
            Tk::Float(f) => {
                self.bump();
                Ok(Expr { k: EK::Float(f), pos })
            }
            Tk::Str(s) => {
                self.bump();
                Ok(Expr { k: EK::Str(s), pos })
            }
            Tk::Id(n) => {
                self.bump();
                Ok(Expr { k: EK::Ident(n), pos })
            }
            Tk::Kw("true") => {
                self.bump();
                Ok(Expr { k: EK::Bool(true), pos })
            }
            Tk::Kw("false") => {
                self.bump();
                Ok(Expr { k: EK::Bool(false), pos })
            }
            Tk::Kw("nil") => {
                self.bump();
                Ok(Expr { k: EK::Nil, pos })
            }
            Tk::Kw("if") => {
                self.bump();
                let (c, t, e) = self.if_stmt()?;
                match e {
                    Some(e) => Ok(Expr { k: EK::If(Box::new(c), t, e), pos }),
                    None => {
                        self.errs.push(Diag { pos, msg: "`if` used as an expression needs an `else` branch".into() });
                        Err(())
                    }
                }
            }
            Tk::Kw("match") => {
                self.bump();
                let scrut = self.header_expr()?;
                self.expect_p("{")?;
                let save = self.no_lit;
                self.no_lit = false;
                let r = self.match_arms();
                self.no_lit = save;
                Ok(Expr { k: EK::Match(Box::new(scrut), r?), pos })
            }
            Tk::Kw("fn") => {
                let t = self.ty()?;
                Ok(Expr { k: EK::TypeE(t), pos })
            }
            Tk::P("(") => {
                self.bump();
                let save = self.no_lit;
                self.no_lit = false;
                let r = (|| {
                    let first = self.expr()?;
                    if self.is_p(",") {
                        let mut v = vec![first];
                        while self.eat_p(",") {
                            if self.is_p(")") {
                                break;
                            }
                            v.push(self.expr()?);
                        }
                        self.expect_p(")")?;
                        return Ok(Expr { k: EK::Tuple(v), pos });
                    }
                    self.expect_p(")")?;
                    Ok(first)
                })();
                self.no_lit = save;
                r
            }
            Tk::P("[") => {
                let t = self.ty()?;
                Ok(Expr { k: EK::TypeE(t), pos })
            }
            _ => self.err("expected expression"),
        }
    }

    fn match_arms(&mut self) -> R<Vec<MatchArm>> {
        let mut arms = Vec::new();
        loop {
            self.skip_nl();
            if self.eat_p("}") {
                break;
            }
            let pos = self.pos();
            let mut pats = Vec::new();
            loop {
                let ppos = self.pos();
                if let Tk::Id(n) = self.peek().clone() {
                    if n == "_" {
                        self.bump();
                        pats.push(Pat::Wild);
                    } else if matches!(self.peek_at(1), Tk::P("(")) {
                        self.bump();
                        self.bump();
                        let mut binds = Vec::new();
                        while !self.is_p(")") {
                            binds.push(self.ident()?);
                            if !self.eat_p(",") {
                                break;
                            }
                        }
                        self.expect_p(")")?;
                        pats.push(Pat::Variant(n, binds, ppos));
                    } else {
                        pats.push(Pat::Const(self.expr()?));
                    }
                } else {
                    pats.push(Pat::Const(self.expr()?));
                }
                if !self.eat_p(",") {
                    break;
                }
            }
            self.expect_p("=>")?;
            let body = if self.is_p("{") {
                self.block()?
            } else {
                let s = self.stmt()?;
                Block { stmts: vec![s], end: self.pos() }
            };
            arms.push(MatchArm { pats, body, pos });
            if !(matches!(self.peek(), Tk::Nl) || self.is_p(";") || self.is_p("}")) {
                return self.err("expected end of match arm");
            }
        }
        Ok(arms)
    }
}
