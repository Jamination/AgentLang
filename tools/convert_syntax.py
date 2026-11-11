#!/usr/bin/env python3
"""Rewrites AL source from the `name :: ...` declaration syntax to keyword declarations.

    before                                   after
    area :: (s: Shape) -> f64 { ... }        fn area(s: Shape) -> f64 { ... }
    apply[T, U] :: (x: T, f: (T) -> U) -> U  fn apply[T, U](x: T, f: fn(T) -> U) -> U
    extern "libc.so.6" getpid :: () -> i32   extern "libc.so.6" fn getpid() -> i32
    (a: Item, b: Item) -> bool { ... }       fn(a: Item, b: Item) -> bool { ... }
    (i64, i64) -> bool    (*u8) -> ()        fn(i64, i64) -> bool    fn(*u8)
    N :: 5                LIMIT : i64 : 100  const N = 5             const LIMIT: i64 = 100
    Item :: struct { name: str, hp: i64 }    struct Item { name: str, hp: i64 }
    Shape :: enum { Circle(f64), Dot }       enum Shape { Circle(f64), Dot }
    Reg :: type i64                          type Reg = i64
    x := 5    x: i64 = 5    x: i64           (variables: unchanged)

Usage:
    tools/convert_syntax.py [options] FILE...

    FILE.al   is rewritten in place.
    FILE.md   AL code in ``` fences is rewritten (fences with a language tag other than
              `al` and fences in which nothing parses as AL of the old form stay as they are),
              and so is AL code in `inline code` that parses as a whole (--no-inline: not).

    --check       write nothing; exit status 1 if a file would change
    --diff        write nothing; print a unified diff of what would change
    --stdout      write nothing; print the converted text (one file)
    --comments    .al files: also rewrite AL code quoted in `backticks` inside // comments
    --no-inline   .md files: leave inline code alone
    -q            do not list the files that changed

The rewriting is done on tokens by a parser of both grammars (the same decisions as
src/parser.al, so that converted input is left alone). Comments, spacing and line structure
stay: every line remains on its line; a `//` comment that was set off by two or more spaces
keeps its column where the line allows it. Strings are never touched.

What is not parsed is not converted: such places are listed on stderr as
`file:line: not converted: reason` (exit status 2 for an .al file; in Markdown they are normal:
fragments, pseudo code, other languages). A statement or declaration that does not parse is
left exactly as it was.

`convert(text, fragment=False)` is the function behind it: returns (new text, problems).
"""
import difflib
import re
import sys

KEYWORDS = {
    "fn", "struct", "enum", "const", "var", "test", "use", "if", "else", "while", "loop", "for",
    "in", "return", "break", "continue", "assert", "true", "false", "nil", "match", "by", "defer",
    "inline", "noinline", "extern", "priv",
}
PUNCTS = [
    "<<=", ">>=", "..=", ":=", "::", "->", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=", "-=",
    "*=", "/=", "%=", "&=", "|=", "^=", "..", "=>", "+", "-", "*", "/", "%", "&", "|", "^", "~", "!",
    "<", ">", "=", "(", ")", "[", "]", "{", "}", ",", ".", ":", ";", "@",
]
LINE_END_KW = {"return", "break", "continue", "true", "false", "nil"}
BINOPS = {"*": 9, "/": 9, "%": 9, "+": 8, "-": 8, "<<": 7, ">>": 7, "&": 6, "^": 5, "|": 4, "==": 3,
          "!=": 3, "<": 3, "<=": 3, ">": 3, ">=": 3, "&&": 2, "||": 1}
ASSIGN_OPS = {"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="}
DECL_KW = {"fn", "struct", "enum", "const", "var", "test", "use", "inline", "noinline", "extern", "priv"}


class Tok:
    __slots__ = ("kind", "text", "pos", "end", "line", "col")

    def __init__(self, kind, text, pos, end, line, col):
        self.kind = kind    # id kw int float str p nl eof dots
        self.text = text
        self.pos = pos
        self.end = end
        self.line = line
        self.col = col


class ParseError(Exception):
    def __init__(self, line, msg):
        Exception.__init__(self, msg)
        self.line = line
        self.msg = msg


def is_alpha(c):
    return ("a" <= c <= "z") or ("A" <= c <= "Z")


def is_digit(c):
    return "0" <= c <= "9"


def is_alnum(c):
    return is_alpha(c) or is_digit(c)


