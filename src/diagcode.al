// The codes of diagnostics. A diagnostic is written where the mistake is found, as a message;
// its code is the kind of mistake, found here from the message. DIAG_ERRORS and DIAG_WARNINGS
// are the whole registry: `alc capabilities` and `alc explain` print them, docs/DIAGNOSTICS.md
// lists them, and tests/driver/diag_codes.sh holds the code of every diagnostic of tests/fail
// (a message that is reworded and loses its code fails there).

struct DiagKind {
    code: str
    name: str
    what: str
    // parts of the message that mean this kind; `^` in front: the message starts with it.
    // The first kind of the table with a matching part is taken.
    pats: []str
}

const DIAG_OTHER_ERROR = "E0000"
const DIAG_OTHER_WARNING = "W0000"
// a mistake in the command line, or a file that cannot be read or written (no position)
const DIAG_DRIVER = "E1002"

fn diag_errors() -> []DiagKind {
    return []DiagKind{
        // ---------- E01: literals and characters ----------
        DiagKind{code: "E0101", name: "invalid-number-literal", what: "A number literal is malformed: a digit outside its base, no digits, too large for any integer type, or a float without digits on both sides of the point.", pats: []str{"integer literal too large", "empty integer literal", "^invalid digit", "invalid float literal", "a float literal has digits on both sides"}},
        DiagKind{code: "E0102", name: "invalid-escape", what: "A string or char literal has an escape that does not exist. The escapes are \\n \\r \\t \\0 \\\\ \\\" \\' and \\xHH.", pats: []str{"escape needs two hex digits", "^unknown escape"}},
        DiagKind{code: "E0103", name: "unterminated-literal", what: "A string, raw string or char literal has no closing quote on its line, or a char literal is not exactly one byte.", pats: []str{"^unterminated ", "char literal must be exactly one byte"}},
        DiagKind{code: "E0104", name: "unexpected-character", what: "A character that no token starts with (often a non-ASCII character outside a string).", pats: []str{"^unexpected character"}},
        // ---------- E02: syntax ----------
        DiagKind{code: "E0201", name: "unclosed-delimiter", what: "A `(`, `[` or `{` is not closed. The message gives the position where it was opened.", pats: []str{" is not closed)"}},
        DiagKind{code: "E0202", name: "keyword-as-name", what: "A keyword stands where a name is expected. Choose another name.", pats: []str{"is a keyword and cannot be used as a name"}},
        DiagKind{code: "E0204", name: "misplaced-declaration", what: "A declaration stands where it is not allowed: `const`, `struct`, `enum`, `test` and `extern` are top-level only; `inline` and `noinline` apply to top-level functions.", pats: []str{"declared at the top level", "stand at top level", "applies to top-level", "a declaration that starts with a name"}},
        DiagKind{code: "E0205", name: "misplaced-priv", what: "`priv` or `pub` is used where it has no meaning or is contradictory: on `main`, a test, a field, a variant, an `extern` variable, twice, or on only some definitions of one name.", pats: []str{"cannot be `priv`", ": remove `priv`", "with and without `priv`", "conflicts with the `priv` declaration", "is written once in front of a declaration", "is written first"}},
        DiagKind{code: "E0206", name: "nesting-too-deep", what: "Blocks, operators, calls or parentheses are nested deeper than the compiler's limit (see `limits` in `alc capabilities`).", pats: []str{"^nesting is too deep"}},
        DiagKind{code: "E0207", name: "function-syntax", what: "A function declaration is malformed: `-> ()`, modifiers in the wrong place, `...` outside an `extern` C function, an anonymous function without named and typed parameters, or type parameters where none are allowed.", pats: []str{"a function without a result has no arrow", "an anonymous function", "stand in front of a function declaration", "stands in front of a C function", "(a variable number of arguments)", "follows at least one named parameter", "cannot have type parameters", "has no body"}},
        DiagKind{code: "E0208", name: "loop-syntax", what: "A loop is malformed: `for` without `in` (a loop on a condition is `while`), a label that names no loop, or `break`/`continue` followed by something other than a label.", pats: []str{"`for` without `in`", "^a label names a loop", "leaves a loop and takes at most", "continues a loop and takes at most"}},
        DiagKind{code: "E0203", name: "unexpected-token", what: "The parser expected one token and found another. The message names both, and often what was probably meant.", pats: []str{"^expected "}},
        // ---------- E09: the C interface and GPU layouts (before the general kinds) ----------
        DiagKind{code: "E0902", name: "layout-mismatch", what: "A compile-time layout check failed: `offsetof`, `variant_count`, `std140_size`, `std430_size` or `hlsl_cbuffer_size` was given a type or field whose layout in AL differs from the one asked for.", pats: []str{"^std430_size[", "^std140_size[", "^hlsl_cbuffer_size[", "^offsetof[", "^variant_count["}},
        DiagKind{code: "E0901", name: "c-interface", what: "A value or declaration cannot cross the boundary to C: a type C has no equivalent of, a variadic or struct-passing function used as a value, or a malformed `extern` declaration.", pats: []str{"cannot cross the C boundary", "cannot be passed to a variadic C function", "^the C function", "`extern` variable", "^extern function", ": no constant `", "is not a string"}},
        // ---------- E07: constants and compile time ----------
        DiagKind{code: "E0704", name: "invalid-define", what: "A `-D NAME=VALUE` option names no constant of the program, or gives a value that is not of the constant's type.", pats: []str{"^-D "}},
        DiagKind{code: "E0703", name: "when-condition", what: "A `when` condition uses something that is not known at compile time. A condition is made of constants declared outside every `when`, literals, and the operators `==`, `!=`, `&&`, `||`, `!`.", pats: []str{"`when` condition", "this `when` was decided", "is declared inside a `when`"}},
        DiagKind{code: "E0701", name: "constant-not-assignable", what: "A constant is assigned to or its address is taken. Copy it to a variable, or declare it without `const`.", pats: []str{"is a constant: "}},
        DiagKind{code: "E0705", name: "invalid-embed", what: "`embed` cannot read its file, or was not given a string literal path.", pats: []str{"^cannot embed", "takes a string literal path"}},
        // ---------- E04: types (the specific kinds before the general ones) ----------
        DiagKind{code: "E0403", name: "value-out-of-range", what: "An integer literal or constant does not fit in the type it is used as, or a float literal stands where an integer is expected.", pats: []str{" does not fit in ", "float literal used where"}},
        DiagKind{code: "E0702", name: "not-a-compile-time-constant", what: "The value of a `const` is not a compile-time constant, has another type than declared, or depends on itself.", pats: []str{"is not a compile-time constant", "depends on itself", "^constant `", "known only at run time", "cannot infer the type of constant"}},
        // ---------- E06: match and patterns ----------
        DiagKind{code: "E0601", name: "non-exhaustive-match", what: "A `match` used as a value does not cover every case. The message lists the missing ones; an arm with a guard does not count.", pats: []str{"must be exhaustive"}},
        DiagKind{code: "E0602", name: "unreachable-pattern", what: "An arm of a `match` can never be taken because an earlier arm has the same pattern.", pats: []str{"this pattern can never match"}},
        DiagKind{code: "E0603", name: "invalid-pattern", what: "A pattern does not fit the matched value: a variant of another enum, the wrong number of fields, a tuple pattern for a non-tuple, a name bound twice or not in every alternative, or a part that is not a constant.", pats: []str{"the pattern has", "the tuple pattern has", "the pattern names", "pattern cannot match", "is an enum variant pattern", "expected an enum variant pattern", "field(s)", "in a pattern", "alternative of this arm", "^cannot match on", "a constant cannot match", "binds a part of the matched value", "this part of the pattern", "is bound more than once", "the pattern of an arm"}},
        // ---------- E05: calls ----------
        DiagKind{code: "E0503", name: "argument-type", what: "An argument has another type than the parameter. The message gives both types; AL has no implicit conversions, so convert explicitly (`i64(x)`, `f32(x)`) or pass an address with `&`.", pats: []str{"^argument "}},
        DiagKind{code: "E0407", name: "type-arguments", what: "A generic type or function has the wrong number of type arguments, needs them written out, or instantiates itself without end.", pats: []str{"needs type arguments", "type argument(s), got", "needs one type argument", "takes no type arguments", "instantiates itself", "cannot infer type"}},
        DiagKind{code: "E0501", name: "argument-count", what: "A call or a variant has the wrong number of arguments.", pats: []str{"argument(s), got", "value(s), got", "components (or a single"}},
        DiagKind{code: "E0502", name: "no-matching-definition", what: "A name has several definitions and none accepts these arguments. The message lists the candidates.", pats: []str{"^no definition of"}},
        DiagKind{code: "E0504", name: "function-as-value", what: "A function is used as a value where that is not possible (it is generic or overloaded), or a nested function is assigned to.", pats: []str{"cannot be used as a value here", "is a nested function: it is not assignable"}},
        // ---------- E03: names ----------
        DiagKind{code: "E0309", name: "captured-variable", what: "A nested or anonymous function uses a variable of the enclosing function. Functions do not capture: pass the value as a parameter.", pats: []str{"is a variable of the enclosing function"}},
        DiagKind{code: "E0302", name: "unknown-function", what: "No function has this name (or none can be called as a method on this type). The message suggests a close name if there is one.", pats: []str{"^unknown function", "^no function `"}},
        DiagKind{code: "E0303", name: "unknown-type", what: "No type has this name. The message suggests the AL name of types known from other languages (`int`, `string`, `float`).", pats: []str{"^unknown type"}},
        DiagKind{code: "E0304", name: "unknown-module", what: "`use std.<name>` names a module that does not exist or is not available for the target.", pats: []str{"^unknown module", "is not available for --target"}},
        DiagKind{code: "E0301", name: "unknown-identifier", what: "No variable, constant or function with this name is visible here. A `priv` declaration of another file is not visible.", pats: []str{"^unknown identifier", "^unknown variable", "^unknown name"}},
        DiagKind{code: "E0305", name: "unknown-field", what: "The type has no field (or vector component) with this name. The message lists the fields.", pats: []str{" has no field `", "^has no field `", "has no component"}},
        DiagKind{code: "E0306", name: "unknown-variant", what: "The enum has no variant with this name. The message lists the variants.", pats: []str{"is not a variant of", " has no variant `"}},
        DiagKind{code: "E0308", name: "ambiguous-variant", what: "A variant name belongs to several enums and the context does not say which. Write `Enum.Variant`.", pats: []str{"is a variant of several enums", " is a variant of "}},
        DiagKind{code: "E0307", name: "duplicate-declaration", what: "A name is declared twice in one scope, or takes the name of a builtin type, or a loop label repeats that of an enclosing loop.", pats: []str{"is already declared", "` twice", "is a builtin type name", "has the name of the", "is already used by the enclosing loop"}},
        // ---------- E04: types ----------
        DiagKind{code: "E0402", name: "operand-types", what: "The operands of an operator have different types, or a type the operator does not work on. AL has no implicit conversions: convert one operand explicitly.", pats: []str{"^operands ", "work on numbers only", "needs two integers of the same type", "cannot be compared"}},
        DiagKind{code: "E0405", name: "invalid-conversion", what: "A conversion `T(x)` between these types does not exist. `cast[T](x)` reinterprets bits; an enum converts from an integer only if no variant has data.", pats: []str{"^cannot convert", " variants, numbered "}},
        DiagKind{code: "E0406", name: "invalid-operation", what: "A value is indexed, sliced, iterated or called and its type does not allow it; or an index is not an integer or is known to be out of range.", pats: []str{"^cannot index", "^cannot iterate", "is not callable", "needs a slice, array, str, Vec or Map", "index must be an integer", "slice bound must be", "is out of bounds for length", "too many elements in array literal"}},
        DiagKind{code: "E0408", name: "missing-value", what: "A function that declares a result does not return one on every path, or an expression without a value is used as one.", pats: []str{"does not return a value", "must return a value", "needs a value; this expression has none"}},
        DiagKind{code: "E0409", name: "condition-not-bool", what: "The condition of `if`, `while` or `assert` is not a `bool`. Integers are not truthy: write `x != 0`.", pats: []str{"must be a bool"}},
        DiagKind{code: "E0404", name: "cannot-infer-type", what: "The type of an expression cannot be inferred here. Annotate the variable (`x: T = ...`) or write the type arguments.", pats: []str{"^cannot infer"}},
        DiagKind{code: "E0401", name: "type-mismatch", what: "A value has another type than the place it is used in expects. The message gives both types.", pats: []str{"^type mismatch", "does not match its declared type", "but its value has type"}},
        // ---------- E08: statements ----------
        DiagKind{code: "E0801", name: "no-effect", what: "A statement is an expression whose value is not used. Often `==` was written for `=`, or a line starts with an operator and so begins a new statement.", pats: []str{"^this expression has no effect"}},
        DiagKind{code: "E0802", name: "loop-control", what: "`break` or `continue` stands outside a loop, or names a label that no enclosing loop has.", pats: []str{"outside of a loop", "there is no loop labelled"}},
        DiagKind{code: "E0803", name: "not-addressable", what: "The address of something that has none is taken or needed: a temporary, a vector component, or the left side of `:=` is not a name.", pats: []str{"^cannot take the address", "by pointer to", "left side of `:=`"}},
        DiagKind{code: "E0804", name: "clone-of-pointer", what: "`clone` of a pointer would copy the pointer, not what it points to. Write `clone(*p)`.", pats: []str{"`clone` of a pointer", " is a copy of "}},
        // ---------- E10: the program and the driver ----------
        DiagKind{code: "E1001", name: "invalid-main", what: "The program has no `fn main()`, or `main` is not declared as `fn main()` or `fn main() -> i64`.", pats: []str{"^missing `fn main", "^`main` is declared"}},
        DiagKind{code: "E1002", name: "driver", what: "A mistake in the command line, or a file that cannot be read or written. These have no position (`line` and `col` are 0).", pats: []str{"^cannot read", "^cannot write", "^unknown command", "^unknown option", "^usage: "}},
        DiagKind{code: "E1003", name: "format", what: "`alc fmt --check` found a file that is not in the canonical layout, or `alc fmt` could not format a file.", pats: []str{"not in the canonical layout", "internal error of alc fmt"}},
        DiagKind{code: "E0000", name: "other", what: "An error that has no code of its own yet. The message says what is wrong.", pats: []str{}},
    }
}

