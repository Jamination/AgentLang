// Generates the Direct3D 12 / DXGI bindings of AL from the mingw-w64 C headers. Run it from the
// repository root:
//
//     ./build/alc run tools/gen_dx12.al               writes std/dx12.al, tests/std/dx12.al, tests/std/dx12.out
//     ./build/alc run tools/gen_dx12.al -- --verify   also writes tmp/Dx12Bindings/verify.c, which states every
//                                                     layout, vtable slot and constant as a C static assertion,
//                                                     and has a C compiler check it against the headers
//                                                     (x86_64-w64-mingw32-gcc, or clang)
//
// Options: --include DIR (header directory), --quiet.
//
// The headers are the widl-generated ones (d3d12.h, dxgi*.h, d3dcommon.h, ...); only their C
// declarations are read: `typedef enum`, `typedef struct`, `typedef struct XVtbl`, `DEFINE_GUID`,
// object-like `#define`s and the exported function prototypes. Mapping rules are described in
// docs/std/dx12.md.
use std.os

const INCLUDE_DIRS = [_]str{"/usr/x86_64-w64-mingw32/include", "/usr/include/wine/windows"}

// A header and the DLL of its exported functions ("": it declares none).
struct Header { file: str, dll: str }

const HEADERS = [_]Header{
    Header{"d3dcommon.h", ""}, Header{"dxgiformat.h", ""}, Header{"dxgicommon.h", ""}, Header{"dxgitype.h", ""},
    Header{"dxgi.h", "dxgi.dll"}, Header{"dxgi1_2.h", "dxgi.dll"}, Header{"dxgi1_3.h", "dxgi.dll"},
    Header{"dxgi1_4.h", "dxgi.dll"}, Header{"dxgi1_5.h", "dxgi.dll"}, Header{"dxgi1_6.h", "dxgi.dll"},
    Header{"dxgidebug.h", "dxgidebug.dll"}, Header{"d3d12.h", "d3d12.dll"}, Header{"d3d12sdklayers.h", ""},
    Header{"d3dcompiler.h", "d3dcompiler_47.dll"},
}

// enums whose (very long) enumerator lists are not emitted; the type itself stays usable
const ENUMS_WITHOUT_CONSTANTS = [_]str{"D3D12_MESSAGE_ID"}

struct Extra { name: str, value: i64 }

// constants built with function-like macros in the headers (checked by --verify like all others)
const EXTRA_CONSTANTS = [_]Extra{Extra{"D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING", 0x1688}}

// Windows base types the D3D headers rely on, in C; they go through the same pipeline.
const BASE_DECLS = `
typedef struct GUID { ULONG Data1; USHORT Data2; USHORT Data3; UCHAR Data4[8];
} GUID;
typedef struct RECT { LONG left; LONG top; LONG right; LONG bottom;
} RECT;
typedef struct POINT { LONG x; LONG y;
} POINT;
typedef struct LUID { DWORD LowPart; LONG HighPart;
} LUID;
typedef struct SECURITY_ATTRIBUTES { DWORD nLength; void *lpSecurityDescriptor; WINBOOL bInheritHandle;
} SECURITY_ATTRIBUTES;
typedef struct MSG { HWND hwnd; UINT message; WPARAM wParam; LPARAM lParam; DWORD time; POINT pt;
} MSG;
typedef struct WNDCLASSEXW { UINT cbSize; UINT style; WNDPROC lpfnWndProc; int cbClsExtra; int cbWndExtra;
    HINSTANCE hInstance; HICON hIcon; HCURSOR hCursor; HBRUSH hbrBackground; LPCWSTR lpszMenuName;
    LPCWSTR lpszClassName; HICON hIconSm;
} WNDCLASSEXW;
typedef struct IUnknownVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IUnknown *This, REFIID riid, void **ppvObject);
    ULONG (STDMETHODCALLTYPE *AddRef)(IUnknown *This);
    ULONG (STDMETHODCALLTYPE *Release)(IUnknown *This);
} IUnknownVtbl;
DEFINE_GUID(IID_IUnknown, 0x00000000, 0x0000, 0x0000, 0xc0,0x00, 0x00,0x00,0x00,0x00,0x00,0x46);
`

// The files to write, where the program is started in the root of the repository.
const SELF = "tools/gen_dx12.al"
const MODULE_PATH = "std/dx12.al"
const TEST_PATH = "tests/std/dx12.al"
const EXPECTED_PATH = "tests/std/dx12.out"
const VERIFY_PATH = "tmp/Dx12Bindings/verify.c"

fn fail(msg: str) -> never {
    eprint(concat("gen_dx12: ", msg))
    exit(1)
}

// ---- the model: everything parsed from the headers, in declaration order ------------------------

// A value of a C constant expression.
enum Num { Int(i64), Float(f64) }

// A C type as written: `const TYPE **name[2][3]` has base TYPE, 2 stars and the dimensions 2, 3.
struct Raw { base: str, stars: i64, dims: []i64 }

// A resolved C type.
enum Ty {
    Void
    Prim(str)       // a number type, by its AL name
    Fn(str)         // a function pointer, by its AL spelling
    Struct(str)     // a struct or union of the model
    Enum(str)
    Iface(str)      // a COM interface
    Opaque(str)     // a name the headers do not define
    Ptr(*Ty)
    Arr(*Ty, i64)
}

// A member of a struct or union. A member declared with a named type has `ctype` (that name) and
// `raw`, from which `ty` is resolved once every name is known; a type written inline has only `ty`.
struct Field { name: str, ctype: str, raw: Raw, ty: Ty }

// A C struct or union. A type written inline inside another one has `outer` (the C name of the
// enclosing typedef) and `cpath` (member path from there); `anon` marks an unnamed union member.
struct Record { name: str, fields: []Field, union: bool, outer: str, cpath: str, anon: bool, bitfield: bool }

struct Enumerator { name: str, value: i64, hexa: bool }

// `al` is the integer type of the enum in AL: i32, or u32 for flags and values above 0x7fffffff.
struct CEnum { name: str, al: str, items: []Enumerator }

// `literal` is the text of the value if the #define is a plain integer literal; `typed`: an HRESULT.
struct Define { name: str, literal: str, value: Num, typed: bool }

struct Guid { name: str, parts: [11]i64 }

// `c` is the C text of the parameter.
struct Param { name: str, raw: Raw, c: str }

struct Method { name: str, ret: Raw, params: []Param, cdecl: str }

struct Iface { name: str, methods: []Method }

struct Func { dll: str, name: str, ret: Raw, params: []Param, cdecl: str }

struct Db {
    structs: Map[str, Record]  // these three in declaration order
    tags: Map[str, str]        // struct tag -> typedef name
    enums: Map[str, CEnum]
    aliases: Map[str, Raw]     // typedef name -> the type it stands for
    consts: Map[str, Num]      // enumerators and #defines, for evaluating later expressions
    defines: Vec[Define]
    guids: Vec[Guid]
    ifaces: Map[str, Iface]
    funcs: Vec[Func]
    skipped: Vec[str]          // notes about declarations that were left out
}

// ---- C names ------------------------------------------------------------------------------------

// The AL type of a C number type, "" for any other name.
fn prim(name: str) -> str {
    match name {
        "char", "CHAR", "UCHAR", "BYTE", "UINT8", "BOOLEAN", "unsigned char" => "u8"
        "INT8", "signed char" => "i8"
        "WCHAR", "wchar_t", "USHORT", "UINT16", "WORD", "ATOM", "unsigned short" => "u16"
        "short", "SHORT", "INT16" => "i16"
        "int", "INT", "long", "LONG", "INT32", "HRESULT", "BOOL", "WINBOOL" => "i32"
        "unsigned", "UINT", "ULONG", "DWORD", "UINT32", "unsigned int", "unsigned long" => "u32"
        "INT64", "LONGLONG", "__int64", "LONG_PTR", "INT_PTR", "SSIZE_T", "LPARAM", "LRESULT", "LARGE_INTEGER",
        "long long" => "i64"
        "UINT64", "ULONGLONG", "SIZE_T", "ULONG_PTR", "UINT_PTR", "DWORD_PTR", "WPARAM", "ULARGE_INTEGER",
        "unsigned __int64", "unsigned long long" => "u64"
        "float", "FLOAT" => "f32"
        "double", "DOUBLE" => "f64"
        _ => ""
    }
}

// Size in bytes of an AL number type, 0 for any other name.
fn prim_size(al: str) -> i64 {
    match al {
        "u8", "i8" => 1
        "u16", "i16" => 2
        "u32", "i32", "f32" => 4
        "u64", "i64", "f64" => 8
        _ => 0
    }
}

fn boxed(ty: Ty) -> *Ty {
    p := new[Ty]()
    *p = ty
    p
}

// The pointer type a Windows handle or string name stands for; false for any other name.
fn pointer_name(name: str) -> (Ty, bool) {
    match name {
        "HANDLE", "HWND", "HDC", "HMONITOR", "HMODULE", "HINSTANCE", "HICON", "HCURSOR", "HBRUSH", "HMENU", "LPVOID",
        "PVOID", "LPCVOID" => (Ptr(boxed(Void)), true)
        "WNDPROC" => (Fn("fn(*u8, u32, u64, i64) -> i64"), true)
        "LPCSTR", "LPSTR" => (Ptr(boxed(Prim("u8"))), true)
        "LPCWSTR", "LPWSTR" => (Ptr(boxed(Prim("u16"))), true)
        "REFIID", "REFGUID", "REFCLSID" => (Ptr(boxed(Struct("GUID"))), true)
        _ => (Void, false)
    }
}

// Interface names as used in application code, and back to the name in the headers.
fn renamed(name: str) -> str { if name == "ID3D10Blob" { "ID3DBlob" } else { name } }
fn header_name(name: str) -> str { if name == "ID3DBlob" { "ID3D10Blob" } else { name } }

// A name as an AL identifier: the words src/lexer.al reserves (LEXER_KEYWORDS), `self` (the
// receiver of the method wrappers) and the number types get an underscore.
fn ident(name: str) -> str {
    reserved := match name {
        "fn", "struct", "enum", "const", "test", "use", "if", "else", "while", "loop", "for", "in", "by", "return",
        "break", "continue", "assert", "match", "defer", "inline", "noinline", "true", "false", "nil", "extern",
        "priv", "self" => true
        _ => prim_size(name) > 0
    }
    if reserved { concat(name, "_") } else { name }
}

