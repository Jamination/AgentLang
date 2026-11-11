main :: () {
    w := 3000
    h := 3000
    bit_num := 0
    byte_acc: u8 = 0
    iter := 50
    limit := 2.0
    put("P4\n", w, " ", h, "\n")
    for yi in 0..h {
        y := f64(yi)
        for xi in 0..w {
            x := f64(xi)
            zr := 0.0
            zi := 0.0
            tr := 0.0
            ti := 0.0
            cr := 2.0 * x / f64(w) - 1.5
            ci := 2.0 * y / f64(h) - 1.0
            i := 0
            while i < iter && tr + ti <= limit * limit {
                zi = 2.0 * zr * zi + ci
                zr = tr - ti + cr
                tr = zr * zr
                ti = zi * zi
                i += 1
            }
            byte_acc = byte_acc << 1
            if tr + ti <= limit * limit {
                byte_acc = byte_acc | 1
            }
            bit_num += 1
            if bit_num == 8 {
                putc(byte_acc)
                byte_acc = 0
                bit_num = 0
            } else if xi == w - 1 {
                byte_acc = byte_acc << u8(8 - w % 8)
                putc(byte_acc)
                byte_acc = 0
                bit_num = 0
            }
        }
    }
}
