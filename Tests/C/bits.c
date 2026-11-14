#include <stdio.h>

int popcount(int x) {
    int n = 0;
    while (x != 0) {
        n += x & 1;
        x >>= 1;
    }
    return n;
}

int main() {
    int i;
    for (i = 0; i < 8; i++) {
        printf("%d:%d:%d ", i, popcount(i), 1 << i);
    }
    printf("\n");

    printf("%d %d %d\n", 12 & 10, 12 | 3, 12 ^ 10);
    printf("%d %d\n", ~0, ~5);

    int flags = 0;
    flags |= 4;
    flags |= 1;
    flags &= ~4;
    printf("flags=%d set1=%d set4=%d\n", flags, flags & 1 ? 1 : 0, flags & 4 ? 1 : 0);
    printf("%d\n", 0xFF & 0b1010);
    return 0;
}
