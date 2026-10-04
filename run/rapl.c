#include "rapl.h"
#include <dirent.h>


int cpu_model;
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

#define CPU_SANDYBRIDGE   42
#define CPU_SANDYBRIDGE_EP  45
#define CPU_IVYBRIDGE   58
#define CPU_IVYBRIDGE_EP  62
#define CPU_HASWELL   60
#define CPU_HASWELL2   69
#define CPU_HASWELL3   70
#define CPU_HASWELL_EP   63
#define CPU_SKYLAKE1   78
#define CPU_SKYLAKE2   94
#define CPU_BROADWELL  77
#define CPU_BROADWELL2  79
#define CPU_KABYLAKE 158

int detect_cpu(void) {

	FILE *fff;

	int family,model=-1;
	char buffer[BUFSIZ],*result;
	char vendor[BUFSIZ];

	fff=fopen("/proc/cpuinfo","r");
	if (fff==NULL) return -1;

	while(1) {
		result=fgets(buffer,BUFSIZ,fff);
		if (result==NULL) break;

		if (!strncmp(result,"vendor_id",8)) {
			sscanf(result,"%*s%*s%s",vendor);

			if (strncmp(vendor,"GenuineIntel",12)) {
				printf("%s not an Intel chip\n",vendor);
        fclose(fff);
				return -1;
			}
		}

		if (!strncmp(result,"cpu family",10)) {
			sscanf(result,"%*s%*s%*s%d",&family);
			if (family!=6) {
				printf("Wrong CPU family %d\n",family);
        fclose(fff);
				return -1;
			}
		}

		if (!strncmp(result,"model",5)) {
			sscanf(result,"%*s%*s%d",&model);
		}

	}

	fclose(fff);
/**
	switch(model) {
		case CPU_SANDYBRIDGE:
			printf("Found Sandybridge CPU\n");
			break;
		case CPU_SANDYBRIDGE_EP:
			printf("Found Sandybridge-EP CPU\n");
			break;
		case CPU_IVYBRIDGE:
			printf("Found Ivybridge CPU\n");
			break;
		case CPU_IVYBRIDGE_EP:
			printf("Found Ivybridge-EP CPU\n");
			break;
    case CPU_HASWELL:
      printf("Found Haswell CPU\n");
      break;
    case CPU_HASWELL2:
      printf("Found Haswell2 CPU\n");
      break;
    case CPU_HASWELL3:
      printf("Found Haswell3 CPU\n");
      break;
    case CPU_HASWELL_EP:
      printf("Found Haswell_EP CPU\n");
      break;
    case CPU_SKYLAKE1:
      printf("Found SKYLAKE1 CPU\n");
      break;
    case CPU_SKYLAKE2:
      printf("Found SKYLAKE2 CPU\n");
      break;
    case CPU_BROADWELL:
      printf("Found BROADWELL CPU\n");
      break;
    case CPU_BROADWELL2:
      printf("Found BROADWELL2 CPU\n");
      break;
    case CPU_KABYLAKE:
      printf("Found KABYLAKE CPU\n");
      break;
		default:	printf("Unsupported model %d\n",model);
				//model=-1;
				break;
	}
**/
	return model;
}






/* ------------------------------------------------------------------ */
/* Zones: one energy counter each, summed into the four domains        */
/* ------------------------------------------------------------------ */

enum { D_PKG = 0, D_CORE = 1, D_GPU = 2, D_DRAM = 3 };

typedef struct {
  int domain;
  int is_msr;            /* 1 = read MSR `msr` on `cpu`; 0 = sysfs `path`  */
  char path[256];        /* powercap .../energy_uj                          */
  int cpu, msr;
  double unit;           /* joules per MSR count                            */
  double range_j;        /* the counter wraps after this many joules         */
} rapl_zone;

static rapl_zone zones[RAPL_MAX_ZONES];
static int nzones = 0, npackages = 0;
static char describe_buf[256] = "not initialised";
static double snap_before[RAPL_MAX_ZONES];

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
    char fn[64];
    uint64_t data;
    snprintf(fn, sizeof(fn), "/dev/cpu/%d/msr", z->cpu);
    int fd = open(fn, O_RDONLY);
    if (fd < 0) return -1;
    int ok = pread(fd, &data, sizeof data, z->msr) == sizeof data;
    close(fd);
    if (!ok) return -1;
    *joules = (double)(data & 0xffffffffULL) * z->unit;
  } else {
    char buf[64];
    if (read_text(z->path, buf, sizeof(buf)) != 0) return -1;
    *joules = strtod(buf, NULL) * 1e-6;
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
  struct dirent *e;
  while ((e = readdir(d)) != NULL) {
    int n, used = 0;
    if (sscanf(e->d_name, "intel-rapl:%d%n", &n, &used) != 1 || e->d_name[used] != '\0') continue;
    char zdir[96], name[64], buf[64], p[256];
    snprintf(zdir, sizeof(zdir), "%s/intel-rapl:%d", base, n);
    snprintf(p, sizeof(p), "%s/name", zdir);
    if (read_text(p, name, sizeof(name)) != 0) continue;
    int top_domain = !strncmp(name, "package-", 8) ? D_PKG : !strcmp(name, "dram") ? D_DRAM : -1;
    if (top_domain < 0) continue;

    rapl_zone z; memset(&z, 0, sizeof(z));
    z.domain = top_domain;
    snprintf(z.path, sizeof(z.path), "%s/energy_uj", zdir);
    snprintf(p, sizeof(p), "%s/max_energy_range_uj", zdir);
    z.range_j = read_text(p, buf, sizeof(buf)) == 0 ? strtod(buf, NULL) * 1e-6 : 0;
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
      memset(&z, 0, sizeof(z));
      z.domain = dom;
      snprintf(z.path, sizeof(z.path), "%s/energy_uj", sdir);
      snprintf(p, sizeof(p), "%s/max_energy_range_uj", sdir);
      z.range_j = read_text(p, buf, sizeof(buf)) == 0 ? strtod(buf, NULL) * 1e-6 : 0;
      add_zone(&z);
    }
  }
  closedir(d);
  return npackages > 0 ? 0 : -1;
}