def lex(s, fragment):
    """Tokens of `s` (as src/lexer.al makes them) and the start offsets of the // comments.
    In a fragment `...` is one token: a placeholder for anything."""
    out = []
    comments = []
    stack = []
    i = 0
    n = len(s)
    line = 1
    line_start = 0
    while i < n:
        c = s[i]
        if c == "\n":
            if not stack or stack[-1] == "{":
                term = False
                if out:
                    t = out[-1]
                    if t.kind in ("id", "int", "float", "str", "dots"):
                        term = True
                    elif t.kind == "p":
                        term = t.text in (")", "]", "}")
                    elif t.kind == "kw":
                        term = t.text in LINE_END_KW
                if term:
                    out.append(Tok("nl", "", i, i, line, i - line_start + 1))
            i += 1
            line += 1
            line_start = i
            continue
        if c in " \t\r":
            i += 1
            continue
        if c == "/" and i + 1 < n and s[i + 1] == "/":
            comments.append(i)
            while i < n and s[i] != "\n":
                i += 1
            continue
        col = i - line_start + 1
        st = i
        if is_alpha(c) or c == "_":
            while i < n and (is_alnum(s[i]) or s[i] == "_"):
                i += 1
            w = s[st:i]
            out.append(Tok("kw" if w in KEYWORDS else "id", w, st, i, line, col))
            continue
        if is_digit(c):
            if c == "0" and i + 1 < n and s[i + 1] in "xbo":
                i += 2
                while i < n and (is_alnum(s[i]) or s[i] == "_"):
                    i += 1
                out.append(Tok("int", s[st:i], st, i, line, col))
                continue
            while i < n and (is_digit(s[i]) or s[i] == "_"):
                i += 1
            is_float = False
            if i + 1 < n and s[i] == "." and is_digit(s[i + 1]):
                is_float = True
                i += 1
                while i < n and (is_digit(s[i]) or s[i] == "_"):
                    i += 1
            if i < n and s[i] in "eE":
                j = i + 1
                if j < n and s[j] in "+-":
                    j += 1
                if j < n and is_digit(s[j]):
                    is_float = True
                    i = j
                    while i < n and is_digit(s[i]):
                        i += 1
            out.append(Tok("float" if is_float else "int", s[st:i], st, i, line, col))
            continue
        if c == "`":
            tline = line
            i += 1
            while i < n and s[i] != "`":
                if s[i] == "\n":
                    line += 1
                    line_start = i + 1
                i += 1
            i = min(i + 1, n)
            out.append(Tok("str", s[st:i], st, i, tline, col))
            continue
        if c == '"' or c == "'":
            i += 1
            while i < n:
                d = s[i]
                if d == c:
                    i += 1
                    break
                if d == "\n":
                    break
                if d == "\\" and i + 1 < n:
                    i += 2
                    if s[i - 1] == "x":
                        k = 0
                        while k < 2 and i < n and s[i] in "0123456789abcdefABCDEF":
                            i += 1
                            k += 1
                    continue
                i += 1
            out.append(Tok("str" if c == '"' else "int", s[st:i], st, i, line, col))
            continue
        if fragment and s.startswith("...", i):
            out.append(Tok("dots", "...", i, i + 3, line, col))
            i += 3
            continue
        for pp in PUNCTS:
            if s.startswith(pp, i):
                if pp in ("(", "[", "{"):
                    stack.append(pp)
                elif pp in (")", "]", "}"):
                    if stack:
                        stack.pop()
                out.append(Tok("p", pp, i, i + len(pp), line, col))
                i += len(pp)
                break
        else:
            i += 1      # a character that is no token (the compiler reports it)
    if out and out[-1].kind != "nl":
        out.append(Tok("nl", "", n, n, line, n - line_start + 1))
    out.append(Tok("eof", "", n, n, line, n - line_start + 1))
    return out, comments