// The placeholder names the headers give to unnamed members (__C89_NAMELESSUNIONNAME1, DUMMYUNIONNAME).
fn placeholder(name: str) -> bool {
    n := len(name)
    while n > 0 && is_digit(name[n - 1]) {
        n -= 1
    }
    stem := name[..n]
    stem == "DUMMYUNIONNAME" || stem == "DUMMYSTRUCTNAME" ||
        (n >= 18 && starts_with(stem, "__C89_NAMELESS") && ends_with(stem, "NAME"))
}

// True if `name` is `prefix` and at least one more character.
fn extends(name: str, prefix: str) -> bool { len(name) > len(prefix) && starts_with(name, prefix) }

// The #defines of the D3D headers that become constants.
fn define_name(name: str) -> bool {
    extends(name, "D3D12_") || extends(name, "DXGI_") || extends(name, "D3D_") || extends(name, "D3DCOMPILE_") ||
        extends(name, "D3DCOMPILER_")
}

// The HRESULT values taken from winerror.h.
fn hresult_name(name: str) -> bool {
    match name {
        "S_OK", "S_FALSE", "E_FAIL", "E_INVALIDARG", "E_OUTOFMEMORY", "E_NOINTERFACE", "E_NOTIMPL", "E_POINTER",
        "E_ABORT", "E_ACCESSDENIED", "E_UNEXPECTED" => true
        _ => extends(name, "DXGI_ERROR_") || extends(name, "DXGI_STATUS_") || extends(name, "D3D12_ERROR_")
    }
}

// ---- type resolution ----------------------------------------------------------------------------

// The type a C type name stands for.
fn named(db: *Db, c_name: str) -> Ty {
    name := renamed(c_name)
    name = if name == "IID" || name == "CLSID" { "GUID" } else { db.tags.get_or(name, name) }
    if name == "void" { return Void }
    if prim(name) != "" { return Prim(prim(name)) }
    pointer, found := pointer_name(name)
    if found { return pointer }
    if db.structs.has(name) { return Struct(name) }
    if db.enums.has(name) { return Enum(name) }
    if db.ifaces.has(name) { return Iface(name) }
    target, aliased := db.aliases.get(name)
    if aliased { return resolve(db, target) }
    Opaque(name)
}

fn resolve(db: *Db, raw: Raw) -> Ty {
    ty := named(db, raw.base)
    for k in 0..raw.stars {
        ty = Ptr(boxed(ty))
    }
    for k in raw.dims.len - 1..=0 by -1 {
        ty = Arr(boxed(ty), raw.dims[k])
    }
    ty
}

// The struct or union that `ty` is, or nil.
fn record_of(db: *Db, ty: Ty) -> *Record {
    match ty {
        Struct(name) => db.structs.ptr(name)
        _ => nil
    }
}

// (size, alignment) under the Windows x64 C ABI.
fn layout(db: *Db, ty: Ty) -> (i64, i64) {
    match ty {
        Prim(name) => (prim_size(name), prim_size(name))
        Ptr(_), Fn(_) => (8, 8)
        Enum(_) => (4, 4)
        Arr(elem, n) => {
            size, align := layout(db, *elem)
            (size * n, align)
        }
        Struct(name) => {
            s := *db.structs.ptr(name)
            size := 0
            align := 1
            for f in s.fields {
                fs, fa := layout(db, f.ty)
                align = max(align, fa)
                size = if s.union { max(size, fs) } else { (size + fa - 1) / fa * fa + fs }
            }
            ((size + align - 1) / align * align, align)
        }
        Void => fail("void has no layout")
        Iface(name), Opaque(name) => fail(fmt("no layout for ", name, " (used by value)"))
    }
}

// The offset of every field of a struct.
fn offsets(db: *Db, s: Record) -> []i64 {
    out := alloc[i64](s.fields.len)
    pos := 0
    for k, f in s.fields {
        fs, fa := layout(db, f.ty)
        if !s.union {
            pos = (pos + fa - 1) / fa * fa
        }
        out[k] = pos
        if !s.union {
            pos += fs
        }
    }
    out
}

// AL spelling of a type.
fn al(db: *Db, ty: Ty) -> str {
    match ty {
        Prim(name), Fn(name), Struct(name), Iface(name) => name
        Enum(name) => db.enums.ptr(name).al
        Arr(elem, n) => fmt("[", n, "]", al(db, *elem))
        Ptr(Void), Ptr(Opaque(_)) => "*u8"
        Ptr(inner) => {
            r := record_of(db, *inner)
            if r != nil && r.bitfield { "*u8" } else { concat("*", al(db, *inner)) }
        }
        Void => fail("void has no AL type")
        Opaque(name) => fail(fmt("no AL type for ", name, " (used by value)"))
    }
}

// ---- scanning -----------------------------------------------------------------------------------

fn is_word(c: u8) -> bool { is_alnum(c) || c == '_' }

// The position of the first character at or after `i` that is not white space.
fn skip_space(s: str, i: i64) -> i64 {
    while i < len(s) && is_space(s[i]) {
        i += 1
    }
    i
}

// The same within a line: spaces and tabs only.
fn skip_blank(s: str, i: i64) -> i64 {
    while i < len(s) && (s[i] == ' ' || s[i] == '\t') {
        i += 1
    }
    i
}

// The end of the word (letters, digits, `_`) that starts at `i`; `i` itself if none does.
fn word_end(s: str, i: i64) -> i64 {
    while i < len(s) && is_word(s[i]) {
        i += 1
    }
    i
}

// The position of the first character at or after `i` that is one of `stops`; len(s) if there is none.
fn scan_to(s: str, i: i64, stops: str) -> i64 {
    k := find_any(s, stops, i)
    if k < 0 { len(s) } else { k }
}

// The C integer literal (decimal or 0x...) at s[i..], without its suffix: (value, end). `end`
// is `i` if there is none.
fn scan_int(s: str, i: i64) -> (i64, i64) {
    end := i
    while end < len(s) && is_digit(s[end]) {
        end += 1
    }
    if end == i + 1 && s[i] == '0' && end + 1 < len(s) && s[end] | 0x20 == 'x' && contains("0123456789abcdefABCDEF", s[end + 1]) {
        end += 1
        while end < len(s) && contains("0123456789abcdefABCDEF", s[end]) {
            end += 1
        }
    }
    v, _ := parse_i64(s[i..end], 0)
    (v, end)
}

// True if the text is one hexadecimal literal.
fn hex_literal(text: str) -> bool {
    _, end := scan_int(text, 0)
    end > 2 && !is_digit(text[1]) && suffix_end(text, end) == len(text)
}

// The end of the suffix (u, l, ul, ull, ...) of an integer literal.
fn suffix_end(s: str, i: i64) -> i64 {
    while i < len(s) && contains("uUlL", s[i]) {
        i += 1
    }
    i
}

// The tokens of a piece of C: names, integer literals, and every other character by itself.
fn tokens(text: str) -> []str {
    out := vec[str]()
    i := 0
    while i < len(text) {
        start := i
        c := text[i]
        if is_digit(c) {
            _, digits_end := scan_int(text, i)
            i = suffix_end(text, digits_end)
        } else if is_word(c) {
            i = word_end(text, i)
        } else {
            i += 1
            if is_space(c) { continue }
        }
        out.push(text[start..i])
    }
    out[..]
}

// White space trimmed and every run of it inside turned into one space.
fn squeeze(s: str) -> str { join(fields(s), " ") }

// The text without comments, and with every line that ends in a backslash joined to the next one.
fn strip_comments(s: str) -> str {
    out := vec[u8]()
    out.reserve(len(s))
    kept := 0                  // s[kept..i] is still to be copied
    i := 0
    while i + 1 < len(s) {
        c := s[i]
        d := s[i + 1]
        if c == '/' && d == '*' {
            close := find(s[i + 2..], "*/")
            if close < 0 { break }
            out.extend(s[kept..i])
            i += close + 4
            kept = i
        } else if c == '/' && d == '/' {
            out.extend(s[kept..i])
            i = scan_to(s, i, "\n")
            kept = i
        } else if c == '\\' && d == '\n' {
            out.extend(s[kept..i])
            out.push(' ')
            i += 2
            kept = i
        } else {
            i += 1
        }
    }
    out.extend(s[kept..])
    out[..]
}

// ---- C constant expressions ---------------------------------------------------------------------

// The state of one evaluation: the text, the position in it, and whether all is well so far.
struct Expr { db: *Db, s: str, i: i64, ok: bool }

// Value of a C constant expression: integer and float literals, constants seen so far, casts,
// unary - + ~ and the binary operators | ^ & << >> + - * / %. False if the text is anything else.
fn evaluate(db: *Db, text: str) -> (Num, bool) {
    e := Expr{db, text, 0, true}
    v := binary(&e, 0)
    (v, e.ok && skip_space(text, e.i) == len(text))
}

// An integer that a declaration cannot do without.
fn evaluate_int(db: *Db, text: str, what: str) -> i64 {
    v, ok := evaluate(db, text)
    match v {
        Int(n) if ok => n
        _ => fail(fmt("cannot evaluate `", text, "` in ", what))
    }
}

// The operator of precedence `level` (0: the loosest) at the position, as its first character; 0 if
// something else is there.
fn operator(e: *Expr, level: i64) -> u8 {
    e.i = skip_space(e.s, e.i)
    if e.i >= len(e.s) { return 0 }
    c := e.s[e.i]
    shift := (c == '<' || c == '>') && e.i + 1 < len(e.s) && e.s[e.i + 1] == c
    found := match level {
        0 => c == '|'
        1 => c == '^'
        2 => c == '&'
        3 => shift
        4 => c == '+' || c == '-'
        _ => c == '*' || c == '/' || c == '%'
    }
    if !found { return 0 }
    e.i += if shift { 2 } else { 1 }
    c
}

fn binary(e: *Expr, level: i64) -> Num {
    if level > 5 { return unary(e) }
    v := binary(e, level + 1)
    loop {
        op := operator(e, level)
        if op == 0 { return v }
        v = apply(e, op, v, binary(e, level + 1))
    }
}

