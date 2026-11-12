// Mistakes in patterns that used to compile: a misspelled variant inside a pattern (it was
// a binding that matches everything) and arms that can never be reached.
enum Shape { Circle(f64), Rect(f64, f64), Empty }
enum UnOp { Neg, Deref }
enum E { Un(UnOp, i64), Other }
enum Tk { Id(str), P(str), Nl }
const LIMIT = 3

fn area(o: Opt[Shape]) -> f64 {
    match o {
        Some(Emty) => 1.0
        Some(other) => 2.0
        None => 3.0
    }
}

fn un(e: E, p: *E, t: (*UnOp, i64)) -> i64 {
    a := match p {
        Un(Dref, x) => 1
        _ => 0
    }
    b := match t {
        (Ngg, LIMIT) => 1
        (op, Limit) => 2
    }
    c := match e {
        Un(Deref, x) => 1
        Un(_, x) => 0
        Un(Neg, 1) => 5
        Other => 2
        Other if a == 2 => 4
        _ => 3
        Un(Neg, _) => 7
    }
    a + b + c
}

fn dup(t: Tk, n: i64, s: str, b: bool, o: Opt[(i64, bool)]) -> i64 {
    r := match t {
        P("+") => 1
        P("+") => 2
        P("-") if n > 0 => 3
        P("-") => 4
        Nl, Tk.Nl => 5
        Id(a) => 6
        Id(_) => 7
    }
    match n {
        1 => {}
        LIMIT => {}
        3 => {}
        2 - 1 => {}
        n => {}
        n => {}
    }
    match s {
        "a" => {}
        "b", "a" => {}
    }
    match b {
        true => {}
        false => {}
        true => {}
    }
    match o {
        Some((1, _)) => {}
        Some((1, false)) => {}
        None => {}
        Some(_) => {}
        Some((2, _)) => {}
    }
    r
}

fn main() {}
