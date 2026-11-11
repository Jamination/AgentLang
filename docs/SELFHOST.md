# Translating the compiler from Rust to AL

The compiler is being moved from Rust (`src/**/*.rs`) to AL (`src/**/*.al`, same file names).
Every file is translated on its own by following these rules, so that independently translated
files fit together. **The rules are a contract: follow them exactly, even where another
choice looks nicer.** The translation is semantic line-by-line: same algorithms, same order of
operations, same data, same diagnostics text. Do not redesign, optimise or "improve".

## Files

- `src/foo.rs` becomes `src/foo.al`; `src/opt/gvn.rs` becomes `src/opt/gvn.al`;
  `src/x86/mod.rs` becomes `src/x86/mod.al`, `src/opt/mod.rs` becomes `src/opt/mod.al`.
- Files do not `use` each other. `src/main.al` lists every file once. To type-check your file
  before the whole compiler exists, write a scratch driver `tmp/<you>/check.al` that `use`s
  `../../src/base.al`, the files yours depends on (those that exist) and yours, plus
  `fn main() {}`, and run `alc check` on it. Errors about names from files that are not
  written yet are expected; everything else must be clean.
- Keep the Rust comments (translated to the AL code they describe). One-line header comment.

## Names

| Rust | AL |
|------|----|
| free function `f` in module `m` (file `m.rs`), public or private | `m_f`: `lexer::lex` is `lexer_lex`, `opt::cleanup::dce` is `cleanup_dce`, `elf::link` is `elf_link`, `x86::compile` is `x86_compile`, `opt::optimize` is `opt_optimize`, `opt::enabled` is `opt_enabled`, `opt::trace` is `opt_trace`, `isel::select` is `isel_select`, `ir::canon` is `ir_canon`, `ir::print_func` is `ir_print_func`, `ir::verify` is `ir_verify`. The module is the file name (`mod.rs`: the directory name). Nested helper `fn`s inside a function: `m_outer_inner`. |
| method `fn name(&self, ..)` / `(&mut self, ..)` in `impl X` | `fn name(self *X, ..)`, same name, no prefix (AL overloads on the receiver type). Call sites: `x.name(..)`. Receivers are always pointers. |
| methods on small value enums (`T`, `Op`, `MOp`, `BinOp`, ...: `t.size()`, `op.is_cmp()`, `op.swap_cmp()`) | take the value, not a pointer: `fn size(self T) i64`, `fn is_cmp(self Op) bool`. Call as `t.size()`. |
| associated function without self (`X::new(..)`, `Val::err()`, `Mem::slot(..)`) | `x_new(..)`, `val_err()`, `mem_slot(..)`: type name in snake case, underscore, function name |
| struct, enum, field names | unchanged. A non-`pub` struct or enum private to a file under `src/opt/` or `src/x86/` gets the file name as prefix in CamelCase (`Ctx` in `simplify.rs` is `SimplifyCtx`, `Ctx` in `mem2reg.rs` is `Mem2regCtx`, `Sel` in `isel.rs` is `IselSel`, `Enc` is `EmitEnc`, `Item` is `EmitItem`, `Frame` is `EmitFrame`, `RM` is `EmitRM`, `Step` in `gvn.rs` is `GvnStep`). Everything else keeps its name. |
| enum variant `Enum::Variant` | `EnumVariant`, concatenated, because AL variants are global: `Op::Add` is `OpAdd`, `MOp::Add` is `MOpAdd`, `BinOp::Add` is `BinOpAdd`, `UnOp::Neg` is `UnOpNeg`, `T::I64` is `TI64`, `TyK::Ptr(t)` is `TyKPtr(t)`, `Tk::Id(s)` is `TkId(s)`, `EK::Int(n)` is `EKInt(n)`, `SK::Let(..)` is `SKLet(..)`, `Term::Jmp(b)` is `TermJmp(b)`, `Opnd::R(r)` is `OpndR(r)`, `MemKind::Slot` is `MemKindSlot`, `Decl::Fn(f)` is `DeclFn(f)`, `Pat::Wild` is `PatWild`, `TypeAst::Name(..)` is `TypeAstName(..)`, `CV::Int(i)` is `CVInt(i)`, `CState::Busy` is `CStateBusy`, `ParamAbi::Scalar(t)` is `ParamAbiScalar(t)`, `RetAbi::SRet` is `RetAbiSRet`, `RelocKind::Abs32Global(g)` is `RelocKindAbs32Global(g)`, `RelocTarget::Func(f)` is `RelocTargetFunc(f)`, `Callee::Direct(f)` is `CalleeDirect(f)`. `use Op::*` shortcuts are expanded. |
| constants (`NOV`, `T_I64`, `RAX`, `AK_PTR`, `MAX_FLAT`, `cc::E`) | `const` with the same name; inside a sub-module the module is a prefix: `cc::E` is `CC_E`. A private constant whose name could clash across files gets the file prefix (`elf.rs` `BASE` is `ELF_BASE`). |
| statics / env switches | globals (`var`) with the same name in lower case and the file prefix |

