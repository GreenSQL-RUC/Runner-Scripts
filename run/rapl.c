#include "rapl.h"
#include <dirent.h>


int core=0;


double power_units,energy_units,time_units;

int open_msr(int core) {

  char msr_filename[BUFSIZ];
  int fd;

  sprintf(msr_filename, "/dev/cpu/%d/msr", core);
  fd = open(msr_filename, O_RDONLY);
  if ( fd < 0 ) {
    if ( errno == ENXIO ) {
      fprintf(stderr, "rdmsr: No CPU %d\n", core);
      exit(2);
    } else if ( errno == EIO ) {
      fprintf(stderr, "rdmsr: CPU %d doesn't support MSRs\n", core);
      exit(3);
    } else if ( errno == EACCES ) {
      perror("rdmsr:open");
      fprintf(stderr, "Permission denied for %s\n", msr_filename);
      fprintf(stderr, "Run as root (e.g., sudo) and ensure the msr module is loaded: sudo modprobe msr\n");
      exit(127);
    } else {
      perror("rdmsr:open");
      fprintf(stderr,"Trying to open %s\n",msr_filename);
      exit(127);
    }
  }

  return fd;
}

long long read_msr(int fd, int which) {

  uint64_t data;

  if ( pread(fd, &data, sizeof data, which) != sizeof data ) {
    perror("rdmsr:pread");
    exit(127);
  }

  return (long long)data;
}

/* ------------------------------------------------------------------ */
/* Zones: one energy counter each, summed into the four domains        */
/* ------------------------------------------------------------------ */

enum { D_PKG = 0, D_CORE = 1, D_GPU = 2, D_DRAM = 3 };

typedef struct {
  int domain;
  int is_msr;            /* 1 = read MSR `msr` on `cpu`; 0 = sysfs `path`  */
  char path[256];        /* powercap .../energy_uj                          */
  int cpu;
  unsigned int msr;      /* MSR address; AMD's (0xC00102xx) do not fit an int */
  double unit;           /* joules per MSR count                            */
  double range_j;        /* the counter wraps after this many joules         */
  double scale;          /* powercap joules multiplier (see fix_dram_unit)  */
} rapl_zone;

static rapl_zone zones[RAPL_MAX_ZONES];
static int nzones = 0, npackages = 0;
static char describe_buf[256] = "not initialised";
static double snap_before[RAPL_MAX_ZONES];
static double snap_after[RAPL_MAX_ZONES];   /* the last rapl_after() snapshot */
static double dram_rescaled = 1.0;   /* != 1: powercap DRAM was rescaled */
static int dram_fixed_msr = 0;       /* MSR DRAM read in the fixed 2^-16 J unit */
static rapl_zone psys_zone;          /* platform energy, outside the domains */
static int has_psys = 0;

/* Server Xeons count DRAM energy in a fixed 2^-16 J (15.3 uJ) unit, not the
 * package unit in MSR 0x606 (the Linux intel_rapl driver's list). */
static int dram_fixed_unit(int model) {
  switch (model) {
    case 63: case 79: case 86: case 85: case 106: case 108:
    case 143: case 207: case 173: case 174: case 87: case 133:
      return 1;
    default:
      return 0;
  }
}

/* psys counts in whole joules on Sapphire / Emerald Rapids (the kernel's
 * rapl_defaults_spr_server; seen on the CloudLab c6620's Xeon Gold 5512U), in
 * the package unit elsewhere. */
static int psys_whole_joules(int model) { return model == 143 || model == 207; }

/* RAPL_CPUINFO and RAPL_MSR_DIR stand in for /proc/cpuinfo and /dev/cpu, so
 * the MSR reader can be tested with fake CPUs (<dir>/<cpu>/msr read at the
 * MSR's offset; AMD's registers are adjacent, so a file-backed fake needs
 * its pread wrapped to give each register its own 8 bytes). */
static const char *cpuinfo_path(void) {
  const char *p = getenv("RAPL_CPUINFO");
  return p && *p ? p : "/proc/cpuinfo";
}

