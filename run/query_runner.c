#define _GNU_SOURCE
/*
 * query_runner.c - the WARM benchmark runner.
 *
 * For every .sql file under QUERY_DIR (or the single file QUERY_DIR names):
 *
 *   [thermal equalisation]   optional, OFF by default (THERMAL_EQUALISE)
 *   WARMUP     unmeasured single-copy runs (the first primes the cache)
 *   step-up    for each N in BATCH_SIZES: RUNS measured batches, where a batch
 *              is N copies of the query concatenated into ONE psql process
 *
 * Every batch is timed (monotonic wall clock), bracketed by RAPL energy
 * counters, and sampled by a background thread for package/core temperature,
 * CPU frequency and thermal-throttle counts. Each batch writes one row to the
 * timing CSV; each copy inside it writes one row to the samples CSV with the
 * server-side figures parsed from the copy's EXPLAIN (ANALYZE, BUFFERS) output.
 * So the query files MUST be written as "EXPLAIN (ANALYZE, ...) <statement>"
 * (the generators and fetch_sqlstorm_queries.sh do this) or the server-side
 * columns come back empty.
 *
 * The per-query cold start (cache drop + cluster restart) is NOT done here: the
 * warm step-up driver (run_warm_stepup.sh) does it and then invokes this runner
 * on one file at a time. Cold-cache measurement is cold_runner.c.
 *
 * CSVs (all under LOGS_DIR, one set per database, appended; a new column
 * layout refuses to append to an old file rather than corrupt it):
 *   query_timing_<db>.csv    one row per BATCH: wall, server sum, client
 *                            overhead, rusage, RAPL joules, thermal/clock state
 *   query_samples_<db>.csv   one row per COPY: planning/execution ms, plan
 *                            shape, buffers, relations
 *   query_catalog_<db>.csv   relation sizes, once per invocation (SKIP_CATALOG=1
 *                            skips it; the step-up driver snapshots once)
 *
 * Configuration (environment variables; the Makefile sets them, see
 * print_config for the full list):
 *   QUERY_DIR DB_NAME DB_USER PGPORT WORKERS STATEMENT_TIMEOUT LOGS_DIR
 *   WARMUP BATCH_SIZES RUNS RUN_ID SKIP_CATALOG
 *   THERMAL_EQUALISE T_LO T_HI PREHEAT_MAX_S COOLDOWN_MAX_S PREHEAT_S
 *   BATCH_CAP_SLOW SLOW_COPY_SEC PREV_END_EPOCH SIGLESS_ADDR SIGLESS_CHANNEL ROOT
 */

#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <dirent.h>
#include <time.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <limits.h>
#include <pthread.h>
#include <sys/wait.h>
#include <sys/resource.h>

#include "rapl.h"

/* ------------------------------------------------------------------ */
/* Defaults (override with the matching environment variable)          */
/* ------------------------------------------------------------------ */
#define DEFAULT_QUERY_DIR   "queries/tpch/tpch-queries"
#define DEFAULT_LOGS_DIR    "logs"
#define DEFAULT_DB_NAME     "tpch"
#define DEFAULT_DB_USER     "postgres"
#define DEFAULT_WARMUP      2
#define DEFAULT_RUNS        1
#define DEFAULT_BATCH_SIZES "1"
#define MAX_BATCH           1024     /* copies per batch (the brief says never > 16) */
#define MAX_SIZES           64
#define RAPL_CORE           0        /* CPU core whose MSRs we read energy from */
#define SAMPLE_INTERVAL_MS  200      /* thermal/clock sampler period            */

#define MAX_QUERIES 32768
#define MAX_CMD     (2 * PATH_MAX + 512)
#define MAX_CPUS    256

/* ================================================================== */
/* Small helpers                                                       */
/* ================================================================== */

