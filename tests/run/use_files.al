use "lib/geom.al"
use "lib/more.al"

fn main() {
    c := Circle{r: 0.5}
    print(circumference(c), twice(TAU), TAU / 2.0)
}
