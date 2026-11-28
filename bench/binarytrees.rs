use std::process;

// bump arena: allocate by appending a node, release everything after a mark at once
const NIL: usize = usize::MAX;

#[derive(Clone, Copy)]
struct TreeNode {
    left: usize,
    right: usize,
}

struct Arena {
    nodes: Vec<TreeNode>,
}

impl Arena {
    #[inline]
    fn alloc(&mut self, left: usize, right: usize) -> usize {
        let p = self.nodes.len();
        if p == self.nodes.capacity() {
            eprintln!("out of arena memory");
            process::exit(1);
        }
        self.nodes.push(TreeNode { left, right });
        p
    }
}

fn item_check(arena: &Arena, tree: usize) -> i64 {
    let node = arena.nodes[tree];
    if node.left == NIL {
        1
    } else {
        1 + item_check(arena, node.left) + item_check(arena, node.right)
    }
}

fn bottom_up_tree(arena: &mut Arena, depth: u32) -> usize {
    if depth > 0 {
        let left = bottom_up_tree(arena, depth - 1);
        let right = bottom_up_tree(arena, depth - 1);
        arena.alloc(left, right)
    } else {
        arena.alloc(NIL, NIL)
    }
}

fn main() {
    let n: u32 = 20;
    let min_depth: u32 = 4;
    let cap: usize = 1 << 30;
    let mut arena = Arena { nodes: Vec::with_capacity(cap / std::mem::size_of::<TreeNode>()) };
    let max_depth = if min_depth + 2 > n { min_depth + 2 } else { n };
    let stretch_depth = max_depth + 1;
    let mark = arena.nodes.len();
    let stretch_tree = bottom_up_tree(&mut arena, stretch_depth);
    println!("stretch tree of depth {}\t check: {}", stretch_depth, item_check(&arena, stretch_tree));
    arena.nodes.truncate(mark);
    let long_lived_tree = bottom_up_tree(&mut arena, max_depth);
    let mut depth = min_depth;
    while depth <= max_depth {
        let iterations: i64 = 1 << (max_depth - depth + min_depth);
        let mut check: i64 = 0;
        for _ in 1..=iterations {
            let m = arena.nodes.len();
            let temp_tree = bottom_up_tree(&mut arena, depth);
            check += item_check(&arena, temp_tree);
            arena.nodes.truncate(m);
        }
        println!("{}\t trees of depth {}\t check: {}", iterations, depth, check);
        depth += 2;
    }
    println!("long lived tree of depth {}\t check: {}", max_depth, item_check(&arena, long_lived_tree));
}
