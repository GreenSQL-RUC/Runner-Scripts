#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <errno.h>
#include <inttypes.h>
#include <unistd.h>
#include <math.h>
#include <string.h>

#define MSR_RAPL_POWER_UNIT		0x606

/*
 * Platform specific RAPL Domains.
 * Note that PP1 RAPL Domain is supported on 062A only
 * And DRAM RAPL Domain is supported on 062D only
 */
/* Package RAPL Domain */
#define MSR_PKG_RAPL_POWER_LIMIT	0x610
#define MSR_PKG_ENERGY_STATUS		0x611
#define MSR_PKG_PERF_STATUS		0x613
#define MSR_PKG_POWER_INFO		0x614

/* PP0 RAPL Domain */
#define MSR_PP0_POWER_LIMIT		0x638
#define MSR_PP0_ENERGY_STATUS		0x639
#define MSR_PP0_POLICY			0x63A
#define MSR_PP0_PERF_STATUS		0x63B

/* PP1 RAPL Domain, may reflect to uncore devices */
#define MSR_PP1_POWER_LIMIT		0x640
#define MSR_PP1_ENERGY_STATUS		0x641
#define MSR_PP1_POLICY			0x642

/* DRAM RAPL Domain */
#define MSR_DRAM_POWER_LIMIT		0x618
#define MSR_DRAM_ENERGY_STATUS		0x619
#define MSR_DRAM_PERF_STATUS		0x61B
#define MSR_DRAM_POWER_INFO		0x61C

/* RAPL UNIT BITMASK */
#define POWER_UNIT_OFFSET	0
#define POWER_UNIT_MASK		0x0F

#define ENERGY_UNIT_OFFSET	0x08
#define ENERGY_UNIT_MASK	0x1F00

#define TIME_UNIT_OFFSET	0x10
#define TIME_UNIT_MASK		0xF000




/* Energy is read from every CPU package (socket) and summed per domain, from
 * the kernel's powercap interface (/sys/class/powercap/intel-rapl:*) when it is
 * readable, else straight from the MSRs. Domains, in CSV order:
 * 0 package, 1 core (PP0), 2 gpu/uncore (PP1), 3 dram.
 * AMD (Zen, family 17h+): package from powercap (or MSR 0xC001029B), and core
 * as the SUM of every physical core's own counter (MSR 0xC001029A, one per
 * core; the kernel's powercap "core" zone reads only the first core, so it is
 * not used). No gpu or dram domain on AMD. */
#define RAPL_MAX_ZONES 512   /* AMD: one zone per physical core (2 x 64-core EPYC = 128) */

int open_msr(int core);
long long read_msr(int fd, int which);
int detect_cpu(void) ;
int rapl_init(int core);
void show_power_info(int core);
void show_power_limit(int core);
void rapl_before (FILE * , int);
void rapl_after  (FILE * , int);

/* Snapshot / delta interface (for readings outside rapl_before/after, such as
 * an idle baseline). raw[] holds RAPL_MAX_ZONES counter values; the delta
 * corrects each counter's wrap and sums zones into the four domains. */
void rapl_snapshot(double raw[RAPL_MAX_ZONES]);
void rapl_delta(const double a[RAPL_MAX_ZONES], const double b[RAPL_MAX_ZONES],
                double out[4], int present[4]);
int rapl_packages(void);
const char *rapl_describe(void);

/* psys: the platform energy the board reports (Skylake+ laptops, Sapphire
 * Rapids+ servers; on the CloudLab c6620 well above package + dram, so the
 * board, its regulators and more). What it covers is the board maker's
 * choice, and it often counts in whole joules. Kept apart from the four
 * domains above. rapl_psys_read gives the cumulative counter in joules (0, or
 * -1 when this machine has no psys zone); rapl_psys_delta corrects a wrap. */
int rapl_psys_read(double *joules);
double rapl_psys_delta(double before, double after);
