// the atomic builtins on every width, bool and pointers (one thread)
struct N { v: i64 }

fn main() {
    a: i8 = 127
    print(atomic_add(&a, 1), a, atomic_sub(&a, 1), a)
    b: u16 = 0xFFFF
    print(atomic_add(&b, 2), b, atomic_swap(&b, 9), b)
    c: i32 = -5
    o, ok := atomic_cas(&c, -5, 6)
    print(o, ok, c, atomic_load(&c))
    d: u64 = 0xF0F0
    print(atomic_and(&d, 0xFF00), atomic_or(&d, 1), atomic_xor(&d, 0xFFFF), d)
    f := false
    print(atomic_swap(&f, true), f, atomic_cas(&f, true, false), f)
    x := N{1}
    y := N{2}
    p := &x
    atomic_store(&p, &y)
    q := atomic_load(&p)
    old, swapped := atomic_cas(&p, &x, &x)
    print(q.v, old.v, swapped)
    atomic_fence()
    s := []i64{1, 2, 3}
    atomic_add(&s[1], 40)
    print(s)
}
