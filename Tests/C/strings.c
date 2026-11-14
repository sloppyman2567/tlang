#include <stdio.h>
#include <string.h>

char buf[64];

int main() {
    char *s = "hello, world";
    int n = strlen(s);
    int i;

    for (i = 0; i < n; i++) {
        buf[i] = s[i];
    }
    buf[n] = '\0';
    printf("%s (%d)\n", buf, n);

    for (i = 0; i < n / 2; i++) {
        char t = buf[i];
        buf[i] = buf[n - 1 - i];
        buf[n - 1 - i] = t;
    }
    printf("%s\n", buf);

    if (strcmp(buf, "dlrow ,olleh") == 0) {
        printf("reversed ok\n");
    } else {
        printf("reversed wrong\n");
    }
    printf("%d\n", strcmp("apple", "banana") < 0);
    return 0;
}