class Parser:
    """The parser of src/parser.al (old and new syntax) without an AST: it records the edits
    that turn old syntax into new syntax. Expressions return what the literal rule needs to
    know about them: 'ident', 'type', 'index' (a name with [..]) or 'other'."""

    def __init__(self, src, fragment):
        self.src = src
        self.fragment = fragment
        self.toks, self.comments = lex(src, fragment)
        self.i = 0
        self.no_lit = False
        self.hdr_stmt = False
        self.edits = []         # (offset, number of characters deleted, inserted text)
        self.problems = []      # (line, message)
        self.items = 0          # top-level items parsed without a problem

    # ----- tokens -----
    def tok(self, n=0):
        return self.toks[min(self.i + n, len(self.toks) - 1)]

    def bump(self):
        t = self.toks[self.i]
        if self.i < len(self.toks) - 1:
            self.i += 1
        return t

    def tp(self, t, s):
        return t.kind == "p" and t.text == s

    def tkw(self, t, k):
        return t.kind == "kw" and t.text == k

    def is_p(self, s, n=0):
        return self.tp(self.tok(n), s)

    def is_kw(self, k, n=0):
        return self.tkw(self.tok(n), k)

    def is_id(self, n=0):
        return self.tok(n).kind == "id"

    def is_word(self, w, n=0):
        t = self.tok(n)
        return t.kind == "id" and t.text == w

    def is_nl(self, n=0):
        return self.tok(n).kind == "nl"

    def is_eof(self, n=0):
        return self.tok(n).kind == "eof"

    def is_dots(self, n=0):
        return self.tok(n).kind == "dots"

    def eat_p(self, s):
        if self.is_p(s):
            self.bump()
            return True
        return False

    def eat_kw(self, k):
        if self.is_kw(k):
            self.bump()
            return True
        return False

    def desc(self):
        t = self.tok()
        if t.kind in ("nl", "eof"):
            return "end of line" if t.kind == "nl" else "end of file"
        return "`%s`" % t.text

    def err(self, msg):
        raise ParseError(self.tok().line, "%s, found %s" % (msg, self.desc()))

    def expect_p(self, s):
        if not self.eat_p(s):
            self.err("expected `%s`" % s)

    def ident(self):
        if not self.is_id():
            self.err("expected identifier")
        return self.bump()

    def skip_nl(self):
        while self.is_nl() or self.is_p(";"):
            self.bump()

    def end_of_stmt(self):
        return self.is_nl() or self.is_p(";") or self.is_p("}") or self.is_eof()

    # ----- edits -----
    # ----- edits -----
    def delete(self, start, end):
        self.edits.append((start, end - start, ""))

    def insert(self, offset, text):
        self.edits.append((offset, 0, text))

    def replace(self, t, text):
        self.edits.append((t.pos, t.end - t.pos, text))

    # ----- file -----
    def file(self):
        while True:
            self.skip_nl()
            if self.is_eof():
                break
            start = self.i
            mark = len(self.edits)
            try:
                if self.fragment:
                    self.item()
                else:
                    self.decl()
                self.items += 1
            except ParseError as e:
                del self.edits[mark:]
                self.problems.append((e.line, e.msg))
                self.sync_decl(start)

    def next_decl(self):
        """documentation: another declaration follows on the same line"""
        t = self.tok()
        if t.kind == "kw":
            return t.text in ("struct", "enum", "fn", "const")
        return t.kind == "id" and (self.is_p("::", 1) or self.tparams_ahead())

    def item(self):
        """in a fragment (documentation): a declaration or a statement"""
        t = self.tok()
        is_decl = False
        if t.kind == "kw":
            is_decl = t.text in ("priv", "inline", "noinline", "extern", "struct", "enum", "const", "test", "use")
            is_decl = is_decl or (t.text == "fn" and self.is_id(1))
        elif t.kind == "id":
            if self.is_p("::", 1) or self.tparams_ahead():
                is_decl = True
            elif self.is_p(":", 1):
                a = self.tok(2)
                is_decl = not (a.kind == "kw" and a.text in ("for", "while", "loop"))
            elif t.text == "type" and self.is_id(1) and self.is_p("=", 2):
                is_decl = True
            elif self.is_p("(", 1) and self.is_id(2) and self.is_p(":", 3):
                # a signature without a keyword: `sort_by(a: []T, less: (T, T) -> bool)`
                self.bump()
                self.fn_sig()
                if not self.end_of_stmt():
                    self.err("expected end of statement")
                return
        if is_decl:
            self.decl()
        else:
            self.stmt()
        if is_decl and self.next_decl():
            return
        if not self.end_of_stmt():
            self.err("expected end of statement")

    def sync_decl(self, start):
        depth = 0
        for j in range(start, self.i):
            if self.tp(self.toks[j], "{"):
                depth += 1
            elif self.tp(self.toks[j], "}"):
                depth -= 1
        if self.i == start:
            self.bump()
        if self.fragment:
            # a fragment has no declarations to wait for: go on with the next line
            while not self.is_eof():
                t = self.tok()
                if t.kind == "nl" and depth <= 0:
                    return
                if self.tp(t, "{"):
                    depth += 1
                elif self.tp(t, "}"):
                    depth -= 1
                self.bump()
            return
        starts = self.i > 0 and self.toks[self.i - 1].line < self.tok().line and depth <= 0
        while True:
            if self.i > 0 and self.toks[self.i - 1].kind == "nl":
                starts = depth <= 0 or self.tok().col == 1
            t = self.tok()
            if t.kind == "eof":
                return
            if t.kind == "p":
                if t.text == "{":
                    depth += 1
                elif t.text == "}":
                    depth -= 1
            elif t.kind == "kw":
                if starts and t.text in DECL_KW:
                    return
            elif t.kind == "id":
                if starts:
                    if self.is_p("::", 1) or self.tparams_ahead():
                        return
                    if depth <= 0 and (self.is_p(":", 1) or self.is_p(":=", 1) or t.text == "type"):
                        return
            self.bump()
            starts = False

    def tparams_ahead(self):
        if not self.is_p("[", 1):
            return False
        j = self.i + 2
        while True:
            if j >= len(self.toks) or self.toks[j].kind != "id":
                return False
            j += 1
            if not self.tp(self.toks[j], ","):
                break
            j += 1
        return self.tp(self.toks[j], "]") and self.tp(self.toks[min(j + 1, len(self.toks) - 1)], "::")

    def tparams(self):
        if self.eat_p("["):
            while True:
                self.ident()
                if not self.eat_p(","):
                    break
            self.expect_p("]")

    # ----- declarations -----
    # ----- declarations -----
    def decl(self):
        self.eat_kw("priv")
        if not self.eat_kw("inline"):
            self.eat_kw("noinline")
        ext = False
        if self.eat_kw("extern"):
            if self.tok().kind != "str":
                self.err("expected a library name string after `extern`")
            self.bump()
            ext = True
        if self.is_kw("fn"):
            return self.fn_decl(ext)
        if self.is_id() and not (self.is_word("type") and self.is_id(1)):
            return self.name_decl(ext)
        if ext:
            self.err("expected the name of the C function")
        if self.eat_kw("struct"):
            self.ident()
            self.tparams()
            return self.struct_rest()
        if self.eat_kw("enum"):
            self.ident()
            self.tparams()
            return self.enum_rest()
        if self.eat_kw("const"):
            self.ident()
            if self.eat_p(":"):
                self.ty()
            self.expect_p("=")
            self.expr()
            return
        if self.eat_kw("test"):
            if self.tok().kind != "str":
                self.err("expected test name string")
            self.bump()
            return self.block()
        if self.eat_kw("use"):
            if self.is_word("std") and self.is_p(".", 1) and self.is_id(2):
                self.i += 3
                return
            if self.tok().kind != "str":
                self.err("expected a file path string or `std.<module>` after `use`")
            self.bump()
            return
        if self.is_word("type"):
            self.bump()
            self.ident()
            self.expect_p("=")
            return self.ty()
        self.err("expected declaration")

    def fn_decl(self, ext=False):
        """`fn name[T](a: A) -> R { ... }` at the `fn`; `extern "lib" fn name(a: A) -> R`"""
        self.bump()
        self.ident()
        self.tparams()
        self.fn_sig()
        if ext or (self.fragment and not self.is_p("{")):
            return
        self.block()

    def elided(self):
        """documentation: `...` or `..` for parameters that are not shown"""
        return self.is_dots() or (self.fragment and self.is_p(".."))

    def struct_rest(self):
        self.expect_p("{")
        while True:
            self.skip_nl()
            if self.eat_p("}"):
                break
            if self.is_dots():
                self.bump()
                self.eat_p(",")
                continue
            self.ident()
            self.expect_p(":")
            self.ty()
            self.eat_p(",")

    def enum_rest(self):
        self.expect_p("{")
        while True:
            self.skip_nl()
            if self.eat_p("}"):
                break
            if self.is_dots():
                self.bump()
                self.eat_p(",")
                continue
            self.ident()
            if self.eat_p("("):
                self.type_list()
            self.eat_p(",")

    def at_fn(self):
        if not self.is_p("("):
            return False
        if self.is_p(")", 1):
            return self.is_p("->", 2) or self.is_p("{", 2)
        return self.is_id(1) and self.is_p(":", 2)

    def parens_then(self, what):
        if not self.is_p("("):
            return False
        j = self.i + 1
        depth = 1
        while depth > 0:
            t = self.toks[j]
            if t.kind == "eof":
                return False
            if t.kind == "p":
                if t.text == "(":
                    depth += 1
                elif t.text == ")":
                    depth -= 1
            j += 1
        return self.tp(self.toks[j], what)

    def at_old_params(self):
        return self.is_p("(") and self.is_id(1) and (self.is_id(2) or self.is_kw("fn", 2))

    def fn_ahead(self):
        if self.at_fn() or self.parens_then("->") or self.parens_then("{") or self.at_old_params():
            return True
        # documentation: `main :: ()` alone
        return self.fragment and self.is_p("(") and self.is_p(")", 1) and (self.is_nl(2) or self.is_eof(2))

    def at_no_result(self):
        return self.is_p("(") and self.is_p(")", 1) and not self.is_p("->", 2)

    def fn_sig(self):
        """`(a: A, b: B) [-> R]`"""
        self.expect_p("(")
        while not self.is_p(")"):
            if self.elided():
                self.bump()
            elif self.fragment and self.is_id() and (self.is_p(")", 1) or self.is_p(",", 1)):
                self.bump()               # documentation: `fn name(params) -> R`
            else:
                self.ident()
                self.expect_p(":")
                self.ty()
            if not self.eat_p(","):
                break
        self.expect_p(")")
        if self.eat_p("->"):
            if self.at_no_result():
                self.err("a function without a result is declared without an arrow")
            self.ty()

    def jai_fn(self, name, name_end, ext):
        """`name[T] :: (a: A) -> R { ... }` at the `(`  ->  `fn name[T](a: A) -> R { ... }`"""
        self.insert(name.pos, "fn ")
        self.delete(name_end, self.tok().pos)
        self.fn_sig()
        if ext or (self.fragment and not self.is_p("{")):
            return
        self.block()

    def name_decl(self, ext=False):
        name = self.ident()
        self.tparams()
        name_end = self.toks[self.i - 1].end
        if self.is_p("::"):
            cc = self.bump()
            if self.is_kw("struct") or self.is_kw("enum"):
                kw = self.bump()
                self.insert(name.pos, kw.text + " ")
                self.delete(name_end, kw.end)
                if kw.text == "struct":
                    return self.struct_rest()
                return self.enum_rest()
            if self.is_word("type"):
                kw = self.bump()
                self.insert(name.pos, "type ")
                self.edits.append((cc.pos, kw.end - cc.pos, "="))
                return self.ty()
            if self.fn_ahead() or (ext and self.is_p("(")):
                return self.jai_fn(name, name_end, ext)
            self.insert(name.pos, "const ")
            self.replace(cc, "=")
            self.expr()
            return
        if self.eat_p(":="):
            self.expr()
            return
        if self.is_p(":"):
            c1 = self.bump()
            self.ty()
            if self.is_p(":"):
                # `N : T : value` -> `const N: T = value`
                self.insert(name.pos, "const ")
                self.delete(name_end, c1.pos)
                self.replace(self.bump(), "=")
                self.expr()
            elif self.eat_p("="):
                self.expr()
            return
        self.err("expected `::`, `:` or `:=` after the name of a declaration")

    # ----- types -----
    def type_list(self):
        """types after a `(`, through the `)`"""
        while not self.is_p(")"):
            if self.elided():
                self.bump()
            else:
                self.ty()
            if not self.eat_p(","):
                break
        self.expect_p(")")

    def ty(self):
        if self.eat_p("*"):
            return self.ty()
        if self.eat_p("["):
            if self.eat_p("]"):
                return self.ty()
            save = self.no_lit
            self.no_lit = False
            try:
                self.expr()
            finally:
                self.no_lit = save
            self.expect_p("]")
            return self.ty()
        if self.is_p("("):
            lp = self.bump()
            self.type_list()
            rp = self.toks[self.i - 1]
            if self.eat_p("->"):
                # `(A, B) -> R` -> `fn(A, B) -> R`; `(A) -> ()` -> `fn(A)`
                self.insert(lp.pos, "fn")
                if self.at_no_result():
                    self.bump()
                    self.delete(rp.end, self.bump().end)
                else:
                    self.ty()
            return
        if self.eat_kw("fn"):
            self.expect_p("(")
            self.type_list()
            if self.eat_p("->"):
                if self.is_p("(") and self.is_p(")", 1):
                    self.err("a function type without a result has no arrow")
                self.ty()
            return
        if self.is_id():
            self.bump()
            if self.eat_p("["):
                while True:
                    self.ty()
                    if not self.eat_p(","):
                        break
                self.expect_p("]")
            return
        if self.is_dots():
            self.bump()
            return
        self.err("expected type")

    # ----- statements -----
    def block(self):
        self.expect_p("{")
        save = self.no_lit
        self.no_lit = False
        try:
            while True:
                self.skip_nl()
                if self.is_p("}") or self.is_eof():
                    break
                mark = len(self.edits)
                try:
                    self.stmt()
                except ParseError as e:
                    del self.edits[mark:]
                    self.problems.append((e.line, e.msg))
                    self.sync_stmt()
                    continue
                if not (self.is_nl() or self.is_p(";") or self.is_p("}")):
                    self.problems.append((self.tok().line, "expected end of statement, found %s" % self.desc()))
                    self.sync_stmt()
        finally:
            self.no_lit = save
        self.expect_p("}")

    def sync_stmt(self):
        depth = 0
        while True:
            t = self.tok()
            if t.kind == "eof":
                return
            if t.kind == "nl":
                if depth == 0:
                    return
            elif t.kind == "p":
                if t.text == "{":
                    depth += 1
                elif t.text == "}":
                    if depth == 0:
                        return
                    depth -= 1
            self.bump()

    def header_expr(self, stmt_header):
        save = (self.no_lit, self.hdr_stmt)
        self.no_lit = True
        self.hdr_stmt = stmt_header
        try:
            return self.expr()
        finally:
            self.no_lit, self.hdr_stmt = save

    def lit_in_header(self, kind):
        if kind == "type":
            return True
        if self.fragment and self.is_dots(1) and self.is_p("}", 2):
            return False        # documentation: `match value { ... }`
        j = self.i
        depth = 0
        arrow = False
        while True:
            t = self.toks[j]
            if t.kind == "eof":
                return False
            if t.kind == "p":
                if t.text == "{":
                    depth += 1
                elif t.text == "}":
                    depth -= 1
                    if depth == 0:
                        break
                elif t.text == "=>" and depth == 1:
                    arrow = True
            j += 1
        if not self.hdr_stmt:
            return not arrow and j > self.i + 1
        after = self.toks[min(j + 1, len(self.toks) - 1)]
        return after.kind == "p" and (after.text in ("{", ".", "[") or after.text in BINOPS)

    def if_stmt(self):
        self.header_expr(True)
        self.block()
        j = self.i
        while self.toks[j].kind == "nl":
            j += 1
        if self.tkw(self.toks[j], "else"):
            self.i = j + 1
            if self.eat_kw("if"):
                return self.if_stmt()
            self.block()

    def stmt(self):
        t = self.tok()
        if t.kind == "dots":
            self.bump()
            return
        if t.kind == "kw":
            k = t.text
            if k in ("priv", "inline", "noinline", "extern"):
                self.err("`%s` applies to top-level declarations only" % k)
            if k == "fn" and self.is_id(1):
                return self.fn_decl()
            if k == "if":
                self.bump()
                return self.if_stmt()
            if k == "while":
                self.bump()
                self.header_expr(True)
                return self.block()
            if k == "loop":
                self.bump()
                return self.block()
            if k == "for":
                self.bump()
                self.ident()
                if self.eat_p(","):
                    self.ident()
                if not self.eat_kw("in"):
                    self.err("expected `in`")
                self.header_expr(True)
                if self.eat_p("..") or self.eat_p("..="):
                    self.header_expr(True)
                if self.eat_kw("by"):
                    self.header_expr(True)
                return self.block()
            if k == "return":
                self.bump()
                if self.is_nl() or self.is_p("}") or self.is_p(";"):
                    return
                self.expr()
                return
            if k in ("break", "continue"):
                self.bump()
                if self.is_id():
                    self.bump()
                return
            if k == "assert":
                self.bump()
                self.expr()
                if self.eat_p(","):
                    self.expr()
                return
            if k == "defer":
                self.bump()
                return self.block()
        if self.is_p("{"):
            return self.block()
        if self.is_id() and self.is_p(":", 1):
            a = self.tok(2)
            if a.kind == "kw" and a.text in ("for", "while", "loop"):
                self.bump()
                self.bump()
                return self.stmt()
            if (a.kind == "kw" and a.text in ("if", "match")) or self.tp(a, "{"):
                self.bump()
                self.bump()
                self.err("a label names a loop")
            self.bump()
            self.bump()
            self.ty()
            if self.is_p(":"):
                self.err("a constant is declared at the top level")
            if self.eat_p("="):
                self.expr()
            return
        if self.is_id() and (self.is_p("::", 1) or self.tparams_ahead()):
            name = self.ident()
            self.tparams()
            name_end = self.toks[self.i - 1].end
            self.expect_p("::")
            if not self.fn_ahead():
                self.err("inside a function only functions can be declared with `::`")
            return self.jai_fn(name, name_end, False)
        if self.is_id() and self.is_p(",", 1):
            self.ident()
            while self.eat_p(","):
                self.ident()
            if self.eat_p("="):
                self.expr()
                return
            self.expect_p(":=")
            self.expr()
            return
        self.expr()
        if self.eat_p(":=") or self.eat_p("="):
            self.expr()
            return
        t = self.tok()
        if t.kind == "p" and t.text in ASSIGN_OPS:
            self.bump()
            self.expr()

    # ----- expressions -----
    def expr(self):
        return self.bin(1)

    def bin(self, min_prec):
        kind = self.unary()
        while True:
            t = self.tok()
            if t.kind != "p" or t.text not in BINOPS:
                break
            prec = BINOPS[t.text]
            if prec < min_prec:
                break
            self.bump()
            self.bin(prec + 1)
            kind = "other"
        return kind

    def unary(self):
        t = self.tok()
        if t.kind == "p" and t.text in ("-", "!", "~", "&", "*"):
            self.bump()
            self.unary()
            return "other"
        return self.postfix()

    def args(self, close):
        save = self.no_lit
        self.no_lit = False
        try:
            while not self.is_p(close):
                self.expr()
                if not self.eat_p(","):
                    break
            self.expect_p(close)
        finally:
            self.no_lit = save

    def postfix(self):
        kind = self.primary()
        while True:
            if self.eat_p("("):
                self.args(")")
                kind = "other"
            elif self.eat_p("["):
                save = self.no_lit
                self.no_lit = False
                try:
                    is_index = self.index_tail()
                finally:
                    self.no_lit = save
                kind = "index" if is_index and kind == "ident" else "other"
            elif self.eat_p("."):
                if self.tok().kind in ("id", "int"):
                    self.bump()
                else:
                    self.err("expected field name")
                kind = "other"
            elif self.is_p("{") and kind in ("ident", "type", "index") and (not self.no_lit or self.lit_in_header(kind)):
                self.bump()
                save = self.no_lit
                self.no_lit = False
                try:
                    self.lit_body()
                finally:
                    self.no_lit = save
                kind = "other"
            else:
                break
        return kind

    def index_tail(self):
        """after `[`; true for an index, false for a slice"""
        if self.eat_p(".."):
            if not self.is_p("]"):
                self.expr()
            self.expect_p("]")
            return False
        self.expr()
        if self.eat_p(".."):
            if not self.is_p("]"):
                self.expr()
            self.expect_p("]")
            return False
        while self.eat_p(","):
            self.expr()
        self.expect_p("]")
        return True

    def lit_body(self):
        while True:
            while self.is_nl():
                self.bump()
            if self.eat_p("}"):
                break
            if self.is_id() and self.is_p(":", 1):
                self.bump()
                self.bump()
            self.expr()
            while self.is_nl():
                self.bump()
            if not self.eat_p(","):
                while self.is_nl():
                    self.bump()
                self.expect_p("}")
                break

    def primary(self):
        t = self.tok()
        if t.kind in ("int", "float", "str", "dots"):
            self.bump()
            return "other"
        if t.kind == "id":
            self.bump()
            return "ident"
        if t.kind == "kw":
            k = t.text
            if k in ("true", "false", "nil"):
                self.bump()
                return "other"
            if k == "if":
                self.bump()
                self.if_stmt()
                return "other"
            if k == "match":
                self.bump()
                self.header_expr(False)
                self.expect_p("{")
                save = self.no_lit
                self.no_lit = False
                try:
                    self.match_arms()
                finally:
                    self.no_lit = save
                return "other"
            if k == "fn":
                return self.fn_expr()
        elif t.kind == "p":
            if t.text == "(":
                if self.at_fn():
                    return self.anon_fn()
                if self.at_old_params():
                    self.err("a parameter of an anonymous function is written `name: Type`")
                if self.parens_then("->"):
                    self.ty()
                    return "type"
                self.bump()
                save = self.no_lit
                self.no_lit = False
                try:
                    kind = self.expr()
                    if self.is_p(","):
                        kind = "other"
                        while self.eat_p(","):
                            if self.is_p(")"):
                                break
                            self.expr()
                    self.expect_p(")")
                finally:
                    self.no_lit = save
                return kind
            if t.text == "[":
                self.ty()
                return "type"
        self.err("expected expression")

    def anon_fn(self):
        """`(a: A, b: B) -> R { ... }` -> `fn(a: A, b: B) -> R { ... }`; `() -> R` is a type"""
        lp = self.tok()
        if self.is_p(")", 1) and self.is_p("->", 2):
            start = self.i
            mark = len(self.edits)
            self.ty()
            if not self.is_p("{"):
                return "type"
            self.i = start
            del self.edits[mark:]
        self.insert(lp.pos, "fn")
        self.fn_sig()
        self.block()
        return "other"

    def fn_expr(self):
        """at `fn` in an expression: an anonymous function or a function type"""
        if self.is_p("[", 1):
            self.err("an anonymous function cannot have type parameters of its own")
        if self.is_id(2) and self.is_p(":", 3):
            self.bump()
            self.fn_sig()
            self.block()
            return "other"
        no_params = self.is_p("(", 1) and self.is_p(")", 2)
        self.ty()
        if not self.is_p("{"):
            return "type"
        if not (no_params or self.fragment):
            self.err("an anonymous function names its parameters")
        self.block()
        return "other"

    def match_arms(self):
        while True:
            self.skip_nl()
            if self.eat_p("}"):
                break
            if self.is_dots() and not self.is_p("=>", 1):
                self.bump()
                continue
            while True:
                self.expr()
                if not self.eat_p(","):
                    break
            if self.eat_kw("if"):
                self.expr()
            self.expect_p("=>")
            if self.is_p("{"):
                self.block()
            else:
                self.stmt()
            if not (self.is_nl() or self.is_p(";") or self.is_p("}")):
                self.err("expected end of match arm")


