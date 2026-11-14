#include <stdio.h>
#include <stdlib.h>

int main() {
  int *a = malloc(sizeof(int) * 4);
  int *b = calloc(3, sizeof(int));
  int i;

  for (i = 0; i < 4; i++) {
    a[i] = (i + 1) * 3;
  }
  b[0] = 7;
  b[1] = 8;
  b[2] = 9;

  printf("%d %d\n", a[3], b[2]);
  free(a);
  free(b);
  return 0;
}
