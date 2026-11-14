#include <stdio.h>

int sum(int *p, int n) {
  int s = 0;
  int i;
  for (i = 0; i < n; i++) {
    s += p[i];
  }
  return s;
}

int main() {
  int a[5];
  int i;
  for (i = 0; i < 5; i++) {
    a[i] = (i + 1) * 10;
  }

  int *p = a;
  p += 2;
  printf("%d %d\n", p[0], p - a);

  int *q = a + 1;
  printf("%d\n", q[0]);
  printf("%d\n", sum(a, 5));

  char *s = "hello";
  char *t = s + 1;
  printf("%s %c\n", t, s[1]);
  t++;
  printf("%c %d\n", t[0], t - s);
  return 0;
}
