// a misspelt name in a condition is an error, never false
const DEMO = true
when DEMOO { }
when TARGET_OS == Windos { }
when DEMO { const INNER = 1 }
when INNER == 1 { }
fn main() {}
