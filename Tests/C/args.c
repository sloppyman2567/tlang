#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int i;
    int total = 0;

    for (i = 1; i < argc; i++) {
        int v = atoi(argv[i]);
        total += v;
        printf("%s=%d\n", argv[i], v);
    }
    printf("total=%d of %d\n", total, argc - 1);
    return 0;
}
