#include <stdio.h>

enum { RED, GREEN, BLUE };

char *name_of(int v) {
    switch (v) {
        case RED:
            return "red";
        case GREEN:
            return "green";
        case BLUE:
            return "blue";
        default:
            return "unknown";
    }
}

int main() {
    int i;
    for (i = 0; i < 5; i++) {
        printf("%d=%s\n", i, name_of(i));
    }

    int score = 73;
    char *grade = score >= 90 ? "A" : score >= 70 ? "B" : "C";
    printf("grade=%s\n", grade);

    for (i = 0; i < 6; i++) {
        switch (i) {
            case 0:
                printf("zero ");
                break;
            case 1:
            case 2:
                printf("small ");
                break;
            default:
                printf("big ");
                break;
        }
    }
    printf("\n");
    return 0;
}
