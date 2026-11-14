/*
 * tbox.c -- C equivalent of Programs/tbox.tl.
 *
 *   tbox wc   [file...]                  lines, words, bytes
 *   tbox head [-n N] [file...]           first N lines (default 10)
 *   tbox tail [-n N] [file...]           last N lines
 *   tbox grep [-i] [-n] [-c] [-v] PATTERN [file...]
 *
 * This is a hosted C implementation (it uses libc). It deliberately follows
 * tbox.tl rather than GNU coreutils: inputs are slurped whole, missing files
 * are treated as empty, output is not padded, and head/tail never print file
 * headers. It is not a freestanding AArch64 guest.
 */

#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DEFAULT_COUNT 10

static const char *g_pattern = "";
static size_t g_pattern_len;
static int g_ignore_case;
static int g_number_lines;
static int g_count_only;
static int g_invert;

static void usage(void) {
  printf("usage: tbox <tool> [options] [file...]\n");
  printf("\n");
  printf("  wc   [file...]        lines, words and bytes\n");
  printf("  head [-n N] [file...] first N lines\n");
  printf("  tail [-n N] [file...] last N lines\n");
  printf("  grep [-i] [-n] [-c] [-v] PATTERN [file...]\n");
  printf("\n");
  printf("no file means standard input\n");
}

static void die(const char *fmt, ...) {
  va_list ap;
  fputs("tbox: ", stderr);
  va_start(ap, fmt);
  vfprintf(stderr, fmt, ap);
  va_end(ap);
  fputc('\n', stderr);
  exit(2);
}

