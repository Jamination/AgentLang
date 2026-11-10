#include <stdio.h>
#include <stdlib.h>

/* bump arena: allocate by advancing a pointer, release everything after a mark at once */
static char *arena_cur, *arena_end;

static inline void *arena_alloc(size_t n) {
    char *p = arena_cur;
    if (p + n > arena_end) {
        fprintf(stderr, "out of arena memory\n");
        exit(1);
    }
    arena_cur = p + n;
    return p;
}

typedef struct tn {
    struct tn *left, *right;
} treeNode;

static treeNode *NewTreeNode(treeNode *left, treeNode *right) {
    treeNode *n = (treeNode *)arena_alloc(sizeof(treeNode));
    n->left = left;
    n->right = right;
    return n;
}

static long ItemCheck(treeNode *tree) {
    if (tree->left == NULL)
        return 1;
    else
        return 1 + ItemCheck(tree->left) + ItemCheck(tree->right);
}

static treeNode *BottomUpTree(unsigned depth) {
    if (depth > 0)
        return NewTreeNode(BottomUpTree(depth - 1), BottomUpTree(depth - 1));
    else
        return NewTreeNode(NULL, NULL);
}

int main(void) {
    unsigned N = 20, depth, minDepth = 4, maxDepth, stretchDepth;
    size_t cap = (size_t)1 << 30;
    arena_cur = malloc(cap);
    arena_end = arena_cur + cap;
    maxDepth = (minDepth + 2) > N ? minDepth + 2 : N;
    stretchDepth = maxDepth + 1;
    char *mark = arena_cur;
    treeNode *stretchTree = BottomUpTree(stretchDepth);
    printf("stretch tree of depth %u\t check: %li\n", stretchDepth, ItemCheck(stretchTree));
    arena_cur = mark;
    treeNode *longLivedTree = BottomUpTree(maxDepth);
    for (depth = minDepth; depth <= maxDepth; depth += 2) {
        long i, iterations, check;
        iterations = 1L << (maxDepth - depth + minDepth);
        check = 0;
        for (i = 1; i <= iterations; i++) {
            char *m = arena_cur;
            treeNode *tempTree = BottomUpTree(depth);
            check += ItemCheck(tempTree);
            arena_cur = m;
        }
        printf("%li\t trees of depth %u\t check: %li\n", iterations, depth, check);
    }
    printf("long lived tree of depth %u\t check: %li\n", maxDepth, ItemCheck(longLivedTree));
    return 0;
}
