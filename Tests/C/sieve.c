#include <stdio.h>

#define LIMIT 100

int composite[LIMIT + 1];
int found = 0;

int main() {
    int i, j, count = 0;
    for (i = 0; i <= LIMIT; i++) {
        composite[i] = 0;
    }
    for (i = 2; i * i <= LIMIT; i++) {
        if (composite[i] == 0) {
            for (j = i * i; j <= LIMIT; j += i) {
                composite[j] = 1;
            }
        }
    }
    for (i = 2; i <= LIMIT; i++) {
        if (!composite[i]) {
            printf("%d ", i);
            count++;
            found++;
        }
    }
    printf("\ncount=%d\n", count);
    return 0;
}
