# The memory model and its trade-offs

AL manages dynamic memory with arenas. There is no `free`, no garbage collector and no borrow
checker. This page says what that buys, what it costs, and which mistakes the compiler and the
run-time library do and do not catch. How to use it is in the language reference
([Memory](LANGUAGE.md#memory)) and in [std/mem.md](std/mem.md).

## The model in one paragraph

Local variables live on the stack. Everything else (`alloc`, `new`, `Vec`, `Map`, `fmt`,
`clone`, every library function) bumps a pointer in the *arena in use* and gets zeroed memory.
Nothing is released one object at a time. Memory goes back in bulk: `release(m)` gives back
everything allocated since `m := mark()`, and `reset(&r)` empties a `Region`, an independent
arena that `enter(&r)` / `leave()` put in use. Data that must outlive a scope is deep-copied
out of it with `clone`. Objects that are created and destroyed individually live in a
`Pool[T]` and are named by generation-checked `Handle`s instead of pointers.

## What you get

- **Nothing to annotate.** No lifetimes, no ownership rules, no move semantics. Any value can
  be stored anywhere and passed anywhere.
- **Allocation is a pointer bump**, and releasing a million objects is one assignment. There
  are no destructors to run.
- **No pauses.** There is no collector, so no collection ever happens in the middle of a frame.
- **Leaks are measurable.** `mem_used()` before and after a frame or a level must return to the
  same value; if it does not, the difference is the leak.
- **Short programs need no memory management at all.** A compiler pass, a command-line tool or
  a script allocates freely and exits.

## What it costs

- **You choose lifetimes yourself.** Every allocation belongs to an arena, and you decide when
  that arena is emptied. For a game that is three lifetimes (program, level, frame); for a
  server, a region per request. A program whose data has no such structure is harder to write
  in AL than in a language with a garbage collector.
- **Use after release is a bug the compiler cannot see.** A slice or pointer into memory that
  `release`, `reset` or `frame_end` gave back is simply invalid. Used anyway, it reads zeroes
  or whatever was allocated there next, without a message. This is the largest difference from
  Rust, and it is deliberate: preventing it statically is what a borrow checker is for.
- **Growing containers follow the arena in use.** A `Vec` or `Map` that grows while a region or
  a frame scope is in use moves its storage there, even if it was created elsewhere, and is
  invalid after the reset. Containers that must survive are given their room before, grown
  outside, or cloned out. In practice this is the mistake people make first.
- **A `Vec` moves when it grows.** A slice or pointer into a `Vec` refers to its old buffer
  after a `push` that grows it. Keep an index, not a pointer. (C++'s `std::vector` has the same
  rule.)
- **Old buffers stay until the arena is emptied.** A `Vec` that doubles ten times leaves ten
  buffers behind in its arena. Peak memory is higher than with `free`, and a long-running
  program that never releases anything grows without bound.
- **Copies share storage.** Assigning a struct that contains a `Vec` copies the reference, not
  the elements. An independent copy is an explicit `clone`, which is a deep copy and costs what
  it copies.
- **Data races are undefined behaviour.** Threads share all memory, and nothing checks that
  shared data is guarded by a `Mutex` or accessed with the atomic builtins.

## What is checked

| Mistake | What happens |
|---|---|
| Index or slice bound out of range | `panic: index out of bounds at file:line` and a stack trace. On by default; `--unchecked` removes it |
| `nil` dereference, stack overflow | `panic: memory fault (...)` and a stack trace |
| Use of an object removed from a `Pool` | `get` returns `nil` for the stale `Handle` |
| Use of memory given back by `release`, `reset` or `frame_end` | **Not detected** in a normal run. With `ALC_CHECK_MEMORY=1`: `panic: use of released memory`, with the stack trace of the access |
| A longer-lived `Vec` or `Map` growing inside a frame scope or region | **Not detected** in a normal run. With `ALC_CHECK_MEMORY=1`: a panic at the `push` |
| Use of a region's memory after `region_free` | `panic: memory fault (...)`: the memory is unmapped |
| Misuse of `enter` / `leave`, `frame_end` in the wrong arena, an exhausted arena | a panic that names the mistake |
| A data race | **Not detected** |
| Uninitialized memory | Cannot happen: all memory is zeroed when it is handed out |

`ALC_CHECK_MEMORY=1` is an environment variable for the program, not a compiler option: the
same executable runs in the checking mode. Released memory is then taken away instead of
reused, so the mode costs memory and is meant for tests and for hunting a bug, not for release.
It finds the mistakes that a run actually makes, not all that a program could make.

## Compared with the alternatives

| | AL | C | Rust | Go, C#, Java |
|---|---|---|---|---|
| Releasing memory | in bulk, by arena | per object, `free` | automatic, by ownership | garbage collector |
| Use after release | possible; found by a checking mode at run time | possible | prevented at compile time | impossible |
| Out-of-bounds access | panics | undefined | panics | panics / exception |
| Double free | cannot be written | possible | prevented at compile time | impossible |
| Data races | undefined | undefined | prevented at compile time | possible |
| Annotations required | none | none | lifetimes, ownership | none |
| Pauses | none | none | none | collector pauses |

AL sits between C and Rust. It removes the errors of per-object management (double free,
mismatched allocators, forgotten frees) by removing per-object management, and it checks
bounds. It does not prove the absence of dangling references; it gives you a small number of
lifetimes to reason about, a `Handle` for the references that most often dangle, and a
run-time mode that finds the rest when a test exercises them.

## Is it enough for long-running programs?

Yes, with structure. The compiler's own language server (`alc lsp`) runs for as long as the
editor does and handles each request in a region of its own that it frees afterwards. A game
runs on the three lifetimes of [std/mem.md](std/mem.md#lifetimes-how-a-game-allocates). The
rule for a loop that runs forever is that every iteration ends by giving back what it
allocated (`frame_end()`, `release(m)` or `reset(&r)`) and that what survives the iteration
was either allocated before it or cloned out of it.

## When AL is the wrong choice

- You need memory safety proved at compile time, for example for code that parses untrusted
  input in a security boundary. Use Rust.
- Your data is a large, long-lived graph in which objects die individually and unpredictably,
  and a `Pool` per type does not fit. Use a language with a garbage collector.
- You need many threads sharing mutable data with the compiler checking the locking.