## Types

| Rust | AL |
|------|----|
| type aliases `V`, `B`, `Reg`, `Ty` and every integer used as an id, index, count, size or position (`u32`, `usize`, `u16`, `u64` sizes) | `i64`. There are no aliases: write `i64`. Sentinels keep their numeric value: `NOV` and `NOREG` are `0xFFFFFFFF`. `Pos` fields are `i64`. |
| integers whose width is semantics (encoded bytes `u8`, `i8`/`i32` displacements when range-checked or wrapped, constant folding by width, hashes, `u64` bit patterns, float bits) | the same width; reproduce every `as` cast as the same AL conversion chain (`k as i32 as i64` is `i64(i32(k))`). AL arithmetic wraps like Rust release builds; `wrapping_*` are the plain operators; shifts mask the count. |
| `u128` (float constant pool) | `struct Bits128 { lo u64, hi u64 }` (defined in `src/x86/mir.al`) |
| `f64` | `f64`; `f64::from_bits(x)` is `cast[f64](x)`, `to_bits()` is `cast[u64](x)`; `f32` likewise with `u32` |
| `bool`, `u8` | same |
| `String`, `&str`, `&'a str`, `Vec<u8>` used as text | `str`. Text is immutable; build with `fmt(a, b, ..)`, `concat`, `join`. `format!("{}..", x)` is `fmt(..)` producing the same characters (`{:?}` of a float: use `fmt(x)`; hex: `hex(u64)`; padding: `pad_left`). |
| `Vec<T>` | `Vec[T]`: `vec[T]()`, `v.push(x)`, `v.pop()`, `v.len`, `v.buf[i]` (read / write element), `v.items()` (slice of the live elements, for `for x in v.items()` and for passing `&[T]`), plus from `src/base.al`: `vec_of(slice)`, `vec_fill(n, x)`, `clone(v)`, `v.last()`, `v.is_empty()`, `v.clear()`, `v.truncate(n)`, `v.resize(n, x)`, `v.extend(slice)`, `v.insert(i, x)`, `v.remove(i)`, `v.swap_remove(i)`, `contains(&v, x)`, `index_of(slice, x)`, `reverse(slice)`, `v.dedup()`, `sort(slice)`, `sort_by(slice, less_fn)`. `vec![x; n]` is `vec_fill(n, x)`; `vec![a, b]` is `vec_of([]T{a, b})`; `Vec::with_capacity` is `vec[T]()`. |
| `&[T]`, `&mut [T]` parameters | `[]T` |
| `[T; N]` | `[N]T` |
| `HashMap<K, V>` | `Map[K, V]`: `map[K, V]()`, `m.set(k, v)`, `m.get(k)` returns `(V, bool)`, `m.get_or(k, d)`, `m.has(k)`, `m.del(k)`, `m.len`, `m.keys()`, `m.clear()`. Keys may be integers, `str`, tuples, structs, slices. `entry(k).or_default().push(x)`: get, modify, set back. `insert` returning the old value: `get` then `set`. |
| `HashSet<T>` | `Map[T, bool]` |
| `Option<T>` | `Opt[T]` from `src/base.al` with variants `Some(x)` and `None`, matched with `match`. For plain ids prefer the sentinel the Rust code would compare against only if the Rust already does so; do not invent sentinels. `if let Some(x) = o { A } else { B }` is a `match`. |
| `Result<T, ()>` in the parser (`R<T>`) | `(T, bool)` with `true` = ok; `?` becomes `if !ok { return (zero, false) }`. `Result<Vec<u8>, String>` (`elf::link`): `(str, str)` where a non-empty second value is the error. |
| `Box<T>` | `*T` allocated with `new[T]()` then assigned, or `&T{..}` |
| `&T`, `&mut T` to a struct | `*T` |
| references to scalars used as out-parameters | `*T` |
| tuples | tuples; `.0` `.1` as in Rust |
| `Rc`, lifetimes, `&'a Expr` | plain pointers `*Expr`; the AST lives for the whole run |
| closures | AL has none. A closure becomes a function named `m_outer_name` taking what it captured as extra parameters (pointers for what it mutates). A closure passed to `sort_by`, `iter().map/filter/any/all/position/find` becomes an explicit loop. |
| iterator chains | explicit loops with the same order of evaluation |
| `impl Trait`, generics | AL generics where needed (`fn f[T](..)`) |
| `enum` with data | AL `enum` with the variant rule above. AL `match` binds variant fields positionally, has no nested patterns, no guards and no `|` between binding patterns: nest `match` / `if` instead, and repeat an arm body through a helper function when Rust merges binding patterns. `matches!(x, A | B)` on a data-less enum is `x == A || x == B`; on an enum with data write a small `is_..` helper with a `match`. |
| `#[derive(PartialEq)]` comparisons | `==` works on structs, tuples, slices, data-less enums; for enums with data write `fn eq(a, b) bool` helpers where the Rust compares them |
| `#[derive(Clone)]` / `.clone()` | **Assignment copies a struct but shares the buffers of any `Vec`, `Map` or slice inside it.** Where Rust clones something that is then mutated independently (or keeps the original while mutating the copy), write a real copy: `clone(v)` for a `Vec`, a `clone` function for a struct that contains Vecs (`fn clone(i *Inst) Inst`), `str` never needs copying. Where the clone only pleases the borrow checker, no copy is needed; when in doubt, copy. |
| `std::mem::take(&mut v)` | `t := v` then `v = vec[T]()` |
| `std::mem::swap` | swap through a temporary |
| `panic!`, `unreachable!`, `assert!` | `panic(fmt(..))`, `assert` |
| `eprintln!` / `eprint!` | `eprint(fmt(.., "\n"))` (`src/base.al`) |
| `println!` / `print!` | `print(..)` / `put(..)` (note `print` separates arguments with spaces: build the exact text with `fmt` when the Rust format string has no spaces) |
| `std::env::var("X")` | `env_get("X")` returning `(str, bool)` |
| `include_str!("x")` | `embed("x")` (path relative to the source file) |
| `std::process::exit(n)` | `exit(n)` |

