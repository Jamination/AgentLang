// comments stay on their lines; a comment line is indented like code in its place
   // at the top level: column 1


const A = 1         // aligned trailing comments
const BB = 22       // keep their column
const CCCCCCCCCCCCC = 333 // unless the code reaches it
priv  const   D=4   // moved with the code that got shorter

struct S {
    x: i64          // the first field
    y: i64          // the second field, whose comment
                    // goes on below it
// a comment line in the struct
}

fn f(x: i64) -> i64 {
// at the start of a block
    if x > 0 {
            // inside the if
        return x    //returns x (the text of a comment is never changed)
    }
        // before the end of the block
    x * 2
    // after the last statement
}

fn main() {
    print(f(1), f(-1),   // in an argument list
        A + BB + CCCCCCCCCCCCC + D)
    xs := []i64{
        1,  // one
        2,  // two
    // three is missing
    }
    print(xs[..], S{})
}
// at the end of the file



