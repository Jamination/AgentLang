#[derive(Clone, Copy)]
struct Entry {
    key: u64,
    val: u64,
}

struct Map {
    e: Vec<Entry>,
    cap: u64,
    len: u64,
}

#[inline]
fn hash(k: u64) -> u64 {
    k.wrapping_mul(0x9E3779B97F4A7C15) >> 32
}

impl Map {
    fn new(cap: u64) -> Map {
        Map { e: vec![Entry { key: 0, val: 0 }; cap as usize], cap, len: 0 }
    }

    fn grow(&mut self) {
        let oldcap = self.cap;
        let old = std::mem::replace(self, Map::new(oldcap * 2)).e;
        for i in 0..oldcap as usize {
            if old[i].key != 0 {
                *self.slot(old[i].key) = old[i].val;
            }
        }
    }

    // find the value slot of key, inserting it if missing
    fn slot(&mut self, key: u64) -> &mut u64 {
        if (self.len + 1) * 4 > self.cap * 3 {
            self.grow();
        }
        let mask = self.cap - 1;
        let mut i = hash(key) & mask;
        loop {
            let e = &mut self.e[i as usize];
            if e.key == key {
                break;
            }
            if e.key == 0 {
                e.key = key;
                self.len += 1;
                break;
            }
            i = (i + 1) & mask;
        }
        &mut self.e[i as usize].val
    }

    fn get(&self, key: u64) -> Option<u64> {
        let mask = self.cap - 1;
        let mut i = hash(key) & mask;
        loop {
            let e = &self.e[i as usize];
            if e.key == key {
                return Some(e.val);
            }
            if e.key == 0 {
                return None;
            }
            i = (i + 1) & mask;
        }
    }
}

fn main() {
    let mut m = Map::new(16);
    let mut seed: u64 = 42;
    for i in 0..5000000u64 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let key = (seed >> 33) % 3000000 + 1;
        let v = m.slot(key);
        *v = v.wrapping_add(i);
    }
    let (mut hits, mut sum) = (0u64, 0u64);
    for _ in 0..10000000u64 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let key = (seed >> 33) % 6000000 + 1;
        if let Some(v) = m.get(key) {
            hits += 1;
            sum = sum.wrapping_add(v);
        }
    }
    println!("{} {} {}", m.len, hits, sum);
}
