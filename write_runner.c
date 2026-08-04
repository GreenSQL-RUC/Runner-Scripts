#define _GNU_SOURCE
/*
 * write_runner.c
 *
 * Energy/timing runner for WRITE (data-mutating) SQL. It is deliberately kept
 * separate from query_runner.c so the read benchmark and its canonical
 * databases can never be touched by a write:
 *
 *   1. ISOLATION. It runs ONLY against a disposable scratch database (default
 *      tpch_write) and REFUSES to start against the canonical read databases
 *      (tpch / tpch2 / tpch5). The scratch DB is a throwaway clone; its own
 *      copies of the TPC-H tables are read as reference data to (re)build small
 *      "w_*" scratch tables, which are the only things ever written.
 *
 *   2. PER-RUN RESET. Writes are not idempotent - a second DELETE would find no
 *      rows, a second INSERT would double the table - so each run must start
 *      from an identical baseline. Every .sql file is split into a SETUP section
 *      and a MEASURED section by a line containing "@MEASURE":
 *
 *          DROP TABLE IF EXISTS w_lineitem;                -- SETUP: rebuild a
 *          CREATE TABLE w_lineitem AS SELECT ... ;         -- pristine scratch
 *          -- @MEASURE                                     -- table (NOT timed)
 *          DELETE FROM w_lineitem WHERE l_quantity <= 25;  -- MEASURED write
 *
 *      The SETUP runs (and commits) before every measured run but is NOT timed;
 *      only the MEASURED section is bracketed by RAPL + the wall clock. A file
 *      with no "@MEASURE" line is measured in full with no reset - use that only
 *      for self-contained statements (e.g. a BEGIN ... ROLLBACK block).
 *
 *   3. SEPARATE LOG. Results append to write_timing_<db>.csv, using the SAME
 *      column layout as the read runner so the two logs share tooling. Because
 *      state is reset between runs, each run is measured on its own; the per-run
 *      energy deltas and elapsed times are summed into one row per query (divide
 *      by "runs" for a per-run figure), exactly like query_runner.c.
 *
 * Configuration (environment variables; see print_config):
 *   QUERY_DIR  directory searched recursively for .sql files (default: write_queries)
 *   DB_NAME    scratch database to run against              (default: tpch_write)
 *   DB_USER    OS user psql runs as, via sudo               (default: postgres)
 *   RUNS       measured runs per query                      (default: 3)
 *   WARMUP     unmeasured runs first, each with its own SETUP  (default: 2)
 *   PGPORT     which cluster/major to run against            (default: 5432)
 *   LOG_FILE   override the default write_timing_<db>.csv
 *   SAMPLE_FILE override the default write_samples_<db>.csv
 */

#include <stdio.h>
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
#include <sys/wait.h>
#include <sys/resource.h>

#include "rapl.h"

#define DEFAULT_QUERY_DIR  "write_queries"
#define DEFAULT_LOG_PREFIX "write_timing_"
#define DEFAULT_SAMPLE_PREFIX "write_samples_"
#define DEFAULT_DB_NAME    "tpch_write"
#define DEFAULT_DB_USER    "postgres"
#define DEFAULT_RUNS       3
#define DEFAULT_WARMUP     2    /* unmeasured runs first (setup still resets state) */
#define RAPL_CORE          0

#define MAX_QUERIES 8192
/* Room for two PATH_MAX paths (the sql temp file and the captured output)
 * plus the sudo/psql boilerplate, so the command can never be truncated. */
#define MAX_CMD     (2 * PATH_MAX + 512)
#define MEASURE_MARKER "@MEASURE"

/* Canonical read databases the write runner must NEVER connect to. Guards
 * against a stray DB_NAME clobbering the read corpus. */
static const char *PROTECTED_DBS[] = { "tpch", "tpch2", "tpch5", NULL };