def apply_edits(src, edits, comments):
    """the edited text; comments that were set off by two or more blanks keep their column"""
    if not edits:
        return src
    edits = sorted(enumerate(edits), key=lambda e: (e[1][0], e[0]))
    # line starts, to find the comment of a line
    out = []
    last = 0
    # per edit: record the change in length at its offset
    shifts = []     # (offset, delta)
    for _, (off, dele, ins) in edits:
        if off < last:
            raise AssertionError("overlapping edits at offset %d" % off)
        out.append(src[last:off])
        out.append(ins)
        last = off + dele
        shifts.append((off, len(ins) - dele))
    out.append(src[last:])
    if not comments:
        return "".join(out)
    # realign comments: work line by line on the original text
    by_line = {}
    for off, delta in shifts:
        ls = src.rfind("\n", 0, off) + 1
        by_line[ls] = by_line.get(ls, 0) + delta
    fix = []        # (offset in the original text, blanks to add (> 0) or remove (< 0))
    for c in comments:
        ls = src.rfind("\n", 0, c) + 1
        delta = by_line.get(ls, 0)
        if delta == 0:
            continue
        g = c
        while g > ls and src[g - 1] == " ":
            g -= 1
        gap = c - g
        if gap < 2 or g == ls:
            continue
        if any(off >= c for off, _ in shifts if src.rfind("\n", 0, off) + 1 == ls):
            continue
        if delta > 0:
            take = min(delta, gap - 2)
            if take > 0:
                fix.append((g, -take))
        else:
            fix.append((g, -delta))
    if not fix:
        return "".join(out)
    all_edits = [e for _, e in edits]
    for g, d in fix:
        if d > 0:
            all_edits.append((g, 0, " " * d))
        else:
            all_edits.append((g, -d, ""))
    return apply_edits(src, all_edits, None)


