#include <stdio.h>

void insertion_sort(int a[], int n) {
    int i, j, key;
    for (i = 1; i < n; i++) {
        key = a[i];
        j = i - 1;
        while (j >= 0 && a[j] > key) {
            a[j + 1] = a[j];
            j--;
        }
        a[j + 1] = key;
    }
}

int main() {
    int a[8] = {5, 3, 9, 1, 7, 2, 8, 4};
    int i;
    insertion_sort(a, 8);
    for (i = 0; i < 8; i++) {
        printf("%d ", a[i]);
    }
    printf("\n");
    return 0;
}