/* ================================================================== */
/* Small helpers                                                       */
/* ================================================================== */

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static void utc_timestamp(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
    if (gmtime_r(&t, &tm_utc) == NULL) { if (buf_size) buf[0] = '\0'; return; }
    strftime(buf, buf_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

static void make_run_id(char *buf, size_t buf_size) {
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

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/*
 * Build the "env PGPORT=N " fragment inserted after `sudo -u USER`. Each
 * installed PostgreSQL major runs its own cluster on its own port, so this is
 * what selects the version (see the Makefile's PGVER knob); empty means psql's
 * default, 5432. Validated as a non-negative integer before being spliced in.
 */
static const char *build_psql_env_prefix(const char *port) {
    static char buf[64];
    buf[0] = '\0';
    if (port && *port) {
        char *end;
        long n = strtol(port, &end, 10);
        if (*end != '\0' || n < 0) {
            fprintf(stderr, "PGPORT must be a non-negative integer, got \"%s\"\n", port);
            exit(1);
        }
        snprintf(buf, sizeof(buf), "env PGPORT=%ld ", n);
    }
    return buf;
}

/*
 * Ask the server which PostgreSQL version it is, once at startup, so every row
 * carries it. Write-path behaviour (HOT updates, MERGE, vacuum) changes between
 * majors, so rows measured on different servers are not safely comparable
 * without this. Returns a static buffer; "unknown" if psql cannot be reached.
 */
static const char *query_pg_version(const char *env_prefix,
                                    const char *db_user, const char *db_name) {
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
        /* Keep just the bare version and keep it CSV-safe: Debian/Ubuntu append a
         * packaging string ("16.14 (Ubuntu 16.14-0ubuntu0.24.04.1)"), so cut at
         * the first space, comma or newline. */
        line[strcspn(line, "\r\n, ")] = '\0';
        if (*line) snprintf(buf, sizeof(buf), "%s", line);
    }
    pclose(p);
    return buf;
}

/* Read a whole file into a NUL-terminated heap buffer (NULL on failure). */
static char *read_file(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return NULL;
    if (fseek(fp, 0, SEEK_END) != 0) { fclose(fp); return NULL; }
    long size = ftell(fp);
    if (size < 0) { fclose(fp); return NULL; }
    rewind(fp);
    char *buf = malloc((size_t)size + 1);
    if (!buf) { fclose(fp); return NULL; }
    size_t got = fread(buf, 1, (size_t)size, fp);
    fclose(fp);
    buf[got] = '\0';
    return buf;
}

/* Recursively collect every "*.sql" file under dir (heap-allocated full paths). */
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

/* True only if s is blank (whitespace) up to its NUL. */
static int is_blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\t' && *s != '\r' && *s != '\n') return 0;
    return 1;
}

/* ================================================================== */
/* RAPL: capture one before/after reading as accumulable numbers       */
/* ================================================================== */
/*
 * rapl_after() only writes its four joule deltas to a FILE, so to accumulate
 * across per-run measurement windows we capture that text into a memory stream
 * and parse it. The format is "pkg,core,[gpu],[dram]" where gpu/dram are empty
 * on CPUs without those RAPL domains; present[i] records which were populated so
 * the CSV can reproduce the read log's blank columns rather than writing 0.
 */
static void rapl_after_capture(int core, double d[4], int present[4]) {
    for (int i = 0; i < 4; i++) { d[i] = 0.0; present[i] = 0; }
    char *buf = NULL;
    size_t len = 0;
    FILE *ms = open_memstream(&buf, &len);
    if (!ms) return;
    rapl_after(ms, core);
    fclose(ms);
    if (!buf) return;
    int i = 0;
    char *tok = buf, *comma;
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

/* ================================================================== */
/* Per-run profile: where the wall time actually went                  */
/* ================================================================== */
/*
 * As in the read runner, most of a fast query's wall time is not the query:
 * process exec, connect/auth and backend fork cost ~33 ms here. Write queries
 * are plain DML rather than EXPLAIN, so there is no plan summary to parse;
 * instead psql's own \timing is switched on for the measured file, giving
 * stmt_ms = the in-session statement time (server work plus one round trip,
 * but no process startup). wait4() supplies the client process tree's CPU and
 * peak RSS - the postgres backend is not our descendant, so its CPU is not
 * included.
 */
typedef struct {
    double stmt_ms;          /* < 0 when psql printed no timing line */
    double user_cpu_sec;
    double sys_cpu_sec;
    long   max_rss_kb;
} run_profile;

static void profile_reset(run_profile *pr) {
    memset(pr, 0, sizeof(*pr));
    pr->stmt_ms = -1.0;
}

/* Sum every "Time: N.NNN ms" psql printed - the measured section may hold more
 * than one statement, and the figure we want is the whole section. */
static void parse_timing(const char *path, run_profile *pr) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        const char *p = strstr(line, "Time: ");
        if (p && strstr(p, " ms")) {
            if (pr->stmt_ms < 0) pr->stmt_ms = 0.0;
            pr->stmt_ms += atof(p + strlen("Time: "));
        }
    }
    fclose(f);
}

/*
 * Run one execution of cmd, filling pr with the child's resource usage.
 * Replaces system() purely so wait4() can hand back a struct rusage; the
 * command is still handed to /bin/sh, so redirections behave identically.
 * Returns the child's exit status (0 on success), or -1 if it could not run.
 */