static int is_space(unsigned char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

static unsigned char lower_byte(unsigned char c) {
  return (c >= 'A' && c <= 'Z') ? (unsigned char)(c + ('a' - 'A')) : c;
}

/* Read a whole file; tbox.tl's read_file returns an empty string on failure. */
static char *read_file(const char *path) {
  FILE *f = fopen(path, "rb");
  size_t cap = 4096, len = 0;
  char *buf;

  if (f == NULL) {
    buf = malloc(1);
    if (buf == NULL) die("out of memory");
    buf[0] = '\0';
    return buf;
  }

  buf = malloc(cap);
  if (buf == NULL) die("out of memory");
  for (;;) {
    size_t got;
    if (len == cap) {
      char *grown = realloc(buf, cap * 2);
      if (grown == NULL) die("out of memory");
      buf = grown;
      cap *= 2;
    }
    got = fread(buf + len, 1, cap - len, f);
    len += got;
    if (got == 0) break;
  }
  fclose(f);
  buf[len] = '\0';
  return buf;
}

static size_t line_end(const char *s, size_t from, size_t total) {
  size_t i = from;
  while (i < total && s[i] != '\n') i++;
  return i;
}

static size_t count_lines(const char *s, size_t total) {
  size_t n = 0, i;
  if (total == 0) return 0;
  for (i = 0; i < total; i++) {
    if (s[i] == '\n') n++;
  }
  if (s[total - 1] != '\n') n++;
  return n;
}

static size_t count_words(const char *s, size_t total) {
  size_t n = 0, i;
  int inside = 0;
  for (i = 0; i < total; i++) {
    unsigned char c = (unsigned char)s[i];
    if (is_space(c)) {
      inside = 0;
    } else if (!inside) {
      inside = 1;
      n++;
    }
  }
  return n;
}

static int match_at(const char *s, size_t pos, const char *pat) {
  size_t k;
  for (k = 0; k < g_pattern_len; k++) {
    unsigned char a = (unsigned char)s[pos + k];
    unsigned char b = (unsigned char)pat[k];
    if (g_ignore_case) {
      a = lower_byte(a);
      b = lower_byte(b);
    }
    if (a != b) return 0;
  }
  return 1;
}

static int line_hits(const char *s, size_t from, size_t to) {
  int found = 0;
  if (g_pattern_len == 0) {
    found = 1;
  } else {
    size_t i = from;
    while (i + g_pattern_len <= to) {
      if (match_at(s, i, g_pattern)) {
        found = 1;
        break;
      }
      i++;
    }
  }
  return g_invert ? 1 - found : found;
}

static char **inputs(int from, int argc, char **argv,
                     int *nfiles, int *stdin_mode) {
  int count = argc - from;
  char **files;
  int i;

  if (count < 0) count = 0;
  files = malloc((size_t)(count > 0 ? count : 1) * sizeof(*files));
  if (files == NULL) die("out of memory");

  for (i = 0; i < count; i++) files[i] = argv[from + i];
  if (count == 0) {
    files[0] = "/dev/stdin";
    count = 1;
    *stdin_mode = 1;
  } else {
    *stdin_mode = 0;
  }
  *nfiles = count;
  return files;
}

static void wc_one(const char *s, const char *label) {
  size_t total = strlen(s);
  size_t lines = count_lines(s, total);
  size_t words = count_words(s, total);
  printf("%zu %zu %zu", lines, words, total);
  if (label[0] != '\0') printf(" %s", label);
  putchar('\n');
}

static void run_wc(int from, int argc, char **argv) {
  int nfiles, stdin_mode;
  char **files = inputs(from, argc, argv, &nfiles, &stdin_mode);
  size_t tot_lines = 0, tot_words = 0, tot_bytes = 0;
  int k;
  for (k = 0; k < nfiles; k++) {
    char *s = read_file(files[k]);
    size_t total = strlen(s);
    size_t lines = count_lines(s, total);
    size_t words = count_words(s, total);
    wc_one(s, stdin_mode ? "" : files[k]);
    tot_lines += lines;
    tot_words += words;
    tot_bytes += total;
    free(s);
  }
  if (nfiles > 1) {
    printf("%zu %zu %zu total\n", tot_lines, tot_words, tot_bytes);
  }
  free(files);
}

static void run_head(int from, int argc, char **argv, long long count) {
  int nfiles, stdin_mode;
  char **files = inputs(from, argc, argv, &nfiles, &stdin_mode);
  int k;
  (void)stdin_mode;
  for (k = 0; k < nfiles; k++) {
    char *s = read_file(files[k]);
    size_t total = strlen(s);
    size_t start = 0;
    long long taken = 0;
    while (start < total && taken < count) {
      size_t end = line_end(s, start, total);
      fwrite(s + start, 1, end - start, stdout);
      putchar('\n');
      start = end + 1;
      taken++;
    }
    free(s);
  }
  free(files);
}

static void run_tail(int from, int argc, char **argv, long long count) {
  int nfiles, stdin_mode;
  char **files = inputs(from, argc, argv, &nfiles, &stdin_mode);
  int k;
  (void)stdin_mode;
  for (k = 0; k < nfiles; k++) {
    char *s = read_file(files[k]);
    size_t total = strlen(s);
    size_t lines = count_lines(s, total);
    size_t skip = 0;
    size_t start = 0, seen = 0;
    if ((unsigned long long)count < (unsigned long long)lines) {
      skip = lines - (size_t)count;
    }
    while (start < total) {
      size_t end = line_end(s, start, total);
      if (seen >= skip) {
        fwrite(s + start, 1, end - start, stdout);
        putchar('\n');
      }
      seen++;
      start = end + 1;
    }
    free(s);
  }
  free(files);
}

static size_t grep_one(const char *s, const char *label) {
  size_t hits = 0, number = 0, start = 0;
  size_t total = strlen(s);
  while (start < total) {
    size_t end = line_end(s, start, total);
    number++;
    if (line_hits(s, start, end)) {
      hits++;
      if (!g_count_only) {
        fputs(label, stdout);
        if (g_number_lines) printf("%zu:", number);
        fwrite(s + start, 1, end - start, stdout);
        putchar('\n');
      }
    }
    start = end + 1;
  }
  return hits;
}

static void run_grep(int from, int argc, char **argv) {
  int i = from;
  int nfiles, stdin_mode;
  char **files;
  size_t hits = 0;
  int k;

  while (i < argc && argv[i][0] == '-') {
    const char *flag = argv[i];
    size_t j;
    if (strcmp(flag, "--help") == 0) {
      usage();
      exit(0);
    }
    for (j = 1; flag[j] != '\0'; j++) {
      switch (flag[j]) {
        case 'i': g_ignore_case = 1; break;
        case 'n': g_number_lines = 1; break;
        case 'c': g_count_only = 1; break;
        case 'v': g_invert = 1; break;
        case 'h': usage(); exit(0);
        default: {
          char option[3] = {'-', flag[j], '\0'};
          die("unknown option %s", option);
        }
      }
    }
    i++;
  }
  if (i >= argc) die("grep needs a pattern");
  g_pattern = argv[i++];
  g_pattern_len = strlen(g_pattern);

  files = inputs(i, argc, argv, &nfiles, &stdin_mode);
  (void)stdin_mode;
  for (k = 0; k < nfiles; k++) {
    char *s = read_file(files[k]);
    char *label = "";
    size_t n;
    if (nfiles > 1) {
      size_t len = strlen(files[k]);
      label = malloc(len + 2);
      if (label == NULL) die("out of memory");
      memcpy(label, files[k], len);
      label[len] = ':';
      label[len + 1] = '\0';
    }
    n = grep_one(s, label);
    hits += n;
    if (g_count_only && nfiles > 1) {
      printf("%s:%zu\n", files[k], n);
    }
    if (nfiles > 1) free(label);
    free(s);
  }
  if (g_count_only) printf("%zu\n", hits);
  free(files);
  if (hits == 0) exit(1);
}

static int count_flag(int from, int argc, char **argv, long long *count) {
  if (from + 1 < argc && strcmp(argv[from], "-n") == 0) {
    char *end = NULL;
    long long value = strtoll(argv[from + 1], &end, 10);
    if (end == argv[from + 1]) value = 0;
    if (value < 0) value = 0;
    *count = value;
    return from + 2;
  }
  *count = DEFAULT_COUNT;
  return from;
}

int main(int argc, char **argv) {
  const char *tool;
  long long count;

  if (argc < 2) {
    usage();
    return 2;
  }
  tool = argv[1];

  if (strcmp(tool, "grep") == 0) {
    run_grep(2, argc, argv);
    return 0;
  }
  if (strcmp(tool, "wc") == 0) {
    run_wc(2, argc, argv);
    return 0;
  }
  if (strcmp(tool, "head") == 0) {
    int at = count_flag(2, argc, argv, &count);
    run_head(at, argc, argv, count);
    return 0;
  }
  if (strcmp(tool, "tail") == 0) {
    int at = count_flag(2, argc, argv, &count);
    run_tail(at, argc, argv, count);
    return 0;
  }
  if (strcmp(tool, "-h") == 0 || strcmp(tool, "--help") == 0 ||
      strcmp(tool, "help") == 0) {
    usage();
    return 0;
  }
  die("no such tool '%s'", tool);
  return 2;
}