/* MSR fallback (Intel only): the first CPU of every package, found from the
 * sysfs topology. PP1 and DRAM are read on the models the original code knew,
 * plus DRAM (in its fixed unit) on server Xeons. */
static int init_msr(void) {
  int first_cpu[64], pkg_id[64], np = 0;
  for (int c = 0; c < 4096 && np < 64; c++) {
    char p[96], buf[32];
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d", c);
    if (access(p, F_OK) != 0) break;
    snprintf(p, sizeof(p), "/sys/devices/system/cpu/cpu%d/topology/physical_package_id", c);
    if (read_text(p, buf, sizeof(buf)) != 0) continue;           /* offline cpu */
    int id = atoi(buf), seen = 0;
    for (int i = 0; i < np; i++) if (pkg_id[i] == id) seen = 1;
    if (!seen) { pkg_id[np] = id; first_cpu[np] = c; np++; }
  }
  if (np == 0) { first_cpu[0] = 0; np = 1; }

  int fd = open_msr(first_cpu[0]);
  long long result = read_msr(fd, MSR_RAPL_POWER_UNIT);
  close(fd);
  power_units = pow(0.5, (double)(result & 0xf));
  energy_units = pow(0.5, (double)((result >> 8) & 0x1f));
  time_units = pow(0.5, (double)((result >> 16) & 0xf));

  int client_pp1 = (cpu_model == CPU_SANDYBRIDGE) || (cpu_model == CPU_IVYBRIDGE) || (cpu_model == CPU_HASWELL);
  int old_dram = (cpu_model == CPU_SANDYBRIDGE_EP) || (cpu_model == CPU_IVYBRIDGE_EP) || (cpu_model == CPU_HASWELL);
  int fixed_dram = dram_fixed_unit(cpu_model);
  for (int i = 0; i < np; i++) {
    rapl_zone z; memset(&z, 0, sizeof(z));
    z.is_msr = 1; z.cpu = first_cpu[i]; z.unit = energy_units;
    z.range_j = 4294967296.0 * energy_units;
    z.domain = D_PKG;  z.msr = MSR_PKG_ENERGY_STATUS; if (add_zone(&z) != 0) return -1;
    z.domain = D_CORE; z.msr = MSR_PP0_ENERGY_STATUS; add_zone(&z);
    if (client_pp1) { z.domain = D_GPU; z.msr = MSR_PP1_ENERGY_STATUS; add_zone(&z); }
    if (old_dram || fixed_dram) {
      z.domain = D_DRAM; z.msr = MSR_DRAM_ENERGY_STATUS;
      if (fixed_dram) { z.unit = pow(0.5, 16); z.range_j = 4294967296.0 * z.unit; }
      add_zone(&z);
    }
  }
  npackages = np;
  return 0;
}

int rapl_init(int core)
{
  (void)core;   /* every package is read now; kept for the old call sites */
  nzones = npackages = 0;
  const char *backend = "powercap";
  if (init_powercap() != 0) {
    nzones = npackages = 0;
    backend = "msr";
    cpu_model = detect_cpu();
    if (cpu_model < 0) {
      printf("Unsupported CPU type (no readable powercap RAPL zones, and not an Intel CPU for the MSR path)\n");
      return -1;
    }
    if (init_msr() != 0) return -1;
  }

  int present[4] = {0, 0, 0, 0};
  for (int i = 0; i < nzones; i++) present[zones[i].domain] = 1;
  snprintf(describe_buf, sizeof(describe_buf), "%s, %d package%s, domains:%s%s%s%s",
           backend, npackages, npackages == 1 ? "" : "s",
           present[D_PKG] ? " pkg" : "", present[D_CORE] ? " core" : "",
           present[D_GPU] ? " gpu/uncore" : "", present[D_DRAM] ? " dram" : "");
  return 0;
}

int rapl_packages(void) { return npackages; }
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
  rapl_delta(snap_before, after, e, present);
  for (int d = 0; d < 4; d++) {
    if (present[d]) fprintf(fp, "%.18f", e[d]);
    if (d < 3) fprintf(fp, ",");
  }
}