/* Monotonic seconds (immune to clock changes) - for durations. */
static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Wall-clock epoch seconds - for idle gaps that span processes. */
static double now_epoch(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void utc_timestamp(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
    if (gmtime_r(&t, &tm_utc) == NULL) { if (buf_size) buf[0] = '\0'; return; }
    strftime(buf, buf_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

static int env_int(const char *name, int fallback) {
    const char *v = getenv(name);
    return (v && *v) ? atoi(v) : fallback;
}

static double env_double(const char *name, double fallback) {
    const char *v = getenv(name);
    return (v && *v) ? atof(v) : fallback;
}

static int env_flag(const char *name) {
    const char *v = getenv(name);
    return v && *v && strcmp(v, "0") != 0 && strcasecmp(v, "off") != 0 && strcasecmp(v, "no") != 0;
}

/* Non-negative integer or exit: everything spliced into a shell line passes here. */
static long require_uint(const char *name, const char *value) {
    char *end;
    long n = strtol(value, &end, 10);
    if (*end != '\0' || n < 0) {
        fprintf(stderr, "%s must be a non-negative integer, got \"%s\"\n", name, value);
        exit(1);
    }
    return n;
}

static int read_first_line(const char *path, char *buf, size_t buf_size) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    if (!fgets(buf, (int)buf_size, f)) { fclose(f); return -1; }
    fclose(f);
    buf[strcspn(buf, "\r\n")] = '\0';
    return 0;
}

static long read_long_file(const char *path, long fallback) {
    char buf[64];
    if (read_first_line(path, buf, sizeof(buf)) != 0) return fallback;
    char *end;
    long v = strtol(buf, &end, 10);
    return (end == buf) ? fallback : v;
}

/* CSV field for a double: "%.<prec>f", or empty for NAN. */
static const char *fmt_num(double v, int prec, char *buf, size_t buf_size) {
    if (isnan(v)) { buf[0] = '\0'; return buf; }
    snprintf(buf, buf_size, "%.*f", prec, v);
    return buf;
}

/* A 16-hex id shared by every row of one invocation. RUN_ID in the environment
 * overrides it, so a driver can pre-assign ids (and record predecessors). */
static void make_run_id(char *buf, size_t buf_size) {
    const char *given = getenv("RUN_ID");
    if (given && *given) {
        size_t n = 0;
        for (const char *p = given; *p && n + 1 < buf_size; p++)
            if (*p != ',' && *p != ' ' && *p != '\n') buf[n++] = *p;
        buf[n] = '\0';
        if (n) return;
    }
    unsigned char raw[8];
    FILE *urandom = fopen("/dev/urandom", "rb");
    if (!urandom || fread(raw, 1, sizeof(raw), urandom) != sizeof(raw)) {
        uint64_t seed = (uint64_t)time(NULL) ^ ((uint64_t)getpid() << 32);
        for (size_t i = 0; i < sizeof(raw); i++) {
            seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
            raw[i] = (unsigned char)(seed >> 56);
        }
    }
    if (urandom) fclose(urandom);
    snprintf(buf, buf_size, "%02X%02X%02X%02X%02X%02X%02X%02X",
             raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7]);
}

/* ================================================================== */
/* psql invocation                                                     */
/* ================================================================== */
/*
 * The "env PGPORT=N PGOPTIONS='...'" fragment between `sudo -u USER` and
 * `psql`: PGPORT selects the cluster (= the PostgreSQL major), WORKERS caps
 * max_parallel_workers_per_gather for every query, STATEMENT_TIMEOUT (seconds)
 * has the SERVER cancel a runaway execution so an unattended sweep moves on.
 */
static const char *build_psql_env_prefix(const char *port, const char *workers,
                                         const char *stmt_timeout) {
    static char buf[256];
    char port_part[48] = "";
    char opts[160] = "";
    size_t n = 0;

    if (port && *port)
        snprintf(port_part, sizeof(port_part), "PGPORT=%ld ", require_uint("PGPORT", port));
    if (workers && *workers)
        n += snprintf(opts + n, sizeof(opts) - n, "%s-c max_parallel_workers_per_gather=%ld",
                      n ? " " : "", require_uint("WORKERS", workers));
    if (stmt_timeout && *stmt_timeout)
        n += snprintf(opts + n, sizeof(opts) - n, "%s-c statement_timeout=%ld000",
                      n ? " " : "", require_uint("STATEMENT_TIMEOUT", stmt_timeout));

    if (!*port_part && !n) buf[0] = '\0';
    else if (!n) snprintf(buf, sizeof(buf), "env %s", port_part);
    else snprintf(buf, sizeof(buf), "env %sPGOPTIONS='%s' ", port_part, opts);
    return buf;
}

/* The server's version, stamped on every row so majors never mix silently. */
static const char *query_pg_version(const char *env_prefix, const char *db_user,
                                    const char *db_name) {
    static char buf[64] = "unknown";
    char cmd[MAX_CMD];
    int n = snprintf(cmd, sizeof(cmd),
                     "sudo -n -u %s %spsql -d %s -tAc \"SHOW server_version\" 2>/dev/null",
                     db_user, env_prefix, db_name);
    if (n <= 0 || n >= (int)sizeof(cmd)) return buf;
    FILE *p = popen(cmd, "r");
    if (!p) return buf;
    char line[64];
    if (fgets(line, sizeof(line), p)) {
        line[strcspn(line, "\r\n, ")] = '\0';   /* "16.14 (Ubuntu ...)" -> "16.14" */
        if (*line) snprintf(buf, sizeof(buf), "%s", line);
    }
    pclose(p);
    return buf;
}

/* ================================================================== */
/* Sensors: package/core temperature, CPU frequency, throttle counts   */
/* ================================================================== */
/*
 * All read from sysfs (no turbostat, no root needed for reading):
 *   package temp   coretemp hwmon "Package id 0" (fallback: x86_pkg_temp zone)
 *   core temps     the other coretemp inputs ("Core N")
 *   frequency      cpuN/cpufreq/scaling_cur_freq (kHz)
 *   throttling     cpuN/thermal_throttle/{core,package}_throttle_count
 * Discovered once; anything missing just leaves its column empty.
 */
typedef struct {
    char pkg_temp[PATH_MAX];
    char core_temp[MAX_CPUS][PATH_MAX]; int n_core_temp;
    char cur_freq[MAX_CPUS][PATH_MAX];  int n_cur_freq;
    char core_thr[MAX_CPUS][PATH_MAX];  int n_core_thr;
    char pkg_thr[MAX_CPUS][PATH_MAX];   int n_pkg_thr;
} sensors_t;

static sensors_t S;

static void discover_sensors(void) {
    char name[64], label[64], path[PATH_MAX], fallback[PATH_MAX] = "";
    memset(&S, 0, sizeof(S));

    for (int h = 0; h < 64; h++) {
        snprintf(path, sizeof(path), "/sys/class/hwmon/hwmon%d/name", h);
        if (read_first_line(path, name, sizeof(name)) != 0) continue;
        if (strcmp(name, "coretemp") != 0) continue;
        for (int t = 1; t < 64; t++) {
            snprintf(path, sizeof(path), "/sys/class/hwmon/hwmon%d/temp%d_input", h, t);
            if (access(path, R_OK) != 0) continue;
            if (!*fallback) snprintf(fallback, sizeof(fallback), "%s", path);
            char lpath[PATH_MAX];
            snprintf(lpath, sizeof(lpath), "/sys/class/hwmon/hwmon%d/temp%d_label", h, t);
            if (read_first_line(lpath, label, sizeof(label)) == 0 && strncmp(label, "Package id", 10) == 0) {
                if (!*S.pkg_temp) snprintf(S.pkg_temp, sizeof(S.pkg_temp), "%s", path);
            } else if (S.n_core_temp < MAX_CPUS) {
                snprintf(S.core_temp[S.n_core_temp++], PATH_MAX, "%s", path);
            }
        }
    }
    for (int z = 0; z < 64 && !*S.pkg_temp; z++) {
        snprintf(path, sizeof(path), "/sys/class/thermal/thermal_zone%d/type", z);
        if (read_first_line(path, name, sizeof(name)) != 0) continue;
        if (strcmp(name, "x86_pkg_temp") == 0)
            snprintf(S.pkg_temp, sizeof(S.pkg_temp), "/sys/class/thermal/thermal_zone%d/temp", z);
    }
    if (!*S.pkg_temp && *fallback) snprintf(S.pkg_temp, sizeof(S.pkg_temp), "%s", fallback);

    for (int c = 0; c < MAX_CPUS; c++) {
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d", c);
        if (access(path, F_OK) != 0) break;
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_cur_freq", c);
        if (access(path, R_OK) == 0) snprintf(S.cur_freq[S.n_cur_freq++], PATH_MAX, "%s", path);
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/thermal_throttle/core_throttle_count", c);
        if (access(path, R_OK) == 0) snprintf(S.core_thr[S.n_core_thr++], PATH_MAX, "%s", path);
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/thermal_throttle/package_throttle_count", c);
        if (access(path, R_OK) == 0) snprintf(S.pkg_thr[S.n_pkg_thr++], PATH_MAX, "%s", path);
    }
}

/* Package temperature in C, or NAN. */
static double read_pkg_temp_c(void) {
    if (!*S.pkg_temp) return NAN;
    long milli = read_long_file(S.pkg_temp, LONG_MIN);
    return milli == LONG_MIN ? NAN : milli / 1000.0;
}

/* Hottest core right now in C, or NAN. */
static double read_core_temp_max_c(void) {
    double mx = NAN;
    for (int i = 0; i < S.n_core_temp; i++) {
        long milli = read_long_file(S.core_temp[i], LONG_MIN);
        if (milli == LONG_MIN) continue;
        double c = milli / 1000.0;
        if (isnan(mx) || c > mx) mx = c;
    }
    return mx;
}

/* Mean scaling_cur_freq over all cpus, in MHz, or NAN. */
static double read_mhz_mean(void) {
    double sum = 0; int n = 0;
    for (int i = 0; i < S.n_cur_freq; i++) {
        long khz = read_long_file(S.cur_freq[i], LONG_MIN);
        if (khz == LONG_MIN) continue;
        sum += khz / 1000.0; n++;
    }
    return n ? sum / n : NAN;
}

/* Sum of throttle counters over all cpus (-1 when unavailable). */
static long read_throttle_sum(char paths[][PATH_MAX], int n) {
    if (n == 0) return -1;
    long sum = 0;
    for (int i = 0; i < n; i++) sum += read_long_file(paths[i], 0);
    return sum;
}

/* ------------------------------------------------------------------ */
/* Background sampler: runs while a batch executes                     */
/* ------------------------------------------------------------------ */
typedef struct {
    pthread_t thread;
    volatile int stop;
    int    n;                    /* samples taken                      */
    double pkg_sum, pkg_max;
    double core_max;
    double mhz_sum; int mhz_n;
} sampler_t;

static void *sampler_main(void *arg) {
    sampler_t *s = (sampler_t *)arg;
    struct timespec period = { 0, SAMPLE_INTERVAL_MS * 1000000L };
    while (!s->stop) {
        double t = read_pkg_temp_c();
        if (!isnan(t)) {
            if (s->n == 0 || t > s->pkg_max) s->pkg_max = t;
            s->pkg_sum += t; s->n++;
        }
        double c = read_core_temp_max_c();
        if (!isnan(c) && (isnan(s->core_max) || c > s->core_max)) s->core_max = c;
        double m = read_mhz_mean();
        if (!isnan(m)) { s->mhz_sum += m; s->mhz_n++; }
        nanosleep(&period, NULL);
    }
    return NULL;
}

static void sampler_start(sampler_t *s) {
    memset(s, 0, sizeof(*s));
    s->core_max = NAN;
    if (pthread_create(&s->thread, NULL, sampler_main, s) != 0) s->stop = 1;
}

static void sampler_stop(sampler_t *s) {
    if (s->stop) return;         /* never started */
    s->stop = 1;
    pthread_join(s->thread, NULL);
}

/* ------------------------------------------------------------------ */
/* Thermal equalisation (OFF by default)                               */
/* ------------------------------------------------------------------ */
/*
 * Make every measured group start from the same thermal state. Modes:
 *   off   nothing (default)
 *   gate  T < T_LO -> all-core burn in 5 s slices until T >= T_LO or PREHEAT_MAX_S
 *         T > T_HI -> sleep in 2 s slices until T <= T_HI or COOLDOWN_MAX_S
 *   burn  a fixed PREHEAT_S all-core burn (constant hot start; the fallback
 *         when no sensor is available)
 * The burn is a fork-per-CPU busy loop, so nothing external is needed.
 */
typedef enum { THERMAL_OFF = 0, THERMAL_GATE, THERMAL_BURN } thermal_mode;

typedef struct {
    thermal_mode mode;
    double t_lo, t_hi, preheat_max_s, cooldown_max_s, preheat_s;
} thermal_cfg;

static void burn_all_cores(double seconds) {
    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    if (ncpu < 1) ncpu = 1;
    pid_t pids[MAX_CPUS];
    int n = 0;
    for (long c = 0; c < ncpu && n < MAX_CPUS; c++) {
        pid_t pid = fork();
        if (pid < 0) break;
        if (pid == 0) {
            double deadline = now_sec() + seconds;
            volatile double x = 1.0;
            while (now_sec() < deadline) for (int i = 0; i < 100000; i++) x = x * 1.000001 + 0.5;
            _exit(0);
        }
        pids[n++] = pid;
    }
    for (int i = 0; i < n; i++) waitpid(pids[i], NULL, 0);
}

/* Returns the seconds spent pre-heating / waiting through the two out params. */
static void thermal_equalise(const thermal_cfg *cfg, double *preheat_s, double *cooldown_s) {
    *preheat_s = 0; *cooldown_s = 0;
    if (cfg->mode == THERMAL_OFF) return;

    if (cfg->mode == THERMAL_BURN) {
        double t0 = now_sec();
        burn_all_cores(cfg->preheat_s);
        *preheat_s = now_sec() - t0;
        return;
    }

    double t = read_pkg_temp_c();
    if (isnan(t)) { fprintf(stderr, "  thermal gate: no package sensor; skipping\n"); return; }
    double t0 = now_sec();
    if (t < cfg->t_lo) {
        while (t < cfg->t_lo && now_sec() - t0 < cfg->preheat_max_s) {
            burn_all_cores(5.0);
            t = read_pkg_temp_c();
        }
        *preheat_s = now_sec() - t0;
        printf("  thermal gate: pre-heated %.0fs -> %.1f C\n", *preheat_s, t);
    } else if (t > cfg->t_hi) {
        while (t > cfg->t_hi && now_sec() - t0 < cfg->cooldown_max_s) {
            sleep(2);
            t = read_pkg_temp_c();
        }
        *cooldown_s = now_sec() - t0;
        printf("  thermal gate: waited %.0fs -> %.1f C\n", *cooldown_s, t);
    }
    fflush(stdout);
}

/* ================================================================== */
/* RAPL: one before/after reading as accumulable numbers               */
/* ================================================================== */

static int is_blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\t' && *s != '\r' && *s != '\n') return 0;
    return 1;
}