static int run_once(const char *cmd, run_profile *pr) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        execl("/bin/sh", "sh", "-c", cmd, (char *)NULL);
        _exit(127);
    }

    int status = 0;
    struct rusage ru;
    memset(&ru, 0, sizeof(ru));
    if (wait4(pid, &status, 0, &ru) < 0) return -1;

    if (pr) {
        pr->user_cpu_sec = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6;
        pr->sys_cpu_sec  = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
        pr->max_rss_kb   = ru.ru_maxrss;
    }

    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* Emit the profile columns for one sample row (trailing comma-separated). */
static void write_profile_columns(FILE *out, const run_profile *pr, double elapsed) {
    if (pr->stmt_ms >= 0) fprintf(out, "%.3f,%.6f,", pr->stmt_ms, elapsed - pr->stmt_ms / 1000.0);
    else                  fprintf(out, ",,");
    fprintf(out, "%.6f,%.6f,%ld,", pr->user_cpu_sec, pr->sys_cpu_sec, pr->max_rss_kb);
}

/* Write the four joule columns, leaving gpu/dram blank where unavailable so the
 * layout matches the read log. */
static void write_energy_columns(FILE *out, const double e[4], const int present[4]) {
    fprintf(out, "%.18f,%.18f,", e[0], e[1]);
    if (present[2]) fprintf(out, "%.18f", e[2]);
    fprintf(out, ",");
    if (present[3]) fprintf(out, "%.18f", e[3]);
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

static void print_config(const char *query_dir, const char *log_file,
                         const char *sample_file,
                         const char *db_name, const char *db_user, int runs,
                         int warmup, const char *pg_port, const char *pg_version) {
    printf("write_runner configuration:\n");
    printf("  QUERY_DIR      = %s\n", query_dir);
    printf("  LOG_FILE       = %s\n", log_file);
    printf("  SAMPLE_FILE    = %s\n", sample_file);
    printf("  DB_NAME        = %s  (scratch; canonical read DBs are refused)\n", db_name);
    printf("  DB_USER        = %s\n", db_user);
    printf("  PGPORT         = %s\n",
           (pg_port && *pg_port) ? pg_port : "(psql default, 5432)");
    printf("  PG_VERSION     = %s\n", pg_version);
    printf("  RUNS           = %d (per query, state reset before each)\n", runs);
    printf("  WARMUP         = %d (unmeasured runs first, logged as phase=warmup)\n", warmup);
    fflush(stdout);
}

int main(void) {
    const char *query_dir = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *db_name   = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user   = env_or("DB_USER",   DEFAULT_DB_USER);
    /* Which cluster (i.e. which PostgreSQL major) to talk to; empty = 5432. */
    const char *pg_port   = env_or("PGPORT",    "");
    const char *env_prefix = build_psql_env_prefix(pg_port);

    /* SAFETY: never run writes against a canonical read database. */
    for (int i = 0; PROTECTED_DBS[i]; i++) {
        if (strcmp(db_name, PROTECTED_DBS[i]) == 0) {
            fprintf(stderr,
                "REFUSING to run: DB_NAME=\"%s\" is a canonical READ database.\n"
                "The write runner only targets a disposable scratch DB (e.g. tpch_write).\n",
                db_name);
            return 1;
        }
    }

    char log_file_buf[PATH_MAX];
    const char *log_file = getenv("LOG_FILE");
    if (!log_file || !*log_file) {
        snprintf(log_file_buf, sizeof(log_file_buf), "%s%s.csv", DEFAULT_LOG_PREFIX, db_name);
        log_file = log_file_buf;
    }

    /* Companion per-run log: one row per individual execution, so run-to-run
     * variance can be analysed instead of being hidden inside the aggregate. */
    char sample_file_buf[PATH_MAX];
    const char *sample_file = getenv("SAMPLE_FILE");
    if (!sample_file || !*sample_file) {
        snprintf(sample_file_buf, sizeof(sample_file_buf), "%s%s.csv",
                 DEFAULT_SAMPLE_PREFIX, db_name);
        sample_file = sample_file_buf;
    }

    int runs = atoi(env_or("RUNS", ""));
    if (runs <= 0) runs = DEFAULT_RUNS;

    /* Unmeasured runs executed before the measured ones, each preceded by the
     * same SETUP, so the measured runs start from an identical state but with
     * warm binaries, catalog caches and relation pages. WARMUP=0 disables. */
    const char *warmup_env = getenv("WARMUP");
    int warmup = (warmup_env && *warmup_env) ? atoi(warmup_env) : DEFAULT_WARMUP;
    if (warmup < 0) warmup = 0;

    /* Stamped onto every row so results stay interpretable after an upgrade. */
    const char *pg_version = query_pg_version(env_prefix, db_user, db_name);

    print_config(query_dir, log_file, sample_file, db_name, db_user, runs,
                 warmup, pg_port, pg_version);

    char *files[MAX_QUERIES];
    int count = collect_queries(query_dir, files, 0, MAX_QUERIES);
    if (count == 0) {
        fprintf(stderr, "No .sql files found under %s\n", query_dir);
        return 1;
    }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d write queries under %s\n\n", count, query_dir);

    if (rapl_init(RAPL_CORE) != 0) {
        fprintf(stderr, "rapl_init failed (need root and the 'msr' module: sudo modprobe msr)\n");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    struct stat log_st;
    int need_header = (stat(log_file, &log_st) != 0 || log_st.st_size == 0);
    FILE *log = fopen(log_file, "a");
    if (!log) {
        perror("fopen log file");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }
    if (need_header) {
        fprintf(log, "timestamp_utc,run_id,pg_version,query,runs,warmup,"
                     "total_elapsed_sec,avg_elapsed_sec,failures,"
                     "rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j\n");
        fflush(log);
    }

    struct stat sample_st;
    int need_sample_header = (stat(sample_file, &sample_st) != 0 || sample_st.st_size == 0);
    FILE *samples = fopen(sample_file, "a");
    if (!samples) {
        perror("fopen sample file");
        fclose(log);
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }
    if (need_sample_header) {
        fprintf(samples, "timestamp_utc,run_id,pg_version,query,phase,run_index,runs,"
                         "elapsed_sec,stmt_ms,client_overhead_sec,"
                         "client_user_cpu_sec,client_sys_cpu_sec,client_max_rss_kb,"
                         "failed,rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j\n");
        fflush(samples);
    }

    char run_id[32];
    make_run_id(run_id, sizeof(run_id));

    /* Temp files (world-readable) so the postgres user can read them via sudo. */
    char setup_tmp[PATH_MAX], measure_tmp[PATH_MAX], out_tmp[PATH_MAX];
    snprintf(setup_tmp,   sizeof(setup_tmp),   "/tmp/write_runner_setup_%d.sql",   (int)getpid());
    snprintf(measure_tmp, sizeof(measure_tmp), "/tmp/write_runner_measure_%d.sql", (int)getpid());
    /* psql's stdout is captured rather than discarded so the \timing lines can
     * be parsed back out of it. */
    snprintf(out_tmp,     sizeof(out_tmp),     "/tmp/write_runner_out_%d.txt",     (int)getpid());

    for (int q = 0; q < count; q++) {
        const char *query_id = files[q];

        char *sql = read_file(query_id);
        if (!sql) {
            fprintf(stderr, "Could not read %s, skipping\n", query_id);
            continue;
        }

        /* Split into SETUP (reset, not measured) and MEASURED sections at the
         * first line containing @MEASURE. */
        char *marker = strstr(sql, MEASURE_MARKER);
        const char *setup_sql = NULL;   /* NULL => no reset step */
        const char *measure_sql = sql;
        char *setup_buf = NULL;
        if (marker) {
            /* start of the marker's line */
            char *line_start = marker;
            while (line_start > sql && line_start[-1] != '\n') line_start--;
            /* end of the marker's line */
            char *line_end = strchr(marker, '\n');
            measure_sql = line_end ? line_end + 1 : "";
            size_t setup_len = (size_t)(line_start - sql);
            setup_buf = malloc(setup_len + 1);
            if (setup_buf) {
                memcpy(setup_buf, sql, setup_len);
                setup_buf[setup_len] = '\0';
                if (!is_blank(setup_buf)) setup_sql = setup_buf;
            }
        }

        /* Write the measured section to its temp file once (identical each run).
         * \timing makes psql report each statement's in-session duration, which
         * is the only server-side figure available here - write queries are
         * plain DML, so unlike the read corpus there is no EXPLAIN summary. */
        FILE *mf = fopen(measure_tmp, "wb");
        if (!mf) { fprintf(stderr, "temp write failed for %s\n", query_id); free(sql); free(setup_buf); continue; }
        fputs("\\timing on\n", mf);
        fputs(measure_sql, mf);
        fclose(mf);
        chmod(measure_tmp, 0644);

        if (setup_sql) {
            FILE *sf = fopen(setup_tmp, "wb");
            if (sf) { fputs(setup_sql, sf); fclose(sf); chmod(setup_tmp, 0644); }
        }

        char setup_cmd[MAX_CMD], measure_cmd[MAX_CMD];
        snprintf(setup_cmd, sizeof(setup_cmd),
                 "sudo -n -u %s %spsql -d %s -q -v ON_ERROR_STOP=1 -f \"%s\" > /dev/null 2>&1",
                 db_user, env_prefix, db_name, setup_tmp);
        snprintf(measure_cmd, sizeof(measure_cmd),
                 "sudo -n -u %s %spsql -d %s -q -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>/dev/null",
                 db_user, env_prefix, db_name, measure_tmp, out_tmp);

        printf("[%d/%d] %s (%d warmup + %d run%s%s)\n", q + 1, count, query_id,
               warmup, runs, runs == 1 ? "" : "s",
               setup_sql ? ", reset each run" : ", no reset");
        fflush(stdout);

        double total_elapsed = 0.0;
        double e[4] = {0, 0, 0, 0};
        int present[4] = {0, 0, 0, 0};
        int failures = 0;

        /* Warmup runs get the same SETUP, so a measured run always starts from
         * an identical state - only the caches are warmer. They are logged as
         * phase=warmup and excluded from the aggregate. */
        for (int r = 1 - warmup; r <= runs; r++) {
            int is_warmup = (r <= 0);
            int shown = is_warmup ? warmup + r : r;
            run_profile pr;
            profile_reset(&pr);

            if (setup_sql) {
                int src = run_once(setup_cmd, NULL);
                if (src != 0) {
                    fprintf(stderr, "  %s %d SETUP FAILED (exit %d) for %s\n",
                            is_warmup ? "warmup" : "run", shown, src, query_id);
                    if (!is_warmup) failures++;
                    continue;   /* skip a measured run we could not reset */
                }
            }

            rapl_before(NULL, RAPL_CORE);
            double start = now_sec();
            int rc = run_once(measure_cmd, &pr);
            double elapsed = now_sec() - start;

            double d[4]; int p[4];
            rapl_after_capture(RAPL_CORE, d, p);
            parse_timing(out_tmp, &pr);

            int failed = (rc != 0);
            if (failed) {
                fprintf(stderr, "  %s %d FAILED (exit %d) for %s\n",
                        is_warmup ? "warmup" : "run", shown, rc, query_id);
            }

            if (is_warmup) {
                printf("  warmup %d/%d: %.6f sec (not measured)\n", shown, warmup, elapsed);
            } else {
                total_elapsed += elapsed;
                for (int i = 0; i < 4; i++) { e[i] += d[i]; present[i] |= p[i]; }
                if (failed) failures++;
                printf("  run %d/%d: %.6f sec", r, runs, elapsed);
                if (pr.stmt_ms >= 0) printf(" (stmt %.3f ms)", pr.stmt_ms);
                printf("\n");
            }
            fflush(stdout);

            char sts[32];
            utc_timestamp(sts, sizeof(sts));
            fprintf(samples, "%s,%s,%s,%s,%s,%d,%d,%.6f,",
                    sts, run_id, pg_version, query_id,
                    is_warmup ? "warmup" : "measured", shown, runs, elapsed);
            write_profile_columns(samples, &pr, elapsed);
            fprintf(samples, "%d,", failed);
            write_energy_columns(samples, d, p);
            fprintf(samples, "\n");
            fflush(samples);
        }

        char ts[32];
        utc_timestamp(ts, sizeof(ts));
        /* avg_elapsed_sec is total/runs: the per-execution figure. Energy stays
         * a total, since one run rarely moves the RAPL counters meaningfully. */
        fprintf(log, "%s,%s,%s,%s,%d,%d,%.6f,%.6f,%d,",
                ts, run_id, pg_version, query_id, runs, warmup,
                total_elapsed, runs > 0 ? total_elapsed / runs : 0.0, failures);
        write_energy_columns(log, e, present);
        fprintf(log, "\n");
        fflush(log);

        printf("  total: %.6f sec over %d run%s (avg %.6f, %d failure%s)\n",
               total_elapsed, runs, runs == 1 ? "" : "s",
               runs > 0 ? total_elapsed / runs : 0.0,
               failures, failures == 1 ? "" : "s");
        fflush(stdout);

        free(sql);
        free(setup_buf);
    }

    unlink(setup_tmp);
    unlink(measure_tmp);
    unlink(out_tmp);
    for (int i = 0; i < count; i++) free(files[i]);
    fclose(log);
    fclose(samples);

    printf("\nDone. Results appended to %s\n", log_file);
    printf("Per-run samples appended to %s\n", sample_file);
    return 0;
}
