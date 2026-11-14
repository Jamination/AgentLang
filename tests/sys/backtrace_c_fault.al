// a memory fault inside C code (a bad pointer passed to it) that a function of the program called
// from a callback of other C code: the trace starts in the C code and shows the frames of the
// program and of the C library on both sides
when TARGET_OS == Windows {
    extern "backtrace_c_fault.dll" fn run_each(f: fn(i32) -> i32, n: i32) -> i32
    extern "backtrace_c_fault.dll" fn poke_twice(p: *i32, v: i32) -> i32
} else {
    extern "libbacktrace_c_fault.so" fn run_each(f: fn(i32) -> i32, n: i32) -> i32
    extern "libbacktrace_c_fault.so" fn poke_twice(p: *i32, v: i32) -> i32
}

fn item(i: i32) -> i32 {
    if i == 2 {
        return poke_twice(cast[*i32](8 * i64(i)), i)
    }
    return i * 2
}

noinline fn walk(n: i32) -> i32 {
    return run_each(item, n) + 1
}

fn main() {
    print("start")
    print(walk(6))
}
