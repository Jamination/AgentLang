// functions inlined by the optimiser still show as frames of their own (default build), the
// same as in the -O0 build where nothing is inlined
inline fn cell(grid: []i64, w: i64, x: i64, y: i64) -> i64 {
    return grid[y * w + x]
}

inline fn neighbours(grid: []i64, w: i64, x: i64, y: i64) -> i64 {
    return cell(grid, w, x - 1, y) + cell(grid, w, x + 1, y)
}

fn main() {
    grid := alloc[i64](9)
    grid[4] = 1
    print(neighbours(grid, 3, 1, 1))
    print(neighbours(grid, 3, 2, 2))
}
