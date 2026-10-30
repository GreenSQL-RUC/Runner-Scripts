/*
 * rapl_check [seconds] - read RAPL through both backends of rapl.c over (almost)
 * the same window and print them side by side: the check, once per machine
 * type, that the MSR reader and the kernel's powercap agree. They should to
 * rounding, except DRAM on a model where the kernel uses the wrong unit (the
 * CloudLab m510's Broadwell-DE: powercap 4x high before rescaling, so equal
 * after it). Run as root with the msr module loaded, idle or under a steady
 * load (e.g. stress-ng --cpu 0 in another shell):
 *
 *   sudo modprobe msr; sudo bin/rapl_check 10
 *
 * rapl.c holds one backend at a time, so the windows are nested: msr start,
 * powercap start, sleep, powercap end, msr end. The msr window is longer by
 * the two re-initialisations (printed); the comparison is in watts.
 */
#include "rapl.h"
#include <time.h>

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static int init(const char *backend, char *desc, size_t len) {
  setenv("RAPL_BACKEND", backend, 1);
  if (rapl_init(0) != 0) return -1;
  snprintf(desc, len, "%s", rapl_describe());
  return 0;
}

int main(int argc, char **argv) {
  double secs = argc > 1 ? atof(argv[1]) : 10.0;
  if (secs <= 0) { fprintf(stderr, "usage: %s [seconds]\n", argv[0]); return 2; }
  static const char *names[4] = { "pkg", "core", "gpu/uncore", "dram" };
  static double m0[RAPL_MAX_ZONES], m1[RAPL_MAX_ZONES], p0[RAPL_MAX_ZONES], p1[RAPL_MAX_ZONES];
  char mdesc[256], pdesc[256];
  double mps0 = NAN, mps1 = NAN, pps0 = NAN, pps1 = NAN;

  if (init("msr", mdesc, sizeof(mdesc)) != 0) return 1;
  double tm0 = now();
  rapl_snapshot(m0);
  if (rapl_psys_read(&mps0) != 0) mps0 = NAN;

  int have_pc = init("powercap", pdesc, sizeof(pdesc)) == 0;
  double tp0 = now(), tp1;
  if (have_pc) {
    rapl_snapshot(p0);
    if (rapl_psys_read(&pps0) != 0) pps0 = NAN;
  }
  usleep((useconds_t)(secs * 1e6));
  tp1 = now();
  double pe[4] = {0}, pps = NAN;
  int ppr[4] = {0};
  if (have_pc) {
    rapl_snapshot(p1);
    if (rapl_psys_read(&pps1) != 0) pps1 = NAN;
    rapl_delta(p0, p1, pe, ppr);
    pps = rapl_psys_delta(pps0, pps1);
  }

  if (init("msr", mdesc, sizeof(mdesc)) != 0) return 1;
  rapl_snapshot(m1);
  if (rapl_psys_read(&mps1) != 0) mps1 = NAN;
  double tm1 = now();
  double me[4], mps = rapl_psys_delta(mps0, mps1);
  int mpr[4];
  rapl_delta(m0, m1, me, mpr);

  double mw = tm1 - tm0, pw = tp1 - tp0;
  printf("msr:      %s\n", mdesc);
  printf("powercap: %s\n", have_pc ? pdesc : "not readable");
  printf("windows:  msr %.3f s, powercap %.3f s\n\n", mw, pw);
  printf("%-11s %10s %10s %8s\n", "domain", "msr W", "powercap W", "ratio");
  for (int d = 0; d < 5; d++) {
    int mp = d < 4 ? mpr[d] : !isnan(mps), pp = d < 4 ? ppr[d] : !isnan(pps);
    if (!mp && !pp) continue;
    double a = d < 4 ? me[d] / mw : mps / mw, b = d < 4 ? pe[d] / pw : pps / pw;
    printf("%-11s ", d < 4 ? names[d] : "psys");
    if (mp) printf("%10.3f ", a); else printf("%10s ", "-");
    if (pp) printf("%10.3f ", b); else printf("%10s ", "-");
    if (mp && pp && b > 0) printf("%8.3f", a / b); else printf("%8s", "-");
    printf("\n");
  }
  return 0;
}