fn apply(e: *Expr, op: u8, a: Num, b: Num) -> Num {
    match (a, b) {
        (Int(x), Int(y)) => match op {
            '|' => Int(x | y)
            '^' => Int(x ^ y)
            '&' => Int(x & y)
            '<' => Int(x << y)
            '>' => Int(x >> y)
            '+' => Int(x + y)
            '-' => Int(x - y)
            '*' => Int(x * y)
            _ if y == 0 => {
                e.ok = false
                a
            }
            '/' => Int(x / y)
            _ => Int(x % y)
        }
        _ => {
            x := to_float(a)
            y := to_float(b)
            match op {
                '+' => Float(x + y)
                '-' => Float(x - y)
                '*' => Float(x * y)
                '/' => Float(x / y)
                _ => {
                    e.ok = false
                    a
                }
            }
        }
    }
}

fn to_float(v: Num) -> f64 {
    match v {
        Int(n) => f64(n)
        Float(x) => x
    }
}

fn unary(e: *Expr) -> Num {
    e.i = skip_space(e.s, e.i)
    if e.i >= len(e.s) {
        e.ok = false
        return Int(0)
    }
    c := e.s[e.i]
    if c == '-' || c == '+' || c == '~' {
        e.i += 1
        v := unary(e)
        return match v {
            Int(n) => Int(if c == '-' { -n } else if c == '~' { ~n } else { n })
            Float(x) if c != '~' => Float(if c == '-' { -x } else { x })
            _ => {
                e.ok = false
                v
            }
        }
    }
    if c == '(' {
        if skip_cast(e) { return unary(e) }
        e.i += 1
        v := binary(e, 0)
        e.i = skip_space(e.s, e.i)
        if e.i < len(e.s) && e.s[e.i] == ')' {
            e.i += 1
        } else {
            e.ok = false
        }
        return v
    }
    if is_digit(c) { return number(e) }
    end := word_end(e.s, e.i)
    name := e.s[e.i..end]
    e.i = end
    // macros of the headers that only mark the type of their argument
    if name == "__MSABI_LONG" || name == "_HRESULT_TYPEDEF_" { return unary(e) }
    v, known := e.db.consts.get(name)
    if !known {
        e.ok = false
    }
    v
}

// Steps over a cast like `(UINT)` or `(D3D12_SHADER_VISIBILITY)`: a type name in parentheses with
// an operand after it. False (and nothing done) if the position is not at one.
fn skip_cast(e: *Expr) -> bool {
    s := e.s
    start := skip_space(s, e.i + 1)
    end := word_end(s, start)
    name := s[start..end]
    if name == "unsigned" && starts_with(s[end..], " int") {
        end += 4
        name = s[start..end]
    }
    is_type := match name {
        "HRESULT", "UINT", "DWORD", "int", "unsigned int", "UINT64" => true
        _ => starts_with(name, "D3D") || starts_with(name, "DXGI")
    }
    close := skip_space(s, end)
    if !is_type || close >= len(s) || s[close] != ')' { return false }
    operand := skip_space(s, close + 1)
    if operand >= len(s) || !(is_word(s[operand]) || contains("(~-", s[operand])) { return false }
    e.i = close + 1
    true
}

// An integer literal with its suffix, or a float literal (1.0f, 3.4e+38f, 1e9).
fn number(e: *Expr) -> Num {
    s := e.s
    start := e.i
    v, i := scan_int(s, start)
    result := Int(v)
    hexa := i > start + 1 && (s[start + 1] == 'x' || s[start + 1] == 'X')
    if !hexa && i < len(s) && contains(".eE", s[i]) {
        if s[i] == '.' {
            i += 1
            while i < len(s) && is_digit(s[i]) {
                i += 1
            }
        }
        if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
            i += 1
            if i < len(s) && (s[i] == '+' || s[i] == '-') {
                i += 1
            }
            while i < len(s) && is_digit(s[i]) {
                i += 1
            }
        }
        x, ok := parse_f64(s[start..i])
        e.ok = e.ok && ok
        result = Float(x)
        if i < len(s) && (s[i] == 'f' || s[i] == 'F') {
            i += 1
        }
    } else {
        i = suffix_end(s, i)
    }
    if i < len(s) && is_word(s[i]) {
        e.ok = false
    }
    e.i = i
    result
}

// ---- parsing ------------------------------------------------------------------------------------

// The position of the token `t` at or after `i`.
fn token_after(toks: []str, i: i64, t: str) -> i64 {
    k := index_of(toks[i..], t)
    if k < 0 { fail(fmt("`", t, "` is missing after `", join(toks[i..], " "), "`")) }
    i + k
}

// `const TYPE *name[N]` -> (name, type, bit-field?). The name is "" if the declaration has none.
fn parse_decl(db: *Db, decl: []str) -> (str, Raw, bool) {
    toks := decl
    colon := index_of(toks, ":")
    if colon >= 0 {
        toks = toks[..colon]
    }
    dims := vec[i64]()
    while toks.len > 0 && toks[toks.len - 1] == "]" {
        open := toks.len - 1
        while open > 0 && toks[open] != "[" {
            open -= 1
        }
        if toks[open] != "[" { fail(fmt("`]` without `[` in `", join(decl, " "), "`")) }
        dims.insert(0, evaluate_int(db, join(toks[open + 1..toks.len - 1], " "), join(decl, " ")))
        toks = toks[..open]
    }
    stars := 0
    words := vec[str]()
    for t in toks {
        if t == "*" {
            stars += 1
        } else if is_word(t[0]) && !is_digit(t[0]) {
            match t {
                "const", "struct", "union", "enum", "volatile" => {}
                _ => words.push(t)
            }
        }
    }
    if words.len == 0 { fail(fmt("no type in `", join(decl, " "), "`")) }
    name := ""
    if words.len > 1 && prim(join(words[..], " ")) == "" && toks[toks.len - 1] == words.last() {
        name = words.pop()
    }
    (name, Raw{join(words[..], " "), stars, dims[..]}, colon >= 0)
}

// Members of a struct/union body: (fields, has bit-fields?). Types written inline become structs
// of their own, named after `owner` (the enclosing typedef) and `path` (the members from there).
fn parse_members(db: *Db, owner: str, toks: []str, path: []str) -> ([]Field, bool) {
    fields := vec[Field]()
    bitfield := false
    i := 0
    while i < toks.len {
        j := i
        while j + 1 < toks.len && (toks[j] == "__C89_NAMELESS" || toks[j] == "__extension__" || toks[j] == "const") {
            j += 1
        }
        if (toks[j] == "struct" || toks[j] == "union") && contains(toks[j..min(j + 3, toks.len)], "{") {
            union := toks[j] == "union"
            open := token_after(toks, j, "{")
            close := open
            depth := 1
            while depth > 0 {
                close += 1
                if close >= toks.len { fail(concat("unbalanced braces in ", owner)) }
                if toks[close] == "{" {
                    depth += 1
                } else if toks[close] == "}" {
                    depth -= 1
                }
            }
            end := token_after(toks, close, ";")
            name := if end > close + 1 && !placeholder(toks[close + 1]) { toks[close + 1] } else { "" }
            anon := name == ""
            if anon && !union { fail(concat("anonymous struct in ", owner)) }
            sub := vec_of(path)
            if anon {
                // the members of an anonymous union are addressed from the enclosing type in C
                taken := false
                for f in fields {
                    taken = taken || (f.ctype == "" && starts_with(f.name, "u"))
                }
                name = if taken { fmt("u", fields.len) } else { "u" }
            } else {
                sub.push(name)
            }
            inner, bits := parse_members(db, owner, toks[open + 1..close], sub[..])
            bitfield = bitfield || bits
            parts := vec_of([]str{owner})
            parts.extend(path)
            parts.push(name)
            sname := join(parts[..], "_")
            db.structs.set(sname, Record{sname, inner, union, owner, join(sub[..], "."), anon, false})
            fields.push(Field{name: name, ty: Struct(sname)})
            i = end + 1
            continue
        }
        end := token_after(toks, i, ";")
        name, raw, bits := parse_decl(db, toks[i..end])
        bitfield = bitfield || bits
        fields.push(Field{name: name, ctype: raw.base, raw: raw})
        i = end + 1
    }
    (fields[..], bitfield)
}

// [(name, type, C text)] of a parameter list; array parameters decay to pointers.
fn parse_params(db: *Db, text: str) -> []Param {
    out := vec[Param]()
    list := trim(text)
    if list == "" || list == "void" { return out[..] }
    for k, p in split(list, ',') {
        name, raw, _ := parse_decl(db, tokens(p))
        if name == "" {
            name = fmt("a", k)
        }
        if raw.dims.len > 0 {
            raw = Raw{raw.base, raw.stars + 1, nil}
        }
        out.push(Param{name, raw, squeeze(p)})
    }
    out[..]
}

// The C texts of parameters, as a list.
fn c_list(params: []Param) -> str {
    texts := vec[str]()
    for p in params {
        texts.push(p.c)
    }
    join(texts[..], ", ")
}

fn parse_enum(db: *Db, name: str, body: str) {
    items := vec[Enumerator]()
    unsigned := ends_with(name, "_FLAG") || ends_with(name, "_FLAGS")
    next := 0
    for part in split(body, ',') {
        eq := index_of(part, '=')
        item := trim(if eq < 0 { part } else { part[..eq] })
        expr := if eq < 0 { "" } else { trim(part[eq + 1..]) }
        if item == "" { continue }
        value := if expr == "" { next } else { evaluate_int(db, expr, name) }
        next = value + 1
        db.consts.set(item, Int(value))
        // size-forcing members and the D3D10/D3D11 spellings of D3D_ enumerators are not API
        if ends_with(item, "_FORCE_UINT") || ends_with(item, "_FORCE_DWORD") || starts_with(item, "D3D10_") ||
            starts_with(item, "D3D11_") {
            continue
        }
        unsigned = unsigned || value > 0x7fffffff
        items.push(Enumerator{item, value, hex_literal(expr)})
    }
    db.enums.set(name, CEnum{name, if unsigned { "u32" } else { "i32" }, items[..]})
}