fn diag_warnings() -> []DiagKind {
    return []DiagKind{
        DiagKind{code: "W0001", name: "unused-variable", what: "A local variable is never read. Prefix its name with `_` if that is intended.", pats: []str{"^unused variable"}},
        DiagKind{code: "W0002", name: "unreachable-code", what: "A statement follows `return`, `break`, `continue` or a call that never returns.", pats: []str{"^unreachable statement"}},
        DiagKind{code: "W0003", name: "self-assignment", what: "A variable is assigned to itself.", pats: []str{"^self-assignment"}},
        DiagKind{code: "W0004", name: "non-exhaustive-match", what: "A `match` statement does not cover every case. Add `_ => {}` if that is intended.", pats: []str{"^non-exhaustive `match`"}},
        DiagKind{code: "W0005", name: "no-effect", what: "A statement computes a value that is not used.", pats: []str{"has no effect"}},
        DiagKind{code: "W0000", name: "other", what: "A warning that has no code of its own yet.", pats: []str{}},
    }
}

// the code of the diagnostic with message `msg`
fn diag_code(msg: str, warn: bool) -> str {
    table := if warn { diag_warnings() } else { diag_errors() }
    for k in table {
        for p in k.pats {
            if p[0] == '^' {
                if starts_with(msg, p[1..]) {
                    return k.code
                }
            } else if find(msg, p) >= 0 {
                return k.code
            }
        }
    }
    return if warn { DIAG_OTHER_WARNING } else { DIAG_OTHER_ERROR }
}

