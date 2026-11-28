#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <new>

// bump arena: allocate by advancing a pointer, release everything after a mark at once
class Arena {
public:
    using Mark = char *;

    void reserve(std::size_t cap) {
        storage_ = std::make_unique_for_overwrite<char[]>(cap);
        cur_ = storage_.get();
        end_ = cur_ + cap;
    }

    void *alloc(std::size_t n) {
        char *p = cur_;
        if (p + n > end_) {
            std::fprintf(stderr, "out of arena memory\n");
            std::exit(1);
        }
        cur_ = p + n;
        return p;
    }

    Mark mark() const { return cur_; }
    void release(Mark m) { cur_ = m; }

private:
    std::unique_ptr<char[]> storage_;
    char *cur_ = nullptr;
    char *end_ = nullptr;
};

static Arena arena;

struct TreeNode {
    TreeNode *left, *right;

    long item_check() const {
        if (left == nullptr)
            return 1;
        else
            return 1 + left->item_check() + right->item_check();
    }
};

static TreeNode *new_tree_node(TreeNode *left, TreeNode *right) {
    return new (arena.alloc(sizeof(TreeNode))) TreeNode{left, right};
}

static TreeNode *bottom_up_tree(unsigned depth) {
    if (depth > 0) {
        // left subtree first, as the C program is compiled (clang evaluates arguments left to right)
        TreeNode *left = bottom_up_tree(depth - 1);
        TreeNode *right = bottom_up_tree(depth - 1);
        return new_tree_node(left, right);
    } else {
        return new_tree_node(nullptr, nullptr);
    }
}

int main() {
    const unsigned N = 20, minDepth = 4;
    arena.reserve(std::size_t{1} << 30);
    const unsigned maxDepth = (minDepth + 2) > N ? minDepth + 2 : N;
    const unsigned stretchDepth = maxDepth + 1;
    Arena::Mark mark = arena.mark();
    TreeNode *stretchTree = bottom_up_tree(stretchDepth);
    std::printf("stretch tree of depth %u\t check: %li\n", stretchDepth, stretchTree->item_check());
    arena.release(mark);
    TreeNode *longLivedTree = bottom_up_tree(maxDepth);
    for (unsigned depth = minDepth; depth <= maxDepth; depth += 2) {
        long iterations = 1L << (maxDepth - depth + minDepth);
        long check = 0;
        for (long i = 1; i <= iterations; i++) {
            Arena::Mark m = arena.mark();
            TreeNode *tempTree = bottom_up_tree(depth);
            check += tempTree->item_check();
            arena.release(m);
        }
        std::printf("%li\t trees of depth %u\t check: %li\n", iterations, depth, check);
    }
    std::printf("long lived tree of depth %u\t check: %li\n", maxDepth, longLivedTree->item_check());
    return 0;
}