// The body of `typedef struct XVtbl`: BEGIN_INTERFACE, one function pointer per method in vtable
// order (`HRESULT (STDMETHODCALLTYPE *Name)(X *This, ...);`), END_INTERFACE.
fn parse_vtbl(db: *Db, c_name: str, body: str) {
    name := renamed(c_name)
    methods := vec[Method]()
    for part in split(body, ';') {
        decl := trim(part)
        if starts_with(decl, "BEGIN_INTERFACE") {
            decl = trim(decl[15..])
        }
        open := index_of(decl, '(')
        if open < 0 { continue }
        close := scan_to(decl, open, ")")
        declarator := tokens(decl[open + 1..close])
        list := skip_space(decl, close + 1)
        if declarator.len != 3 || declarator[0] != "STDMETHODCALLTYPE" || declarator[1] != "*" ||
            list >= len(decl) || decl[list] != '(' || decl[len(decl) - 1] != ')' {
            continue
        }
        // the result type is what a declaration of some name with this text in front would have
        ret := squeeze(decl[..open])
        ret_decl := vec_of(tokens(ret))
        ret_decl.push("_")
        _, ret_type, _ := parse_decl(db, ret_decl[..])
        params := parse_params(db, decl[list + 1..len(decl) - 1])
        if params.len == 0 || params[0].name != "This" {
            fail(fmt(name, "::", declarator[2], " does not take `This` first"))
        }
        cdecl := fmt(ret, " ", name, "::", declarator[2], "(", c_list(params[1..]), ")")
        methods.push(Method{declarator[2], ret_type, params[1..], cdecl})
    }
    db.ifaces.set(name, Iface{name, methods[..]})
}

// `typedef TYPE NAME`, as tokens.
fn parse_alias(db: *Db, toks: []str) {
    if toks.len == 0 { return }
    if toks.len == 3 && toks[1] == toks[2] && contains([]str{"interface", "struct", "union", "enum"}, toks[0]) {
        return   // forward declaration
    }
    name, raw, _ := parse_decl(db, toks)
    _, is_pointer := pointer_name(name)
    if name == "" || prim(name) != "" || is_pointer || db.aliases.has(name) || db.structs.has(name) {
        return
    }
    t, found := db.structs.get(db.tags.get_or(raw.base, raw.base))
    if found && raw.stars == 0 && raw.dims.len == 0 && raw.base != "GUID" {
        // AL has no type aliases: `typedef RECT D3D12_RECT` becomes a struct with the same members
        db.structs.set(name, Record{name: name, fields: t.fields, union: t.union})
    } else {
        db.aliases.set(name, raw)
    }
}

// A typedef; s[i..] follows the word. Returns the position after it, or `i` if it is of no known form.
fn parse_typedef(db: *Db, s: str, i: i64) -> i64 {
    start := skip_space(s, i)
    k := scan_to(s, start, ";{}()")
    if start == i || k >= len(s) { return i }
    if s[k] == ';' {
        parse_alias(db, tokens(s[start..k]))
        return k + 1
    }
    if s[k] == '(' {
        // a function pointer type, `typedef void (WINAPI *NAME)(...);`: as a type it is a `void *`
        close := scan_to(s, k, ")")
        end := scan_to(s, k, ";")
        if close >= end || end >= len(s) || s[skip_space(s, close + 1)] != '(' { return i }
        declarator := tokens(s[k + 1..close])
        if declarator.len == 3 && contains([]str{"WINAPI", "__stdcall", "STDMETHODCALLTYPE"}, declarator[0]) {
            declarator = declarator[1..]
        }
        if declarator.len != 2 || declarator[0] != "*" || !is_word(declarator[1][0]) { return i }
        if !db.aliases.has(declarator[1]) {
            db.aliases.set(declarator[1], Raw{"void", 1, nil})
        }
        return end + 1
    }
    if s[k] != '{' { return i }
    // `typedef enum [TAG] { ... } NAME;`, `typedef struct|union TAG { ... } NAME;`
    head := tokens(s[start..k])
    close := k
    depth := 1
    while depth > 0 {
        close = scan_to(s, close + 1, "{}")
        if close >= len(s) { return i }
        depth += if s[close] == '{' { 1 } else { -1 }
    }
    name_start := skip_space(s, close + 1)
    name_end := word_end(s, name_start)
    end := skip_space(s, name_end)
    if head.len == 0 || name_end == name_start || end >= len(s) || s[end] != ';' { return i }
    name := s[name_start..name_end]
    body := s[k + 1..close]
    if head[0] == "enum" && head.len <= 2 {
        parse_enum(db, name, body)
    } else if (head[0] == "struct" || head[0] == "union") && head.len == 2 {
        tag := head[1]
        if head[0] == "struct" && len(tag) > 4 && ends_with(tag, "Vtbl") && ends_with(name, "Vtbl") {
            parse_vtbl(db, tag[..len(tag) - 4], body)
        } else {
            db.tags.set(tag, name)
            if !db.structs.has(name) {
                db.structs.set(name, Record{name: name})   // keeps the position in front of its inline types
                fields, bitfield := parse_members(db, name, tokens(body), nil)
                db.structs.set(name, Record{name: name, fields: fields, union: head[0] == "union", bitfield: bitfield})
            }
        }
    } else {
        return i
    }
    end + 1
}

// The text of the value if `body` is one integer literal, possibly in parentheses or __MSABI_LONG( ); else "".
fn plain_literal(body: str) -> str {
    i := 0
    while i < len(body) && (is_space(body[i]) || body[i] == '(') {
        i += 1
    }
    if starts_with(body[i..], "__MSABI_LONG(") {
        i += 13
    }
    _, end := scan_int(body, i)
    literal := body[i..end]
    i = suffix_end(body, end)
    while i < len(body) && (is_space(body[i]) || body[i] == ')') {
        i += 1
    }
    if i < len(body) { "" } else { literal }
}

// `#define NAME value`; s[i..] follows `#define`. Only the constants this module wants are kept.
fn parse_define(db: *Db, s: str, i: i64, hresults_only: bool) {
    name_start := skip_blank(s, i)
    name_end := word_end(s, name_start)
    body_start := skip_blank(s, name_end)
    body_end := scan_to(s, body_start, "\n")
    // not a name after a blank, a macro with parameters, or no value
    if name_start == i || name_end == name_start || body_start == name_end || body_end == body_start { return }
    name := s[name_start..name_end]
    body := trim(s[body_start..body_end])
    wanted := if hresults_only { hresult_name(name) } else { define_name(name) }
    if !wanted || db.consts.has(name) || ends_with(name, "_DEFINED__") || ends_with(name, "_H__") { return }
    value, ok := evaluate(db, body)
    if !ok {
        extra := false
        for x in EXTRA_CONSTANTS {
            extra = extra || x.name == name
        }
        if !extra {
            db.skipped.push(fmt("#define ", name, " ", body))
        }
        return
    }
    db.consts.set(name, value)
    typed := hresults_only || find(body, "HRESULT") >= 0
    db.defines.push(Define{name, if typed { "" } else { to_lower(plain_literal(body)) }, value, typed})
}

// `DEFINE_GUID(NAME, 11 integers)`; s[i..] follows the word.
fn parse_guid(db: *Db, s: str, i: i64) -> i64 {
    open := skip_space(s, i)
    name_start := skip_space(s, open + 1)
    name_end := word_end(s, name_start)
    comma := skip_space(s, name_end)
    close := scan_to(s, comma, ")")
    if open >= len(s) || s[open] != '(' || name_end == name_start || close >= len(s) || s[comma] != ',' { return i }
    g := Guid{name: s[name_start..name_end]}
    values := split(s[comma + 1..close], ',')
    if values.len != 11 { fail(concat("DEFINE_GUID without 11 values: ", g.name)) }
    for k, text in values {
        t := trim(text)
        v, end := scan_int(t, 0)
        if end == 0 || end != len(t) { fail(fmt("DEFINE_GUID(", g.name, "): `", t, "` is not an integer")) }
        g.parts[k] = v
    }
    db.guids.push(g)
    close + 1
}

// `DEFINE_ENUM_FLAG_OPERATORS(NAME)`: the enum is a set of flags; s[i..] follows the word.
fn parse_flags(db: *Db, s: str, i: i64) -> i64 {
    open := skip_space(s, i)
    name_start := skip_space(s, open + 1)
    name_end := word_end(s, name_start)
    close := skip_space(s, name_end)
    if open >= len(s) || s[open] != '(' || close >= len(s) || s[close] != ')' { return i }
    e := db.enums.ptr(s[name_start..name_end])
    if e == nil { fail(concat("DEFINE_ENUM_FLAG_OPERATORS of an unknown enum: ", s[name_start..name_end])) }
    e.al = "u32"
    close + 1
}

// An exported function, `HRESULT WINAPI Name(parameters);`, at s[i..].
fn parse_prototype(db: *Db, s: str, i: i64, dll: str) -> i64 {
    ret_end := word_end(s, i)
    conv_start := skip_space(s, ret_end)
    conv_end := word_end(s, conv_start)
    name_start := skip_space(s, conv_end)
    name_end := word_end(s, name_start)
    open := skip_space(s, name_end)
    conv := s[conv_start..conv_end]
    if ret_end == i || conv_start == ret_end || (conv != "WINAPI" && conv != "__stdcall") || name_start == conv_end ||
        name_end == name_start || open >= len(s) || s[open] != '(' {
        return i
    }
    end := scan_to(s, open, ";{}")
    if end >= len(s) || s[end] != ';' { return i }
    close := end - 1
    while is_space(s[close]) {
        close -= 1
    }
    if s[close] != ')' { return i }
    name := s[name_start..name_end]
    if dll != "" && !ends_with(name, "_Proxy") && !ends_with(name, "_Stub") {
        params := parse_params(db, s[open + 1..close])
        cdecl := fmt(s[i..ret_end], " ", name, "(", c_list(params), ")")
        db.funcs.push(Func{dll, name, Raw{s[i..ret_end], 0, nil}, params, cdecl})
    }
    end + 1
}