/* Intel family-6 model from /proc/cpuinfo, or -1 (not Intel / not family 6). */
static int intel_model(void) {
  FILE *f = fopen(cpuinfo_path(), "r");
  if (!f) return -1;
  char line[256];
  int intel = 0, family = -1, model = -1;
  while (fgets(line, sizeof(line), f) && model < 0) {
    if (!strncmp(line, "vendor_id", 9)) intel = strstr(line, "GenuineIntel") != NULL;
    else if (!strncmp(line, "cpu family", 10)) sscanf(strchr(line, ':') + 1, "%d", &family);
    else if (!strncmp(line, "model", 5) && line[5] != ' ') sscanf(strchr(line, ':') + 1, "%d", &model);
  }
  fclose(f);
  return intel && family == 6 ? model : -1;
}

/* The kernel's powercap driver does not use the fixed 2^-16 J DRAM unit on
 * every model that has it: on Broadwell-DE (model 86, the CloudLab m510's
 * Xeon D-1548) it applies the package unit, so DRAM reads 4x high with a
 * 2^-14 J package unit (perf's RAPL PMU and the SDM say 2^-16). Its
 * max_energy_range_uj is 2^32 counts times the unit it used, so on a fixed-unit
 * model a range other than 2^32 x 2^-16 J = 65536 J gives the correction; it
 * is rounded to a power of two (unit ratios always are). */
static void fix_dram_unit(rapl_zone *z, int model) {
  const double want = 4294967296.0 * pow(0.5, 16);
  if (!dram_fixed_unit(model) || z->range_j <= 0) return;
  double s = pow(2.0, round(log2(want / z->range_j)));
  if (s == 1.0) return;                       /* the kernel got it right */
  z->scale = s;
  z->range_j *= s;
  dram_rescaled = s;
}

/* ---- AMD (Zen) ----------------------------------------------------------- */
#define MSR_AMD_RAPL_POWER_UNIT    0xC0010299
#define MSR_AMD_CORE_ENERGY_STATUS 0xC001029A
#define MSR_AMD_PKG_ENERGY_STATUS  0xC001029B
static int amd_cores = -1;            /* per-core zones added (-1: not AMD) */

/* AuthenticAMD / HygonGenuine, family 17h or later (Zen): the RAPL MSRs above. */
static int cpu_is_amd_zen(void) {
  FILE *f = fopen(cpuinfo_path(), "r");
  if (!f) return 0;
  char line[256];
  int amd = 0, family = -1;
  while (fgets(line, sizeof(line), f) && family < 0) {
    if (!strncmp(line, "vendor_id", 9)) amd = strstr(line, "AuthenticAMD") || strstr(line, "HygonGenuine");
    else if (!strncmp(line, "cpu family", 10)) sscanf(strchr(line, ':') + 1, "%d", &family);
  }
  fclose(f);
  return amd && family >= 0x17;
}

/* One MSR, without the exit-on-error of open_msr(): 0 on success. Each CPU's
 * device is opened once and kept (a run reads every counter twice per batch;
 * on an AMD node that is one per core), close-on-exec so psql never inherits
 * it; msr_close_all() lets rapl_init start over. */
#define RAPL_MAX_CPUS 4096
static int msr_fd[RAPL_MAX_CPUS];
static int msr_fd_ready = 0;

static void msr_close_all(void) {
  for (int c = 0; msr_fd_ready && c < RAPL_MAX_CPUS; c++)
    if (msr_fd[c] >= 0) { close(msr_fd[c]); msr_fd[c] = -1; }
}

static int msr_read_quiet(int cpu, unsigned reg, uint64_t *v) {
  if (cpu < 0 || cpu >= RAPL_MAX_CPUS) return -1;
  if (!msr_fd_ready) {
    for (int c = 0; c < RAPL_MAX_CPUS; c++) msr_fd[c] = -1;
    msr_fd_ready = 1;
  }
  if (msr_fd[cpu] < 0) {
    const char *dir = getenv("RAPL_MSR_DIR");
    char fn[300];
    snprintf(fn, sizeof(fn), "%s/%d/msr", dir && *dir ? dir : "/dev/cpu", cpu);
    if ((msr_fd[cpu] = open(fn, O_RDONLY | O_CLOEXEC)) < 0) return -1;
  }
  return pread(msr_fd[cpu], v, sizeof(*v), reg) == (ssize_t)sizeof(*v) ? 0 : -1;
}

