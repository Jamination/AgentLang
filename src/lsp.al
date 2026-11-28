// `alc lsp`: Language Server Protocol (LSP 3.17) server over stdio.
//
// Reuses the real AL compiler frontend (lexer, parser, when, priv, lower, fmt) directly so
// diagnostics, hover types, overload-resolved go-to-definition, references, completions,
// signature help, document symbols, and formatting stay 100% in sync with `alc`.
//
// Memory model: persistent open-document overlays live in the main arena; each analysis or
// formatting request runs inside a fresh temporary Region that is freed right after writing
// the JSON-RPC response, with frontend global caches reset before leaving.

use std.asset

// ---------- JSON encoding helpers (bootstrap-safe, no std.asset json_stringify needed) ----------
priv fn lsp_jstr(s: str) -> str {
    out := vec[u8]()
    out.push('"')
    for c in s {
        match c {
            '"' => out.extend("\\\"")
            '\\' => out.extend("\\\\")
            '\n' => out.extend("\\n")
            '\r' => out.extend("\\r")
            '\t' => out.extend("\\t")
            _ if c < 0x20 => {
                out.extend("\\u00")
                out.extend(hex(u64(c), 2))
            }
            _ => out.push(c)
        }
    }
    out.push('"')
    return out.items()
}

priv fn lsp_range_json(sl: i64, sc: i64, el: i64, ec: i64) -> str {
    return fmt("{\"start\":{\"line\":", max(sl, 0), ",\"character\":", max(sc, 0), "},\"end\":{\"line\":", max(el, 0), ",\"character\":", max(ec, 0), "}}")
}

priv fn lsp_loc_json(uri: str, sl: i64, sc: i64, el: i64, ec: i64) -> str {
    return fmt("{\"uri\":", lsp_jstr(uri), ",\"range\":", lsp_range_json(sl, sc, el, ec), "}")
}

priv fn lsp_id_json(v: *Json) -> str {
    if v == nil {
        return ""
    }
    if v.kind == JsonNumber {
        return v.text
    }
    if v.kind == JsonString {
        return lsp_jstr(v.text)
    }
    return "null"
}

// ---------- JSON-RPC stdio transport (Content-Length framing) ----------
priv struct LspReader {
    buf: [8192]u8
    pos: i64
    len: i64
    eof: bool
}

priv fn lsp_read_byte(r: *LspReader) -> i64 {
    if r.pos >= r.len {
        if r.eof {
            return -1
        }
        n := __os_read(0, cast[i64](ptr(r.buf[..])), 8192)
        if n <= 0 {
            r.eof = true
            return -1
        }
        r.pos = 0
        r.len = n
    }
    b := i64(r.buf[r.pos])
    r.pos += 1
    return b
}

priv fn lsp_read_line(r: *LspReader) -> (str, bool) {
    out := vec[u8]()
    loop {
        b := lsp_read_byte(r)
        if b < 0 {
            if out.is_empty() {
                return ("", false)
            }
            break
        }
        if b == '\n' {
            break
        }
        if b != '\r' {
            out.push(u8(b))
        }
    }
    return (out.items(), true)
}

priv fn lsp_read_exact(r: *LspReader, n: i64) -> (str, bool) {
    if n < 0 || n > (64 << 20) {
        return ("", false)
    }
    out := mkslice[u8](__alloc_raw(n), n)
    got := 0
    while got < n {
        if r.pos < r.len {
            avail := min(r.len - r.pos, n - got)
            memcopy(cast[i64](ptr(out)) + got, cast[i64](ptr(r.buf[..])) + r.pos, avail)
            r.pos += avail
            got += avail
        } else {
            k := __os_read(0, cast[i64](ptr(out)) + got, n - got)
            if k <= 0 {
                r.eof = true
                return ("", false)
            }
            got += k
        }
    }
    return (out, true)
}

priv fn lsp_read_msg(r: *LspReader) -> (str, bool) {
    clen := -1
    loop {
        line, ok := lsp_read_line(r)
        if !ok {
            return ("", false)
        }
        if len(line) == 0 {
            if clen >= 0 {
                break
            }
            continue
        }
        low := to_lower(line)
        if starts_with(low, "content-length:") {
            v, vok := parse_i64(trim(line[15..]))
            if vok && v >= 0 {
                clen = v
            }
        }
    }
    return lsp_read_exact(r, clen)
}

priv fn lsp_send(body: str) {
    put(fmt("Content-Length: ", len(body), "\r\n\r\n"))
    put(body)
    flush()
}

// when true (`alc query`), lsp_ok prints the raw JSON result to stdout instead of LSP framing
priv lsp_raw_stdout: bool

priv fn lsp_ok(id_json: str, result_json: str) {
    if lsp_raw_stdout {
        print(result_json)
        return
    }
    if len(id_json) == 0 {
        return
    }
    lsp_send(fmt("{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"result\":", result_json, "}"))
}

priv fn lsp_err(id_json: str, code: i64, msg: str) {
    if len(id_json) == 0 {
        return
    }
    lsp_send(fmt("{\"jsonrpc\":\"2.0\",\"id\":", id_json, ",\"error\":{\"code\":", code, ",\"message\":", lsp_jstr(msg), "}}"))
}

priv fn lsp_notify(method: str, params_json: str) {
    lsp_send(fmt("{\"jsonrpc\":\"2.0\",\"method\":", lsp_jstr(method), ",\"params\":", params_json, "}"))
}

// ---------- URI <-> path helpers ----------
priv fn hex_val(c: u8) -> i64 {
    if c >= '0' && c <= '9' {
        return i64(c - '0')
    }
    if c >= 'a' && c <= 'f' {
        return i64(c - 'a') + 10
    }
    if c >= 'A' && c <= 'F' {
        return i64(c - 'A') + 10
    }
    return -1
}

priv fn lsp_pct_decode(s: str) -> str {
    out := vec[u8]()
    i := 0
    while i < len(s) {
        if s[i] == '%' && i + 2 < len(s) {
            hi := hex_val(s[i + 1])
            lo := hex_val(s[i + 2])
            if hi >= 0 && lo >= 0 {
                out.push(u8((hi << 4) | lo))
                i += 3
                continue
            }
        }
        out.push(s[i])
        i += 1
    }
    return out.items()
}

priv fn lsp_pct_encode(s: str) -> str {
    out := vec[u8]()
    for c in s {
        keep := is_alnum(c) || c == '/' || c == '-' || c == '_' || c == '.' || c == '~' || c == ':'
        if keep {
            out.push(c)
        } else {
            out.push('%')
            out.extend(to_upper(hex(u64(c), 2)))
        }
    }
    return out.items()
}

