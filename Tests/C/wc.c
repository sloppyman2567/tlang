#include <stdio.h>

int main() {
    int c;
    int lines = 0, words = 0, chars = 0;
    int inword = 0;

    while ((c = getchar()) != EOF) {
        chars++;
        if (c == '\n') {
            lines++;
        }
        if (c == ' ' || c == '\n' || c == '\t') {
            inword = 0;
        } else if (inword == 0) {
            inword = 1;
            words++;
        }
    }
    printf("%d %d %d\n", lines, words, chars);
    return 0;
}
