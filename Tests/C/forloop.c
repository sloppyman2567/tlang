#include <stdio.h>

int main() {
    int i, j, total = 0;

    for (i = 0; i < 10; i++) {
        if (i % 3 == 0) {
            continue;
        }
        total += i;
    }
    printf("sum=%d\n", total);

    i = 0;
    do {
        total += 1;
        i++;
    } while (i < 3);
    printf("total=%d\n", total);

    for (i = 1; i <= 3; i++) {
        for (j = 1; j <= 3; j++) {
            printf("%d", i * j);
        }
        printf(" ");
    }
    printf("\n");

    for (i = 0; i < 100; i++) {
        if (i == 4) {
            break;
        }
    }
    printf("broke at %d\n", i);
    return 0;
}