// One pass over the top-level declarations of a header, in file order. Each starts a line.
fn parse_header(db: *Db, text: str, dll: str, hresults_only: bool) {
    s := strip_comments(text)
    i := 0
    while i < len(s) {
        rest := s[i..]
        end := i
        if starts_with(rest, "#define") {
            parse_define(db, s, i + 7, hresults_only)
        } else if hresults_only {
            // winerror.h: nothing but its #defines is wanted
        } else if starts_with(rest, "typedef") {
            end = parse_typedef(db, s, i + 7)
        } else if starts_with(rest, "DEFINE_GUID") {
            end = parse_guid(db, s, i + 11)
        } else if starts_with(rest, "DEFINE_ENUM_FLAG_OPERATORS") {
            end = parse_flags(db, s, i + 26)
        } else if is_word(s[i]) {
            end = parse_prototype(db, s, i, dll)
        }
        i = scan_to(s, end, "\n") + 1
    }
}

fn read_header(dir: str, file: str) -> str {
    path := fmt(dir, "/", file)
    text, ok := read_file(path)
    if !ok { fail(fmt("cannot read ", path, ": ", error_text(io_error()))) }
    text
}

fn by_value_bitfield(db: *Db, ty: Ty) -> bool {
    match ty {
        Arr(elem, _) => by_value_bitfield(db, *elem)
        Struct(name) => db.structs.ptr(name).bitfield
        _ => false
    }
}

fn load(db: *Db, include_dir: str) {
    parse_header(db, BASE_DECLS, "", false)
    for h in HEADERS {
        parse_header(db, read_header(include_dir, h.file), h.dll, false)
    }
    parse_header(db, read_header(include_dir, "winerror.h"), "", true)
    for x in EXTRA_CONSTANTS {
        db.consts.set(x.name, Int(x.value))
        db.defines.push(Define{x.name, concat("0x", hex(u64(x.value))), Int(x.value), false})
    }
    // resolve member types now that every name is known
    structs := db.structs.values()
    for s in structs {
        for k in 0..s.fields.len {
            if s.fields[k].ctype != "" {
                s.fields[k].ty = resolve(db, s.fields[k].raw)
            }
        }
    }
    for i, s in structs {
        for f in s.fields {
            if by_value_bitfield(db, f.ty) {
                structs[i].bitfield = true
            }
        }
    }
}

// ---- emission -----------------------------------------------------------------------------------

// The text of a raw string of this file, in which `^` stands for the backquote that it cannot contain.
fn unquoted(raw: str) -> str { replace(raw, "^", "`") }

// Appends one line.
fn line(out: *Vec[u8], text: str) {
    out.extend(text)
    out.push('\n')
}

// The headline of a section: the title and a rule of so many dashes.
fn heading(out: *Vec[u8], title: str, dashes: i64) {
    out.line(fmt(title, " ", repeat("-", dashes)))
}

fn int_literal(value: i64, hexa: bool) -> str {
    if !hexa { return fmt(value) }
    if value < 0 { concat("-0x", hex(u64(-value))) } else { concat("0x", hex(u64(value))) }
}

// A float as Python's repr writes it, the notation the constants of std/dx12.al have: the shortest
// digits that read back exactly (as AL prints them), with an exponent only below 1e-4 and from
// 1e16 on, written `e+38` and `e-07`.
fn float_literal(x: f64) -> str {
    text := fmt(x)
    digits := vec[u8]()        // the significant digits; the value is 0.DIGITS * 10^exp
    exp := 0
    point := false
    i := if text[0] == '-' { 1 } else { 0 }
    while i < len(text) && text[i] != 'e' {
        if text[i] == '.' {
            point = true
        } else if digits.len > 0 || text[i] != '0' {
            digits.push(text[i])
            exp += if point { 0 } else { 1 }
        } else if point {
            exp -= 1
        }
        i += 1
    }
    if i < len(text) {
        e, _ := parse_i64(text[i + 1..])
        exp += e
    }
    while digits.len > 0 && digits.last() == '0' {
        digits.pop()
    }
    if digits.len == 0 { return text }   // 0.0, inf, nan
    d := digits[..]
    out := vec[u8]()
    if text[0] == '-' {
        out.push('-')
    }
    if exp < -3 || exp > 16 {
        out.push(d[0])
        if d.len > 1 {
            out.push('.')
            out.extend(d[1..])
        }
        out.extend(if exp < 1 { "e-" } else { "e+" })
        out.extend(fmti(abs(exp - 1), 2, '0'))
    } else if exp <= 0 {
        out.extend("0.")
        for k in exp..0 {
            out.push('0')
        }
        out.extend(d)
    } else {
        for k in 0..exp {
            out.push(if k < d.len { d[k] } else { '0' })
        }
        out.push('.')
        if d.len > exp {
            out.extend(d[exp..])
        } else {
            out.push('0')
        }
    }
    out[..]
}

// The value of an enumerator as its AL constant has it.
fn enumerator_value(e: CEnum, item: Enumerator) -> i64 {
    if e.al == "i32" { item.value } else { item.value & 0xffffffff }
}

fn emit_constants(db: *Db, out: *Vec[u8]) {
    out.heading("// ---- constants (#define)", 70)
    for d in db.defines {
        match d.value {
            Int(v) if d.typed => out.line(fmt("const ", d.name, ": i32 = 0x", hex(u64(v & 0xffffffff), 8)))
            Int(v) => out.line(fmt("const ", d.name, " = ", if d.literal != "" { d.literal } else { fmt(v) }))
            Float(x) => out.line(fmt("const ", d.name, " = ", float_literal(x)))
        }
    }
    out.line("")
    out.heading("// ---- enums: typed constants; struct fields and parameters use the enum's integer type", 8)
    for e in db.enums.values() {
        if contains(ENUMS_WITHOUT_CONSTANTS[..], e.name) {
            out.line(fmt("// enum ", e.name, " (", e.al, "): enumerators not listed"))
            continue
        }
        out.line(concat("// enum ", e.name))
        for item in e.items {
            out.line(fmt("const ", item.name, ": ", e.al, " = ", int_literal(enumerator_value(e, item), item.hexa)))
        }
    }
    out.line("")
}

// The structs that AL can describe: unions appear as a block of bytes inside their owner, and
// structs with bit-fields not at all.
fn emitted_structs(db: *Db) -> []Record {
    out := vec[Record]()
    for s in db.structs.values() {
        if !s.union && !s.bitfield {
            out.push(s)
        }
    }
    out[..]
}

fn emit_structs(db: *Db, out: *Vec[u8]) {
    out.heading("// ---- structs (Windows x64 C layout)", 60)
    for s in db.structs.values() {
        if s.union { continue }
        if s.bitfield {
            out.line(fmt("// struct ", s.name, ": skipped, it has bit-fields (pointers to it are *u8)"))
            continue
        }
        size, align := layout(db, Struct(s.name))
        out.line(fmt("// ", size, " bytes, alignment ", align))
        out.line(fmt("struct ", s.name, " {"))
        accessors := vec[str]()
        for f in s.fields {
            r := record_of(db, f.ty)
            if r != nil && r.union {
                u := *r
                usize, ualign := layout(db, f.ty)
                block := fmt("u", ualign * 8)
                if usize != ualign {
                    block = fmt("[", usize / ualign, "]", block)
                }
                names := vec[str]()
                for m in u.fields {
                    names.push(concat("u_", m.name))
                    target := al(db, m.ty)
                    accessors.push(fmt("// The `", m.name, "` member of the union in ", s.name, "."))
                    accessors.push(fmt("inline fn u_", m.name, "(s: *", s.name, ") -> *", target, " { cast[*", target,
                        "](&s.", ident(f.name), ") }"))
                }
                out.line(fmt("    ", ident(f.name), ": ", block, " // union: ", join(names[..], ", ")))
            } else {
                // an enum or a typedef of a number loses its name in AL: keep it as a remark
                lost := db.enums.has(f.ctype) || db.aliases.has(f.ctype)
                out.line(fmt("    ", ident(f.name), ": ", al(db, f.ty), if lost { concat(" // ", f.ctype) } else { "" }))
            }
        }
        out.line("}")
        for a in accessors {
            out.line(a)
        }
    }
    out.line("")
}

fn emit_guids(db: *Db, out: *Vec[u8]) {
    out.heading("// ---- GUIDs", 86)
    seen := map[str, bool]()
    for g in db.guids {
        name := if extends(g.name, "IID_") { concat("IID_", renamed(g.name[4..])) } else { g.name }
        if seen.has(name) { continue }
        seen.set(name, true)
        bytes := vec[str]()
        for b in g.parts[3..] {
            bytes.push(concat("0x", hex(u64(b), 2)))
        }
        out.line(fmt(name, " := GUID{0x", hex(u64(g.parts[0]), 8), ", 0x", hex(u64(g.parts[1]), 4), ", 0x",
            hex(u64(g.parts[2]), 4), ", [8]u8{", join(bytes[..], ", "), "}}"))
    }
    out.line("")
}

// How a method appears in AL: the types of its vtable entry, the parameters of the wrapper
// (`params`, and the types alone after `self`), the arguments of the call through the vtable, the
// result ("": none), the struct it returns through a hidden pointer ("": none), type parameters.
struct Sig { vt: []str, params: []str, types: []str, args: []str, ret: str, sret: str, tparams: []str }

// An 8-byte-or-smaller struct passed by value travels as one integer (Win64): (its type, the
// expression that builds it from the struct `expr`).
fn scalar_pack(db: *Db, s: Record, size: i64, expr: str) -> (str, str) {
    target := fmt("u", size * 8)
    parts := vec[str]()
    offs := offsets(db, s)
    for k, f in s.fields {
        fs, _ := layout(db, f.ty)
        fty := al(db, f.ty)
        integer := match f.ty {
            Prim(_), Enum(_) => fty[0] == 'i' || fty[0] == 'u'
            _ => false
        }
        if !integer { fail(fmt(s.name, ".", f.name, ": cannot pass it in a register")) }
        part := fmt(expr, ".", ident(f.name))
        unsigned := fmt("u", fs * 8)
        if fty != unsigned {
            part = fmt(unsigned, "(", part, ")")
        }
        if fs != size {
            part = fmt(target, "(", part, ")")
        }
        parts.push(if offs[k] != 0 { fmt("(", part, " << ", offs[k] * 8, ")") } else { part })
    }
    (target, join(parts[..], " | "))
}

