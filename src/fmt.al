// `alc fmt`: the canonical layout of AL source files (docs/DETAILS.md#alc-fmt).
//
// The formatter changes white space only: the tokens of a file and the lines they are on stay
// as written (no line is joined or broken, so the newlines that end statements cannot move),
// comments keep their text and their line. What it decides:
//   - indentation: 4 spaces per open bracket of the lines before (several brackets opened on
//     one line count once), a line that starts with a closing bracket at the indentation of
//     the line that opened it, 4 more for a line that continues a statement after a line
//     ending in an operator; a comment line is indented like code in its place
//   - spaces inside a line: one around binary operators, `=`, `:=`, `->`, `=>`; none after a
//     unary operator, around `.`, `..`, `..=`, inside `( )` and `[ ]`, before `,` `;` `:`, before
//     a call's `(` or an index's `[`; after `,` `;` `:` one; a literal `T{a, b}` has none inside
//     its braces, a block `{ x }` one; `{}` none
//   - a comment after code keeps its column (moved with the line's indentation) when the code
//     still ends before it, else one space separates them
//   - blank lines: at most one in a row, none after a line that ends in an opening bracket,
//     before a line that starts with a closing one, at the start or end of the file
//   - no trailing white space, one line end after the last line; the line ends of the file
//     (LF, or CRLF if its first line ends so) except inside raw strings, which stay as they are
// A file with a syntax error is not changed. Before a result is used it is checked: lexed
// again it must give the same tokens (newlines that end statements included) and the same
// comments, and formatting it again must not change it.

use std.asset

// a token or a comment of the file being formatted
priv struct Item {
    tok: bool               // a token (else a comment)
    t: Tk
    text: str               // as written
    line: i64               // the line it starts on
    end_line: i64           // the line it ends on (a raw string may span lines)
    col: i64                // its column in the original, from 0
    lit: bool               // the `{` of a literal (the parser says which)
}

// a file taken apart: its items, every token of the lexer (Nl and Eof too), and its errors
priv struct Src {
    items: Vec[Item]
    toks: Vec[Token]
    errs: Vec[Diag]
}

// an open bracket: its byte, the indentation of the line that opened it (without the extra
// of a continuation line), a literal's `{`, a `[` that starts a type (`[]T`, `[4]u8`)
priv struct Open {
    ch: i64
    base: i64
    lit: bool
    prefix: bool
    // a block's `{` whose lines may continue after a `,` (statements, the arms of a `match`;
    // not the members of a `struct` or `enum`, separated by commas)
    comma_cont: bool
}

priv fn punct(t: Tk, c: i64) -> bool {
    return match t {
        P(q) => q == c
        _ => false
    }
}

priv fn opener(t: Tk) -> bool {
    return punct(t, '(') || punct(t, '[') || punct(t, '{')
}

priv fn closer(t: Tk) -> bool {
    return punct(t, ')') || punct(t, ']') || punct(t, '}')
}

// a token that ends an operand: a following `-`, `*`, `&` is binary, `(` a call, `[` an index
// (`pclose`: a `]` that closes the `[` of a type, after which a type follows)
priv fn ends_operand(t: Tk, pclose: bool) -> bool {
    return match t {
        Id(_), Int(_, _), Float(_, _), Str(_) => true
        Kw(k) => k == KW_TRUE || k == KW_FALSE || k == KW_NIL
        P(c) => c == ')' || c == '}' || (c == ']' && !pclose)
        _ => false
    }
}

// a token at the end of a line after which the statement continues on the next line (an
// operator; not a bracket, `,`, `;`, or the `:` of a label on the line before its loop)
priv fn continues(t: Tk) -> bool {
    return match t {
        P(c) => !(opener(t) || closer(t) || c == ',' || c == ';' || c == ':')
        _ => false
    }
}

// the end of the token that starts at s[i]; the next token starts at `to`
priv fn tok_end(s: str, i: i64, to: i64) -> i64 {
    q := s[i]
    if q == '"' || q == '\'' {
        j := i + 1
        while j < to && s[j] != q {
            j += if s[j] == '\\' { 2 } else { 1 }
        }
        return min(j + 1, to)
    }
    if q == '`' {
        j := i + 1
        while j < to && s[j] != '`' {
            j += 1
        }
        return min(j + 1, to)
    }
    j := i + 1
    while j < to && s[j] != ' ' && s[j] != '\t' && s[j] != '\r' && s[j] != '\n' && !(s[j] == '/' && j + 1 < len(s) && s[j + 1] == '/') {
        j += 1
    }
    return j
}