/* The kernel's test for a RAPL domain (rapl_check_domain): its energy counter
 * is readable and not 0. A counter the model lacks faults or reads 0 (PP0 on
 * most server Xeons); one that exists but stands still while idle (PP1/uncore
 * with the GPU asleep) is kept, as powercap keeps it. */
static int msr_counter_present(int cpu, unsigned reg) {
  uint64_t v;
  return msr_read_quiet(cpu, reg, &v) == 0 && (v & 0xffffffffULL) != 0;
}

static int read_text(const char *path, char *buf, size_t len);
static int add_zone(const rapl_zone *z);

/* The first online CPU of every RAPL unit: each package, and with by_die each
 * die of a multi-die Intel package (Cascade Lake-AP style), whose counters are
 * per die. Returns the number of units; *packages gets the number of distinct
 * packages. */
static int rapl_units(int by_die, int first_cpu[], int max, int *packages) {
  int key[256], pkgs[256], n = 0, np = 0;
  if (max > 256) max = 256;
  for (int c = 0; c < RAPL_MAX_CPUS && n < max; c++) {
    char p[128], buf[32];
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d", c);
    if (access(p, F_OK) != 0) break;
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", c);
    if (read_text(p, buf, sizeof(buf)) != 0) continue;           /* offline cpu */
    int pkg = atoi(buf), die = 0, seen = 0;
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/topology/die_id", c);
    if (by_die && read_text(p, buf, sizeof(buf)) == 0) die = atoi(buf);
    int k = pkg * 1024 + die;
    for (int i = 0; i < n; i++) if (key[i] == k) seen = 1;
    if (seen) continue;
    key[n] = k; first_cpu[n++] = c;
    seen = 0;
    for (int i = 0; i < np; i++) if (pkgs[i] == pkg) seen = 1;
    if (!seen) pkgs[np++] = pkg;
  }
  *packages = np;
  return n;
}

/* One zone per physical core (the first thread of each), domain core, summed
 * by rapl_delta. Returns how many were added (0: MSRs unreadable - not root,
 * or the msr module is not loaded). */
static int add_amd_core_zones(void) {
  uint64_t u;
  if (msr_read_quiet(0, MSR_AMD_RAPL_POWER_UNIT, &u) != 0) return 0;
  double unit = pow(0.5, (double)((u >> 8) & 0x1f));
  int added = 0;
  for (int c = 0; c < 4096; c++) {
    char p[128], buf[64];
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d", c);
    if (access(p, F_OK) != 0) break;
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", c);
    if (read_text(p, buf, sizeof(buf)) != 0) continue;           /* offline cpu */
    if (atoi(buf) != c) continue;                                /* not the core's first thread */
    rapl_zone z; memset(&z, 0, sizeof(z));
    z.domain = D_CORE; z.is_msr = 1; z.cpu = c; z.msr = MSR_AMD_CORE_ENERGY_STATUS;
    z.unit = unit; z.range_j = 4294967296.0 * unit; z.scale = 1.0;
    if (add_zone(&z) == 0) added++;
  }
  return added;
}

/* AMD from the MSRs: the package counter of every socket (in that socket's
 * unit), plus the per-core ones. */
static int init_msr_amd(void) {
  int first[64], np;
  int nu = rapl_units(0, first, 64, &np);
  for (int i = 0; i < nu; i++) {
    uint64_t u;
    if (msr_read_quiet(first[i], MSR_AMD_RAPL_POWER_UNIT, &u) != 0) return -1;
    double unit = pow(0.5, (double)((u >> 8) & 0x1f));
    rapl_zone z; memset(&z, 0, sizeof(z));
    z.domain = D_PKG; z.is_msr = 1; z.cpu = first[i]; z.msr = MSR_AMD_PKG_ENERGY_STATUS;
    z.unit = unit; z.range_j = 4294967296.0 * unit; z.scale = 1.0;
    if (!msr_counter_present(z.cpu, z.msr) || add_zone(&z) != 0) return -1;
  }
  npackages = np;
  amd_cores = add_amd_core_zones();
  return nu > 0 ? 0 : -1;
}

