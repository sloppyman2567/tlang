#include <stdio.h>

int fib(int n) {
    if (n < 2) {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

int main() {
    int i;
    for (i = 0; i < 15; i++) {
        printf("%d ", fib(i));
    }
    printf("\n");
    return 0;
}
