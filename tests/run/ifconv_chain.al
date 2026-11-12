// a long chain of small ifs that if-conversion turns into selects (one-armed and two-armed,
// joins that start the next diamond): all are converted in one round and must keep their values
noinline fn h(x: i64) -> i64 { return x }
fn main() {
    x := h(5)
    y := h(-3)
    s := 0
    if x > 0 { s += 0 }
    if (s ^ x) & 2 != 0 { y = s + 1 } else { y = x - 1 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 4 }
    if (s ^ x) & 32 != 0 { y = s + 5 } else { y = x - 5 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 8 }
    if (s ^ x) & 8 != 0 { y = s + 9 } else { y = x - 9 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 12 }
    if (s ^ x) & 2 != 0 { y = s + 13 } else { y = x - 13 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 16 }
    if (s ^ x) & 32 != 0 { y = s + 17 } else { y = x - 17 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 20 }
    if (s ^ x) & 8 != 0 { y = s + 21 } else { y = x - 21 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 24 }
    if (s ^ x) & 2 != 0 { y = s + 25 } else { y = x - 25 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 28 }
    if (s ^ x) & 32 != 0 { y = s + 29 } else { y = x - 29 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 32 }
    if (s ^ x) & 8 != 0 { y = s + 33 } else { y = x - 33 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 36 }
    if (s ^ x) & 2 != 0 { y = s + 37 } else { y = x - 37 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 40 }
    if (s ^ x) & 32 != 0 { y = s + 41 } else { y = x - 41 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 44 }
    if (s ^ x) & 8 != 0 { y = s + 45 } else { y = x - 45 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 48 }
    if (s ^ x) & 2 != 0 { y = s + 49 } else { y = x - 49 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 52 }
    if (s ^ x) & 32 != 0 { y = s + 53 } else { y = x - 53 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 56 }
    if (s ^ x) & 8 != 0 { y = s + 57 } else { y = x - 57 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 60 }
    if (s ^ x) & 2 != 0 { y = s + 61 } else { y = x - 61 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 64 }
    if (s ^ x) & 32 != 0 { y = s + 65 } else { y = x - 65 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 68 }
    if (s ^ x) & 8 != 0 { y = s + 69 } else { y = x - 69 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 72 }
    if (s ^ x) & 2 != 0 { y = s + 73 } else { y = x - 73 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 76 }
    if (s ^ x) & 32 != 0 { y = s + 77 } else { y = x - 77 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 80 }
    if (s ^ x) & 8 != 0 { y = s + 81 } else { y = x - 81 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 84 }
    if (s ^ x) & 2 != 0 { y = s + 85 } else { y = x - 85 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 88 }
    if (s ^ x) & 32 != 0 { y = s + 89 } else { y = x - 89 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 92 }
    if (s ^ x) & 8 != 0 { y = s + 93 } else { y = x - 93 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 96 }
    if (s ^ x) & 2 != 0 { y = s + 97 } else { y = x - 97 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 100 }
    if (s ^ x) & 32 != 0 { y = s + 101 } else { y = x - 101 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 104 }
    if (s ^ x) & 8 != 0 { y = s + 105 } else { y = x - 105 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 108 }
    if (s ^ x) & 2 != 0 { y = s + 109 } else { y = x - 109 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 112 }
    if (s ^ x) & 32 != 0 { y = s + 113 } else { y = x - 113 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 116 }
    if (s ^ x) & 8 != 0 { y = s + 117 } else { y = x - 117 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 120 }
    if (s ^ x) & 2 != 0 { y = s + 121 } else { y = x - 121 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 124 }
    if (s ^ x) & 32 != 0 { y = s + 125 } else { y = x - 125 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 128 }
    if (s ^ x) & 8 != 0 { y = s + 129 } else { y = x - 129 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 132 }
    if (s ^ x) & 2 != 0 { y = s + 133 } else { y = x - 133 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 136 }
    if (s ^ x) & 32 != 0 { y = s + 137 } else { y = x - 137 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 140 }
    if (s ^ x) & 8 != 0 { y = s + 141 } else { y = x - 141 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 144 }
    if (s ^ x) & 2 != 0 { y = s + 145 } else { y = x - 145 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 148 }
    if (s ^ x) & 32 != 0 { y = s + 149 } else { y = x - 149 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 152 }
    if (s ^ x) & 8 != 0 { y = s + 153 } else { y = x - 153 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 156 }
    if (s ^ x) & 2 != 0 { y = s + 157 } else { y = x - 157 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 160 }
    if (s ^ x) & 32 != 0 { y = s + 161 } else { y = x - 161 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 164 }
    if (s ^ x) & 8 != 0 { y = s + 165 } else { y = x - 165 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 168 }
    if (s ^ x) & 2 != 0 { y = s + 169 } else { y = x - 169 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 172 }
    if (s ^ x) & 32 != 0 { y = s + 173 } else { y = x - 173 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 176 }
    if (s ^ x) & 8 != 0 { y = s + 177 } else { y = x - 177 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 180 }
    if (s ^ x) & 2 != 0 { y = s + 181 } else { y = x - 181 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 184 }
    if (s ^ x) & 32 != 0 { y = s + 185 } else { y = x - 185 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 188 }
    if (s ^ x) & 8 != 0 { y = s + 189 } else { y = x - 189 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 192 }
    if (s ^ x) & 2 != 0 { y = s + 193 } else { y = x - 193 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 196 }
    if (s ^ x) & 32 != 0 { y = s + 197 } else { y = x - 197 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 200 }
    if (s ^ x) & 8 != 0 { y = s + 201 } else { y = x - 201 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 204 }
    if (s ^ x) & 2 != 0 { y = s + 205 } else { y = x - 205 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 208 }
    if (s ^ x) & 32 != 0 { y = s + 209 } else { y = x - 209 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 212 }
    if (s ^ x) & 8 != 0 { y = s + 213 } else { y = x - 213 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 216 }
    if (s ^ x) & 2 != 0 { y = s + 217 } else { y = x - 217 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 220 }
    if (s ^ x) & 32 != 0 { y = s + 221 } else { y = x - 221 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 224 }
    if (s ^ x) & 8 != 0 { y = s + 225 } else { y = x - 225 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 228 }
    if (s ^ x) & 2 != 0 { y = s + 229 } else { y = x - 229 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 232 }
    if (s ^ x) & 32 != 0 { y = s + 233 } else { y = x - 233 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 236 }
    if (s ^ x) & 8 != 0 { y = s + 237 } else { y = x - 237 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 240 }
    if (s ^ x) & 2 != 0 { y = s + 241 } else { y = x - 241 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 244 }
    if (s ^ x) & 32 != 0 { y = s + 245 } else { y = x - 245 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 248 }
    if (s ^ x) & 8 != 0 { y = s + 249 } else { y = x - 249 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 252 }
    if (s ^ x) & 2 != 0 { y = s + 253 } else { y = x - 253 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 256 }
    if (s ^ x) & 32 != 0 { y = s + 257 } else { y = x - 257 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 260 }
    if (s ^ x) & 8 != 0 { y = s + 261 } else { y = x - 261 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 264 }
    if (s ^ x) & 2 != 0 { y = s + 265 } else { y = x - 265 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 268 }
    if (s ^ x) & 32 != 0 { y = s + 269 } else { y = x - 269 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 272 }
    if (s ^ x) & 8 != 0 { y = s + 273 } else { y = x - 273 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 276 }
    if (s ^ x) & 2 != 0 { y = s + 277 } else { y = x - 277 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 280 }
    if (s ^ x) & 32 != 0 { y = s + 281 } else { y = x - 281 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 284 }
    if (s ^ x) & 8 != 0 { y = s + 285 } else { y = x - 285 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 288 }
    if (s ^ x) & 2 != 0 { y = s + 289 } else { y = x - 289 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 292 }
    if (s ^ x) & 32 != 0 { y = s + 293 } else { y = x - 293 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 296 }
    if (s ^ x) & 8 != 0 { y = s + 297 } else { y = x - 297 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 300 }
    if (s ^ x) & 2 != 0 { y = s + 301 } else { y = x - 301 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 304 }
    if (s ^ x) & 32 != 0 { y = s + 305 } else { y = x - 305 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 308 }
    if (s ^ x) & 8 != 0 { y = s + 309 } else { y = x - 309 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 312 }
    if (s ^ x) & 2 != 0 { y = s + 313 } else { y = x - 313 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 316 }
    if (s ^ x) & 32 != 0 { y = s + 317 } else { y = x - 317 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 320 }
    if (s ^ x) & 8 != 0 { y = s + 321 } else { y = x - 321 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 324 }
    if (s ^ x) & 2 != 0 { y = s + 325 } else { y = x - 325 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 328 }
    if (s ^ x) & 32 != 0 { y = s + 329 } else { y = x - 329 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 332 }
    if (s ^ x) & 8 != 0 { y = s + 333 } else { y = x - 333 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 336 }
    if (s ^ x) & 2 != 0 { y = s + 337 } else { y = x - 337 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 340 }
    if (s ^ x) & 32 != 0 { y = s + 341 } else { y = x - 341 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 344 }
    if (s ^ x) & 8 != 0 { y = s + 345 } else { y = x - 345 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 348 }
    if (s ^ x) & 2 != 0 { y = s + 349 } else { y = x - 349 }
    s = if y < s { s - y } else { s + 12 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 352 }
    if (s ^ x) & 32 != 0 { y = s + 353 } else { y = x - 353 }
    s = if y < s { s - y } else { s + 3 }
    if s & 1 == 0 { x = x + 1 }
    if x > 4 { s += 356 }
    if (s ^ x) & 8 != 0 { y = s + 357 } else { y = x - 357 }
    s = if y < s { s - y } else { s + 7 }
    if s & 1 == 0 { x = x + 1 }
    if x > 8 { s += 360 }
    if (s ^ x) & 2 != 0 { y = s + 361 } else { y = x - 361 }
    s = if y < s { s - y } else { s + 11 }
    if s & 1 == 0 { x = x + 1 }
    if x > 1 { s += 364 }
    if (s ^ x) & 32 != 0 { y = s + 365 } else { y = x - 365 }
    s = if y < s { s - y } else { s + 2 }
    if s & 1 == 0 { x = x + 1 }
    if x > 5 { s += 368 }
    if (s ^ x) & 8 != 0 { y = s + 369 } else { y = x - 369 }
    s = if y < s { s - y } else { s + 6 }
    if s & 1 == 0 { x = x + 1 }
    if x > 9 { s += 372 }
    if (s ^ x) & 2 != 0 { y = s + 373 } else { y = x - 373 }
    s = if y < s { s - y } else { s + 10 }
    if s & 1 == 0 { x = x + 1 }
    if x > 2 { s += 376 }
    if (s ^ x) & 32 != 0 { y = s + 377 } else { y = x - 377 }
    s = if y < s { s - y } else { s + 1 }
    if s & 1 == 0 { x = x + 1 }
    if x > 6 { s += 380 }
    if (s ^ x) & 8 != 0 { y = s + 381 } else { y = x - 381 }
    s = if y < s { s - y } else { s + 5 }
    if s & 1 == 0 { x = x + 1 }
    if x > 10 { s += 384 }
    if (s ^ x) & 2 != 0 { y = s + 385 } else { y = x - 385 }
    s = if y < s { s - y } else { s + 9 }
    if s & 1 == 0 { x = x + 1 }
    if x > 3 { s += 388 }
    if (s ^ x) & 32 != 0 { y = s + 389 } else { y = x - 389 }
    s = if y < s { s - y } else { s + 0 }
    if s & 1 == 0 { x = x + 1 }
    if x > 7 { s += 392 }
    if (s ^ x) & 8 != 0 { y = s + 393 } else { y = x - 393 }
    s = if y < s { s - y } else { s + 4 }
    if s & 1 == 0 { x = x + 1 }
    if x > 0 { s += 396 }
    if (s ^ x) & 2 != 0 { y = s + 397 } else { y = x - 397 }
    s = if y < s { s - y } else { s + 8 }
    if s & 1 == 0 { x = x + 1 }
    print(s, x, y)
}