static int read_text(const char *path, char *buf, size_t len) {
  FILE *f = fopen(path, "r");
  if (!f) return -1;
  if (!fgets(buf, (int)len, f)) { fclose(f); return -1; }
  fclose(f);
  buf[strcspn(buf, "\r\n")] = '\0';
  return 0;
}

static int read_zone(const rapl_zone *z, double *joules) {
  if (z->is_msr) {
    uint64_t data;
    if (msr_read_quiet(z->cpu, z->msr, &data) != 0) return -1;
    *joules = (double)(data & 0xffffffffULL) * z->unit;
  } else {
    char buf[64];
    if (read_text(z->path, buf, sizeof(buf)) != 0) return -1;
    *joules = strtod(buf, NULL) * 1e-6 * z->scale;
  }
  return 0;
}

static int add_zone(const rapl_zone *z) {
  double j;
  if (nzones >= RAPL_MAX_ZONES || read_zone(z, &j) != 0) return -1;
  zones[nzones++] = *z;
  return 0;
}

/* powercap: top-level zones intel-rapl:<n> named package-<k> (psys and the
 * duplicate intel-rapl-mmio tree are skipped), with sub-zones core / uncore /
 * dram. The kernel applies each domain's own unit. energy_uj is root-only. */
static int init_powercap(void) {
  const char *base = "/sys/class/powercap";
  DIR *d = opendir(base);
  if (!d) return -1;
  int model = intel_model();
  int amd = cpu_is_amd_zen();
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    int n, used = 0;
    if (sscanf(e->d_name, "intel-rapl:%d%n", &n, &used) != 1 || e->d_name[used] != '\0') continue;
    char zdir[96], name[64], buf[64], p[256];
    snprintf(zdir, sizeof(zdir), "%s/intel-rapl:%d", base, n);
    snprintf(p, sizeof(p), "%s/name", zdir);
    if (read_text(p, name, sizeof(name)) != 0) continue;
    if (!strcmp(name, "psys") && !has_psys) {
      rapl_zone z; memset(&z, 0, sizeof(z));
      z.scale = 1.0;
      snprintf(z.path, sizeof(z.path), "%s/energy_uj", zdir);
      snprintf(p, sizeof(p), "%s/max_energy_range_uj", zdir);
      z.range_j = read_text(p, buf, sizeof(buf)) == 0 ? strtod(buf, NULL) * 1e-6 : 0;
      double j;
      if (read_zone(&z, &j) == 0) { psys_zone = z; has_psys = 1; }
      continue;
    }
    int top_domain = !strncmp(name, "package-", 8) ? D_PKG : !strcmp(name, "dram") ? D_DRAM : -1;
    if (top_domain < 0) continue;

    rapl_zone z; memset(&z, 0, sizeof(z));
    z.domain = top_domain; z.scale = 1.0;
    snprintf(z.path, sizeof(z.path), "%s/energy_uj", zdir);
    snprintf(p, sizeof(p), "%s/max_energy_range_uj", zdir);
    z.range_j = read_text(p, buf, sizeof(buf)) == 0 ? strtod(buf, NULL) * 1e-6 : 0;
    if (top_domain == D_DRAM) fix_dram_unit(&z, model);
    if (add_zone(&z) != 0) { closedir(d); return -1; }   /* unreadable: not root */
    if (top_domain == D_PKG) npackages++;

    for (int m = 0; m < 8; m++) {
      char sdir[128];
      snprintf(sdir, sizeof(sdir), "%s/intel-rapl:%d:%d", zdir, n, m);
      snprintf(p, sizeof(p), "%s/name", sdir);
      if (read_text(p, name, sizeof(name)) != 0) continue;
      int dom = !strcmp(name, "core") ? D_CORE : !strcmp(name, "uncore") ? D_GPU
              : !strcmp(name, "dram") ? D_DRAM : -1;
      if (dom < 0) continue;
      if (amd && dom == D_CORE) continue;        /* one core only: per-core MSRs below */
      memset(&z, 0, sizeof(z));
      z.domain = dom; z.scale = 1.0;
      snprintf(z.path, sizeof(z.path), "%s/energy_uj", sdir);
      snprintf(p, sizeof(p), "%s/max_energy_range_uj", sdir);
      z.range_j = read_text(p, buf, sizeof(buf)) == 0 ? strtod(buf, NULL) * 1e-6 : 0;
      if (dom == D_DRAM) fix_dram_unit(&z, model);
      add_zone(&z);
    }
  }
  closedir(d);
  if (npackages > 0 && amd) amd_cores = add_amd_core_zones();
  return npackages > 0 ? 0 : -1;
}