// The comments in s[i..to], where nothing but white space and comments may stand; the line
// at `to`, or -1 if something else is there.
priv fn gap(s: str, i: i64, to: i64, line: i64, starts: *Vec[i64], items: *Vec[Item]) -> i64 {
    while i < to {
        c := s[i]
        if c == '\n' {
            line += 1
            i += 1
        } else if c == ' ' || c == '\t' || c == '\r' {
            i += 1
        } else if c == '/' && i + 1 < to && s[i + 1] == '/' {
            j := i
            while j < to && s[j] != '\n' {
                j += 1
            }
            items.push(Item{tok: false, text: trim_right(s[i..j], " \t\r"), line: line, end_line: line, col: i - starts[line]})
            i = j
        } else {
            return -1
        }
    }
    return line
}

priv fn internal(r: *Src, line: i64, what: str) {
    r.errs.push(Diag{pos: Pos{file: 0, line: i32(line), col: 1}, msg: fmt("internal error of alc fmt: ", what, " (the file is left as it is; please report this)")})
}

// lexes and parses `s`; its items if it has no errors
priv fn scan(s: str) -> Src {
    r := Src{}
    toks := lexer_lex(s, 0, &r.errs)
    r.toks = clone(toks)
    if !r.errs.is_empty() {
        return r
    }
    parser_lits.clear()
    parser_lits_on = true
    p := parser_new(toks, &r.errs)
    p.file()
    parser_lits_on = false
    if !r.errs.is_empty() {
        return r
    }
    lits := map[i64, bool]()
    for q in parser_lits {
        lits.set(i64(q.line) << 32 | i64(q.col), true)
    }
    // the offset of each line's start (index: the line, from 1)
    starts := vec[i64]()
    starts.push(0)
    starts.push(if starts_with(s, "\xEF\xBB\xBF") { 3 } else { 0 })
    for i in 0..len(s) {
        if s[i] == '\n' {
            starts.push(i + 1)
        }
    }
    real := vec[Token]()
    for t in r.toks {
        if t.t != Nl && t.t != Eof {
            real.push(t)
        }
    }
    fn offset(starts: *Vec[i64], t: Token) -> i64 {
        return starts[i64(t.pos.line)] + i64(t.pos.col) - 1
    }
    at := starts[1]
    line := 1
    for k, t in real {
        off := offset(&starts, t)
        line = gap(s, at, off, line, &starts, &r.items)
        if line != i64(t.pos.line) {
            r.internal(i64(t.pos.line), "the text before this token")
            return r
        }
        to := if k + 1 < real.len { offset(&starts, real[k + 1]) } else { len(s) }
        e := tok_end(s, off, to)
        text := s[off..e]
        nl := count(text, "\n")
        key := i64(t.pos.line) << 32 | i64(t.pos.col)
        r.items.push(Item{tok: true, t: t.t, text: text, line: line, end_line: line + nl, col: i64(t.pos.col) - 1, lit: t.t == P('{') && lits.has(key)})
        at = e
        line += nl
    }
    if gap(s, at, len(s), line, &starts, &r.items) < 0 {
        r.internal(line, "the text after the last token")
    }
    return r
}

// the output of `layout`
priv struct Out {
    b: Vec[u8]
    line_start: i64         // where the current line starts in b
}

priv fn add(o: *Out, s: str) {
    o.b.extend(s)
}

priv fn pad(o: *Out, n: i64) {
    for _ in 0..n {
        o.b.push(' ')
    }
}

// whether one space separates the tokens a and b on a line (a_unary: a is a unary operator,
// a_pclose: a `]` that closes the `[` of a type, a_lit / b_lit: braces of a literal)
priv fn space(a: Tk, a_unary: bool, a_pclose: bool, a_lit: bool, b: Tk, b_lit: bool) -> bool {
    if punct(b, ',') || punct(b, ';') || punct(b, ')') || punct(b, ']') {
        return false
    }
    if punct(b, '}') {
        return !punct(a, '{') && !b_lit
    }
    if punct(a, '{') {
        return !a_lit
    }
    if punct(a, '(') || punct(a, '[') || a_unary || a_pclose {
        return false
    }
    if punct(a, '.') || punct(b, '.') || punct(a, P_RANGE) || punct(b, P_RANGE) || punct(a, P_RANGE_EQ) || punct(b, P_RANGE_EQ) {
        return false
    }
    if punct(b, '(') {
        return !(ends_operand(a, a_pclose) || a == Kw(KW_FN) || punct(a, ']'))
    }
    if punct(b, '[') {
        return !(ends_operand(a, a_pclose) || punct(a, ']'))
    }
    if punct(b, '{') {
        return !b_lit
    }
    if punct(b, ':') {
        return false
    }
    return true
}

