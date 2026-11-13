// element sizes that x86 addresses with lea/shift (3, 5, 9 times a power of two) and some
// that it does not; multiplications by such constants in every integer type
struct S3 { f0: u8, f1: u8, f2: u8 }
noinline fn t3(n: i64, d: i64) -> i64 {
    a := alloc[S3](n)
    for i in 0..n {
        a[i].f0 = u8(i * 3 + 1)
        a[i].f1 = u8(i ^ 5)
        a[i].f2 = u8(i + d)
    }
    h := i64(sizeof[S3]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f2)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u8(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f2)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f2 = u8(99)
    h = h * 31 + i64(a[d].f2) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S5 { f0: u8, f1: u8, f2: u8, f3: u8, f4: u8 }
noinline fn t5(n: i64, d: i64) -> i64 {
    a := alloc[S5](n)
    for i in 0..n {
        a[i].f0 = u8(i * 3 + 1)
        a[i].f1 = u8(i ^ 5)
        a[i].f4 = u8(i + d)
    }
    h := i64(sizeof[S5]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f4)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u8(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f4)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f4 = u8(99)
    h = h * 31 + i64(a[d].f4) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S6 { f0: u16, f1: u16, f2: u16 }
noinline fn t6(n: i64, d: i64) -> i64 {
    a := alloc[S6](n)
    for i in 0..n {
        a[i].f0 = u16(i * 3 + 1)
        a[i].f1 = u16(i ^ 5)
        a[i].f2 = u16(i + d)
    }
    h := i64(sizeof[S6]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f2)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u16(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f2)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f2 = u16(99)
    h = h * 31 + i64(a[d].f2) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S7 { f0: u8, f1: u8, f2: u8, f3: u8, f4: u8, f5: u8, f6: u8 }
noinline fn t7(n: i64, d: i64) -> i64 {
    a := alloc[S7](n)
    for i in 0..n {
        a[i].f0 = u8(i * 3 + 1)
        a[i].f1 = u8(i ^ 5)
        a[i].f6 = u8(i + d)
    }
    h := i64(sizeof[S7]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f6)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u8(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f6)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f6 = u8(99)
    h = h * 31 + i64(a[d].f6) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S9 { f0: u8, f1: u8, f2: u8, f3: u8, f4: u8, f5: u8, f6: u8, f7: u8, f8: u8 }
noinline fn t9(n: i64, d: i64) -> i64 {
    a := alloc[S9](n)
    for i in 0..n {
        a[i].f0 = u8(i * 3 + 1)
        a[i].f1 = u8(i ^ 5)
        a[i].f8 = u8(i + d)
    }
    h := i64(sizeof[S9]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f8)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u8(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f8)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f8 = u8(99)
    h = h * 31 + i64(a[d].f8) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S10 { f0: u16, f1: u16, f2: u16, f3: u16, f4: u16 }
noinline fn t10(n: i64, d: i64) -> i64 {
    a := alloc[S10](n)
    for i in 0..n {
        a[i].f0 = u16(i * 3 + 1)
        a[i].f1 = u16(i ^ 5)
        a[i].f4 = u16(i + d)
    }
    h := i64(sizeof[S10]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f4)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u16(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f4)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f4 = u16(99)
    h = h * 31 + i64(a[d].f4) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S12 { f0: i32, f1: i32, f2: i32 }
noinline fn t12(n: i64, d: i64) -> i64 {
    a := alloc[S12](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f2 = i32(i + d)
    }
    h := i64(sizeof[S12]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f2)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f2)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f2 = i32(99)
    h = h * 31 + i64(a[d].f2) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S16 { f0: i32, f1: i32, f2: i32, f3: i32 }
noinline fn t16(n: i64, d: i64) -> i64 {
    a := alloc[S16](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f3 = i32(i + d)
    }
    h := i64(sizeof[S16]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f3)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f3)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f3 = i32(99)
    h = h * 31 + i64(a[d].f3) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S18 { f0: u16, f1: u16, f2: u16, f3: u16, f4: u16, f5: u16, f6: u16, f7: u16, f8: u16 }
noinline fn t18(n: i64, d: i64) -> i64 {
    a := alloc[S18](n)
    for i in 0..n {
        a[i].f0 = u16(i * 3 + 1)
        a[i].f1 = u16(i ^ 5)
        a[i].f8 = u16(i + d)
    }
    h := i64(sizeof[S18]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f8)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += u16(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f8)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f8 = u16(99)
    h = h * 31 + i64(a[d].f8) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S20 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32 }
noinline fn t20(n: i64, d: i64) -> i64 {
    a := alloc[S20](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f4 = i32(i + d)
    }
    h := i64(sizeof[S20]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f4)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f4)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f4 = i32(99)
    h = h * 31 + i64(a[d].f4) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S24 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32 }
noinline fn t24(n: i64, d: i64) -> i64 {
    a := alloc[S24](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f5 = i32(i + d)
    }
    h := i64(sizeof[S24]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f5)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f5)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f5 = i32(99)
    h = h * 31 + i64(a[d].f5) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S36 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32 }
noinline fn t36(n: i64, d: i64) -> i64 {
    a := alloc[S36](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f8 = i32(i + d)
    }
    h := i64(sizeof[S36]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f8)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f8)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f8 = i32(99)
    h = h * 31 + i64(a[d].f8) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S40 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32 }
noinline fn t40(n: i64, d: i64) -> i64 {
    a := alloc[S40](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f9 = i32(i + d)
    }
    h := i64(sizeof[S40]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f9)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f9)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f9 = i32(99)
    h = h * 31 + i64(a[d].f9) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S48 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32, f10: i32, f11: i32 }
noinline fn t48(n: i64, d: i64) -> i64 {
    a := alloc[S48](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f11 = i32(i + d)
    }
    h := i64(sizeof[S48]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f11)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f11)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f11 = i32(99)
    h = h * 31 + i64(a[d].f11) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S72 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32, f10: i32, f11: i32, f12: i32, f13: i32, f14: i32, f15: i32, f16: i32, f17: i32 }
noinline fn t72(n: i64, d: i64) -> i64 {
    a := alloc[S72](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f17 = i32(i + d)
    }
    h := i64(sizeof[S72]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f17)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f17)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f17 = i32(99)
    h = h * 31 + i64(a[d].f17) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S80 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32, f10: i32, f11: i32, f12: i32, f13: i32, f14: i32, f15: i32, f16: i32, f17: i32, f18: i32, f19: i32 }