/* Intel from the MSRs, the way the kernel's intel_rapl driver finds its
 * domains: every RAPL unit (package, or die) in its own unit from MSR 0x606;
 * package, then PP0 (core), PP1 (uncore) and DRAM wherever the counter is
 * present (msr_counter_present), DRAM in the fixed 2^-16 J unit on the server
 * models that have it, and psys once, from the first unit. */
static int init_msr_intel(void) {
  int model = intel_model();
  if (model < 0) return -1;
  int first[64], np;
  int nu = rapl_units(1, first, 64, &np);
  static const struct { int domain; unsigned msr; } sub[] = {
    { D_CORE, MSR_PP0_ENERGY_STATUS }, { D_GPU, MSR_PP1_ENERGY_STATUS }, { D_DRAM, MSR_DRAM_ENERGY_STATUS },
  };
  for (int i = 0; i < nu; i++) {
    uint64_t u;
    if (msr_read_quiet(first[i], MSR_RAPL_POWER_UNIT, &u) != 0) return -1;
    double unit = pow(0.5, (double)((u >> 8) & 0x1f));
    if (i == 0) {               /* for show_power_info / show_power_limit */
      power_units = pow(0.5, (double)(u & 0xf));
      energy_units = unit;
      time_units = pow(0.5, (double)((u >> 16) & 0xf));
    }
    rapl_zone z; memset(&z, 0, sizeof(z));
    z.is_msr = 1; z.cpu = first[i]; z.scale = 1.0;
    z.domain = D_PKG; z.msr = MSR_PKG_ENERGY_STATUS;
    z.unit = unit; z.range_j = 4294967296.0 * unit;
    if (!msr_counter_present(z.cpu, z.msr) || add_zone(&z) != 0) return -1;
    for (size_t k = 0; k < sizeof(sub) / sizeof(sub[0]); k++) {
      if (!msr_counter_present(z.cpu, sub[k].msr)) continue;
      z.domain = sub[k].domain; z.msr = sub[k].msr;
      z.unit = sub[k].domain == D_DRAM && dram_fixed_unit(model) ? pow(0.5, 16) : unit;
      z.range_j = 4294967296.0 * z.unit;
      if (add_zone(&z) == 0 && z.domain == D_DRAM && z.unit != unit) dram_fixed_msr = 1;
    }
    if (i == 0 && msr_counter_present(z.cpu, MSR_PLATFORM_ENERGY_STATUS)) {
      z.domain = D_PKG; z.msr = MSR_PLATFORM_ENERGY_STATUS;
      z.unit = psys_whole_joules(model) ? 1.0 : unit;
      z.range_j = 4294967296.0 * z.unit;
      psys_zone = z; has_psys = 1;
    }
  }
  npackages = np;
  return nu > 0 ? 0 : -1;
}

static void reset_state(void) {
  nzones = npackages = 0;
  dram_rescaled = 1.0;
  dram_fixed_msr = 0;
  has_psys = 0;
  amd_cores = -1;
  msr_close_all();
}