// The text of a scanned file in the canonical layout. `crlf`: lines end in "\r\n".
priv fn layout(sc: *Src, crlf: bool, bom: bool) -> str {
    eol := if crlf { "\r\n" } else { "\n" }
    items := sc.items
    o := Out{}
    if bom {
        o.add("\xEF\xBB\xBF")
        o.line_start = 3
    }
    stack := vec[Open]()
    // the previous token: its kind, a unary operator, a `]` of a type, a literal's brace
    pt := Tk.Eof
    p_unary := false
    p_pclose := false
    p_lit := false
    // the previous line of code ends in an operator (or a `,` where that continues the
    // statement) / in an opening bracket
    cont := false
    cont_extra := 0
    opened := false
    last_end := 0
    // `struct`, `enum` or `match` seen at this depth of brackets: the kind of the next block
    hdr := -1
    hdr_depth := -1
    // the last comment after code: its column in the original and in the result (a comment
    // line below it in the same column continues it)
    tc_col := -1
    tc_at := 0
    k := 0
    while k < items.len {
        g0 := k
        end := items[k].end_line
        k += 1
        while k < items.len && items[k].line <= end {
            end = max(end, items[k].end_line)
            k += 1
        }
        first := items[g0]
        starts_closed := first.tok && closer(first.t)
        if last_end > 0 {
            if first.line > last_end + 1 && !opened && !starts_closed {
                o.add(eol)
                o.line_start = o.b.len
            }
        }
        prev_end := last_end
        last_end = end
        // the indentation
        extra := if cont && !starts_closed { cont_extra } else { 0 }
        indent := 0
        if starts_closed {
            indent = stack.last().base
        } else if stack.len > 0 {
            indent = stack.last().base + 4 + extra
        } else {
            indent = extra
        }
        base := indent - extra
        // a comment line that continues the comment after the code of the line above
        tc_prev := tc_col
        tc_col = -1
        if !first.tok && k == g0 + 1 && first.col == tc_prev && prev_end + 1 == first.line {
            indent = tc_at
            tc_col = tc_prev
        }
        o.pad(indent)
        multi := end > first.line
        has_tok := false
        // brackets closed on this line below the depth it started at: the indentation of the
        // last one (a bracket opened after them belongs to the line that opened that one)
        depth0 := stack.len
        close_base := base
        for i in g0..k {
            it := items[i]
            if !it.tok {
                if i > g0 {
                    // after code: in its column, moved with the line, if the code ends before it
                    cur := o.b.len - o.line_start
                    at := if multi { it.col } else { it.col + indent - first.col }
                    o.pad(if at > cur { at - cur } else { 1 })
                    tc_col = it.col
                    tc_at = o.b.len - o.line_start
                }
                o.add(it.text)
                continue
            }
            t := it.t
            first_tok := !has_tok
            unary := (punct(t, '-') || punct(t, '*') || punct(t, '&')) && (first_tok || !ends_operand(pt, p_pclose))
            unary = unary || punct(t, '!') || punct(t, '~')
            lit := it.lit
            pclose := false
            if closer(t) && stack.len > 0 {
                top := stack.pop()
                lit = top.lit
                pclose = top.prefix
                if stack.len < depth0 {
                    close_base = top.base
                }
            }
            if !first_tok && space(pt, p_unary, p_pclose, p_lit, t, lit) {
                o.add(" ")
            }
            match t {
                Kw(kw) if kw == KW_STRUCT || kw == KW_ENUM || kw == KW_MATCH => {
                    hdr = kw
                    hdr_depth = stack.len
                }
                _ => {}
            }
            if opener(t) {
                prefix := punct(t, '[') && (first_tok || !ends_operand(pt, p_pclose))
                ch := if punct(t, '(') { '(' } else if punct(t, '[') { '[' } else { '{' }
                comma_cont := false
                if ch == '{' && !lit {
                    comma_cont = !(hdr_depth == stack.len && (hdr == KW_STRUCT || hdr == KW_ENUM))
                    if hdr_depth == stack.len {
                        hdr_depth = -1
                    }
                }
                stack.push(Open{ch: ch, base: if stack.len < depth0 { close_base } else { base }, lit: lit, prefix: prefix, comma_cont: comma_cont})
            }
            o.add(it.text)
            nl := rfind(it.text, "\n")
            if nl >= 0 {
                o.line_start = o.b.len - len(it.text) + nl + 1
            }
            pt = t
            p_unary = unary
            p_pclose = pclose
            p_lit = lit
            has_tok = true
        }
        if has_tok {
            // the next line continues this one: 4 more, unless a bracket left open here
            // indents it already; a third line continues like the second
            was_cont := cont
            cont = continues(pt) || (punct(pt, ',') && (stack.len == 0 || stack.last().comma_cont))
            if cont {
                cont_extra = if was_cont { extra } else if stack.len > depth0 { 0 } else { 4 }
            }
            opened = opener(pt)
        } else {
            opened = false
        }
        o.add(eol)
        o.line_start = o.b.len
    }
    return o.b.items()
}