// `void **`
fn is_void_pp(ty: Ty) -> bool {
    match ty {
        Ptr(Ptr(Void)) => true
        _ => false
    }
}

// True for the C text of a REFIID parameter.
fn is_refiid(c: str) -> bool { starts_with(c, "REFIID") && (len(c) == 6 || !is_word(c[6])) }

fn signature(db: *Db, m: Method, self_ty: str) -> Sig {
    vt := vec_of([]str{concat("*", self_ty)})
    params := vec_of([]str{concat("self: *", self_ty)})
    types := vec[str]()
    args := vec_of([]str{"self"})
    tparams := vec[str]()
    sret := ""
    prev_c := ""
    for p in m.params {
        ty := resolve(db, p.raw)
        name := ident(p.name)
        r := record_of(db, ty)
        if name == "__ret" {
            // widl's spelling of a struct result: the caller passes where to store it
            match ty {
                Ptr(result) => {
                    sret = al(db, *result)
                }
                _ => fail(concat("__ret is not a pointer in ", m.cdecl))
            }
            vt.push(al(db, ty))
            args.push("&r")
        } else if r != nil {
            size, _ := layout(db, ty)
            if size == 1 || size == 2 || size == 4 || size == 8 {
                scalar, packed := scalar_pack(db, *r, size, name)
                vt.push(scalar)
                args.push(packed)
            } else {
                vt.push(concat("*", al(db, ty)))
                args.push(concat("&", name))
            }
            params.push(fmt(name, ": ", al(db, ty)))
            types.push(al(db, ty))
        } else if is_void_pp(ty) && is_refiid(prev_c) {
            // `REFIID riid, void **ppv`: the wrapper takes a pointer to a typed interface variable
            t := if tparams.len > 0 { fmt("T", tparams.len + 1) } else { "T" }
            tparams.push(t)
            vt.push("**u8")
            params.push(fmt(name, ": **", t))
            types.push(concat("**", t))
            args.push(fmt("cast[**u8](", name, ")"))
        } else {
            vt.push(al(db, ty))
            params.push(fmt(name, ": ", al(db, ty)))
            types.push(al(db, ty))
            args.push(name)
        }
        prev_c = p.c
    }
    ret := resolve(db, m.ret)
    Sig{vt[..], params[..], types[..], args[..], if ret == Void { "" } else { al(db, ret) }, sret, tparams[..]}
}

// ` -> type`, or nothing for a function without result.
fn arrow(ret: str) -> str { if ret == "" { "" } else { concat(" -> ", ret) } }

fn emit_interfaces(db: *Db, out: *Vec[u8]) {
    out.heading("// ---- COM interfaces: object = { vt }, vtable = function pointers in header order", 14)
    for it in db.ifaces.values() {
        out.line(fmt("struct ", it.name, " { vt: *", it.name, "Vtbl }"))
        sigs := vec[Sig]()
        out.line(fmt("struct ", it.name, "Vtbl {"))
        for m in it.methods {
            sig := signature(db, m, it.name)
            out.line(fmt("    ", m.name, ": fn(", join(sig.vt, ", "), ")", arrow(sig.ret)))
            sigs.push(sig)
        }
        out.line("}")
        for slot, m in it.methods {
            sig := sigs[slot]
            out.line(fmt("// [", slot, "] ", m.cdecl))
            call := fmt("self.vt.", m.name, "(", join(sig.args, ", "), ")")
            head := fmt("inline fn ", m.name, if sig.tparams.len > 0 { fmt("[", join(sig.tparams, ", "), "]") } else { "" },
                "(", join(sig.params, ", "), ")")
            if sig.sret != "" {
                out.line(fmt(head, " -> ", sig.sret, " { r: ", sig.sret, "; ", call, "; r }"))
            } else {
                out.line(fmt(head, arrow(sig.ret), " { ", call, " }"))
            }
        }
        out.line("")
    }
}

// True if the function hands out an interface this module does not describe.
fn hands_out_unknown(db: *Db, f: Func) -> bool {
    for p in f.params {
        match resolve(db, p.raw) {
            Ptr(Ptr(Opaque(_))) => return true
            _ => {}
        }
    }
    false
}

// Emits the exported functions and returns their number.
fn emit_functions(db: *Db, out: *Vec[u8]) -> i64 {
    out.heading("// ---- exported functions", 72)
    count := 0
    for f in db.funcs {
        if hands_out_unknown(db, f) {
            db.skipped.push(f.cdecl)
            continue
        }
        params := vec[str]()
        for p in f.params {
            params.push(fmt(ident(p.name), ": ", al(db, resolve(db, p.raw))))
        }
        ret := resolve(db, f.ret)
        out.line(concat("// ", f.cdecl))
        out.line(fmt("extern \"", f.dll, "\" fn ", f.name, "(", join(params[..], ", "), ")",
            arrow(if ret == Void { "" } else { al(db, ret) })))
        count += 1
    }
    count
}

// The fixed part of std/dx12.al (`^` stands for a backquote).
const PROLOGUE = `// std.dx12: Direct3D 12 and DXGI for AL. GENERATED by tools/gen_dx12.al from the mingw-w64
// headers (d3d12.h, dxgi*.h, d3dcommon.h, d3d12sdklayers.h, d3dcompiler.h); do not edit.
//
// Windows only: build with ^alc build --target windows^. Bindings only: device set-up, fences,
// shader compilation and rendering are the program's own code (examples/gamekit/dx12_gpu.al is
// one way to write them). See docs/std/dx12.md for the mapping rules and a walk-through.
//
//   device: *ID3D12Device
//   hr := D3D12CreateDevice(nil, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, ppv(&device))
//   if FAILED(hr) { panic(hresult_text("D3D12CreateDevice", hr)) }
//   queue: *ID3D12CommandQueue
//   desc := D3D12_COMMAND_QUEUE_DESC{Type: D3D12_COMMAND_LIST_TYPE_DIRECT}
//   hr = device.CreateCommandQueue(&desc, &IID_ID3D12CommandQueue, &queue)

// ---- helpers -------------------------------------------------------------------------------

// True if an HRESULT signals success (S_OK, S_FALSE, ...).
inline fn SUCCEEDED(hr: i32) -> bool { hr >= 0 }

// True if an HRESULT signals failure.
inline fn FAILED(hr: i32) -> bool { hr < 0 }

// The name of a common HRESULT ("DXGI_ERROR_DEVICE_REMOVED"), or "".
fn hresult_name(hr: i32) -> str {
    match hr {
        S_OK => "S_OK"
        S_FALSE => "S_FALSE"
        E_FAIL => "E_FAIL"
        E_INVALIDARG => "E_INVALIDARG"
        E_OUTOFMEMORY => "E_OUTOFMEMORY"
        E_NOINTERFACE => "E_NOINTERFACE"
        E_NOTIMPL => "E_NOTIMPL"
        E_POINTER => "E_POINTER"
        DXGI_ERROR_UNSUPPORTED => "DXGI_ERROR_UNSUPPORTED"
        DXGI_ERROR_NOT_FOUND => "DXGI_ERROR_NOT_FOUND"
        DXGI_ERROR_INVALID_CALL => "DXGI_ERROR_INVALID_CALL"
        DXGI_ERROR_DEVICE_REMOVED => "DXGI_ERROR_DEVICE_REMOVED"
        DXGI_ERROR_DEVICE_HUNG => "DXGI_ERROR_DEVICE_HUNG"
        DXGI_ERROR_DEVICE_RESET => "DXGI_ERROR_DEVICE_RESET"
        DXGI_ERROR_DRIVER_INTERNAL_ERROR => "DXGI_ERROR_DRIVER_INTERNAL_ERROR"
        DXGI_ERROR_SDK_COMPONENT_MISSING => "DXGI_ERROR_SDK_COMPONENT_MISSING"
        _ => ""
    }
}

// "0x887a0004 (DXGI_ERROR_UNSUPPORTED)": the code in hexadecimal and its name if it is a common one.
fn hresult_code(hr: i32) -> str {
    name := hresult_name(hr)
    fmt("0x", pad_left(hex(u64(u32(hr))), 8, '0'), if name == "" { "" } else { fmt(" (", name, ")") })
}

// "what failed: HRESULT 0x887a0004 (DXGI_ERROR_UNSUPPORTED)"
fn hresult_text(what: str, hr: i32) -> str { fmt(what, " failed: HRESULT ", hresult_code(hr)) }

// An interface pointer variable as the ^void **^ out-argument of an exported function:
// ^CreateDXGIFactory2(0, &IID_IDXGIFactory4, ppv(&factory))^. Methods take ^&factory^ directly.
inline fn ppv[T](p: **T) -> **u8 { cast[**u8](p) }

// Releases the COM object in ^*pp^ (if any) and sets the variable to nil.
fn com_release[T](pp: **T) {
    if *pp != nil {
        cast[*IUnknown](*pp).Release()
        *pp = nil
    }
}

// NUL-terminated UTF-16 copy of UTF-8 text, for the ^*u16^ (LPCWSTR) parameters. Allocates from the arena.
fn utf16(s: str) -> *u16 {
    w := alloc[u16](len(s) + 1)
    n := 0
    i := 0
    while i < len(s) {
        c := u32(s[i])
        extra := 0
        if c >= 0xf0 {
            c &= 0x07
            extra = 3
        } else if c >= 0xe0 {
            c &= 0x0f
            extra = 2
        } else if c >= 0xc0 {
            c &= 0x1f
            extra = 1
        }
        i += 1
        while extra > 0 && i < len(s) {
            c = c << 6 | u32(s[i]) & 0x3f
            i += 1
            extra -= 1
        }
        if c >= 0x10000 {
            c -= 0x10000
            w[n] = u16(0xd800 + (c >> 10))
            w[n + 1] = u16(0xdc00 + (c & 0x3ff))
            n += 2
        } else {
            w[n] = u16(c)
            n += 1
        }
    }
    ptr(w)
}

// The contents of a blob (compiled shader, serialized root signature, error text) as bytes; no copy.
fn blob_bytes(b: *ID3DBlob) -> str { mkslice[u8](b.GetBufferPointer(), i64(b.GetBufferSize())) }

// ---- Win32: just enough to open a window, pump messages and wait on a fence ----------------
const WS_OVERLAPPEDWINDOW: u32 = 0x00cf0000
const WS_VISIBLE: u32 = 0x10000000
const CW_USEDEFAULT: i32 = 0x80000000
const CS_VREDRAW: u32 = 0x1
const CS_HREDRAW: u32 = 0x2
const WM_DESTROY: u32 = 0x2
const WM_SIZE: u32 = 0x5
const WM_PAINT: u32 = 0xf
const WM_CLOSE: u32 = 0x10
const WM_QUIT: u32 = 0x12
const WM_KEYDOWN: u32 = 0x100
const WM_KEYUP: u32 = 0x101
const PM_REMOVE: u32 = 0x1
const SW_SHOW: i32 = 5
const VK_ESCAPE: u64 = 0x1b
const IDC_ARROW: u64 = 32512
const INFINITE: u32 = 0xffffffff
const WAIT_OBJECT_0: u32 = 0

// A window procedure is a plain AL function: fn(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64.

// Handle of a loaded module; nil names the executable itself.
extern "kernel32.dll" fn GetModuleHandleW(name: *u16) -> *u8
// Creates an event object (for ID3D12Fence.SetEventOnCompletion); nil on failure.
extern "kernel32.dll" fn CreateEventW(attributes: *SECURITY_ATTRIBUTES, manual_reset: i32, initial_state: i32, name: *u16) -> *u8
// Blocks until the object is signalled or the time-out (INFINITE: none) passes.
extern "kernel32.dll" fn WaitForSingleObject(handle: *u8, milliseconds: u32) -> u32
// Closes a kernel object handle.
extern "kernel32.dll" fn CloseHandle(handle: *u8) -> i32
// Suspends the calling thread.
extern "kernel32.dll" fn Sleep(milliseconds: u32)
// Error code of the last failed Win32 call on this thread.
extern "kernel32.dll" fn GetLastError() -> u32
// Sends a NUL-terminated string to the debugger output.
extern "kernel32.dll" fn OutputDebugStringA(text: *u8)
// Reads the high-resolution counter.
extern "kernel32.dll" fn QueryPerformanceCounter(count: *i64) -> i32
// Ticks per second of the high-resolution counter.
extern "kernel32.dll" fn QueryPerformanceFrequency(frequency: *i64) -> i32
// Registers a window class; 0 on failure.
extern "user32.dll" fn RegisterClassExW(class: *WNDCLASSEXW) -> u16
// Creates a window; nil on failure.
extern "user32.dll" fn CreateWindowExW(ex_style: u32, class_name: *u16, window_name: *u16, style: u32, x: i32, y: i32, width: i32, height: i32, parent: *u8, menu: *u8, instance: *u8, param: *u8) -> *u8
// Default handling for the messages a window procedure does not process.
extern "user32.dll" fn DefWindowProcW(hwnd: *u8, msg: u32, wparam: u64, lparam: i64) -> i64
// Shows or hides a window (SW_SHOW).
extern "user32.dll" fn ShowWindow(hwnd: *u8, cmd: i32) -> i32
// Destroys a window.
extern "user32.dll" fn DestroyWindow(hwnd: *u8) -> i32
// Fetches the next queued message without blocking; 0 if there is none.
extern "user32.dll" fn PeekMessageW(msg: *MSG, hwnd: *u8, filter_min: u32, filter_max: u32, remove: u32) -> i32
// Turns key messages into character messages.
extern "user32.dll" fn TranslateMessage(msg: *MSG) -> i32
// Hands a message to the window procedure.
extern "user32.dll" fn DispatchMessageW(msg: *MSG) -> i64
// Queues WM_QUIT, which ends the message loop.
extern "user32.dll" fn PostQuitMessage(exit_code: i32)
// Loads a cursor; system cursors use a nil instance and ^cast[*u16](IDC_ARROW)^.
extern "user32.dll" fn LoadCursorW(instance: *u8, name: *u16) -> *u8
// Grows a client rectangle to the window rectangle of a style.
extern "user32.dll" fn AdjustWindowRect(rect: *RECT, style: u32, menu: i32) -> i32
// Client-area size of a window.
extern "user32.dll" fn GetClientRect(hwnd: *u8, rect: *RECT) -> i32
// Shows a modal message box.
extern "user32.dll" fn MessageBoxW(hwnd: *u8, text: *u16, caption: *u16, kind: u32) -> i32
`