noinline fn t80(n: i64, d: i64) -> i64 {
    a := alloc[S80](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f19 = i32(i + d)
    }
    h := i64(sizeof[S80]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f19)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f19)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f19 = i32(99)
    h = h * 31 + i64(a[d].f19) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S96 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32, f10: i32, f11: i32, f12: i32, f13: i32, f14: i32, f15: i32, f16: i32, f17: i32, f18: i32, f19: i32, f20: i32, f21: i32, f22: i32, f23: i32 }
noinline fn t96(n: i64, d: i64) -> i64 {
    a := alloc[S96](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f23 = i32(i + d)
    }
    h := i64(sizeof[S96]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f23)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f23)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f23 = i32(99)
    h = h * 31 + i64(a[d].f23) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
struct S144 { f0: i32, f1: i32, f2: i32, f3: i32, f4: i32, f5: i32, f6: i32, f7: i32, f8: i32, f9: i32, f10: i32, f11: i32, f12: i32, f13: i32, f14: i32, f15: i32, f16: i32, f17: i32, f18: i32, f19: i32, f20: i32, f21: i32, f22: i32, f23: i32, f24: i32, f25: i32, f26: i32, f27: i32, f28: i32, f29: i32, f30: i32, f31: i32, f32: i32, f33: i32, f34: i32, f35: i32 }
noinline fn t144(n: i64, d: i64) -> i64 {
    a := alloc[S144](n)
    for i in 0..n {
        a[i].f0 = i32(i * 3 + 1)
        a[i].f1 = i32(i ^ 5)
        a[i].f35 = i32(i + d)
    }
    h := i64(sizeof[S144]())
    for i in 0..n {
        j := (i * 7 + d) % n
        h = h * 31 + i64(a[j].f0) + i64(a[j].f35)
    }
    for i in 0..n by 3 {
        j := (i * 5) % n
        a[j].f1 += i32(j)
        a[j] = a[(j + 1) % n]
    }
    s := a[d..]
    for i in 2..len(s) {
        h = h * 31 + i64(s[i - 2].f1) - i64(s[i].f0)
    }
    for k in len(s) - 1..=0 by -1 {
        h = h * 31 + i64(s[k].f1) + i64(s[len(s) - 1 - k].f35)
    }
    k8: u8 = 0
    k32: i32 = i32(n) - 1
    while k32 >= 0 {
        h = h * 31 + i64(a[k32].f0) + i64(a[k8].f1)
        k32 -= 2
        k8 += 1
    }
    q := &a[d]
    q.f35 = i32(99)
    h = h * 31 + i64(a[d].f35) + i64(if a[d] == a[d + 1] { 1 } else { 0 })
    return h
}
noinline fn m_i8(xs: []i8) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11)
    print(-12, xs[0] * -12, xs[1] * -12, xs[2] * -12, xs[3] * -12, xs[4] * -12, xs[5] * -12, xs[6] * -12, xs[7] * -12, xs[8] * -12)
    acc: i8 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * -12 + 1 }
    print(acc)
}
noinline fn m_u8(xs: []u8) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11)
    acc: u8 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 11 + 1 }
    print(acc)
}
noinline fn m_i16(xs: []i16) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3, xs[9] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5, xs[9] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6, xs[9] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9, xs[9] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10, xs[9] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12, xs[9] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18, xs[9] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20, xs[9] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24, xs[9] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36, xs[9] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40, xs[9] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48, xs[9] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72, xs[9] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80, xs[9] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96, xs[9] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144, xs[8] * 144, xs[9] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7, xs[9] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11, xs[9] * 11)
    print(-12, xs[0] * -12, xs[1] * -12, xs[2] * -12, xs[3] * -12, xs[4] * -12, xs[5] * -12, xs[6] * -12, xs[7] * -12, xs[8] * -12, xs[9] * -12)
    acc: i16 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * -12 + 1 }
    print(acc)
}
noinline fn m_u16(xs: []u16) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11)
    acc: u16 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 11 + 1 }
    print(acc)
}
noinline fn m_i32(xs: []i32) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3, xs[9] * 3, xs[10] * 3, xs[11] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5, xs[9] * 5, xs[10] * 5, xs[11] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6, xs[9] * 6, xs[10] * 6, xs[11] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9, xs[9] * 9, xs[10] * 9, xs[11] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10, xs[9] * 10, xs[10] * 10, xs[11] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12, xs[9] * 12, xs[10] * 12, xs[11] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18, xs[9] * 18, xs[10] * 18, xs[11] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20, xs[9] * 20, xs[10] * 20, xs[11] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24, xs[9] * 24, xs[10] * 24, xs[11] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36, xs[9] * 36, xs[10] * 36, xs[11] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40, xs[9] * 40, xs[10] * 40, xs[11] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48, xs[9] * 48, xs[10] * 48, xs[11] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72, xs[9] * 72, xs[10] * 72, xs[11] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80, xs[9] * 80, xs[10] * 80, xs[11] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96, xs[9] * 96, xs[10] * 96, xs[11] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144, xs[8] * 144, xs[9] * 144, xs[10] * 144, xs[11] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7, xs[9] * 7, xs[10] * 7, xs[11] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11, xs[9] * 11, xs[10] * 11, xs[11] * 11)
    print(-12, xs[0] * -12, xs[1] * -12, xs[2] * -12, xs[3] * -12, xs[4] * -12, xs[5] * -12, xs[6] * -12, xs[7] * -12, xs[8] * -12, xs[9] * -12, xs[10] * -12, xs[11] * -12)
    print(3145728, xs[0] * 3145728, xs[1] * 3145728, xs[2] * 3145728, xs[3] * 3145728, xs[4] * 3145728, xs[5] * 3145728, xs[6] * 3145728, xs[7] * 3145728, xs[8] * 3145728, xs[9] * 3145728, xs[10] * 3145728, xs[11] * 3145728)
    print(1342177280, xs[0] * 1342177280, xs[1] * 1342177280, xs[2] * 1342177280, xs[3] * 1342177280, xs[4] * 1342177280, xs[5] * 1342177280, xs[6] * 1342177280, xs[7] * 1342177280, xs[8] * 1342177280, xs[9] * 1342177280, xs[10] * 1342177280, xs[11] * 1342177280)
    acc: i32 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 1342177280 + 1 }
    print(acc)
}
noinline fn m_u32(xs: []u32) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144, xs[8] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11)
    print(3145728, xs[0] * 3145728, xs[1] * 3145728, xs[2] * 3145728, xs[3] * 3145728, xs[4] * 3145728, xs[5] * 3145728, xs[6] * 3145728, xs[7] * 3145728, xs[8] * 3145728)
    print(1342177280, xs[0] * 1342177280, xs[1] * 1342177280, xs[2] * 1342177280, xs[3] * 1342177280, xs[4] * 1342177280, xs[5] * 1342177280, xs[6] * 1342177280, xs[7] * 1342177280, xs[8] * 1342177280)
    acc: u32 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 1342177280 + 1 }
    print(acc)
}
noinline fn m_i64(xs: []i64) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3, xs[9] * 3, xs[10] * 3, xs[11] * 3, xs[12] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5, xs[9] * 5, xs[10] * 5, xs[11] * 5, xs[12] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6, xs[9] * 6, xs[10] * 6, xs[11] * 6, xs[12] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9, xs[9] * 9, xs[10] * 9, xs[11] * 9, xs[12] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10, xs[9] * 10, xs[10] * 10, xs[11] * 10, xs[12] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12, xs[9] * 12, xs[10] * 12, xs[11] * 12, xs[12] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18, xs[9] * 18, xs[10] * 18, xs[11] * 18, xs[12] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20, xs[9] * 20, xs[10] * 20, xs[11] * 20, xs[12] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24, xs[9] * 24, xs[10] * 24, xs[11] * 24, xs[12] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36, xs[9] * 36, xs[10] * 36, xs[11] * 36, xs[12] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40, xs[9] * 40, xs[10] * 40, xs[11] * 40, xs[12] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48, xs[9] * 48, xs[10] * 48, xs[11] * 48, xs[12] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72, xs[9] * 72, xs[10] * 72, xs[11] * 72, xs[12] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80, xs[9] * 80, xs[10] * 80, xs[11] * 80, xs[12] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96, xs[9] * 96, xs[10] * 96, xs[11] * 96, xs[12] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144, xs[8] * 144, xs[9] * 144, xs[10] * 144, xs[11] * 144, xs[12] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7, xs[9] * 7, xs[10] * 7, xs[11] * 7, xs[12] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11, xs[9] * 11, xs[10] * 11, xs[11] * 11, xs[12] * 11)
    print(-12, xs[0] * -12, xs[1] * -12, xs[2] * -12, xs[3] * -12, xs[4] * -12, xs[5] * -12, xs[6] * -12, xs[7] * -12, xs[8] * -12, xs[9] * -12, xs[10] * -12, xs[11] * -12, xs[12] * -12)
    print(3145728, xs[0] * 3145728, xs[1] * 3145728, xs[2] * 3145728, xs[3] * 3145728, xs[4] * 3145728, xs[5] * 3145728, xs[6] * 3145728, xs[7] * 3145728, xs[8] * 3145728, xs[9] * 3145728, xs[10] * 3145728, xs[11] * 3145728, xs[12] * 3145728)
    print(1342177280, xs[0] * 1342177280, xs[1] * 1342177280, xs[2] * 1342177280, xs[3] * 1342177280, xs[4] * 1342177280, xs[5] * 1342177280, xs[6] * 1342177280, xs[7] * 1342177280, xs[8] * 1342177280, xs[9] * 1342177280, xs[10] * 1342177280, xs[11] * 1342177280, xs[12] * 1342177280)
    print(9895604649984, xs[0] * 9895604649984, xs[1] * 9895604649984, xs[2] * 9895604649984, xs[3] * 9895604649984, xs[4] * 9895604649984, xs[5] * 9895604649984, xs[6] * 9895604649984, xs[7] * 9895604649984, xs[8] * 9895604649984, xs[9] * 9895604649984, xs[10] * 9895604649984, xs[11] * 9895604649984, xs[12] * 9895604649984)
    print(6917529027641081856, xs[0] * 6917529027641081856, xs[1] * 6917529027641081856, xs[2] * 6917529027641081856, xs[3] * 6917529027641081856, xs[4] * 6917529027641081856, xs[5] * 6917529027641081856, xs[6] * 6917529027641081856, xs[7] * 6917529027641081856, xs[8] * 6917529027641081856, xs[9] * 6917529027641081856, xs[10] * 6917529027641081856, xs[11] * 6917529027641081856, xs[12] * 6917529027641081856)
    acc: i64 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 6917529027641081856 + 1 }
    print(acc)
}
noinline fn m_u64(xs: []u64) {
    print(3, xs[0] * 3, xs[1] * 3, xs[2] * 3, xs[3] * 3, xs[4] * 3, xs[5] * 3, xs[6] * 3, xs[7] * 3, xs[8] * 3, xs[9] * 3)
    print(5, xs[0] * 5, xs[1] * 5, xs[2] * 5, xs[3] * 5, xs[4] * 5, xs[5] * 5, xs[6] * 5, xs[7] * 5, xs[8] * 5, xs[9] * 5)
    print(6, xs[0] * 6, xs[1] * 6, xs[2] * 6, xs[3] * 6, xs[4] * 6, xs[5] * 6, xs[6] * 6, xs[7] * 6, xs[8] * 6, xs[9] * 6)
    print(9, xs[0] * 9, xs[1] * 9, xs[2] * 9, xs[3] * 9, xs[4] * 9, xs[5] * 9, xs[6] * 9, xs[7] * 9, xs[8] * 9, xs[9] * 9)
    print(10, xs[0] * 10, xs[1] * 10, xs[2] * 10, xs[3] * 10, xs[4] * 10, xs[5] * 10, xs[6] * 10, xs[7] * 10, xs[8] * 10, xs[9] * 10)
    print(12, xs[0] * 12, xs[1] * 12, xs[2] * 12, xs[3] * 12, xs[4] * 12, xs[5] * 12, xs[6] * 12, xs[7] * 12, xs[8] * 12, xs[9] * 12)
    print(18, xs[0] * 18, xs[1] * 18, xs[2] * 18, xs[3] * 18, xs[4] * 18, xs[5] * 18, xs[6] * 18, xs[7] * 18, xs[8] * 18, xs[9] * 18)
    print(20, xs[0] * 20, xs[1] * 20, xs[2] * 20, xs[3] * 20, xs[4] * 20, xs[5] * 20, xs[6] * 20, xs[7] * 20, xs[8] * 20, xs[9] * 20)
    print(24, xs[0] * 24, xs[1] * 24, xs[2] * 24, xs[3] * 24, xs[4] * 24, xs[5] * 24, xs[6] * 24, xs[7] * 24, xs[8] * 24, xs[9] * 24)
    print(36, xs[0] * 36, xs[1] * 36, xs[2] * 36, xs[3] * 36, xs[4] * 36, xs[5] * 36, xs[6] * 36, xs[7] * 36, xs[8] * 36, xs[9] * 36)
    print(40, xs[0] * 40, xs[1] * 40, xs[2] * 40, xs[3] * 40, xs[4] * 40, xs[5] * 40, xs[6] * 40, xs[7] * 40, xs[8] * 40, xs[9] * 40)
    print(48, xs[0] * 48, xs[1] * 48, xs[2] * 48, xs[3] * 48, xs[4] * 48, xs[5] * 48, xs[6] * 48, xs[7] * 48, xs[8] * 48, xs[9] * 48)
    print(72, xs[0] * 72, xs[1] * 72, xs[2] * 72, xs[3] * 72, xs[4] * 72, xs[5] * 72, xs[6] * 72, xs[7] * 72, xs[8] * 72, xs[9] * 72)
    print(80, xs[0] * 80, xs[1] * 80, xs[2] * 80, xs[3] * 80, xs[4] * 80, xs[5] * 80, xs[6] * 80, xs[7] * 80, xs[8] * 80, xs[9] * 80)
    print(96, xs[0] * 96, xs[1] * 96, xs[2] * 96, xs[3] * 96, xs[4] * 96, xs[5] * 96, xs[6] * 96, xs[7] * 96, xs[8] * 96, xs[9] * 96)
    print(144, xs[0] * 144, xs[1] * 144, xs[2] * 144, xs[3] * 144, xs[4] * 144, xs[5] * 144, xs[6] * 144, xs[7] * 144, xs[8] * 144, xs[9] * 144)
    print(7, xs[0] * 7, xs[1] * 7, xs[2] * 7, xs[3] * 7, xs[4] * 7, xs[5] * 7, xs[6] * 7, xs[7] * 7, xs[8] * 7, xs[9] * 7)
    print(11, xs[0] * 11, xs[1] * 11, xs[2] * 11, xs[3] * 11, xs[4] * 11, xs[5] * 11, xs[6] * 11, xs[7] * 11, xs[8] * 11, xs[9] * 11)
    print(3145728, xs[0] * 3145728, xs[1] * 3145728, xs[2] * 3145728, xs[3] * 3145728, xs[4] * 3145728, xs[5] * 3145728, xs[6] * 3145728, xs[7] * 3145728, xs[8] * 3145728, xs[9] * 3145728)
    print(1342177280, xs[0] * 1342177280, xs[1] * 1342177280, xs[2] * 1342177280, xs[3] * 1342177280, xs[4] * 1342177280, xs[5] * 1342177280, xs[6] * 1342177280, xs[7] * 1342177280, xs[8] * 1342177280, xs[9] * 1342177280)
    print(9895604649984, xs[0] * 9895604649984, xs[1] * 9895604649984, xs[2] * 9895604649984, xs[3] * 9895604649984, xs[4] * 9895604649984, xs[5] * 9895604649984, xs[6] * 9895604649984, xs[7] * 9895604649984, xs[8] * 9895604649984, xs[9] * 9895604649984)
    print(6917529027641081856, xs[0] * 6917529027641081856, xs[1] * 6917529027641081856, xs[2] * 6917529027641081856, xs[3] * 6917529027641081856, xs[4] * 6917529027641081856, xs[5] * 6917529027641081856, xs[6] * 6917529027641081856, xs[7] * 6917529027641081856, xs[8] * 6917529027641081856, xs[9] * 6917529027641081856)
    acc: u64 = 1
    for x in xs { acc = acc * 12 + x; acc = acc * 5 - x; acc = acc * 6917529027641081856 + 1 }
    print(acc)
}
fn main() {
    n := 23 + len(args()) // not a constant
    d := len(args())
    print(3, t3(n, d))
    print(5, t5(n, d))
    print(6, t6(n, d))
    print(7, t7(n, d))
    print(9, t9(n, d))
    print(10, t10(n, d))
    print(12, t12(n, d))
    print(16, t16(n, d))
    print(18, t18(n, d))
    print(20, t20(n, d))
    print(24, t24(n, d))
    print(36, t36(n, d))
    print(40, t40(n, d))
    print(48, t48(n, d))
    print(72, t72(n, d))
    print(80, t80(n, d))
    print(96, t96(n, d))
    print(144, t144(n, d))
    m_i8([]i8{0, 1, 2, -1, -128, 127, -127, 126, 37})
    m_u8([]u8{0, 1, 2, 0, 255, 1, 254, 37})
    m_i16([]i16{0, 1, 2, -1, -32768, 32767, -32767, 32766, 37, -1000})
    m_u16([]u16{0, 1, 2, 0, 65535, 1, 65534, 37})
    m_i32([]i32{0, 1, 2, -1, -2147483648, 2147483647, -2147483647, 2147483646, 37, -1000, 100000, -7777777})
    m_u32([]u32{0, 1, 2, 0, 4294967295, 1, 4294967294, 37, 100000})
    m_i64([]i64{0, 1, 2, -1, -9223372036854775807 - 1, 9223372036854775807, -9223372036854775807, 9223372036854775806, 37, -1000, 100000, -7777777, 123456789012})
    m_u64([]u64{0, 1, 2, 0, 18446744073709551615, 1, 18446744073709551614, 37, 100000, 123456789012})
}