// the kind with this code (as written by the user: any case), if there is one
fn diag_kind(code: str) -> Opt[DiagKind] {
    want := to_upper(code)
    for k in diag_errors() {
        if k.code == want {
            return Some(k)
        }
    }
    for k in diag_warnings() {
        if k.code == want {
            return Some(k)
        }
    }
    return None
}

// The words an advice starts with. A message gives its advice after `: `, after `; ` or in
// parentheses: "`for` without `in`: a loop on a condition is written `while cond { }`" has
// none of these, "... (use `&&`)" and "...: remove `priv`" have.
priv fn diag_verbs() -> []str {
    return []str{"write ", "remove ", "leave out ", "use ", "add ", "rename ", "give ", "declare ", "copy ", "convert ", "pass ", "prefix ", "call ", "annotate ", "order ", "bind ", "label ", "name ", "raise "}
}

priv fn diag_starts_advice(s: str) -> bool {
    for v in diag_verbs() {
        if starts_with(s, v) {
            return true
        }
    }
    return false
}

// the end of the parenthesis that opens just before s[from]: the index of its `)`, or len(s).
// Parentheses inside `...` are code and do not count.
priv fn diag_paren_end(s: str, from: i64) -> i64 {
    depth := 1
    code := false
    for i in from..len(s) {
        c := s[i]
        if c == '`' {
            code = !code
        } else if !code && c == '(' {
            depth += 1
        } else if !code && c == ')' {
            depth -= 1
            if depth == 0 {
                return i
            }
        }
    }
    return len(s)
}

