// word frequencies of standard input: `alc run examples/wordfreq.al < file`
Entry :: struct { word: str, count: i64 }

more :: (a: Entry, b: Entry) -> bool {
    a.count > b.count || (a.count == b.count && cmp(a.word, b.word) < 0)
}

main :: () {
    text := read_all(0)
    counts := map[str, i64]()
    start := -1
    for i in 0..=len(text) {
        letter := i < len(text) && ((text[i] | 32) >= 'a' && (text[i] | 32) <= 'z')
        if letter && start < 0 {
            start = i
        }
        if !letter && start >= 0 {
            w := text[start..i]
            counts.set(w, counts.get_or(w, 0) + 1)
            start = -1
        }
    }
    entries := vec[Entry]()
    for k in counts.keys() {
        entries.push(Entry{k, counts.get_or(k, 0)})
    }
    sort_by(entries.items(), more)
    for i, e in entries.items() {
        if i == 10 {
            break
        }
        print(e.count, e.word)
    }
}