def convert(text, fragment=False):
    """`text` in the new syntax and the list of (line, message) of what did not parse"""
    p = Parser(text, fragment)
    p.file()
    new = apply_edits(text, p.edits, p.comments)
    if new.count("\n") != text.count("\n"):
        raise AssertionError("line structure changed")
    return new, sorted(set(p.problems))




def convert_span(code):
    """an inline piece of code (a `code span`, backticks in a comment): converted if all of it
    parses as AL and something in it is old syntax; else None"""
    if "\n" in code or not ("::" in code or "->" in code or " : " in code):
        return None
    p = Parser(code, True)
    p.file()
    if p.problems or not p.edits:
        return None
    return apply_edits(code, p.edits, None)


SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)")


def convert_spans(line):
    def one(m):
        code = m.group(2)
        pad = code.startswith(" ") and code.endswith(" ") and len(code) > 2
        new = convert_span(code.strip() if pad else code)
        if new is None:
            return m.group(0)
        if pad:
            new = " " + new + " "
        ticks = m.group(1)
        return ticks + new + ticks
    return SPAN.sub(one, line)


def convert_comments(text):
    """AL code quoted in backticks inside the // comments of an .al file"""
    _, comments = lex(text, False)
    out = []
    last = 0
    for c in comments:
        e = text.find("\n", c)
        if e < 0:
            e = len(text)
        out.append(text[last:c])
        out.append(convert_spans(text[c:e]))
        last = e
    out.append(text[last:])
    return "".join(out)