// Appends the text of std/dx12.al and returns the number of exported functions in it.
fn emit_module(db: *Db, out: *Vec[u8]) -> i64 {
    out.line(unquoted(PROLOGUE))
    emit_constants(db, out)
    emit_structs(db, out)
    emit_guids(db, out)
    emit_interfaces(db, out)
    emit_functions(db, out)
}

// ---- self-test written in AL --------------------------------------------------------------------

// The fixed part of tests/std/dx12.al (`^` stands for a backquote).
const TEST_HEAD = `// GENERATED by tools/gen_dx12.al together with std/dx12.al.
// Checks on Linux what can be checked without Windows: struct sizes and field offsets against
// the values computed from the headers (which ^gen_dx12.al --verify^ proves against a C
// compiler), vtable sizes, the helpers, and calls through a COM vtable built in AL.
use std.dx12

checked: i64
wrong: i64

fn chk(got: i64, want: i64, what: str) {
    checked += 1
    if got != want {
        wrong += 1
        print("MISMATCH", what, "got", got, "want", want)
    }
}

// A COM object implemented in AL: the vtable layout of ID3DBlob with a reference count.
struct FakeBlob { vt: *ID3DBlobVtbl, refs: u32, data: str }

fn fake_query(self: *ID3DBlob, riid: *GUID, out: **u8) -> i32 {
    if *riid == IID_ID3DBlob || *riid == IID_IUnknown {
        *out = cast[*u8](self)
        cast[*FakeBlob](self).refs += 1
        return S_OK
    }
    *out = nil
    E_NOINTERFACE
}

fn fake_addref(self: *ID3DBlob) -> u32 {
    b := cast[*FakeBlob](self)
    b.refs += 1
    b.refs
}

fn fake_release(self: *ID3DBlob) -> u32 {
    b := cast[*FakeBlob](self)
    b.refs -= 1
    b.refs
}

fn fake_pointer(self: *ID3DBlob) -> *u8 { ptr(cast[*FakeBlob](self).data) }

fn fake_size(self: *ID3DBlob) -> u64 { u64(len(cast[*FakeBlob](self).data)) }

fn helpers() {
    print("S_OK", SUCCEEDED(S_OK), FAILED(S_OK), "S_FALSE", SUCCEEDED(S_FALSE), "E_FAIL", SUCCEEDED(E_FAIL), FAILED(E_FAIL))
    print("DXGI_ERROR_DEVICE_REMOVED", hex(u64(u32(DXGI_ERROR_DEVICE_REMOVED))), FAILED(DXGI_ERROR_DEVICE_REMOVED))
    print(hresult_name(DXGI_ERROR_DEVICE_REMOVED), hresult_code(E_FAIL), hresult_code(0x7fff0001), hresult_text("Present", DXGI_ERROR_DEVICE_HUNG))
    w := mkslice[u16](utf16("A\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80z"), 7)
    print("utf16", w)
    print("guid", hex(u64(IID_ID3D12Device.Data1)), IID_ID3D12Device.Data4, IID_ID3D12Device == IID_ID3D12Device, IID_ID3D12Device == IID_ID3D12Resource)
    print("consts", D3D12_COMMAND_LIST_TYPE_DIRECT, D3D_FEATURE_LEVEL_12_0, DXGI_FORMAT_R8G8B8A8_UNORM, D3D12_RESOURCE_STATE_GENERIC_READ, D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING, DXGI_USAGE_RENDER_TARGET_OUTPUT)

    // unions: the accessors view the same bytes
    barrier: D3D12_RESOURCE_BARRIER
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
    t := barrier.u_Transition()
    t.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES
    t.StateBefore = D3D12_RESOURCE_STATE_PRESENT
    t.StateAfter = D3D12_RESOURCE_STATE_RENDER_TARGET
    print("barrier", cast[i64](barrier.u_Aliasing()) - cast[i64](&barrier), barrier.u_Transition().Subresource, barrier.u_Transition().StateAfter)
    clear: D3D12_CLEAR_VALUE
    color := clear.u_Color()
    color[2] = 0.5
    print("clear", clear.u_Color()[2], clear.u_DepthStencil().Depth)

    // calls through a vtable
    vt: ID3DBlobVtbl
    vt.QueryInterface = fake_query
    vt.AddRef = fake_addref
    vt.Release = fake_release
    vt.GetBufferPointer = fake_pointer
    vt.GetBufferSize = fake_size
    fake := FakeBlob{&vt, 1, "shader bytes"}
    blob := cast[*ID3DBlob](&fake)
    print("blob", blob.GetBufferSize(), blob_bytes(blob), blob.AddRef(), blob.Release())
    unknown: *IUnknown
    device: *ID3D12Device
    print("query", blob.QueryInterface(&IID_IUnknown, &unknown) == S_OK, unknown == cast[*IUnknown](blob), fake.refs,
        blob.QueryInterface(&IID_ID3D12Device, &device) == E_NOINTERFACE, device == nil)
    com_release(&unknown)
    com_release(&unknown)
    print("release", unknown == nil, fake.refs)
}
`

// The output of tests/std/dx12.al: of the fixed part, and the numbers of checks.
const TEST_OUTPUT = `S_OK true false S_FALSE true E_FAIL false true
DXGI_ERROR_DEVICE_REMOVED 887a0005 true
utf16 [65, 233, 8364, 55357, 56832, 122, 0]
guid 189819f1 [190, 84, 24, 33, 51, 155, 133, 247] true false
consts 0 49152 28 2755 5768 32
barrier 8 4294967295 4
clear 0.5 0.0
blob 12 shader bytes 2 1
query true true 2 true true
release true 1
`

// Structs per function of the test: one function for all would be very long.
const CHUNK = 24

