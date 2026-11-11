use "lib/geom.al"
use "lib/more.al"

main :: () {
    c := Circle{r: 0.5}
    print(circumference(c), twice(TAU), TAU / 2.0)
}