// The canonical layout of the source text `s`; the diagnostics (file 0) if it has syntax
// errors or the result would not be safe, and then `s` itself.
fn fmt_source(s: str) -> (str, Vec[Diag]) {
    sc := scan(s)
    if !sc.errs.is_empty() {
        return (s, sc.errs)
    }
    nl := find(s, "\n")
    crlf := nl > 0 && s[nl - 1] == '\r'
    bom := starts_with(s, "\xEF\xBB\xBF")
    out := layout(&sc, crlf, bom)
    // the checks: the same tokens and comments, and a fixed point
    again := scan(out)
    if !again.errs.is_empty() {
        sc.internal(i64(again.errs[0].pos.line), fmt("the result does not parse: ", again.errs[0].msg))
        return (s, sc.errs)
    }
    n := min(sc.toks.len, again.toks.len)
    for i in 0..n {
        if sc.toks[i].t != again.toks[i].t {
            sc.internal(i64(sc.toks[i].pos.line), "the result would have other tokens here")
            return (s, sc.errs)
        }
    }
    if sc.toks.len != again.toks.len {
        sc.internal(1, "the result would have another number of tokens")
        return (s, sc.errs)
    }
    na := 0
    for it in sc.items {
        if !it.tok {
            na += 1
        }
    }
    comments := vec[str]()
    for it in again.items {
        if !it.tok {
            comments.push(it.text)
        }
    }
    ci := 0
    for it in sc.items {
        if !it.tok {
            if ci >= comments.len || comments[ci] != it.text {
                sc.internal(it.line, "the result would lose or change this comment")
                return (s, sc.errs)
            }
            ci += 1
        }
    }
    if ci != comments.len || na != comments.len {
        sc.internal(1, "the result would have other comments")
        return (s, sc.errs)
    }
    if layout(&again, crlf, bom) != out {
        sc.internal(1, "formatting the result again would change it")
        return (s, sc.errs)
    }
    return (out, sc.errs)
}

// the .al files under a directory, in the order of their paths (names that start with `.`
// are skipped)
priv fn walk(dir: str, out: *Vec[str]) {
    names := vec_of(list_dir(dir))
    sort(names.items())
    for n in names {
        if len(n) == 0 || n[0] == '.' {
            continue
        }
        p := path_join(dir, n)
        if is_dir(p) {
            walk(p, out)
        } else if ends_with(n, ".al") {
            out.push(p)
        }
    }
}

priv const FMT_USAGE = "usage: alc fmt [--check | --stdout] <file.al | directory | -> ...\n  rewrites the files in place in the canonical layout (directories: every .al file in them)\n  --check   change nothing; list the files that would change (exit status 1 if any)\n  --stdout  write the result to standard output instead of the file\n  -         read standard input, write standard output\n"

// `alc fmt ARGS`. `report` prints the diagnostics of files named by `names` (main.al), and
// tells whether there were any.
fn fmt_main(argv: []str, report: fn(*Vec[str], *Vec[Diag]) -> bool) -> i64 {
    check := false
    to_stdout := false
    paths := vec[str]()
    for a in argv {
        if a == "--check" {
            check = true
        } else if a == "--stdout" {
            to_stdout = true
        } else if a == "-" || !starts_with(a, "-") {
            paths.push(a)
        } else {
            eput(fmt("unknown option ", a, "\n", FMT_USAGE))
            return 2
        }
    }
    if paths.len == 0 || (check && to_stdout) {
        eput(FMT_USAGE)
        return 2
    }
    files := vec[str]()
    for p in paths {
        if p != "-" && is_dir(p) {
            walk(p, &files)
        } else {
            files.push(p)
        }
    }
    status := 0
    for f in files {
        text := ""
        if f == "-" {
            text = read_all(0)
        } else {
            t, ok := read_file(f)
            if !ok {
                eput(fmt("error: cannot read `", f, "`: ", os_error(io_error()), "\n"))
                status = 1
                continue
            }
            text = t
        }
        names := vec_one(if f == "-" { "<stdin>" } else { f })
        if find(text, "\x00") >= 0 {
            eput(fmt("error: `", names[0], "` is not a source file (it contains NUL bytes)\n"))
            status = 1
            continue
        }
        out, errs := fmt_source(text)
        if report(&names, &errs) {
            status = 1
            if f == "-" || to_stdout {
                put(text)
            }
            continue
        }
        if f == "-" || to_stdout {
            put(out)
        } else if out != text {
            if check {
                print(f)
                status = 1
            } else if !write_file(f, out) {
                eput(fmt("error: cannot write `", f, "`: ", os_error(io_error()), "\n"))
                status = 1
            }
        }
    }
    return status
}
