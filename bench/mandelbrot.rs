use std::io::{self, BufWriter, Write};

fn main() -> io::Result<()> {
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut bit_num = 0;
    let mut byte_acc: u8 = 0;
    let iter = 50;
    let limit = 2.0f64;
    let w: i32 = 3000;
    let h: i32 = 3000;
    writeln!(out, "P4\n{} {}", w, h)?;
    let mut y = 0.0f64;
    while y < h as f64 {
        let mut x = 0.0f64;
        while x < w as f64 {
            let (mut zr, mut zi, mut tr, mut ti) = (0.0f64, 0.0f64, 0.0f64, 0.0f64);
            let cr = 2.0 * x / w as f64 - 1.5;
            let ci = 2.0 * y / h as f64 - 1.0;
            let mut i = 0;
            while i < iter && tr + ti <= limit * limit {
                zi = 2.0 * zr * zi + ci;
                zr = tr - ti + cr;
                tr = zr * zr;
                ti = zi * zi;
                i += 1;
            }
            byte_acc <<= 1;
            if tr + ti <= limit * limit {
                byte_acc |= 0x01;
            }
            bit_num += 1;
            if bit_num == 8 {
                out.write_all(&[byte_acc])?;
                byte_acc = 0;
                bit_num = 0;
            } else if x == (w - 1) as f64 {
                byte_acc = ((byte_acc as u32) << (8 - w % 8)) as u8;
                out.write_all(&[byte_acc])?;
                byte_acc = 0;
                bit_num = 0;
            }
            x += 1.0;
        }
        y += 1.0;
    }
    out.flush()
}