/* rapl_after() prints "pkg,core,[gpu],[dram]"; capture and parse it. present[]
 * records which domains this CPU has so the CSV can leave the others blank. */
static void rapl_after_capture(int core, double d[4], int present[4]) {
    for (int i = 0; i < 4; i++) { d[i] = 0.0; present[i] = 0; }
    char *buf = NULL; size_t len = 0;
    FILE *ms = open_memstream(&buf, &len);
    if (!ms) return;
    rapl_after(ms, core);
    fclose(ms);
    if (!buf) return;
    int i = 0; char *tok = buf, *comma;
    while (i < 4) {
        comma = strchr(tok, ',');
        if (comma) *comma = '\0';
        if (!is_blank(tok)) { d[i] = atof(tok); present[i] = 1; }
        i++;
        if (!comma) break;
        tok = comma + 1;
    }
    free(buf);
}

static void write_energy_columns(FILE *out, const double e[4], const int present[4]) {
    fprintf(out, "%.18f,%.18f,", e[0], e[1]);
    if (present[2]) fprintf(out, "%.18f", e[2]);
    fprintf(out, ",");
    if (present[3]) fprintf(out, "%.18f", e[3]);
}

/* ================================================================== */
/* Per-copy profile, parsed from the EXPLAIN output                    */
/* ================================================================== */
/*
 * A batch is one `sudo psql -f file` process running N copies; for a fast
 * query most of the wall time is process/connection overhead, not the SQL.
 * Every copy's own server figures are parsed out of its plan so the two can
 * be separated afterwards:
 *   - planning/execution ms from the SUMMARY lines
 *   - buffers (shared hit/read/..., temp) from BUFFERS
 *   - plan shape / work size: node counts, actual rows x loops, width bytes,
 *     the relations scanned - what makes runs comparable across scale factors
 */