// What the message says to do, as a sentence of its own: "" if it gives no advice. The message
// keeps its text; this is the same advice without the description of the mistake.
fn diag_fix(msg: str) -> str {
    dym := find(msg, "did you mean ")
    if dym >= 0 {
        rest := msg[dym + 13..]
        q := find(rest, "?")
        if q > 0 {
            return fmt("write ", rest[..q])
        }
    }
    code := false
    n := len(msg)
    for i in 0..n {
        c := msg[i]
        if c == '`' {
            code = !code
            continue
        }
        if code || i + 2 >= n {
            continue
        }
        if (c == ':' || c == ';') && msg[i + 1] == ' ' && diag_starts_advice(msg[i + 2..]) {
            // (inside a parenthesis the advice ends with it)
            rest := msg[i + 2..]
            return rest[..diag_paren_end(rest, 0)]
        }
        if c == ' ' && msg[i + 1] == '(' && diag_starts_advice(msg[i + 2..]) {
            return msg[i + 2..diag_paren_end(msg, i + 2)]
        }
    }
    return ""
}

// The end of the token that starts at column `col` (from 1) of `line_text`: the column after
// its last character. A name or number ends where its characters do, a quoted literal at its
// closing quote, anything else is one character.
fn diag_token_end(line_text: str, col: i64) -> i64 {
    n := len(line_text)
    i := col - 1
    if i < 0 || i >= n {
        return max(col, 1)
    }
    c := line_text[i]
    if is_alnum(c) || c == '_' {
        j := i + 1
        while j < n && (is_alnum(line_text[j]) || line_text[j] == '_') {
            j += 1
        }
        return j + 1
    }
    if c == '"' || c == '\'' || c == '`' {
        j := i + 1
        while j < n && line_text[j] != c {
            if line_text[j] == '\\' && c != '`' {
                j += 1
            }
            j += 1
        }
        return min(j + 1, n) + 1
    }
    return col + 1
}

// line `line` (from 1) of `text` without its line end, "" if there is none
fn diag_line_text(text: str, line: i64) -> str {
    cur := 1
    start := 0
    for i in 0..len(text) {
        if text[i] == '\n' {
            if cur == line {
                end := if i > start && text[i - 1] == '\r' { i - 1 } else { i }
                return text[start..end]
            }
            cur += 1
            start = i + 1
        }
    }
    return if cur == line { text[start..] } else { "" }
}
