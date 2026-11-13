// f32 literals near the top of the range round once, from the text: everything below the
// midpoint between the largest f32 and 2^128 is the largest f32, the midpoint and above is inf
fn main() {
    print(3.4028235e38)
    print(3.4028235677973366e38)
    print(3.40282356779733661637539395458142568447e38)
    print(3.4028235677973366163753939545814256845e38)
    print(3.4028236e38)
    print(-3.4028235677973366e38)
    x: f64 = 3.4028235677973366e38
    print(x)
}