/* RAPL_BACKEND picks the reader: "auto" (the default) tries the MSRs first and
 * falls back to powercap, "msr" or "powercap" use only that one. The MSRs give
 * the same domains as powercap, and DRAM in its right unit where the kernel
 * gets it wrong (the m510); powercap remains for machines where the MSRs are
 * not readable (no msr module, a VM) or not how the kernel reads RAPL (the
 * newest Xeons read it through TPMI). The backend is in rapl_describe(). */
int rapl_init(int core)
{
  (void)core;   /* every package is read now; kept for the old call sites */
  const char *want = getenv("RAPL_BACKEND");
  if (!want || !*want) want = "auto";
  if (strcmp(want, "auto") && strcmp(want, "msr") && strcmp(want, "powercap")) {
    printf("RAPL_BACKEND=%s: expected auto, msr or powercap\n", want);
    return -1;
  }
  int amd = cpu_is_amd_zen();
  const char *backend = NULL, *fallback = "";
  reset_state();
  if (strcmp(want, "powercap") != 0) {
    if ((amd ? init_msr_amd() : init_msr_intel()) == 0) {
      backend = "msr";
    } else {
      reset_state();
      if (!strcmp(want, "msr")) {
        printf("RAPL_BACKEND=msr: no readable RAPL MSRs (%s)\n",
               amd || intel_model() >= 0 ? "need root and the msr module: sudo modprobe msr"
                                         : "not an Intel or AMD Zen CPU");
        return -1;
      }
      fallback = " (msr not readable)";
    }
  }
  if (!backend) {
    if (init_powercap() != 0) {
      reset_state();
      printf("No readable RAPL: no MSRs (need root and the msr module: sudo modprobe msr) and no powercap zones\n");
      return -1;
    }
    backend = "powercap";
  }

  int present[4] = {0, 0, 0, 0};
  for (int i = 0; i < nzones; i++) present[zones[i].domain] = 1;
  char fix[96] = "";
  if (dram_rescaled != 1.0)
    snprintf(fix, sizeof(fix), " (dram x%g: kernel used the package unit)", dram_rescaled);
  else if (dram_fixed_msr)
    snprintf(fix, sizeof(fix), " (dram in its fixed 2^-16 J unit)");
  else if (amd_cores > 0)
    snprintf(fix, sizeof(fix), " (core = sum of %d per-core counters)", amd_cores);
  else if (amd_cores == 0)
    snprintf(fix, sizeof(fix), " (no core: per-core MSRs unreadable, load msr)");
  snprintf(describe_buf, sizeof(describe_buf), "%s%s, %d package%s, domains:%s%s%s%s%s%s",
           backend, fallback, npackages, npackages == 1 ? "" : "s",
           present[D_PKG] ? " pkg" : "", present[D_CORE] ? " core" : "",
           present[D_GPU] ? " gpu/uncore" : "", present[D_DRAM] ? " dram" : "",
           has_psys ? " (+ psys)" : "", fix);
  return 0;
}

int rapl_packages(void) { return npackages; }

void rapl_disable(const char *why) {
  nzones = npackages = 0;
  has_psys = 0;
  amd_cores = -1;
  snprintf(describe_buf, sizeof(describe_buf), "none (%s)", why);
}

static int is_percore(const rapl_zone *z) { return z->msr == MSR_AMD_CORE_ENERGY_STATUS; }

int rapl_percore_count(void) {
  int n = 0;
  for (int i = 0; i < nzones; i++) n += is_percore(&zones[i]);
  return n;
}

int rapl_percore_cpu(int k) {
  for (int i = 0, n = 0; i < nzones; i++)
    if (is_percore(&zones[i]) && n++ == k) return zones[i].cpu;
  return -1;
}

void rapl_percore_delta(const double a[RAPL_MAX_ZONES], const double b[RAPL_MAX_ZONES], double *out) {
  for (int i = 0, n = 0; i < nzones; i++) {
    if (!is_percore(&zones[i])) continue;
    double d = b[i] - a[i];
    if (d < 0 && zones[i].range_j > 0) d += zones[i].range_j;
    out[n++] = d;
  }
}

void rapl_percore_last(double *out) { rapl_percore_delta(snap_before, snap_after, out); }