#define MAX_RELATIONS_LEN 480

typedef struct {
    double planning_ms;      /* < 0 when the copy emitted no SUMMARY */
    double execution_ms;
    double user_cpu_sec;     /* client process tree only (from wait4) */
    double sys_cpu_sec;
    long   max_rss_kb;
    long   shared_hit, shared_read, shared_dirtied, shared_written;
    long   temp_read, temp_written;
    int    have_buffers;
    long      plan_nodes, scan_nodes;
    long long rows_out, rows_estimated, rows_processed, bytes_processed, rows_removed_filter;
    long      workers_launched;
    int       have_plan;
    char      relations[MAX_RELATIONS_LEN];  /* ';'-separated, deduped */
} run_profile;

static void profile_reset(run_profile *pr) {
    memset(pr, 0, sizeof(*pr));
    pr->planning_ms = pr->execution_ms = -1.0;
}

static void add_relation(run_profile *pr, const char *start) {
    char name[64]; size_t i = 0;
    while (start[i] && start[i] != ' ' && start[i] != '(' && start[i] != ','
           && start[i] != '\n' && start[i] != '\r' && i < sizeof(name) - 1) { name[i] = start[i]; i++; }
    name[i] = '\0';
    if (i == 0) return;
    for (const char *t = pr->relations; *t; ) {           /* already present? */
        const char *end = strchr(t, ';');
        size_t len = end ? (size_t)(end - t) : strlen(t);
        if (len == i && strncmp(t, name, i) == 0) return;
        if (!end) break;
        t = end + 1;
    }
    size_t used = strlen(pr->relations);
    if (used + (used ? 1 : 0) + i + 1 > sizeof(pr->relations)) return;
    if (used) pr->relations[used++] = ';';
    memcpy(pr->relations + used, name, i + 1);
}

/* One plan-node line: "->  Seq Scan on lineitem l  (cost=.. rows=N width=W) (actual rows=R loops=L)".
 * actual rows is PER LOOP, so the work done is rows x loops. */
static void parse_plan_node(const char *line, const char *cost, run_profile *pr) {
    pr->plan_nodes++;
    pr->have_plan = 1;
    if (strstr(line, "Scan")) pr->scan_nodes++;
    const char *er = strstr(cost, "rows=");   long long est   = er ? atoll(er + 5) : 0;
    const char *wp = strstr(cost, "width=");  long long width = wp ? atoll(wp + 6) : 0;
    long long arows = 0, loops = 1;
    const char *act = strstr(line, "(actual rows=");
    if (act) {
        arows = atoll(act + strlen("(actual rows="));
        const char *lp = strstr(act, "loops=");
        if (lp) loops = atoll(lp + 6);
        if (loops < 1) loops = 1;
    }
    if (pr->plan_nodes == 1) { pr->rows_out = arows * loops; pr->rows_estimated = est; }
    pr->rows_processed  += arows * loops;
    pr->bytes_processed += arows * loops * width;
    const char *on = strstr(line, " on ");
    if (on) add_relation(pr, on + 4);
}

static long field_after(const char *s, const char *key) {
    const char *k = s ? strstr(s, key) : NULL;
    return k ? atol(k + strlen(key)) : 0;
}

/* "Buffers: shared hit=N read=N ..., temp read=N written=N" (first line per plan). */
static void parse_buffers_line(const char *p, run_profile *pr) {
    pr->have_buffers = 1;
    char shared_part[8192];
    snprintf(shared_part, sizeof(shared_part), "%s", p);
    char *temp_part = strstr(shared_part, "temp ");
    if (temp_part) *temp_part++ = '\0';
    if (strstr(shared_part, "shared ")) {
        pr->shared_hit     = field_after(shared_part, "hit=");
        pr->shared_read    = field_after(shared_part, "read=");
        pr->shared_dirtied = field_after(shared_part, "dirtied=");
        pr->shared_written = field_after(shared_part, "written=");
    }
    if (temp_part) {
        pr->temp_read    = field_after(temp_part, "read=");
        pr->temp_written = field_after(temp_part, "written=");
    }
}

/* A batch's captured output is N plans back to back; "Execution Time:" (the
 * last SUMMARY line) closes each copy. Returns copies stored (<= max_copies). */
static int parse_batch(const char *path, run_profile *profiles, int max_copies) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int n = 0;
    run_profile cur; profile_reset(&cur);
    char line[8192];
    while (fgets(line, sizeof(line), f)) {
        const char *p;
        const char *cost = strstr(line, "(cost=");
        if (cost) parse_plan_node(line, cost, &cur);
        if ((p = strstr(line, "Planning Time:")) != NULL) {
            cur.planning_ms = atof(p + strlen("Planning Time:"));
        } else if ((p = strstr(line, "Execution Time:")) != NULL) {
            cur.execution_ms = atof(p + strlen("Execution Time:"));
            if (n < max_copies) profiles[n] = cur;
            n++;
            profile_reset(&cur);
        } else if ((p = strstr(line, "Workers Launched:")) != NULL) {
            cur.workers_launched = atol(p + strlen("Workers Launched:"));
        } else if ((p = strstr(line, "Rows Removed by Filter:")) != NULL) {
            cur.rows_removed_filter += atoll(p + strlen("Rows Removed by Filter:"));
        } else if (!cur.have_buffers && (p = strstr(line, "Buffers:")) != NULL) {
            parse_buffers_line(p, &cur);
        }
    }
    fclose(f);
    return (n < max_copies) ? n : max_copies;
}

/* Run cmd via /bin/sh, returning its exit status and the child's rusage. */
static int run_once(const char *cmd, run_profile *pr) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) { execl("/bin/sh", "sh", "-c", cmd, (char *)NULL); _exit(127); }
    int status = 0; struct rusage ru; memset(&ru, 0, sizeof(ru));
    if (wait4(pid, &status, 0, &ru) < 0) return -1;
    pr->user_cpu_sec = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6;
    pr->sys_cpu_sec  = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
    pr->max_rss_kb   = ru.ru_maxrss;
    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* First ERROR:/FATAL:/psql: line of a captured output, so a failure says why. */
static void first_error(const char *path, char *buf, size_t buf_size) {
    if (buf_size) buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "ERROR:") || strstr(line, "FATAL:") || strstr(line, "psql:")) {
            line[strcspn(line, "\r\n")] = '\0';
            snprintf(buf, buf_size, "%s", line);
            break;
        }
    }
    fclose(f);
}

/* One copy's server-side columns (each followed by a comma). Blank, not zero,
 * when the copy produced no plan / no BUFFERS. */