FENCE = re.compile(r"^(\s*)(```+|~~~+)\s*([A-Za-z0-9_+-]*)\s*$")


def convert_markdown(text, inline=True):
    """Markdown: AL code in fences (and in inline code). Returns (text, problems); the problems
    are (line, message) of fences in which something was converted and something else did not
    parse."""
    lines = text.split("\n")
    out = []
    problems = []
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            out.append(convert_spans(lines[i]) if inline else lines[i])
            i += 1
            continue
        fence = m.group(2)
        lang = m.group(3).lower()
        j = i + 1
        while j < len(lines) and not (lines[j].strip().startswith(fence) and lines[j].strip().strip(fence[0]) == ""):
            j += 1
        body = lines[i + 1:j]
        out.append(lines[i])
        if lang in ("", "al") and body:
            code = "\n".join(body)
            new, probs = convert(code, True)
            if new != code:
                for line, msg in probs:
                    problems.append((i + 1 + line, msg))
            out.extend(new.split("\n"))
        else:
            out.extend(body)
        if j < len(lines):
            out.append(lines[j])
        i = j + 1
    return "\n".join(out), problems


def main(argv):
    opts = {"--check": False, "--diff": False, "--stdout": False, "--comments": False, "--no-inline": False, "-q": False}
    files = []
    for a in argv:
        if a in opts:
            opts[a] = True
        elif a.startswith("-"):
            sys.stderr.write(__doc__)
            return 64
        else:
            files.append(a)
    if not files:
        sys.stderr.write(__doc__)
        return 64
    status = 0
    changed = 0
    for path in files:
        with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
            text = f.read()
        if path.endswith(".md"):
            new, problems = convert_markdown(text, not opts["--no-inline"])
        else:
            new, problems = convert(text)
            if opts["--comments"]:
                new = convert_comments(new)
            if problems:
                status = max(status, 2)
        for line, msg in problems:
            sys.stderr.write("%s:%d: not converted: %s\n" % (path, line, msg))
        if opts["--stdout"]:
            sys.stdout.write(new)
            continue
        if new == text:
            continue
        changed += 1
        if opts["--diff"]:
            sys.stdout.writelines(difflib.unified_diff(text.splitlines(True), new.splitlines(True), path, path))
        elif opts["--check"]:
            print("%s: old syntax" % path)
        else:
            with open(path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
                f.write(new)
            if not opts["-q"]:
                print("converted %s" % path)
    if opts["--check"] and changed:
        status = max(status, 1)
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))