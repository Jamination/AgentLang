// AL code called back on a thread that a C library created: it gets an arena, an id and an
// output buffer of its own when it first needs them
use std.os

when TARGET_OS == Windows {
    extern "thread_ccb.dll" fn call_from_thread(f: fn(i32), x: i32)
} else {
    extern "libthread_ccb.so" fn call_from_thread(f: fn(i32), x: i32)
}

fn callback(x: i32) {
    v := vec[str]()
    for i in 0..1000 {
        v.push(fmt("s", i))
    }
    m := map[i64, str]()
    m.set(1, clone(v[999]))
    print("callback", x, v[999], m.get_or(1, ""), thread_id() > 0, thread_id() != 0)
}

fn main() {
    call_from_thread(callback, 7)
    call_from_thread(callback, 8)
    print("done", thread_id())
}