static void write_copy_profile(FILE *out, const run_profile *pr) {
    if (pr->planning_ms >= 0)  fprintf(out, "%.3f,", pr->planning_ms);  else fprintf(out, ",");
    if (pr->execution_ms >= 0) fprintf(out, "%.3f,", pr->execution_ms); else fprintf(out, ",");
    if (pr->have_plan)
        fprintf(out, "%ld,%ld,%lld,%lld,%lld,%lld,%lld,%ld,%s,",
                pr->plan_nodes, pr->scan_nodes, pr->rows_out, pr->rows_processed,
                pr->rows_estimated, pr->bytes_processed, pr->rows_removed_filter,
                pr->workers_launched, pr->relations);
    else fprintf(out, ",,,,,,,,,");
    if (pr->have_buffers)
        fprintf(out, "%ld,%ld,%ld,%ld,%ld,%ld,", pr->shared_hit, pr->shared_read,
                pr->shared_dirtied, pr->shared_written, pr->temp_read, pr->temp_written);
    else fprintf(out, ",,,,,,");
}

/* ================================================================== */
/* CSV files                                                           */
/* ================================================================== */
/*
 * Column order is load-bearing: the analysis loaders read columns by name and
 * expect new ones APPENDED, never inserted. timestamp_utc is written at batch
 * END; elapsed_sec is the whole batch; rapl_*_j the whole batch.
 *
 * Thermal/clock columns (per batch): pkg_temp_start_c is the key state
 * variable (die temperature the batch started at); the mean and max are sampled
 * every 200 ms during the batch; mhz_mean is the mean scaling_cur_freq over
 * all cpus and samples; throttle_*_delta = throttle counter end - start
 * (non-zero = hard throttling happened); idle_before_s = wall time since the
 * previous batch ended (across processes via PREV_END_EPOCH); preheat_s /
 * cooldown_wait_s = what the equalisation step took before THIS query's first
 * batch (0 otherwise, 0 always when it is off); pkg_watts_mean = rapl_pkg_j /
 * elapsed_sec.
 */
#define HDR_LOG \
    "timestamp_utc,run_id,pg_version,query,phase,batch_index,batchnum,runs,warmup," \
    "elapsed_sec,avg_copy_elapsed_sec,server_sum_ms,client_overhead_sec," \
    "client_user_cpu_sec,client_sys_cpu_sec,client_max_rss_kb,failed," \
    "rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j," \
    "pkg_temp_start_c,pkg_temp_end_c,pkg_temp_mean_c,pkg_temp_max_c,core_temp_max_c," \
    "mhz_mean,throttle_core_delta,throttle_pkg_delta,idle_before_s,preheat_s," \
    "cooldown_wait_s,pkg_watts_mean\n"

#define HDR_SAMPLES \
    "timestamp_utc,run_id,pg_version,query,phase,batch_index,copy_index,batchnum,runs," \
    "server_planning_ms,server_execution_ms," \
    "plan_nodes,scan_nodes,rows_out,rows_processed," \
    "rows_estimated,bytes_processed,rows_removed_filter," \
    "workers_launched,relations," \
    "shared_hit_blks,shared_read_blks," \
    "shared_dirtied_blks,shared_written_blks," \
    "temp_read_blks,temp_written_blks,failed,pkg_temp_start_c,mhz_mean\n"

#define HDR_CATALOG \
    "timestamp_utc,run_id,pg_version,database,schema,relname," \
    "relkind,reltuples,relpages,heap_bytes,index_bytes,total_bytes\n"

/* Append, writing the header only for a new file. A header MISMATCH refuses:
 * these logs take hours to make, and mixing layouts corrupts every older row. */
static FILE *open_csv_append(const char *path, const char *header) {
    struct stat st;
    int is_new = (stat(path, &st) != 0 || st.st_size == 0);
    if (!is_new) {
        FILE *chk = fopen(path, "r");
        if (chk) {
            char have[8192], want[8192];
            if (fgets(have, sizeof(have), chk)) {
                have[strcspn(have, "\r\n")] = '\0';
                snprintf(want, sizeof(want), "%s", header);
                want[strcspn(want, "\r\n")] = '\0';
                if (strcmp(have, want) != 0) {
                    fclose(chk);
                    fprintf(stderr,
                        "\nREFUSING to append to %s\n"
                        "  Its header does not match what this build writes, so appending\n"
                        "  would mix two column layouts in one file.\n"
                        "    file says: %s\n"
                        "    we write : %s\n"
                        "  Move the old file aside (or use another LOGS_DIR), then re-run.\n\n",
                        path, have, want);
                    return NULL;
                }
            }
            fclose(chk);
        }
    }
    FILE *f = fopen(path, "a");
    if (!f) { perror(path); return NULL; }
    if (is_new) { fputs(header, f); fflush(f); }
    return f;
}

/* Relation sizes (rows, pages, bytes) once per invocation, so a measurement can
 * be normalised per row / per byte and compared across scale factors. */
static void write_catalog_snapshot(const char *catalog_file, const char *env_prefix,
                                   const char *db_user, const char *db_name,
                                   const char *pg_version, const char *run_id) {
    FILE *out = open_csv_append(catalog_file, HDR_CATALOG);
    if (!out) return;
    char cmd[MAX_CMD];
    int n = snprintf(cmd, sizeof(cmd),
        "sudo -n -u %s %spsql -d %s -tA -F',' -c \""
        "SELECT n.nspname, c.relname, c.relkind, c.reltuples::bigint, c.relpages, "
        "pg_relation_size(c.oid), pg_indexes_size(c.oid), pg_total_relation_size(c.oid) "
        "FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
        "WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast') "
        "AND c.relkind IN ('r','i','m','p') ORDER BY n.nspname, c.relname\" 2>/dev/null",
        db_user, env_prefix, db_name);
    if (n <= 0 || n >= (int)sizeof(cmd)) { fclose(out); return; }
    FILE *p = popen(cmd, "r");
    if (!p) { fclose(out); return; }
    char ts[32]; utc_timestamp(ts, sizeof(ts));
    char line[1024]; int rows = 0;
    while (fgets(line, sizeof(line), p)) {
        line[strcspn(line, "\r\n")] = '\0';
        if (!*line) continue;
        fprintf(out, "%s,%s,%s,%s,%s\n", ts, run_id, pg_version, db_name, line);
        rows++;
    }
    pclose(p);
    fclose(out);
    printf("Catalog snapshot: %d relations -> %s\n", rows, catalog_file);
    fflush(stdout);
}

/* Optional start/end markers to an external power meter (no-op unless
 * SIGLESS_ADDR is set). The helper script lives in run/ under ROOT. */
static void sigless_post(const char *addr, const char *channel, const char *msg) {
    if (!addr || !*addr) return;
    char cmd[2048];
    int n = snprintf(cmd, sizeof(cmd), "sh \"%s/run/post_to_sigless.sh\" %s %s \"%s\" >/dev/null 2>&1",
                     env_or("ROOT", "."), addr, channel, msg);
    if (n > 0 && n < (int)sizeof(cmd)) { int rc = system(cmd); (void)rc; }
}