// An argument for a wrapper parameter of AL type `t` in a call that is only compiled: the
// interface variable `o` for a type parameter, else the zero value of the type.
fn sample_argument(t: str) -> str {
    if starts_with(t, "**T") { return "o" }
    if t[0] == '*' { return "nil" }
    if prim_size(t) > 0 { "0" } else { concat(t, "{}") }
}

// Appends the text of tests/std/dx12.al to `out` and the output it must print to `expected`.
fn emit_test(db: *Db, out: *Vec[u8], expected: *Vec[u8]) {
    out.line(unquoted(TEST_HEAD))
    structs := emitted_structs(db)
    nfields := 0
    for first in 0..structs.len by CHUNK {
        out.line(fmt("fn layouts_", first / CHUNK, "(b: *u8) {"))
        out.line("    a := cast[i64](b)")
        for s in structs[first..min(first + CHUNK, structs.len)] {
            size, _ := layout(db, Struct(s.name))
            out.line(fmt("    chk(sizeof[", s.name, "](), ", size, ", \"", s.name, "\")"))
            offs := offsets(db, s)
            for k, f in s.fields {
                out.line(fmt("    chk(cast[i64](&cast[*", s.name, "](b).", ident(f.name), ") - a, ", offs[k], ", \"", s.name,
                    ".", f.name, "\")"))
            }
            nfields += s.fields.len
        }
        out.line("}")
        out.line("")
    }
    out.line("fn vtables() {")
    for it in db.ifaces.values() {
        out.line(fmt("    chk(sizeof[", it.name, "Vtbl](), ", 8 * it.methods.len, ", \"", it.name, "Vtbl\")"))
    }
    out.line("}")
    out.line("")
    // every generic wrapper (COM out-parameters) instantiated once; never called, only compiled
    out.line("fn instantiate(o: **IUnknown) {")
    for it in db.ifaces.values() {
        opened := false
        for m in it.methods {
            sig := signature(db, m, it.name)
            if sig.tparams.len == 0 { continue }
            if !opened {
                out.line("    {")
                out.line(concat("        x: *", it.name))
                opened = true
            }
            args := vec[str]()
            for t in sig.types {
                args.push(sample_argument(t))
            }
            out.line(fmt("        x.", m.name, "(", join(args[..], ", "), ")"))
        }
        if opened {
            out.line("    }")
        }
    }
    out.line("}")
    out.line("")
    out.line("fn main() {")
    out.line("    helpers()")
    out.line("    scratch := alloc[u8](8192)")
    for first in 0..structs.len by CHUNK {
        out.line(fmt("    layouts_", first / CHUNK, "(ptr(scratch))"))
    }
    out.line(fmt("    print(\"structs\", ", structs.len, ", \"layout checks\", checked, \"wrong\", wrong)"))
    out.line("    checked = 0")
    out.line("    vtables()")
    out.line("    print(\"vtables\", checked, \"wrong\", wrong)")
    out.line("}")
    expected.extend(TEST_OUTPUT)
    expected.line(fmt("structs ", structs.len, " layout checks ", structs.len + nfields, " wrong 0"))
    expected.line(fmt("vtables ", db.ifaces.len, " wrong 0"))
}

// ---- verification against a C compiler ----------------------------------------------------------

const C_HEAD = `#define COBJMACROS
#define CINTERFACE
#include <stddef.h>
#include <windows.h>
#include <d3d12.h>
#include <d3d12sdklayers.h>
#include <dxgi1_6.h>
#include <dxgidebug.h>
#include <d3dcompiler.h>
#define CHECK(c) _Static_assert(c, #c)
`

// C name of a field; an anonymous union is located through its first member.
fn c_member(db: *Db, f: Field) -> str {
    r := record_of(db, f.ty)
    if r != nil && r.anon { c_member(db, r.fields[0]) } else { f.name }
}

// Appends a C translation unit of static assertions; returns what it asserts, in words.
fn emit_c(db: *Db, out: *Vec[u8]) -> str {
    out.line(C_HEAD)
    structs := 0
    fields := 0
    methods := 0
    constants := 0
    for s in db.structs.values() {
        if s.bitfield || s.anon { continue }
        size, align := layout(db, Struct(s.name))
        offs := offsets(db, s)
        if s.outer != "" {   // written inline: reachable only as a member of the enclosing type
            out.line(fmt("CHECK(sizeof(((", s.outer, " *)0)->", s.cpath, ") == ", size, ");"))
            for k, f in s.fields {
                out.line(fmt("CHECK(offsetof(", s.outer, ", ", s.cpath, ".", c_member(db, f), ") - offsetof(", s.outer, ", ",
                    s.cpath, ") == ", offs[k], ");"))
            }
        } else {
            out.line(fmt("CHECK(sizeof(", s.name, ") == ", size, ");"))
            out.line(fmt("CHECK(_Alignof(", s.name, ") == ", align, ");"))
            for k, f in s.fields {
                out.line(fmt("CHECK(offsetof(", s.name, ", ", c_member(db, f), ") == ", offs[k], ");"))
            }
        }
        structs += 1
        fields += s.fields.len
    }
    for it in db.ifaces.values() {
        vt := concat(header_name(it.name), "Vtbl")
        out.line(fmt("CHECK(sizeof(", vt, ") == ", 8 * it.methods.len, ");"))
        for slot, m in it.methods {
            out.line(fmt("CHECK(offsetof(", vt, ", ", m.name, ") / 8 == ", slot, ");"))
        }
        methods += it.methods.len
    }
    for e in db.enums.values() {
        out.line(fmt("CHECK(sizeof(", e.name, ") == 4);"))
        for item in e.items {
            out.line(fmt("CHECK((long long)", item.name, " == ", item.value, "LL);"))
        }
        constants += e.items.len
    }
    for d in db.defines {
        match d.value {
            Float(x) => out.line(fmt("CHECK((float)", d.name, " == (float)", float_literal(x), ");"))
            Int(v) if d.typed => out.line(fmt("CHECK((unsigned)", d.name, " == ", v & 0xffffffff, "u);"))
            Int(v) => out.line(fmt("CHECK((long long)", d.name, " == ", v, "LL);"))
        }
    }
    constants += db.defines.len
    // the Win32 constants of the fixed part: `const NAME: TYPE = VALUE`
    for text in lines(PROLOGUE) {
        w := split(text, ' ')
        if w.len != 5 || w[0] != "const" { continue }
        name := w[1][..len(w[1]) - 1]
        if name == "IDC_ARROW" { continue }   // a resource id, a pointer in C: below
        out.line(fmt("CHECK((unsigned long long)(", if w[2] == "u64" { "unsigned long long" } else { "unsigned" }, ")", name,
            " == ", w[4], "ull);"))
        constants += 1
    }
    out.line("CHECK((ULONG_PTR)IDC_ARROW == 32512);")
    fmt(structs, " structs (", fields, " field offsets), ", db.ifaces.len, " interfaces (", methods,
        " vtable slots), ", constants, " constants")
}

// ---- the program --------------------------------------------------------------------------------

fn save(path: str, data: str) {
    if !write_file(path, data) { fail(fmt("cannot write ", path, ": ", error_text(io_error()))) }
}

fn main() {
    include_dir := ""
    verify := false
    quiet := false
    a := args()
    i := 1
    while i < a.len {
        if a[i] == "--include" && i + 1 < a.len {
            include_dir = a[i + 1]
            i += 1
        } else if a[i] == "--verify" {
            verify = true
        } else if a[i] == "--quiet" {
            quiet = true
        } else {
            fail(fmt("unknown argument `", a[i], "`; usage: alc run ", SELF, " [-- [--include DIR] [--quiet] [--verify]]"))
        }
        i += 1
    }
    if !file_exists(SELF) { fail(fmt("run it from the root of the repository (there is no ", SELF, " here)")) }
    for dir in INCLUDE_DIRS {
        if include_dir != "" { break }
        if file_exists(concat(dir, "/d3d12.h")) { include_dir = dir }
    }
    if include_dir == "" {
        fail(fmt("d3d12.h not found in ", join(INCLUDE_DIRS[..], " or "), "; install the mingw-w64 headers or pass --include DIR"))
    }

    db: Db
    load(&db, include_dir)
    module := vec[u8]()
    functions := emit_module(&db, &module)
    selftest := vec[u8]()
    expected := vec[u8]()
    emit_test(&db, &selftest, &expected)
    c := vec[u8]()
    asserted := emit_c(&db, &c)

    // everything is generated: write
    save(MODULE_PATH, module[..])
    save(TEST_PATH, selftest[..])
    save(EXPECTED_PATH, expected[..])
    if !quiet {
        nlines := count(module[..], "\n")
        nmethods := 0
        for it in db.ifaces.values() {
            nmethods += it.methods.len
        }
        print(fmt(MODULE_PATH, ": ", nlines, " lines; ", db.enums.len, " enums, ", db.defines.len, " #defines, ",
            emitted_structs(&db).len, " structs, ", db.guids.len, " GUIDs, ", db.ifaces.len, " interfaces, ", nmethods,
            " methods, ", functions, " functions"))
        for note in db.skipped {
            print(concat("  skipped: ", note[..min(len(note), 150)]))
        }
    }
    if verify {
        if !make_dir(path_dir(VERIFY_PATH)) { fail(fmt("cannot create ", path_dir(VERIFY_PATH), ": ", error_text(io_error()))) }
        save(VERIFY_PATH, c[..])
        // a C compiler for Windows targets checks the assertions against the headers
        commands := [][]str{
            []str{"x86_64-w64-mingw32-gcc", "-fsyntax-only", "-w", VERIFY_PATH},
            []str{"clang", "--target=x86_64-w64-mingw32", "-fsyntax-only", "-w", "-isystem", include_dir, VERIFY_PATH},
        }
        for command in commands {
            status := run(command)
            if status < 0 { continue }          // not installed: try the next one
            if status != 0 { fail(fmt("verify: ", join(command, " "), ": exit status ", status)) }
            print(fmt("verify: ", asserted, " hold as static assertions (", command[0], ", ", VERIFY_PATH, ")"))
            return
        }
        fail(fmt("cannot verify ", VERIFY_PATH, ": neither x86_64-w64-mingw32-gcc nor clang is installed"))
    }
}
