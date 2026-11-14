// a panic in a function of the program that C code called: the trace goes on through the frames
// of the C library (built without frame pointers) to the frames of the program that called it
when TARGET_OS == Windows {
    extern "backtrace_c_callback.dll" fn run_each(f: fn(i32) -> i32, n: i32) -> i32
} else {
    extern "libbacktrace_c_callback.so" fn run_each(f: fn(i32) -> i32, n: i32) -> i32
}

fn check(i: i32) {
    assert i != 3, "item 3 is bad"
}

fn item(i: i32) -> i32 {
    check(i)
    return i * 2
}

noinline fn walk(n: i32) -> i32 {
    return run_each(item, n) + 1
}

fn main() {
    print("start")
    print(walk(6))
}