fn lsp_norm_path(p: str) -> str {
    s := replace(p, "\\", "/")
    // collapse redundant slashes and trailing slash (except root "/")
    parts := vec[str]()
    abs := starts_with(s, "/")
    for seg in split(s, '/') {
        if len(seg) == 0 || seg == "." {
            continue
        }
        if seg == ".." && !parts.is_empty() && parts.last() != ".." {
            parts.pop()
            continue
        }
        parts.push(seg)
    }
    joined := join(parts.items(), "/")
    if abs {
        return concat("/", joined)
    }
    return joined
}

priv fn lsp_abs_path(p: str) -> str {
    if host_root(p) > 0 {
        return lsp_norm_path(p)
    }
    cwd := __os_current_dir()
    if len(cwd) > 0 {
        return lsp_norm_path(path_join(cwd, p))
    }
    return lsp_norm_path(p)
}

priv fn lsp_uri_to_path(uri: str) -> str {
    s := uri
    if starts_with(s, "file://") {
        s = s[7..]
        // strip localhost if present
        if starts_with(s, "localhost/") {
            s = s[9..]
        }
        s = lsp_pct_decode(s)
        // Windows file:///C:/foo -> C:/foo
        if len(s) >= 3 && s[0] == '/' && is_alpha(s[1]) && s[2] == ':' {
            s = s[1..]
        }
    }
    return lsp_norm_path(s)
}

priv fn lsp_path_to_uri(path: str) -> str {
    abs := lsp_abs_path(path)
    // Windows drive path C:/... -> file:///C:/...
    if len(abs) >= 2 && is_alpha(abs[0]) && abs[1] == ':' {
        return concat("file:///", lsp_pct_encode(abs))
    }
    if starts_with(abs, "/") {
        return concat("file://", lsp_pct_encode(abs))
    }
    return concat("file:///", lsp_pct_encode(abs))
}

// ---------- text & position utilities ----------
priv fn lsp_is_ident(c: u8) -> bool {
    return is_alnum(c) || c == '_'
}

priv fn lsp_line_bounds(text: str, line0: i64) -> (i64, i64) {
    if line0 < 0 {
        return (0, 0)
    }
    cur := 0
    start := 0
    i := 0
    n := len(text)
    while i < n && cur < line0 {
        if text[i] == '\n' {
            cur += 1
            start = i + 1
        }
        i += 1
    }
    if cur < line0 {
        return (n, n)
    }
    end := start
    while end < n && text[end] != '\n' && text[end] != '\r' {
        end += 1
    }
    return (start, end)
}

priv fn lsp_line_text(text: str, line0: i64) -> str {
    s, e := lsp_line_bounds(text, line0)
    return text[s..e]
}

priv fn lsp_offset_of(text: str, line0: i64, col0: i64) -> i64 {
    s, e := lsp_line_bounds(text, line0)
    return min(s + max(col0, 0), e)
}

priv fn lsp_end_pos(text: str) -> (i64, i64) {
    line := 0
    col := 0
    for c in text {
        if c == '\n' {
            line += 1
            col = 0
        } else {
            col += 1
        }
    }
    return (line, col)
}

// identifier at 0-based (line0, col0): (word, start_col0, end_col0)
priv fn lsp_word_at(text: str, line0: i64, col0: i64) -> (str, i64, i64) {
    lt := lsp_line_text(text, line0)
    n := len(lt)
    if n == 0 {
        return ("", 0, 0)
    }
    c := min(max(col0, 0), n)
    if c == n || !lsp_is_ident(lt[c]) {
        if c > 0 && lsp_is_ident(lt[c - 1]) {
            c -= 1
        } else {
            return ("", col0, col0)
        }
    }
    lo := c
    while lo > 0 && lsp_is_ident(lt[lo - 1]) {
        lo -= 1
    }
    hi := c + 1
    while hi < n && lsp_is_ident(lt[hi]) {
        hi += 1
    }
    return (lt[lo..hi], lo, hi)
}

// smart 0-based [start_col, end_col) span for a 1-based diagnostic position
priv fn lsp_token_span(text: str, line1: i64, col1: i64) -> (i64, i64) {
    if line1 <= 0 {
        return (0, 0)
    }
    lt := lsp_line_text(text, line1 - 1)
    n := len(lt)
    sc := min(max(col1 - 1, 0), n)
    if sc < n && lsp_is_ident(lt[sc]) {
        ec := sc + 1
        while ec < n && lsp_is_ident(lt[ec]) {
            ec += 1
        }
        return (sc, ec)
    }
    return (sc, min(sc + 1, n))
}

priv fn lsp_apply_change(old_text: str, ch: *Json) -> str {
    nt := ch.get("text").as_str("")
    rng := ch.get("range")
    if rng == nil || rng.kind != JsonObject {
        return nt
    }
    st := rng.get("start")
    en := rng.get("end")
    a := lsp_offset_of(old_text, st.get("line").as_i64(0), st.get("character").as_i64(0))
    b := lsp_offset_of(old_text, en.get("line").as_i64(0), en.get("character").as_i64(0))
    if a > b {
        a = b
    }
    return fmt(old_text[..a], nt, old_text[b..])
}

// ---------- Server state ----------
priv struct LspServer {
    docs: Map[str, str]         // normalized path -> open document text
    uris: Map[str, str]         // normalized path -> original client URI
    root_path: str              // workspace root path (if provided in initialize)
    shutdown: bool
}

priv fn lsp_reset_frontend() {
    ast_reset()
    lexer_reset()
    parser_reset()
    lower_fn_reset()
}

priv fn lsp_uri_for(srv: *LspServer, fname: str) -> str {
    if starts_with(fname, "<std/") && ends_with(fname, ".al>") && len(srv.root_path) > 0 {
        cand := path_join(srv.root_path, fname[1..len(fname) - 1])
        if file_exists(cand) {
            return lsp_path_to_uri(cand)
        }
    }
    if starts_with(fname, "<") {
        return ""
    }
    norm := lsp_abs_path(fname)
    u, ok := srv.uris.get(norm)
    if ok {
        return u
    }
    return lsp_path_to_uri(norm)
}

priv fn lsp_text_for(srv: *LspServer, fname: str) -> str {
    norm := lsp_abs_path(fname)
    t, ok := srv.docs.get(norm)
    if ok {
        return t
    }
    return sigs_text(fname)
}

priv fn lsp_find_file_idx(names: *Vec[str], norm_path: str) -> i64 {
    for i in 0..names.len {
        if !starts_with(names[i], "<") && lsp_abs_path(names[i]) == norm_path {
            return i
        }
    }
    return -1
}

