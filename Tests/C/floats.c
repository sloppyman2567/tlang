#include <stdio.h>

double average(double a, double b) {
  return (a + b) / 2.0;
}

int main() {
  double x = 1.5;
  double y = x * 2.0 + 1.0;
  printf("%f\n", y);
  printf("%f\n", average(1.0, 3.0));
  printf("%d\n", (int)3.9);
  printf("%f\n", (double)2);
  return 0;
}
