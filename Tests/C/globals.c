#include <stdio.h>

int calls = 0;
int acc = 1;

int bump(int by) {
    calls++;
    acc += by;
    return acc;
}

int main() {
    bump(2);
    bump(3);
    bump(bump(0));
    printf("calls=%d acc=%d\n", calls, acc);
    return 0;
}