## Things that are easy to get wrong

- `Map` iteration order differs from Rust's `HashMap`. Where the Rust iterates a `HashMap`
  or `HashSet` and the order can affect the output, iterate `m.keys()` after `sort`, or keep a
  side `Vec` of keys in insertion order. Say so in a comment.
- `v.buf[i]` is only bounds-checked against the capacity. Do not read past `v.len`.
- A `[]T` obtained from `v.items()` is stale after a `push` that grows `v`. Do not hold slices
  or element pointers (`&v.buf[i]`) across pushes to the same Vec; re-take them. This is the
  Rust borrow rule, now unchecked.
- Struct values are copied on assignment and when passed by value: to mutate an element of a
  Vec in place write `v.buf[i].field = x` or take `p := &v.buf[i]`. `x := v.buf[i]; x.f = 1`
  changes a copy (in Rust `let x = &mut v[i]` mutated the element).
- Integer literals are `i64`, there are no implicit conversions: `u8(x)`, `i64(c)`.
- `match` on integers needs a `_` arm when used as a value. Enum `match` as a value must be
  exhaustive or have `_`.
- Recursion depth: fine, the driver raises the stack limit.
- Memory is an arena; never free. Do not use `mark()` / `release()` in the compiler.
- User-visible names of the language's own prelude (`min`, `max`, `abs`, `sort`, `fmt`,
  `find`, `split`, `lines`, `trim`, `hex`, `join`, `concat`, `push`, `pop`, `get`, `set`,
  `has`, `del`, `keys`, `items`, `len`, `length`, `dot`, `cross`, `sign`, `step`, `lerp`,
  `floor`, `round`, `E`, `PI`, ...) are visible in compiler code too; a compiler function or
  constant with such a name is fine when its parameter types differ (overloading) but never
  name a constant or global like a prelude constant (`E`, `PI`, `INF`, `NAN`, `TAU`).

## Checking your work

There is no way to run a single file. Type-check with the scratch driver, then re-read your
translation against the Rust once, function by function, looking for: dropped statements,
changed evaluation order, `clone` cases, off-by-one in ranges (`a..b` is the same in AL,
`a..=b` too), signed / unsigned comparisons and shifts (`u32 >> n` is logical, `i32 >> n`
arithmetic: in AL the operand type decides in the same way, so ids that became `i64` must not
rely on unsigned wrap-around: check every `wrapping_sub`, `as u32`, `as u8` on them).
