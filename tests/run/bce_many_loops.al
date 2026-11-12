// many loops with bounds checks in one function: bce hoists in all independent loops per
// round (siblings, nests, loops after the 200th), and the results must not change
noinline fn h(x: i64) -> i64 { return x }
fn main() {
    v := vec_fill(h(64), 0)
    for i in 0..v.len { v[i] = i * 3 + 1 }
    a: [16]i64
    s := 0
    for i in 0..h(0) { s += v[i + 0] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 5] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 1] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 14] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 6] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 19] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 2] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 24] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 7] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 29] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 3] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 34] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 8] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 39] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 4] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 44] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 0] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 49] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 5] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 1] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 6] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 14] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 2] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 19] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 7] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 24] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 3] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 29] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 8] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 34] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 4] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 39] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 0] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 44] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 5] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 49] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 1] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 6] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 2] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 14] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 7] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 19] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 3] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 24] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 8] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 29] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 4] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 34] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 0] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 39] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 5] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 44] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 1] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 49] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 6] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 2] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 7] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 14] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 3] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 19] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 8] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 24] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 4] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 29] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 0] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 34] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 5] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 39] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 1] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 44] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 6] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 49] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 2] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 7] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 3] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 14] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 8] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 19] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(20) { s += v[i + 4] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 24] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(25) { s += v[i + 0] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(3) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 29] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(30) { s += v[i + 5] }
    for i in h(21)..=h(26) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(1) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 34] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(35) { s += v[i + 1] }
    for i in h(26)..=h(31) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(6) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 39] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(0) { s += v[i + 6] }
    for i in h(1)..=h(6) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(4) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(6)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 44] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(5) { s += v[i + 2] }
    for i in h(6)..=h(11) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(2) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(11)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 49] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(10) { s += v[i + 7] }
    for i in h(11)..=h(16) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(0) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(16)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 4] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    for i in 0..h(15) { s += v[i + 3] }
    for i in h(16)..=h(21) { s = s * 3 + v[i] - a[i & 15] }
    for i in 0..h(5) { for j in 0..h(3) { s += v[i * 4 + j] + a[j] } }
    for i in h(21)..=h(1) by -1 { a[i & 15] = s; s += v[i * 2] }
    if s & 1 == 0 { for i in 0..h(5) { s += v[i + 9] } } else { for i in 0..h(3) { s -= v[60 - i] } }
    print(s)
}