// ---------- Diagnostics ----------
priv fn lsp_publish_diags(srv: *LspServer, path: str, uri: str) {
    r := region()
    enter(&r)
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    cur_file := lsp_find_file_idx(&src.names, path)
    cur_text := srv.docs.get_or(path, "")
    all_errs := vec[Diag]()
    for d in src.errs {
        all_errs.push(d)
    }
    if ok {
        for d in cx.errs {
            all_errs.push(d)
        }
    }
    items := vec[str]()
    seen := map[str, bool]()
    for d in all_errs {
        // show diagnostics belonging to this open file (or file -1 / entry errors attributed to line 0)
        if d.pos.file >= 0 && cur_file >= 0 && d.pos.file != cur_file {
            continue
        }
        line0 := max(i64(d.pos.line) - 1, 0)
        sc, ec := lsp_token_span(cur_text, i64(d.pos.line), i64(d.pos.col))
        sev := if d.warn { 2 } else { 1 }
        msg := ast_plain_text(d.msg)
        dedup_key := fmt(line0, ":", sc, ":", sev, ":", msg)
        if seen.has(dedup_key) {
            continue
        }
        seen.set(dedup_key, true)
        items.push(fmt("{\"range\":", lsp_range_json(line0, sc, line0, ec), ",\"severity\":", sev, ",\"source\":\"alc\",\"message\":", lsp_jstr(msg), "}"))
    }
    lsp_notify("textDocument/publishDiagnostics", fmt("{\"uri\":", lsp_jstr(uri), ",\"diagnostics\":[", join(items.items(), ","), "]}"))
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Formatting ----------
priv fn lsp_handle_format(srv: *LspServer, id_json: str, path: str) {
    text, ok := srv.docs.get(path)
    if !ok {
        t, rok := read_file(path)
        if !rok {
            lsp_ok(id_json, "[]")
            return
        }
        text = t
    }
    r := region()
    enter(&r)
    out, errs := fmt_source(text)
    if !errs.is_empty() || out == text {
        lsp_ok(id_json, "[]")
    } else {
        el, ec := lsp_end_pos(text)
        edit := fmt("[{\"range\":", lsp_range_json(0, 0, el, ec), ",\"newText\":", lsp_jstr(out), "}]")
        lsp_ok(id_json, edit)
    }
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Document Symbols ----------
priv fn lsp_handle_symbols(srv: *LspServer, id_json: str, path: str) {
    text, ok := srv.docs.get(path)
    if !ok {
        t, rok := read_file(path)
        if !rok {
            lsp_ok(id_json, "[]")
            return
        }
        text = t
    }
    r := region()
    enter(&r)
    errs := vec[Diag]()
    toks := lexer_lex(text, 0, &errs)
    p := parser_new(toks, &errs)
    decls := p.file()
    items := vec[str]()
    for d in decls {
        match d {
            Fn(f) => {
                l0 := max(i64(f.pos.line) - 1, 0)
                c0 := max(i64(f.pos.col) - 1, 0)
                el0 := max(i64(f.body.end.line) - 1, l0)
                ec0 := max(i64(f.body.end.col), c0 + len(f.name))
                sig := ast_plain_text(ast_sig_str(&f))
                items.push(fmt("{\"name\":", lsp_jstr(ast_plain(f.name)), ",\"detail\":", lsp_jstr(sig), ",\"kind\":12,\"range\":", lsp_range_json(l0, c0, el0, ec0), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(f.name))), "}"))
            }
            Struct(s) => {
                l0 := max(i64(s.pos.line) - 1, 0)
                c0 := max(i64(s.pos.col) - 1, 0)
                children := vec[str]()
                for fld in s.fields {
                    ft := ast_type_str(&fld.1)
                    children.push(fmt("{\"name\":", lsp_jstr(fld.0), ",\"detail\":", lsp_jstr(ft), ",\"kind\":8,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(s.name)), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(s.name)), "}"))
                }
                sig := ast_plain_text(ast_struct_str(&s))
                items.push(fmt("{\"name\":", lsp_jstr(ast_plain(s.name)), ",\"detail\":", lsp_jstr(sig), ",\"kind\":23,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(s.name))), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(s.name))), ",\"children\":[", join(children.items(), ","), "]}"))
            }
            Enum(e) => {
                l0 := max(i64(e.pos.line) - 1, 0)
                c0 := max(i64(e.pos.col) - 1, 0)
                children := vec[str]()
                for v in e.variants {
                    children.push(fmt("{\"name\":", lsp_jstr(v.0), ",\"kind\":22,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(e.name)), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(e.name)), "}"))
                }
                sig := ast_plain_text(ast_enum_str(&e))
                items.push(fmt("{\"name\":", lsp_jstr(ast_plain(e.name)), ",\"detail\":", lsp_jstr(sig), ",\"kind\":10,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(e.name))), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(e.name))), ",\"children\":[", join(children.items(), ","), "]}"))
            }
            Const(c) => {
                l0 := max(i64(c.pos.line) - 1, 0)
                c0 := max(i64(c.pos.col) - 1, 0)
                items.push(fmt("{\"name\":", lsp_jstr(ast_plain(c.name)), ",\"kind\":14,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(c.name))), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(c.name))), "}"))
            }
            Global(g) => {
                l0 := max(i64(g.pos.line) - 1, 0)
                c0 := max(i64(g.pos.col) - 1, 0)
                items.push(fmt("{\"name\":", lsp_jstr(ast_plain(g.name)), ",\"kind\":13,\"range\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(g.name))), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + len(ast_plain(g.name))), "}"))
            }
            Test(t) => {
                l0 := max(i64(t.pos.line) - 1, 0)
                c0 := max(i64(t.pos.col) - 1, 0)
                el0 := max(i64(t.body.end.line) - 1, l0)
                items.push(fmt("{\"name\":", lsp_jstr(fmt("test \"", t.name, "\"")), ",\"kind\":12,\"range\":", lsp_range_json(l0, c0, el0, 1), ",\"selectionRange\":", lsp_range_json(l0, c0, l0, c0 + 4), "}"))
            }
            Use(_, _), When(_) => {}
        }
    }
    lsp_ok(id_json, fmt("[", join(items.items(), ","), "]"))
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Hit & Declaration Lookup Helpers ----------
// Finds the most specific LspHit covering 1-based (line1, col1) in `cur_file`, or -1.
priv fn lsp_find_hit(cx: *Cx, cur_file: i64, line1: i64, col1: i64) -> i64 {
    best := -1
    best_len := 1_000_000
    for i, h in cx.lsp_hits {
        if h.pos.file != cur_file || i64(h.pos.line) != line1 {
            continue
        }
        sc := i64(h.pos.col)
        ec := sc + i64(h.len)
        if col1 >= sc && col1 <= ec && i64(h.len) <= best_len {
            best = i
            best_len = i64(h.len)
        }
    }
    return best
}

// Looks up a top-level declaration by name (preferring exact line match if `line1 > 0`).
// Returns (found, def_pos, detail).
priv fn lsp_lookup_decl(cx: *Cx, name: str, cur_file: i64, line1: i64) -> (bool, Pos, str) {
    // 1. Exact declaration on this line in cur_file
    if line1 > 0 {
        for fd in cx.fn_decls {
            if fd.pos.file == cur_file && i64(fd.pos.line) == line1 && ast_plain(fd.name) == name {
                return (true, fd.pos, ast_plain_text(ast_sig_str(fd)))
            }
        }
        for sd in cx.struct_decls {
            if sd.pos.file == cur_file && i64(sd.pos.line) == line1 && ast_plain(sd.name) == name {
                return (true, sd.pos, ast_plain_text(ast_struct_str(sd)))
            }
        }
        for ed in cx.enum_decls {
            if ed.pos.file == cur_file && i64(ed.pos.line) == line1 && ast_plain(ed.name) == name {
                return (true, ed.pos, ast_plain_text(ast_enum_str(ed)))
            }
        }
        for k in cx.const_decls.keys() {
            cd := cx.const_decls.get_or(k, nil)
            if cd != nil && cd.pos.file == cur_file && i64(cd.pos.line) == line1 && ast_plain(cd.name) == name {
                return (true, cd.pos, fmt("const ", name))
            }
        }
        for k in cx.global_decls.keys() {
            gd := cx.global_decls.get_or(k, nil)
            if gd != nil && gd.pos.file == cur_file && i64(gd.pos.line) == line1 && ast_plain(gd.name) == name {
                ty := match gd.ty {
                    Some(t) => ast_plain_text(ast_type_str(&t))
                    None => "..."
                }
                return (true, gd.pos, fmt(name, ": ", ty))
            }
        }
    }
    // 2. General lookup across visible declarations (functions, structs, enums, consts, globals)
    for fd in cx.fn_decls {
        if ast_plain(fd.name) == name && (!ast_is_private(fd.name) || fd.pos.file == cur_file) && !starts_with(name, "__") {
            return (true, fd.pos, ast_plain_text(ast_sig_str(fd)))
        }
    }
    for sd in cx.struct_decls {
        if ast_plain(sd.name) == name && (!ast_is_private(sd.name) || sd.pos.file == cur_file) {
            return (true, sd.pos, ast_plain_text(ast_struct_str(sd)))
        }
    }
    for ed in cx.enum_decls {
        if ast_plain(ed.name) == name && (!ast_is_private(ed.name) || ed.pos.file == cur_file) {
            return (true, ed.pos, ast_plain_text(ast_enum_str(ed)))
        }
    }
    for k in cx.const_decls.keys() {
        cd := cx.const_decls.get_or(k, nil)
        if cd != nil && ast_plain(cd.name) == name && (!ast_is_private(cd.name) || cd.pos.file == cur_file) {
            return (true, cd.pos, fmt("const ", name))
        }
    }
    for k in cx.global_decls.keys() {
        gd := cx.global_decls.get_or(k, nil)
        if gd != nil && ast_plain(gd.name) == name && (!ast_is_private(gd.name) || gd.pos.file == cur_file) {
            ty := match gd.ty {
                Some(t) => ast_plain_text(ast_type_str(&t))
                None => "..."
            }
            return (true, gd.pos, fmt(name, ": ", ty))
        }
    }
    return (false, Pos{file: -1}, "")
}

priv fn lsp_doc_comment(srv: *LspServer, names: *Vec[str], def_pos: Pos) -> str {
    if def_pos.file < 0 || def_pos.file >= names.len || def_pos.line <= 0 {
        return ""
    }
    txt := lsp_text_for(srv, names[def_pos.file])
    if len(txt) == 0 {
        return ""
    }
    cl := comment_lines(txt)
    return sigs_doc(&cl, i64(def_pos.line))
}

// ---------- Hover ----------
priv fn lsp_handle_hover(srv: *LspServer, id_json: str, path: str, line0: i64, col0: i64) {
    r := region()
    enter(&r)
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    cur_file := lsp_find_file_idx(&src.names, path)
    cur_text := lsp_text_for(srv, path)
    word, ws, we := lsp_word_at(cur_text, line0, col0)
    detail := ""
    def_pos := Pos{file: -1}
    if ok && cur_file >= 0 {
        hi := lsp_find_hit(&cx, cur_file, line0 + 1, col0 + 1)
        if hi >= 0 {
            h := cx.lsp_hits[hi]
            detail = h.detail
            def_pos = h.def_pos
            ws = max(i64(h.pos.col) - 1, 0)
            we = ws + i64(h.len)
        } else if len(word) > 0 {
            found, dp, dt := lsp_lookup_decl(&cx, word, cur_file, line0 + 1)
            if found {
                detail = dt
                def_pos = dp
            }
        }
    }
    if len(detail) == 0 {
        lsp_ok(id_json, "null")
    } else {
        doc := lsp_doc_comment(srv, &src.names, def_pos)
        md := fmt("```al\n", detail, "\n```")
        if len(doc) > 0 {
            md = fmt(md, "\n\n", doc)
        }
        lsp_ok(id_json, fmt("{\"contents\":{\"kind\":\"markdown\",\"value\":", lsp_jstr(md), "},\"range\":", lsp_range_json(line0, ws, line0, we), "}"))
    }
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Go to Definition ----------
priv fn lsp_use_target(srv: *LspServer, cur_path: str, line_text: str) -> str {
    t := trim(line_text)
    if !starts_with(t, "use ") {
        return ""
    }
    rest := trim(t[4..])
    if starts_with(rest, "\"") {
        q := find(rest[1..], "\"")
        if q > 0 {
            rel := rest[1..1 + q]
            dir := path_parent(cur_path).or(".")
            cand := lsp_abs_path(path_join(dir, rel))
            if file_exists(cand) || srv.docs.has(cand) {
                return cand
            }
        }
    } else if starts_with(rest, "std.") && len(srv.root_path) > 0 {
        mname := rest[4..]
        // stop at space or comment
        sp := find(mname, " ")
        if sp >= 0 {
            mname = mname[..sp]
        }
        cand := lsp_abs_path(path_join(srv.root_path, fmt("std/", mname, ".al")))
        if file_exists(cand) {
            return cand
        }
    }
    return ""
}

priv fn lsp_handle_definition(srv: *LspServer, id_json: str, path: str, line0: i64, col0: i64) {
    r := region()
    enter(&r)
    cur_text := lsp_text_for(srv, path)
    // 1. Check `use "file.al"` or `use std.mod` on the current line
    use_tgt := lsp_use_target(srv, path, lsp_line_text(cur_text, line0))
    if len(use_tgt) > 0 {
        lsp_ok(id_json, lsp_loc_json(lsp_uri_for(srv, use_tgt), 0, 0, 0, 0))
        lsp_reset_frontend()
        leave()
        region_free(&r)
        return
    }
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    cur_file := lsp_find_file_idx(&src.names, path)
    def_pos := Pos{file: -1}
    dlen := 1
    if ok && cur_file >= 0 {
        hi := lsp_find_hit(&cx, cur_file, line0 + 1, col0 + 1)
        if hi >= 0 {
            def_pos = cx.lsp_hits[hi].def_pos
            dlen = i64(cx.lsp_hits[hi].len)
        } else {
            word, _, _ := lsp_word_at(cur_text, line0, col0)
            if len(word) > 0 {
                found, dp, _ := lsp_lookup_decl(&cx, word, cur_file, line0 + 1)
                if found {
                    def_pos = dp
                    dlen = len(word)
                }
            }
        }
    }
    if def_pos.file >= 0 && def_pos.file < src.names.len && def_pos.line > 0 {
        uri := lsp_uri_for(srv, src.names[def_pos.file])
        if len(uri) > 0 {
            dl0 := max(i64(def_pos.line) - 1, 0)
            dc0 := max(i64(def_pos.col) - 1, 0)
            lsp_ok(id_json, lsp_loc_json(uri, dl0, dc0, dl0, dc0 + max(dlen, 1)))
        } else {
            lsp_ok(id_json, "null")
        }
    } else {
        lsp_ok(id_json, "null")
    }
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Find References ----------
priv fn lsp_handle_references(srv: *LspServer, id_json: str, path: str, line0: i64, col0: i64, include_decl: bool) {
    r := region()
    enter(&r)
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    cur_file := lsp_find_file_idx(&src.names, path)
    cur_text := lsp_text_for(srv, path)
    def_pos := Pos{file: -1}
    sym_name := ""
    if ok && cur_file >= 0 {
        hi := lsp_find_hit(&cx, cur_file, line0 + 1, col0 + 1)
        if hi >= 0 {
            def_pos = cx.lsp_hits[hi].def_pos
            sym_name = cx.lsp_hits[hi].name
        } else {
            word, _, _ := lsp_word_at(cur_text, line0, col0)
            if len(word) > 0 {
                found, dp, _ := lsp_lookup_decl(&cx, word, cur_file, line0 + 1)
                if found {
                    def_pos = dp
                    sym_name = word
                }
            }
        }
    }
    locs := vec[str]()
    seen := map[str, bool]()
    if ok && def_pos.file >= 0 && def_pos.line > 0 {
        if include_decl && def_pos.file < src.names.len {
            uri := lsp_uri_for(srv, src.names[def_pos.file])
            if len(uri) > 0 {
                dl0 := max(i64(def_pos.line) - 1, 0)
                dc0 := max(i64(def_pos.col) - 1, 0)
                k := fmt(uri, ":", dl0, ":", dc0)
                seen.set(k, true)
                locs.push(lsp_loc_json(uri, dl0, dc0, dl0, dc0 + max(len(sym_name), 1)))
            }
        }
        for h in cx.lsp_hits {
            if h.def_pos.file == def_pos.file && h.def_pos.line == def_pos.line && h.def_pos.col == def_pos.col && h.name == sym_name {
                if h.pos.file < 0 || h.pos.file >= src.names.len {
                    continue
                }
                uri := lsp_uri_for(srv, src.names[h.pos.file])
                if len(uri) == 0 {
                    continue
                }
                l0 := max(i64(h.pos.line) - 1, 0)
                c0 := max(i64(h.pos.col) - 1, 0)
                k := fmt(uri, ":", l0, ":", c0)
                if !seen.has(k) {
                    seen.set(k, true)
                    locs.push(lsp_loc_json(uri, l0, c0, l0, c0 + max(i64(h.len), 1)))
                }
            }
        }
    }
    lsp_ok(id_json, fmt("[", join(locs.items(), ","), "]"))
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Completions ----------
priv fn lsp_comp_item(label: str, kind: i64, detail: str) -> str {
    if len(detail) == 0 {
        return fmt("{\"label\":", lsp_jstr(label), ",\"kind\":", kind, "}")
    }
    return fmt("{\"label\":", lsp_jstr(label), ",\"kind\":", kind, ",\"detail\":", lsp_jstr(detail), "}")
}

priv fn lsp_strip_ty_base(ty: str) -> str {
    s := trim(ty)
    while starts_with(s, "*") {
        s = s[1..]
    }
    br := find(s, "[")
    if br >= 0 {
        s = s[..br]
    }
    return s
}

priv fn lsp_handle_completion(srv: *LspServer, id_json: str, path: str, line0: i64, col0: i64) {
    r := region()
    enter(&r)
    cur_text := lsp_text_for(srv, path)
    lt := lsp_line_text(cur_text, line0)
    c := min(max(col0, 0), len(lt))
    before := lt[..c]
    // extract typed identifier prefix right before cursor
    pstart := c
    while pstart > 0 && lsp_is_ident(lt[pstart - 1]) {
        pstart -= 1
    }
    prefix := lt[pstart..c]
    pref_low := to_lower(prefix)

    // Case 1: `use std.<prefix>`
    if starts_with(trim(before), "use std.") {
        items := vec[str]()
        for m in lsp_std_modules() {
            if len(prefix) == 0 || starts_with(to_lower(m), pref_low) {
                items.push(lsp_comp_item(m, 9, fmt("std.", m)))
            }
        }
        lsp_ok(id_json, fmt("[", join(items.items(), ","), "]"))
        lsp_reset_frontend()
        leave()
        region_free(&r)
        return
    }

    // Case 2: dot completion `<recv>.<prefix>`
    is_dot := pstart > 0 && lt[pstart - 1] == '.'
    recv_word := ""
    recv_col := -1
    if is_dot {
        re := pstart - 1
        rs := re
        while rs > 0 && lsp_is_ident(lt[rs - 1]) {
            rs -= 1
        }
        if rs < re {
            recv_word = lt[rs..re]
            recv_col = rs
        }
    }

    // Analyze the current buffers first; if dot completion is on an incomplete line like `p.`
    // that failed to parse, retry with `.<prefix>` replaced by spaces so `p` type-checks.
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    if is_dot && !ok {
        ov := map[str, str]()
        for k in srv.docs.keys() {
            ov.set(k, srv.docs.get_or(k, ""))
        }
        ls, _ := lsp_line_bounds(cur_text, line0)
        dot_off := ls + pstart - 1
        end_off := ls + c
        if dot_off >= 0 && end_off <= len(cur_text) {
            spaces := repeat(" ", end_off - dot_off)
            patched := fmt(cur_text[..dot_off], spaces, cur_text[end_off..])
            ov.set(path, patched)
            src, _, cx, ok = lsp_analyze(path, &ov)
        }
    }
    cur_file := lsp_find_file_idx(&src.names, path)
    items := vec[str]()
    seen := map[str, bool]()

    if is_dot && ok {
        // Determine receiver's type (enum name, or local/global/hit type)
        matched_enum := false
        if len(recv_word) > 0 {
            for ed in cx.enum_decls {
                if ast_plain(ed.name) == recv_word && (!ast_is_private(ed.name) || ed.pos.file == cur_file) {
                    matched_enum = true
                    for v in ed.variants {
                        if len(prefix) == 0 || starts_with(to_lower(v.0), pref_low) {
                            if !seen.has(v.0) {
                                seen.set(v.0, true)
                                items.push(lsp_comp_item(v.0, 20, fmt(recv_word, ".", v.0)))
                            }
                        }
                    }
                    break
                }
            }
        }
        if !matched_enum {
            recv_ty := ""
            if recv_col >= 0 && cur_file >= 0 {
                hi := lsp_find_hit(&cx, cur_file, line0 + 1, recv_col + 1)
                if hi >= 0 {
                    // detail for var/global is "name: Type"
                    dt := cx.lsp_hits[hi].detail
                    colon := find(dt, ": ")
                    recv_ty = if colon >= 0 { dt[colon + 2..] } else { dt }
                }
            }
            if len(recv_ty) == 0 && len(recv_word) > 0 {
                // fallback: check enclosing function locals
                for lv in cx.lsp_locals {
                    if lv.file == cur_file && lv.name == recv_word && line0 + 1 >= i64(lv.fn_line) && line0 + 1 <= i64(lv.fn_end) {
                        recv_ty = lv.ty
                        break
                    }
                }
            }
            base_ty := lsp_strip_ty_base(recv_ty)
            // Struct fields
            if len(base_ty) > 0 {
                for sd in cx.struct_decls {
                    if ast_plain(sd.name) == base_ty && (!ast_is_private(sd.name) || sd.pos.file == cur_file) {
                        for fld in sd.fields {
                            if len(prefix) == 0 || starts_with(to_lower(fld.0), pref_low) {
                                if !seen.has(fld.0) {
                                    seen.set(fld.0, true)
                                    items.push(lsp_comp_item(fld.0, 5, ast_plain_text(ast_type_str(&fld.1))))
                                }
                            }
                        }
                        break
                    }
                }
            }
            // .len for slices, arrays, str, Vec, Map
            if starts_with(recv_ty, "[") || recv_ty == "str" || base_ty == "Vec" || base_ty == "Map" {
                if (len(prefix) == 0 || starts_with("len", pref_low)) && !seen.has("len") {
                    seen.set("len", true)
                    items.push(lsp_comp_item("len", 5, "i64"))
                }
            }
            // UFCS methods whose first parameter matches base_ty (or *base_ty)
            if len(base_ty) > 0 {
                for fd in cx.fn_decls {
                    fn_plain := ast_plain(fd.name)
                    if fd.params.len == 0 || starts_with(fn_plain, "__") || (ast_is_private(fd.name) && fd.pos.file != cur_file) {
                        continue
                    }
                    p0 := lsp_strip_ty_base(ast_plain_text(ast_type_str(&fd.params[0].1)))
                    if p0 == base_ty || (recv_ty == "str" && (p0 == "str" || p0 == "[]u8")) {
                        if (len(prefix) == 0 || starts_with(to_lower(fn_plain), pref_low)) && !seen.has(fn_plain) {
                            seen.set(fn_plain, true)
                            items.push(lsp_comp_item(fn_plain, 2, ast_plain_text(ast_sig_str(fd))))
                        }
                    }
                }
            }
        }
        lsp_ok(id_json, fmt("[", join(items.items(), ","), "]"))
        lsp_reset_frontend()
        leave()
        region_free(&r)
        return
    }

    // Case 3: General identifier completion
    if ok {
        // Enclosing function locals & parameters
        for lv in cx.lsp_locals {
            if lv.file == cur_file && line0 + 1 >= i64(lv.fn_line) && line0 + 1 <= i64(lv.fn_end) {
                if (len(prefix) == 0 || starts_with(to_lower(lv.name), pref_low)) && !seen.has(lv.name) {
                    seen.set(lv.name, true)
                    items.push(lsp_comp_item(lv.name, 6, lv.ty))
                }
            }
        }
        // Functions
        for fd in cx.fn_decls {
            name := ast_plain(fd.name)
            if starts_with(name, "__") || (ast_is_private(fd.name) && fd.pos.file != cur_file) {
                continue
            }
            if (len(prefix) == 0 || starts_with(to_lower(name), pref_low)) && !seen.has(name) {
                seen.set(name, true)
                items.push(lsp_comp_item(name, 3, ast_plain_text(ast_sig_str(fd))))
            }
        }
        // Structs
        for sd in cx.struct_decls {
            name := ast_plain(sd.name)
            if starts_with(name, "__") || (ast_is_private(sd.name) && sd.pos.file != cur_file) {
                continue
            }
            if (len(prefix) == 0 || starts_with(to_lower(name), pref_low)) && !seen.has(name) {
                seen.set(name, true)
                items.push(lsp_comp_item(name, 22, ast_plain_text(ast_struct_str(sd))))
            }
        }
        // Enums
        for ed in cx.enum_decls {
            name := ast_plain(ed.name)
            if starts_with(name, "__") || (ast_is_private(ed.name) && ed.pos.file != cur_file) {
                continue
            }
            if (len(prefix) == 0 || starts_with(to_lower(name), pref_low)) && !seen.has(name) {
                seen.set(name, true)
                items.push(lsp_comp_item(name, 13, ast_plain_text(ast_enum_str(ed))))
            }
        }
        // Constants & globals
        for k in cx.const_decls.keys() {
            cd := cx.const_decls.get_or(k, nil)
            if cd == nil {
                continue
            }
            name := ast_plain(cd.name)
            if starts_with(name, "__") || (ast_is_private(cd.name) && cd.pos.file != cur_file) {
                continue
            }
            if (len(prefix) == 0 || starts_with(to_lower(name), pref_low)) && !seen.has(name) {
                seen.set(name, true)
                items.push(lsp_comp_item(name, 21, fmt("const ", name)))
            }
        }
        for k in cx.global_decls.keys() {
            gd := cx.global_decls.get_or(k, nil)
            if gd == nil {
                continue
            }
            name := ast_plain(gd.name)
            if starts_with(name, "__") || (ast_is_private(gd.name) && gd.pos.file != cur_file) {
                continue
            }
            if (len(prefix) == 0 || starts_with(to_lower(name), pref_low)) && !seen.has(name) {
                seen.set(name, true)
                items.push(lsp_comp_item(name, 6, "global"))
            }
        }
    }
    // Builtins & keywords
    builtins := []str{"print", "put", "fmt", "len", "sizeof", "offsetof", "cast", "ptr", "mkslice", "memcopy", "memfill", "hash", "clone", "panic", "embed", "sqrt", "fabs", "fmin", "fmax", "popcnt", "ctz", "clz", "bswap", "rotl", "rotr", "mulhi"}
    for b in builtins {
        if (len(prefix) == 0 || starts_with(to_lower(b), pref_low)) && !seen.has(b) {
            seen.set(b, true)
            items.push(lsp_comp_item(b, 3, "builtin"))
        }
    }
    kws := []str{"fn", "struct", "enum", "const", "priv", "pub", "use", "when", "if", "else", "match", "for", "in", "by", "while", "loop", "break", "continue", "return", "defer", "assert", "test", "extern", "inline", "noinline", "true", "false", "nil", "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64", "bool", "str"}
    for kw in kws {
        if (len(prefix) == 0 || starts_with(to_lower(kw), pref_low)) && !seen.has(kw) {
            seen.set(kw, true)
            items.push(lsp_comp_item(kw, 14, ""))
        }
    }
    lsp_ok(id_json, fmt("[", join(items.items(), ","), "]"))
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Signature Help ----------
priv fn lsp_handle_sig_help(srv: *LspServer, id_json: str, path: str, line0: i64, col0: i64) {
    r := region()
    enter(&r)
    cur_text := lsp_text_for(srv, path)
    lt := lsp_line_text(cur_text, line0)
    c := min(max(col0, 0), len(lt))
    // Scan backward from cursor for unmatched '(' while counting top-level commas
    depth := 0
    commas := 0
    open_at := -1
    i := c - 1
    while i >= 0 {
        ch := lt[i]
        if ch == ')' || ch == ']' || ch == '}' {
            depth += 1
        } else if ch == '(' {
            if depth == 0 {
                open_at = i
                break
            }
            depth -= 1
        } else if ch == '[' || ch == '{' {
            if depth > 0 {
                depth -= 1
            }
        } else if ch == ',' && depth == 0 {
            commas += 1
        }
        i -= 1
    }
    if open_at <= 0 {
        lsp_ok(id_json, "null")
        lsp_reset_frontend()
        leave()
        region_free(&r)
        return
    }
    // Skip optional `[T, ...]` type args right before `(`
    ne := open_at
    while ne > 0 && is_space(lt[ne - 1]) {
        ne -= 1
    }
    if ne > 0 && lt[ne - 1] == ']' {
        bd := 1
        ne -= 1
        while ne > 0 && bd > 0 {
            ne -= 1
            if lt[ne] == ']' {
                bd += 1
            } else if lt[ne] == '[' {
                bd -= 1
            }
        }
    }
    ns := ne
    while ns > 0 && lsp_is_ident(lt[ns - 1]) {
        ns -= 1
    }
    callee := lt[ns..ne]
    is_method := ns > 0 && lt[ns - 1] == '.'
    if len(callee) == 0 {
        lsp_ok(id_json, "null")
        lsp_reset_frontend()
        leave()
        region_free(&r)
        return
    }
    src, _, cx, ok := lsp_analyze(path, &srv.docs)
    cur_file := lsp_find_file_idx(&src.names, path)
    sigs := vec[str]()
    if ok {
        for fd in cx.fn_decls {
            if ast_plain(fd.name) != callee || (ast_is_private(fd.name) && fd.pos.file != cur_file) {
                continue
            }
            label := ast_plain_text(ast_sig_str(fd))
            pitems := vec[str]()
            for prm in fd.params {
                plab := fmt(ast_plain(prm.0), ": ", ast_plain_text(ast_type_str(&prm.1)))
                pitems.push(fmt("{\"label\":", lsp_jstr(plab), "}"))
            }
            doc := lsp_doc_comment(srv, &src.names, fd.pos)
            doc_field := if len(doc) > 0 { fmt(",\"documentation\":", lsp_jstr(doc)) } else { "" }
            sigs.push(fmt("{\"label\":", lsp_jstr(label), doc_field, ",\"parameters\":[", join(pitems.items(), ","), "]}"))
        }
    }
    if sigs.is_empty() {
        lsp_ok(id_json, "null")
    } else {
        active_p := commas + (if is_method { 1 } else { 0 })
        lsp_ok(id_json, fmt("{\"signatures\":[", join(sigs.items(), ","), "],\"activeSignature\":0,\"activeParameter\":", active_p, "}"))
    }
    lsp_reset_frontend()
    leave()
    region_free(&r)
}

// ---------- Main LSP Event Loop ----------
fn lsp_main(argv: []str) -> i64 {
    for a in argv {
        if a == "--help" || a == "-h" {
            put("usage: alc lsp\n  starts the AgentLang Language Server Protocol (LSP) server over stdio.\n")
            return 0
        } else {
            eput(fmt("alc lsp: unknown option ", a, "\n"))
            return 2
        }
    }
    srv := LspServer{docs: map[str, str](), uris: map[str, str](), root_path: "", shutdown: false}
    rd := LspReader{}
    loop {
        body, ok := lsp_read_msg(&rd)
        if !ok {
            break
        }
        msg, jok := json_parse(body)
        if !jok || msg == nil {
            continue
        }
        method := msg.get("method").as_str("")
        id_json := lsp_id_json(msg.get("id"))
        params := msg.get("params")
        match method {
            "initialize" => {
                ruri := params.get("rootUri").as_str("")
                if len(ruri) > 0 {
                    srv.root_path = lsp_uri_to_path(ruri)
                } else {
                    rp := params.get("rootPath").as_str("")
                    if len(rp) > 0 {
                        srv.root_path = lsp_norm_path(rp)
                    }
                }
                caps := "{\"textDocumentSync\":{\"openClose\":true,\"change\":1,\"save\":{\"includeText\":true}},\"hoverProvider\":true,\"definitionProvider\":true,\"referencesProvider\":true,\"documentSymbolProvider\":true,\"documentFormattingProvider\":true,\"completionProvider\":{\"triggerCharacters\":[\".\",\":\"]},\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}}"
                info := fmt("{\"name\":\"alc\",\"version\":", lsp_jstr(lsp_version()), "}")
                lsp_ok(id_json, fmt("{\"capabilities\":", caps, ",\"serverInfo\":", info, "}"))
            }
            "initialized", "$/cancelRequest", "$/setTrace" => {}
            "shutdown" => {
                srv.shutdown = true
                lsp_ok(id_json, "null")
            }
            "exit" => {
                return if srv.shutdown { 0 } else { 1 }
            }
            "textDocument/didOpen" => {
                td := params.get("textDocument")
                uri := td.get("uri").as_str("")
                text := td.get("text").as_str("")
                if len(uri) > 0 {
                    path := lsp_uri_to_path(uri)
                    srv.docs.set(path, text)
                    srv.uris.set(path, uri)
                    lsp_publish_diags(&srv, path, uri)
                }
            }
            "textDocument/didChange" => {
                td := params.get("textDocument")
                uri := td.get("uri").as_str("")
                changes := params.get("contentChanges")
                if len(uri) > 0 && changes != nil && changes.count() > 0 {
                    path := lsp_uri_to_path(uri)
                    cur := srv.docs.get_or(path, "")
                    for ci in 0..changes.count() {
                        cur = lsp_apply_change(cur, changes.at(ci))
                    }
                    srv.docs.set(path, cur)
                    srv.uris.set(path, uri)
                    lsp_publish_diags(&srv, path, uri)
                }
            }
            "textDocument/didSave" => {
                td := params.get("textDocument")
                uri := td.get("uri").as_str("")
                if len(uri) > 0 {
                    path := lsp_uri_to_path(uri)
                    tj := params.get("text")
                    if tj != nil && tj.kind == JsonString {
                        srv.docs.set(path, tj.text)
                    }
                    lsp_publish_diags(&srv, path, uri)
                }
            }
            "textDocument/didClose" => {
                td := params.get("textDocument")
                uri := td.get("uri").as_str("")
                if len(uri) > 0 {
                    path := lsp_uri_to_path(uri)
                    srv.docs.del(path)
                    lsp_notify("textDocument/publishDiagnostics", fmt("{\"uri\":", lsp_jstr(uri), ",\"diagnostics\":[]}"))
                }
            }
            "textDocument/formatting" => {
                uri := params.get("textDocument").get("uri").as_str("")
                lsp_handle_format(&srv, id_json, lsp_uri_to_path(uri))
            }
            "textDocument/documentSymbol" => {
                uri := params.get("textDocument").get("uri").as_str("")
                lsp_handle_symbols(&srv, id_json, lsp_uri_to_path(uri))
            }
            "textDocument/hover" => {
                uri := params.get("textDocument").get("uri").as_str("")
                pos := params.get("position")
                lsp_handle_hover(&srv, id_json, lsp_uri_to_path(uri), pos.get("line").as_i64(0), pos.get("character").as_i64(0))
            }
            "textDocument/definition" => {
                uri := params.get("textDocument").get("uri").as_str("")
                pos := params.get("position")
                lsp_handle_definition(&srv, id_json, lsp_uri_to_path(uri), pos.get("line").as_i64(0), pos.get("character").as_i64(0))
            }
            "textDocument/references" => {
                uri := params.get("textDocument").get("uri").as_str("")
                pos := params.get("position")
                inc := params.get("context").get("includeDeclaration").as_bool(true)
                lsp_handle_references(&srv, id_json, lsp_uri_to_path(uri), pos.get("line").as_i64(0), pos.get("character").as_i64(0), inc)
            }
            "textDocument/completion" => {
                uri := params.get("textDocument").get("uri").as_str("")
                pos := params.get("position")
                lsp_handle_completion(&srv, id_json, lsp_uri_to_path(uri), pos.get("line").as_i64(0), pos.get("character").as_i64(0))
            }
            "textDocument/signatureHelp" => {
                uri := params.get("textDocument").get("uri").as_str("")
                pos := params.get("position")
                lsp_handle_sig_help(&srv, id_json, lsp_uri_to_path(uri), pos.get("line").as_i64(0), pos.get("character").as_i64(0))
            }
            _ => {
                if len(id_json) > 0 {
                    lsp_err(id_json, -32601, fmt("method not found: ", method))
                }
            }
        }
    }
    return if srv.shutdown { 0 } else { 1 }
}

// ---------- One-shot CLI semantic queries (`alc query`) ----------
priv const QUERY_USAGE = "usage: alc query <kind> <file.al[:line:col]>\n  kinds:\n    hover    <file.al:line:col>   resolved type/signature and doc comment at 1-based line:col (JSON)\n    def      <file.al:line:col>   definition location at 1-based line:col (JSON)\n    refs     <file.al:line:col>   all references to the symbol at 1-based line:col (JSON)\n    complete <file.al:line:col>   completion items at 1-based line:col (JSON)\n    symbols  <file.al>            document symbols (JSON)\n"

// parses `file.al:line:col` (1-based line and col; handles Windows drive letters like C:\foo.al:10:5)
priv fn lsp_parse_loc(spec: str) -> (str, i64, i64, bool) {
    c2 := rfind(spec, ":")
    if c2 <= 0 {
        return (spec, 0, 0, false)
    }
    col, ok2 := parse_i64(spec[c2 + 1..])
    if !ok2 || col < 1 {
        return (spec, 0, 0, false)
    }
    c1 := rfind(spec[..c2], ":")
    if c1 <= 0 {
        return (spec, 0, 0, false)
    }
    line, ok1 := parse_i64(spec[c1 + 1..c2])
    if !ok1 || line < 1 {
        return (spec, 0, 0, false)
    }
    return (spec[..c1], line, col, true)
}

fn lsp_query_main(argv: []str) -> i64 {
    if len(argv) == 0 || argv[0] == "--help" || argv[0] == "-h" {
        put(QUERY_USAGE)
        return 0
    }
    if len(argv) < 2 {
        eput(QUERY_USAGE)
        return 2
    }
    kind := argv[0]
    spec := argv[1]
    need_pos := kind == "hover" || kind == "def" || kind == "refs" || kind == "complete"
    if !need_pos && kind != "symbols" {
        eput(fmt("alc query: unknown query kind `", kind, "`\n", QUERY_USAGE))
        return 2
    }
    path := spec
    line1 := 1
    col1 := 1
    if need_pos {
        p, l, c, ok := lsp_parse_loc(spec)
        if !ok {
            eput(fmt("alc query ", kind, ": expected `<file.al:line:col>` (1-based), got `", spec, "`\n"))
            return 2
        }
        path = p
        line1 = l
        col1 = c
    }
    abs := lsp_abs_path(path)
    text, rok := read_file(abs)
    if !rok {
        eput(fmt("alc query: cannot read `", path, "`: ", error_text(io_error()), "\n"))
        return 1
    }
    srv := LspServer{docs: map[str, str](), uris: map[str, str](), root_path: __os_current_dir(), shutdown: false}
    srv.docs.set(abs, text)
    srv.uris.set(abs, lsp_path_to_uri(abs))
    lsp_raw_stdout = true
    match kind {
        "hover" => lsp_handle_hover(&srv, "1", abs, line1 - 1, col1 - 1)
        "def" => lsp_handle_definition(&srv, "1", abs, line1 - 1, col1 - 1)
        "refs" => lsp_handle_references(&srv, "1", abs, line1 - 1, col1 - 1, true)
        "complete" => lsp_handle_completion(&srv, "1", abs, line1 - 1, col1 - 1)
        _ => lsp_handle_symbols(&srv, "1", abs)
    }
    lsp_raw_stdout = false
    return 0
}