/* ================================================================== */
/* Query discovery                                                     */
/* ================================================================== */

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Every *.sql under dir, recursively, as heap-allocated paths (capped). */
static int collect_queries(const char *dir, char **files, int count, int max) {
    DIR *d = opendir(dir);
    if (!d) { fprintf(stderr, "opendir(%s): %s\n", dir, strerror(errno)); return count; }
    struct dirent *entry;
    while (count < max && (entry = readdir(d)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        char path[PATH_MAX];
        int n = snprintf(path, sizeof(path), "%s/%s", dir, entry->d_name);
        if (n <= 0 || n >= (int)sizeof(path)) continue;
        struct stat st;
        if (stat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            count = collect_queries(path, files, count, max);
        } else if (S_ISREG(st.st_mode)) {
            size_t len = strlen(entry->d_name);
            if (len > 4 && strcmp(entry->d_name + len - 4, ".sql") == 0) {
                files[count] = strdup(path);
                if (files[count]) count++;
            }
        }
    }
    closedir(d);
    return count;
}

/* N copies of one query in one file (the batch), built outside every timing
 * window. World-readable so the postgres user can read it via sudo. */
static int build_batch_file(const char *src, const char *dst, int copies) {
    FILE *in = fopen(src, "rb");
    if (!in) { fprintf(stderr, "cannot read %s: %s\n", src, strerror(errno)); return -1; }
    if (fseek(in, 0, SEEK_END) != 0) { fclose(in); return -1; }
    long sz = ftell(in);
    if (sz < 0) { fclose(in); return -1; }
    rewind(in);
    char *content = malloc((size_t)sz + 1);
    if (!content) { fclose(in); return -1; }
    size_t got = fread(content, 1, (size_t)sz, in);
    fclose(in);
    FILE *out = fopen(dst, "wb");
    if (!out) { free(content); return -1; }
    for (int i = 0; i < copies; i++) { fwrite(content, 1, got, out); fputc('\n', out); }
    fclose(out);
    free(content);
    chmod(dst, 0644);
    return 0;
}

/* ================================================================== */
/* One batch: execute, measure, write its rows                         */
/* ================================================================== */

/* Everything the runner carries from batch to batch. */
typedef struct {
    FILE *log, *samples;
    const char *run_id, *pg_version;
    run_profile *profiles;         /* one per copy, sized to the widest batch */
    double prev_end_epoch;         /* end of the previous batch (NAN = unknown) */
    double preheat_s, cooldown_s;  /* pending equalisation figures for the next row */
} runner_state;

typedef struct {
    double elapsed;
    int    failed;
    int    ncopies;
    double server_sum;
} batch_result;

static batch_result run_one_batch(runner_state *st, const char *cmd, const char *out_tmp,
                                  int copies, const char *query_id, const char *phase,
                                  int batch_index, int runs, int warmup) {
    batch_result br; memset(&br, 0, sizeof(br));
    run_profile meta; profile_reset(&meta);

    /* --- state at batch start ---------------------------------------- */
    double idle_before = isnan(st->prev_end_epoch) ? NAN : now_epoch() - st->prev_end_epoch;
    double pkg_start   = read_pkg_temp_c();
    long   thr_core0   = read_throttle_sum(S.core_thr, S.n_core_thr);
    long   thr_pkg0    = read_throttle_sum(S.pkg_thr, S.n_pkg_thr);

    /* --- the measured window ----------------------------------------- */
    sampler_t sm; sampler_start(&sm);
    double e[4]; int present[4];
    rapl_before(NULL, RAPL_CORE);
    double start = now_sec();
    int rc = run_once(cmd, &meta);
    br.elapsed = now_sec() - start;
    rapl_after_capture(RAPL_CORE, e, present);
    sampler_stop(&sm);

    /* --- state at batch end ------------------------------------------ */
    double pkg_end  = read_pkg_temp_c();
    long   thr_core1 = read_throttle_sum(S.core_thr, S.n_core_thr);
    long   thr_pkg1  = read_throttle_sum(S.pkg_thr, S.n_pkg_thr);
    st->prev_end_epoch = now_epoch();

    br.ncopies = parse_batch(out_tmp, st->profiles, copies);
    br.failed  = (rc != 0);
    if (br.failed) {
        char err[512]; first_error(out_tmp, err, sizeof(err));
        fprintf(stderr, "  %s batch %d FAILED (exit code %d) for %s%s%s\n",
                phase, batch_index, rc, query_id, *err ? "\n      " : "", err);
    }
    for (int c = 0; c < br.ncopies; c++)
        if (st->profiles[c].execution_ms >= 0) br.server_sum += st->profiles[c].execution_ms;

    char ts[32]; utc_timestamp(ts, sizeof(ts));
    char b_start[16], b_end[16], b_mean[16], b_max[16], b_core[16], b_mhz[16], b_idle[16], b_watts[16];
    fmt_num(pkg_start, 1, b_start, sizeof(b_start));
    fmt_num(pkg_end, 1, b_end, sizeof(b_end));
    fmt_num(sm.n ? sm.pkg_sum / sm.n : NAN, 2, b_mean, sizeof(b_mean));
    fmt_num(sm.n ? sm.pkg_max : NAN, 1, b_max, sizeof(b_max));
    fmt_num(sm.core_max, 1, b_core, sizeof(b_core));
    double mhz_mean = sm.mhz_n ? sm.mhz_sum / sm.mhz_n : NAN;
    fmt_num(mhz_mean, 0, b_mhz, sizeof(b_mhz));
    fmt_num(idle_before, 3, b_idle, sizeof(b_idle));
    fmt_num((present[0] && br.elapsed > 0) ? e[0] / br.elapsed : NAN, 3, b_watts, sizeof(b_watts));
    char b_thr_core[24] = "", b_thr_pkg[24] = "";
    if (thr_core0 >= 0 && thr_core1 >= 0) snprintf(b_thr_core, sizeof(b_thr_core), "%ld", thr_core1 - thr_core0);
    if (thr_pkg0 >= 0 && thr_pkg1 >= 0)   snprintf(b_thr_pkg, sizeof(b_thr_pkg), "%ld", thr_pkg1 - thr_pkg0);

    /* --- the BATCH row ------------------------------------------------ */
    fprintf(st->log, "%s,%s,%s,%s,%s,%d,%d,%d,%d,%.6f,%.6f,",
            ts, st->run_id, st->pg_version, query_id, phase,
            batch_index, copies, runs, warmup, br.elapsed, br.elapsed / copies);
    if (br.ncopies > 0) fprintf(st->log, "%.3f,%.6f,", br.server_sum, br.elapsed - br.server_sum / 1000.0);
    else                fprintf(st->log, ",,");
    fprintf(st->log, "%.6f,%.6f,%ld,%d,", meta.user_cpu_sec, meta.sys_cpu_sec, meta.max_rss_kb, br.failed);
    write_energy_columns(st->log, e, present);
    fprintf(st->log, ",%s,%s,%s,%s,%s,%s,%s,%s,%s,%.1f,%.1f,%s\n",
            b_start, b_end, b_mean, b_max, b_core, b_mhz, b_thr_core, b_thr_pkg, b_idle,
            st->preheat_s, st->cooldown_s, b_watts);
    fflush(st->log);
    st->preheat_s = st->cooldown_s = 0;    /* only the query's first batch carries them */

    /* --- one row per COPY --------------------------------------------- */
    int rows = br.ncopies > 0 ? br.ncopies : 1;
    run_profile empty; profile_reset(&empty);
    for (int c = 0; c < rows; c++) {
        fprintf(st->samples, "%s,%s,%s,%s,%s,%d,%d,%d,%d,",
                ts, st->run_id, st->pg_version, query_id, phase, batch_index, c + 1, copies, runs);
        write_copy_profile(st->samples, br.ncopies > 0 ? &st->profiles[c] : &empty);
        fprintf(st->samples, "%d,%s,%s\n", br.failed, b_start, b_mhz);
    }
    fflush(st->samples);
    return br;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

static const char *thermal_mode_name(thermal_mode m) {
    return m == THERMAL_GATE ? "gate" : m == THERMAL_BURN ? "burn" : "off";
}

int main(void) {
    /* --- configuration ------------------------------------------------ */
    const char *query_dir = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *db_name   = env_or("DB_NAME", DEFAULT_DB_NAME);
    const char *db_user   = env_or("DB_USER", DEFAULT_DB_USER);
    const char *logs_dir  = env_or("LOGS_DIR", DEFAULT_LOGS_DIR);
    (void)mkdir(logs_dir, 0755);

    char log_file[PATH_MAX], sample_file[PATH_MAX], catalog_file[PATH_MAX];
    snprintf(log_file, sizeof(log_file), "%s/query_timing_%s.csv", logs_dir, db_name);
    snprintf(sample_file, sizeof(sample_file), "%s/query_samples_%s.csv", logs_dir, db_name);
    snprintf(catalog_file, sizeof(catalog_file), "%s/query_catalog_%s.csv", logs_dir, db_name);

    int runs   = env_int("RUNS", DEFAULT_RUNS);     if (runs < 1) runs = 1;
    int warmup = env_int("WARMUP", DEFAULT_WARMUP); if (warmup < 0) warmup = 0;

    /* BATCH_SIZES: "1 16", "1 2 4 8 16", ... Each query is measured RUNS times
     * at every size after the warmups. Default "1" = plain single-copy runs. */
    int sizes[MAX_SIZES], n_sizes = 0, max_batch = 1;
    {
        char tmp[256];
        snprintf(tmp, sizeof(tmp), "%s", env_or("BATCH_SIZES", DEFAULT_BATCH_SIZES));
        for (char *tok = strtok(tmp, " ,\t"); tok && n_sizes < MAX_SIZES; tok = strtok(NULL, " ,\t")) {
            int v = atoi(tok);
            if (v < 1) continue;
            if (v > MAX_BATCH) { fprintf(stderr, "batch size %d capped at %d\n", v, MAX_BATCH); v = MAX_BATCH; }
            sizes[n_sizes++] = v;
            if (v > max_batch) max_batch = v;
        }
        if (n_sizes == 0) { sizes[0] = 1; n_sizes = 1; }
    }

    /* Runtime-tiered cap (brief 3d): a query whose warm 1-copy run exceeds
     * SLOW_COPY_SEC skips sizes above BATCH_CAP_SLOW. Off unless set. */
    int    cap_slow      = env_int("BATCH_CAP_SLOW", 0);
    double slow_copy_sec = env_double("SLOW_COPY_SEC", 1.0);

    thermal_cfg th;
    {
        const char *m = env_or("THERMAL_EQUALISE", "0");
        th.mode = (strcasecmp(m, "burn") == 0) ? THERMAL_BURN
                : (strcmp(m, "1") == 0 || strcasecmp(m, "gate") == 0 || strcasecmp(m, "on") == 0) ? THERMAL_GATE
                : THERMAL_OFF;
        th.t_lo = env_double("T_LO", 55); th.t_hi = env_double("T_HI", 60);
        th.preheat_max_s = env_double("PREHEAT_MAX_S", 60);
        th.cooldown_max_s = env_double("COOLDOWN_MAX_S", 120);
        th.preheat_s = env_double("PREHEAT_S", 30);
    }

    int skip_catalog = env_flag("SKIP_CATALOG");
    const char *sigless_addr = env_or("SIGLESS_ADDR", "");
    const char *sigless_chan = env_or("SIGLESS_CHANNEL", "CH1");
    const char *pg_port      = env_or("PGPORT", "");
    const char *workers      = env_or("WORKERS", "");
    const char *stmt_timeout = env_or("STATEMENT_TIMEOUT", "");
    const char *env_prefix   = build_psql_env_prefix(pg_port, workers, stmt_timeout);
    const char *pg_version   = query_pg_version(env_prefix, db_user, db_name);

    discover_sensors();

    char run_id[64];
    make_run_id(run_id, sizeof(run_id));

    printf("query_runner configuration:\n");
    printf("  QUERY_DIR         = %s\n", query_dir);
    printf("  LOGS_DIR          = %s  (query_timing_/query_samples_/query_catalog_%s.csv)\n", logs_dir, db_name);
    printf("  DB_NAME / DB_USER = %s / %s\n", db_name, db_user);
    printf("  PGPORT            = %s  (server reports %s)\n", *pg_port ? pg_port : "(psql default)", pg_version);
    printf("  RUN_ID            = %s\n", run_id);
    printf("  WARMUP            = %d single-copy warm-ups (the first primes the cache)\n", warmup);
    printf("  BATCH_SIZES       =");
    for (int i = 0; i < n_sizes; i++) printf(" %d", sizes[i]);
    printf("  x RUNS=%d measured batches each\n", runs);
    if (cap_slow > 0) printf("  BATCH_CAP_SLOW    = %d when the warm 1-copy run > %.2fs\n", cap_slow, slow_copy_sec);
    printf("  WORKERS           = %s\n", *workers ? workers : "(planner default)");
    printf("  STATEMENT_TIMEOUT = %s\n", *stmt_timeout ? stmt_timeout : "(none)");
    printf("  THERMAL_EQUALISE  = %s", thermal_mode_name(th.mode));
    if (th.mode == THERMAL_GATE) printf(" (T_LO=%.0f T_HI=%.0f preheat<=%.0fs cooldown<=%.0fs)", th.t_lo, th.t_hi, th.preheat_max_s, th.cooldown_max_s);
    if (th.mode == THERMAL_BURN) printf(" (%.0fs all-core burn before each query)", th.preheat_s);
    printf("\n");
    printf("  sensors           = pkg:%s cores:%d cpufreq:%d throttle:%d/%d\n",
           *S.pkg_temp ? S.pkg_temp : "(none)", S.n_core_temp, S.n_cur_freq, S.n_core_thr, S.n_pkg_thr);
    printf("  SIGLESS_ADDR      = %s\n", *sigless_addr ? sigless_addr : "(disabled)");
    fflush(stdout);

    /* --- queries ------------------------------------------------------ */
    char *files[MAX_QUERIES];
    int count;
    struct stat st_q;
    if (stat(query_dir, &st_q) == 0 && S_ISREG(st_q.st_mode)) {
        files[0] = strdup(query_dir);
        count = files[0] ? 1 : 0;
    } else {
        count = collect_queries(query_dir, files, 0, MAX_QUERIES);
        if (count >= MAX_QUERIES)
            fprintf(stderr, "warning: hit the MAX_QUERIES cap (%d) - queries beyond it under %s were NOT collected\n", MAX_QUERIES, query_dir);
    }
    if (count == 0) { fprintf(stderr, "No .sql files found under %s\n", query_dir); return 1; }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d quer%s under %s\n\n", count, count == 1 ? "y" : "ies", query_dir);

    if (rapl_init(RAPL_CORE) != 0) {
        fprintf(stderr, "rapl_init failed (need root and the 'msr' module: sudo modprobe msr)\n");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    /* --- outputs ------------------------------------------------------ */
    runner_state st;
    memset(&st, 0, sizeof(st));
    st.run_id = run_id; st.pg_version = pg_version;
    st.prev_end_epoch = env_double("PREV_END_EPOCH", NAN);
    if (st.prev_end_epoch <= 0) st.prev_end_epoch = NAN;
    st.log = open_csv_append(log_file, HDR_LOG);
    st.samples = st.log ? open_csv_append(sample_file, HDR_SAMPLES) : NULL;
    if (!st.log || !st.samples) {
        if (st.log) fclose(st.log);
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }
    if (!skip_catalog)
        write_catalog_snapshot(catalog_file, env_prefix, db_user, db_name, pg_version, run_id);

    st.profiles = malloc((size_t)max_batch * sizeof(run_profile));
    if (!st.profiles) { fprintf(stderr, "out of memory for a %d-copy batch\n", max_batch); return 1; }

    /* psql's output is captured so the plans can be parsed; batch_tmp holds the
     * N-copy file. Keyed by pid so parallel runners never collide. */
    char out_tmp[PATH_MAX], batch_tmp[PATH_MAX];
    snprintf(out_tmp,   sizeof(out_tmp),   "/tmp/query_runner_out_%d.txt", (int)getpid());
    snprintf(batch_tmp, sizeof(batch_tmp), "/tmp/query_runner_batch_%d.sql", (int)getpid());

    /* --- the loop ----------------------------------------------------- */
    int total_failures = 0;
    for (int q = 0; q < count; q++) {
        const char *query_id = files[q];   /* logged as given, so ids match across sweeps */

        char cmd[MAX_CMD];
        int n = snprintf(cmd, sizeof(cmd),
                         /* ON_ERROR_STOP makes psql exit non-zero on a failed
                          * statement, so failures are logged as failures. */
                         "sudo -n -u %s %spsql -d %s -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
                         db_user, env_prefix, db_name, batch_tmp, out_tmp);
        if (n <= 0 || n >= (int)sizeof(cmd)) { fprintf(stderr, "Command too long for %s, skipping\n", query_id); continue; }

        printf("[%d/%d] %s (%d warmup + step-up", q + 1, count, query_id, warmup);
        for (int i = 0; i < n_sizes; i++) printf(" %d", sizes[i]);
        printf(" x%d)\n", runs);
        fflush(stdout);

        char marker[PATH_MAX + 16];
        snprintf(marker, sizeof(marker), "start,%s", query_id);
        sigless_post(sigless_addr, sigless_chan, marker);

        /* Equalise BEFORE the warm-ups (off by default); the figures ride on
         * this query's first batch row. */
        thermal_equalise(&th, &st.preheat_s, &st.cooldown_s);

        int failures = 0;
        double last_warm_elapsed = NAN;

        if (warmup > 0 && build_batch_file(query_id, batch_tmp, 1) == 0) {
            for (int w = 1; w <= warmup; w++) {
                batch_result br = run_one_batch(&st, cmd, out_tmp, 1, query_id, "warmup", w, runs, warmup);
                if (br.failed) failures++;
                last_warm_elapsed = br.elapsed;
                printf("  warmup %d/%d: %.6f sec%s\n", w, warmup, br.elapsed, w == 1 ? " (cache prime)" : "");
                fflush(stdout);
            }
        }

        int cap = 0;
        if (cap_slow > 0 && !isnan(last_warm_elapsed) && last_warm_elapsed > slow_copy_sec) {
            cap = cap_slow;
            printf("  warm 1-copy run %.2fs > %.2fs: capping batch size at %d\n", last_warm_elapsed, slow_copy_sec, cap);
        }

        for (int si = 0; si < n_sizes; si++) {
            int bs = sizes[si];
            if (cap > 0 && bs > cap) { printf("  N=%-3d skipped (cap %d)\n", bs, cap); continue; }
            if (build_batch_file(query_id, batch_tmp, bs) != 0) {
                fprintf(stderr, "Could not build %d-copy file for %s\n", bs, query_id);
                failures++;
                continue;
            }
            for (int r = 1; r <= runs; r++) {
                batch_result br = run_one_batch(&st, cmd, out_tmp, bs, query_id, "measured", r, runs, warmup);
                if (br.failed) failures++;
                printf("  N=%-3d batch %d/%d: %.6f sec, %d cop%s", bs, r, runs, br.elapsed,
                       br.ncopies, br.ncopies == 1 ? "y" : "ies");
                if (br.server_sum > 0) printf(" (server sum %.3f ms)", br.server_sum);
                printf("\n");
                fflush(stdout);
            }
        }

        snprintf(marker, sizeof(marker), "end,%s", query_id);
        sigless_post(sigless_addr, sigless_chan, marker);

        total_failures += failures;
        printf("  done: %d size%s x %d run%s (%d failure%s)\n", n_sizes, n_sizes == 1 ? "" : "s",
               runs, runs == 1 ? "" : "s", failures, failures == 1 ? "" : "s");
        fflush(stdout);
    }

    unlink(out_tmp);
    unlink(batch_tmp);
    free(st.profiles);
    for (int i = 0; i < count; i++) free(files[i]);
    fclose(st.log);
    fclose(st.samples);

    printf("\nDone. Batch rows appended to %s\n", log_file);
    printf("Per-copy samples appended to %s\n", sample_file);
    if (!skip_catalog) printf("Relation sizes appended to %s\n", catalog_file);
    printf("Last batch ended at epoch %.3f (PREV_END_EPOCH for the next invocation)\n", st.prev_end_epoch);
    if (total_failures) printf("%d batch failure%s (see the failed column)\n", total_failures, total_failures == 1 ? "" : "s");
    return 0;
}
