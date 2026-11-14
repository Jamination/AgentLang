// library functions that fail for their caller (pop, unwrap, insert): the first frame is the
// call in the program
fn last_score(scores: *Vec[i64]) -> i64 {
    return scores.pop()
}

fn main() {
    scores := vec[i64]()
    scores.push(5)
    print(last_score(&scores))
    print(last_score(&scores))
}