int rapl_psys_read(double *joules) {
  if (!has_psys) return -1;
  return read_zone(&psys_zone, joules);
}

double rapl_psys_delta(double before, double after) {
  if (isnan(before) || isnan(after)) return NAN;
  double d = after - before;
  if (d < 0 && psys_zone.range_j > 0) d += psys_zone.range_j;
  return d;
}
const char *rapl_describe(void) { return describe_buf; }

void rapl_snapshot(double raw[RAPL_MAX_ZONES]) {
  for (int i = 0; i < nzones; i++)
    if (read_zone(&zones[i], &raw[i]) != 0) raw[i] = NAN;
}

/* Per-zone delta with wrap correction (a counter that went backwards crossed
 * its range), summed per domain. A domain with no zone is not present. */
void rapl_delta(const double a[RAPL_MAX_ZONES], const double b[RAPL_MAX_ZONES],
                double out[4], int present[4]) {
  for (int d = 0; d < 4; d++) { out[d] = 0.0; present[d] = 0; }
  for (int i = 0; i < nzones; i++) {
    double delta = b[i] - a[i];
    if (delta < 0 && zones[i].range_j > 0) delta += zones[i].range_j;
    out[zones[i].domain] += delta;
    present[zones[i].domain] = 1;
  }
}

void show_power_info(int core)
{ int fd;
  long long result;
  double thermal_spec_power,minimum_power,maximum_power,time_window;



 /* Show package power info */

  fd=open_msr(core);
  result=read_msr(fd,MSR_PKG_POWER_INFO);

  thermal_spec_power=power_units*(double)(result&0x7fff);
  printf("Package thermal spec: %.3fW\n",thermal_spec_power);

  minimum_power=power_units*(double)((result>>16)&0x7fff);
  printf("Package minimum power: %.3fW\n",minimum_power);

  maximum_power=power_units*(double)((result>>32)&0x7fff);
  printf("Package maximum power: %.3fW\n",maximum_power);

  time_window=time_units*(double)((result>>48)&0x7fff);
  printf("Package maximum time window: %.6fs\n",time_window);

  close(fd);
}



void show_power_limit(int core)
{ int fd;
  long long result;


 /* Show package power limit */

  fd=open_msr(core);
  result=read_msr(fd,MSR_PKG_RAPL_POWER_LIMIT);

  printf("Package power limits are %s\n", (result >> 63) ? "locked" : "unlocked");
  double pkg_power_limit_1 = power_units*(double)((result>>0)&0x7FFF);
  double pkg_time_window_1 = time_units*(double)((result>>17)&0x007F);
  printf("Package power limit #1: %.3fW for %.6fs (%s, %s)\n", pkg_power_limit_1, pkg_time_window_1,
           (result & (1LL<<15)) ? "enabled" : "disabled",
           (result & (1LL<<16)) ? "clamped" : "not_clamped");
  double pkg_power_limit_2 = power_units*(double)((result>>32)&0x7FFF);
  double pkg_time_window_2 = time_units*(double)((result>>49)&0x007F);
  printf("Package power limit #2: %.3fW for %.6fs (%s, %s)\n", pkg_power_limit_2, pkg_time_window_2,
          (result & (1LL<<47)) ? "enabled" : "disabled",
          (result & (1LL<<48)) ? "clamped" : "not_clamped");

  printf("\n");

  close(fd);

}




void rapl_before(FILE * fp,int core)
{
  (void)fp; (void)core;
  rapl_snapshot(snap_before);
}

/* Prints "pkg,core,[gpu],[dram]" (a blank field for a domain this machine
 * does not have), the format the runners parse. */
void rapl_after(FILE * fp , int core)
{
  double after[RAPL_MAX_ZONES], e[4];
  int present[4];
  (void)core;
  rapl_snapshot(after);
  memcpy(snap_after, after, sizeof(snap_after));
  rapl_delta(snap_before, after, e, present);
  for (int d = 0; d < 4; d++) {
    if (present[d]) fprintf(fp, "%.18f", e[d]);
    if (d < 3) fprintf(fp, ",");
  }
}
