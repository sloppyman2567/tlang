#include <stdio.h>
#include <stdlib.h>

struct Node {
    int value;
    struct Node *next;
};

struct Node *push(struct Node *head, int value) {
    struct Node *n = malloc(sizeof(struct Node));
    n->value = value;
    n->next = head;
    return n;
}

int sum(struct Node *head) {
    int total = 0;
    struct Node *p = head;
    while (p != NULL) {
        total += p->value;
        p = p->next;
    }
    return total;
}

int main() {
    struct Node *head = NULL;
    int i;
    for (i = 0; i < 5; i++) {
        head = push(head, i * i);
    }

    struct Node *p = head;
    while (p != NULL) {
        printf("%d ", p->value);
        p = p->next;
    }
    printf("\n");
    printf("sum=%d\n", sum(head));
    return 0;
}
