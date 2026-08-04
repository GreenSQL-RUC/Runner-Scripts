#define _GNU_SOURCE
/*
 * query_runner.c
 *
 * A small, self-contained benchmark runner for SQL queries.
 *
 * For every .sql file found under a query directory it:
 *   1. runs the query against PostgreSQL (via psql) WARMUP times unmeasured,
 *      then RUNS times measured,
 *   2. times the executions (wall clock, monotonic), and
 *   3. records the RAPL energy used (package / core / gpu / dram, in joules).
 *
 * SLOPE METHOD. RAPL cannot attribute energy finer than one process, and every
 * process pays a fixed ~0.5 J of overhead (fork/connect/backend spawn) that
 * swamps a fast query's own energy. To separate the two, each query is measured
 * at TWO batch sizes - 1 copy and BATCHNUM copies - where a "batch" is that many
 * copies of the query concatenated into one file and run in ONE psql process.
 * Fitting a line through the two points, E_batch = intercept + slope*N, gives:
 *
 *     slope     = the query's own WARM marginal energy (or wall time) per copy,
 *                 free of process overhead AND of the cold first-copy penalty -
 *                 both are fixed per batch, so they land in the intercept;
 *     intercept = the fixed per-process overhead (energy or wall time).
 *
 * Every batch, at either size, contains exactly one cold first copy (a fresh
 * connection), so that cold cost is constant across the two sizes and cancels
 * into the intercept - which is why the slope comes out clean. BATCHNUM=1
 * disables the second size (no slope; the classic one-size-per-process runner).
 *
 * RUNS is how many measured batches at N=BATCHNUM. The N=1 slope anchor is NOT
 * a separate phase - it is the WARM warmup runs: a warm 1-copy warmup is the
 * same measurement as a dedicated 1-copy run (verified <1% on every query with
 * real signal). WARMUP single-copy runs come first; the first primes the cache
 * (cold, excluded) and the rest are the warm N=1 anchor, so WARMUP>=2 gives a
 * clean anchor. Copies are generated at runtime, before any timing/RAPL window,
 * so building them never lands in a measurement.
 *
 * FOUR CSVs:
 *   LOG_FILE     one row per BATCH: wall, avg_copy_elapsed_sec, server_sum,
 *                client overhead, rusage, RAPL energy, and the batch's size
 *                (batchnum column). Both sizes and the warmups land here, told
 *                apart by phase + batchnum; batch-to-batch variation lives here.
 *   SAMPLE_FILE  one row per COPY: that copy's own EXPLAIN server figures
 *                (planning/execution ms, buffers, rows/bytes, relations).
 *                Copy-to-copy variation within a batch lives here.
 *   SLOPE_FILE   one row per QUERY (only when BATCHNUM>1): the fitted slope and
 *                intercept for wall, package and core energy - the headline
 *                overhead-free numbers.
 *   CATALOG_FILE relation sizes for the database, written once per sweep.
 *
 * All carry the server's pg_version so rows from different servers are never
 * silently mixed.
 *
 * The query directory is searched recursively, so you can group queries into
 * sub-folders and point the runner at whichever group you want to test:
 *
 *   make run                      # every query under ./queries
 *   make run DIR=queries/Joins    # only the queries in ./queries/Joins
 *
 * Everything is configured through a handful of environment variables (all
 * optional, sensible defaults below). See print_config() for the full list.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

/* ------------------------------------------------------------------ */
/* Defaults (override with the matching environment variable)          */
/* ------------------------------------------------------------------ */
#define DEFAULT_QUERY_DIR "queries"
#define DEFAULT_LOG_PREFIX "query_timing_"  /* default log is <prefix><db>.csv     */
#define DEFAULT_SAMPLE_PREFIX "query_samples_" /* per-run log is <prefix><db>.csv  */
#define DEFAULT_CATALOG_PREFIX "query_catalog_" /* size snapshot <prefix><db>.csv  */
#define DEFAULT_SLOPE_PREFIX "query_slope_"  /* per-query slope <prefix><db>.csv   */
#define DEFAULT_LOGS_DIR  "logs"    /* CSVs default to <logs_dir>/<prefix><db>.csv */
#define DEFAULT_DB_NAME   "tpch"
#define DEFAULT_DB_USER   "postgres"
#define DEFAULT_RUNS      2      /* measured BATCHES per query at N=BATCHNUM    */
#define DEFAULT_WARMUP    1      /* warm single-copy runs (the N=1 anchor)     */
#define DEFAULT_BATCHNUM  5      /* copies per batch = the slope's large point */
#define MAX_BATCHNUM      100000 /* guard against a runaway BATCHNUM allocation*/
#define RAPL_CORE         0     /* CPU core whose MSRs we read energy from    */

#define MAX_QUERIES 8192        /* upper bound on .sql files we will collect  */
/* Room for two PATH_MAX paths (the query file and the captured output) plus
 * the sudo/psql boilerplate, so the command can never be truncated. */
#define MAX_CMD     (2 * PATH_MAX + 512)

/* ================================================================== */
/* Small helpers                                                       */
/* ================================================================== */

/* Monotonic wall-clock time in seconds (immune to system clock changes). */
static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Fill buf with the current UTC time, e.g. "2026-07-16T10:11:12Z". */
static void utc_timestamp(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
    if (gmtime_r(&t, &tm_utc) == NULL) {
        if (buf_size > 0) buf[0] = '\0';
        return;
    }
    strftime(buf, buf_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

/* A short random hex id shared by every row of a single invocation, so rows
 * from the same run are easy to group later. */
static void make_run_id(char *buf, size_t buf_size) {
    unsigned char raw[8];
    FILE *urandom = fopen("/dev/urandom", "rb");

    if (!urandom || fread(raw, 1, sizeof(raw), urandom) != sizeof(raw)) {
        /* Fall back to time+pid if /dev/urandom is unavailable. */
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

/* Read an environment variable, returning fallback when it is unset/empty. */
static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

/* Parse a non-negative integer setting, exiting with a clear message if it is
 * not one. Everything spliced into a shell command line goes through here. */
static long require_uint(const char *name, const char *value) {
    char *end;
    long n = strtol(value, &end, 10);
    if (*end != '\0' || n < 0) {
        fprintf(stderr, "%s must be a non-negative integer, got \"%s\"\n", name, value);
        exit(1);
    }
    return n;
}

/*
 * Build the shell fragment that goes between `sudo -u USER` and `psql`, setting
 * up the environment for every invocation without touching a single query file:
 *
 *   PGPORT     which cluster to talk to. Each installed PostgreSQL major runs
 *              its own cluster on its own port, so this is what selects the
 *              version (see the Makefile's PGVER knob). Empty => default 5432.
 *   WORKERS    caps max_parallel_workers_per_gather for EVERY query, uniformly
 *              across the sweep (WORKERS=0 => fully serial). Empty => the
 *              planner picks the worker count itself.
 *   STATEMENT_TIMEOUT  seconds after which the SERVER cancels a query. Empty
 *              (the default) means no limit. This is the safety net for an
 *              unattended sweep: a query that would otherwise run for hours is
 *              cancelled, psql exits non-zero, and the runner records a failure
 *              and moves on. Cancelling server-side matters - killing the
 *              client would leave the backend running until it next tried to
 *              return a row, which is how a sweep ends up wedged overnight.
 *
 * Returns "" when nothing is set. Every value is validated as a non-negative
 * integer, so they are safe to splice into the command line.
 */
static const char *build_psql_env_prefix(const char *port, const char *workers,
                                         const char *stmt_timeout) {
    static char buf[256];
    char port_part[48] = "";
    char opts[160] = "";
    size_t n = 0;

    if (port && *port) {
        snprintf(port_part, sizeof(port_part), "PGPORT=%ld ", require_uint("PGPORT", port));
    }
    if (workers && *workers) {
        n += snprintf(opts + n, sizeof(opts) - n,
                      "%s-c max_parallel_workers_per_gather=%ld",
                      n ? " " : "", require_uint("WORKERS", workers));
    }
    if (stmt_timeout && *stmt_timeout) {
        /* GUC wants milliseconds; the knob is in seconds for legibility. */
        n += snprintf(opts + n, sizeof(opts) - n, "%s-c statement_timeout=%ld000",
                      n ? " " : "", require_uint("STATEMENT_TIMEOUT", stmt_timeout));
    }

    if (!*port_part && !n) buf[0] = '\0';
    else if (!n) snprintf(buf, sizeof(buf), "env %s", port_part);
    else snprintf(buf, sizeof(buf), "env %sPGOPTIONS='%s' ", port_part, opts);
    return buf;
}

/*
 * Ask the server which PostgreSQL version it is, once at startup, so every row
 * carries it. Planner and executor behaviour changes between majors, so rows
 * measured on different servers are not safely comparable without this.
 * Returns a static buffer; "unknown" if psql cannot be reached.
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

/* ================================================================== */
/* RAPL: capture one before/after reading as accumulable numbers       */
/* ================================================================== */

/* True only if s is blank (whitespace) up to its NUL. */
static int is_blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\t' && *s != '\r' && *s != '\n') return 0;
    return 1;
}

/*
 * rapl_after() only writes its four joule deltas to a FILE, so to both log a
 * per-run figure AND accumulate a per-query total we capture that text into a
 * memory stream and parse it. The format is "pkg,core,[gpu],[dram]" where
 * gpu/dram are empty on CPUs without those RAPL domains; present[i] records
 * which were populated so the CSV can reproduce blank columns rather than 0.
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

/* Write the four joule columns, leaving gpu/dram blank where unavailable. */
static void write_energy_columns(FILE *out, const double e[4], const int present[4]) {
    fprintf(out, "%.18f,%.18f,", e[0], e[1]);
    if (present[2]) fprintf(out, "%.18f", e[2]);
    fprintf(out, ",");
    if (present[3]) fprintf(out, "%.18f", e[3]);
}

/* ================================================================== */
/* Per-run profile: where the wall time actually went                  */
/* ================================================================== */
/*
 * A measured run is a whole `sudo psql -f file` invocation, and for a fast
 * query most of that wall time is NOT the query: process exec, dynamic linking,
 * connect/auth and backend fork cost ~33 ms on this machine, which dwarfs an
 * 8 ms scan. To make that separable after the fact, every run records:
 *
 *   - server_planning_ms / server_execution_ms, parsed from the EXPLAIN
 *     SUMMARY the queries emit. This is PostgreSQL's own view of the work.
 *   - client_overhead_sec = wall - (planning + execution). Everything outside
 *     the server: fork/exec, linking, TCP/socket setup, auth, teardown.
 *   - the psql process tree's CPU and peak RSS, from wait4(). Note this covers
 *     the CLIENT only - the postgres backend is not our descendant, so its CPU
 *     does not appear here.
 *   - buffer counts from EXPLAIN BUFFERS, which is what makes cache warming
 *     visible: a run that reads blocks (shared_read) instead of finding them
 *     cached (shared_hit) is the slow one, and temp_* exposes spill to disk.
 *
 * On top of that, the plan carries the SIZE of the work done, which is what
 * makes a measurement comparable across scale factors and across tables:
 * per-node "actual rows"/"loops" and "width", plus the relations scanned. See
 * parse_plan_node.
 */
#define MAX_RELATIONS_LEN 480

typedef struct {
    double planning_ms;      /* < 0 when the query emitted no SUMMARY        */
    double execution_ms;     /* < 0 when the query emitted no SUMMARY        */
    double user_cpu_sec;     /* client process tree only, not the backend    */
    double sys_cpu_sec;
    long   max_rss_kb;
    long   shared_hit, shared_read, shared_dirtied, shared_written;
    long   temp_read, temp_written;
    int    have_buffers;

    /* --- plan shape / work size (Tier 1) ------------------------------- */
    long      plan_nodes;    /* executor nodes in the plan                  */
    long      scan_nodes;    /* how many of them are scans                  */
    long long rows_out;      /* rows the query returned (top node)          */
    long long rows_estimated;/* planner's estimate for the top node         */
    long long rows_processed;/* SUM(actual rows x loops) over every node    */
    long long bytes_processed;   /* SUM(actual rows x loops x width)        */
    long long rows_removed_filter;
    long      workers_launched;
    int       have_plan;
    char      relations[MAX_RELATIONS_LEN];  /* ';'-separated, deduped      */
} run_profile;

static void profile_reset(run_profile *pr) {
    memset(pr, 0, sizeof(*pr));
    pr->planning_ms = pr->execution_ms = -1.0;
}

/* Record a relation name once. Names are kept ';'-separated (never ',') so the
 * whole set fits in a single CSV field. Silently stops at MAX_RELATIONS_LEN -
 * the set is for grouping/joining, not an audit trail. */
static void add_relation(run_profile *pr, const char *start) {
    char name[64];
    size_t i = 0;
    while (start[i] && start[i] != ' ' && start[i] != '(' && start[i] != ','
           && start[i] != '\n' && start[i] != '\r' && i < sizeof(name) - 1) {
        name[i] = start[i];
        i++;
    }
    name[i] = '\0';
    if (i == 0) return;

    /* Already present? Compare whole ';'-delimited tokens so "orders" does not
     * match inside "orders_archive". */
    for (const char *t = pr->relations; *t; ) {
        const char *end = strchr(t, ';');
        size_t len = end ? (size_t)(end - t) : strlen(t);
        if (len == i && strncmp(t, name, i) == 0) return;
        if (!end) break;
        t = end + 1;
    }

    size_t used = strlen(pr->relations);
    size_t need = used + (used ? 1 : 0) + i + 1;
    if (need > sizeof(pr->relations)) return;
    if (used) pr->relations[used++] = ';';
    memcpy(pr->relations + used, name, i + 1);
}

/*
 * Pull the work size out of one plan-node line, e.g.
 *
 *   ->  Parallel Seq Scan on lineitem l  (cost=0.00..143817.90 rows=249305
 *       width=13) (actual rows=199963 loops=3)
 *
 * "actual rows" is PER LOOP, so the work a node really did is rows x loops -
 * that is what makes a parallel plan (loops = workers) or a nested loop's inner
 * side add up correctly. Unlike Buffers, a node's row count does NOT include
 * its children, so summing over nodes is the total tuple flow.
 */
static void parse_plan_node(const char *line, const char *cost, run_profile *pr) {
    pr->plan_nodes++;
    pr->have_plan = 1;
    if (strstr(line, "Scan")) pr->scan_nodes++;

    /* Estimated rows and row width both live in the "(cost=...)" group. */
    const char *er = strstr(cost, "rows=");
    long long est = er ? atoll(er + 5) : 0;
    const char *wp = strstr(cost, "width=");
    long long width = wp ? atoll(wp + 6) : 0;

    /* "(actual rows=N loops=N)" is absent for a node that never executed. */
    long long arows = 0, loops = 1;
    const char *act = strstr(line, "(actual rows=");
    if (act) {
        arows = atoll(act + strlen("(actual rows="));
        const char *lp = strstr(act, "loops=");
        if (lp) loops = atoll(lp + 6);
        if (loops < 1) loops = 1;
    }

    if (pr->plan_nodes == 1) {          /* top node = the query's own result */
        pr->rows_out       = arows * loops;
        pr->rows_estimated = est;
    }
    pr->rows_processed  += arows * loops;
    pr->bytes_processed += arows * loops * width;

    /* "... Scan on <relation> [alias]" / "... using <index> on <relation>". */
    const char *on = strstr(line, " on ");
    if (on) add_relation(pr, on + 4);
}

/* Value of "<key><number>" inside s, or 0 when the key is absent. */
static long field_after(const char *s, const char *key) {
    const char *k = s ? strstr(s, key) : NULL;
    return k ? atol(k + strlen(key)) : 0;
}

/* Accumulate one Buffers: line into pr (only the first per plan is meaningful -
 * a parent node's counts already include its children). */
static void parse_buffers_line(const char *p, run_profile *pr) {
    pr->have_buffers = 1;
    /* Format: "shared hit=N read=N dirtied=N written=N, temp read=N written=N".
     * The bare hit/read/... keys belong to whichever section precedes them, so
     * split at "temp " before parsing. */
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

/*
 * Parse a captured BATCH output into one run_profile per copy. A batch file is
 * BATCHNUM copies of an EXPLAIN, so its output is BATCHNUM plans back to back.
 * "Execution Time:" is the last line each plan prints (from SUMMARY ON), so it
 * marks the end of a copy: everything accumulated since the previous one
 * belongs to this copy, which is then finalised and stored.
 *
 * Returns the number of copies stored (<= max_copies). A partial/failed batch
 * simply yields fewer copies.
 */
static int parse_batch(const char *path, run_profile *profiles, int max_copies) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;

    int n = 0;
    run_profile cur;
    profile_reset(&cur);

    char line[8192];
    while (fgets(line, sizeof(line), f)) {
        const char *p;

        /* A plan-node line is exactly the one carrying a "(cost=...)" group.
         * Per-worker breakdowns ("Worker 0: actual rows=...") have no cost
         * group and so are not miscounted as extra nodes. */
        const char *cost = strstr(line, "(cost=");
        if (cost) parse_plan_node(line, cost, &cur);

        if ((p = strstr(line, "Planning Time:")) != NULL) {
            cur.planning_ms = atof(p + strlen("Planning Time:"));
        } else if ((p = strstr(line, "Execution Time:")) != NULL) {
            cur.execution_ms = atof(p + strlen("Execution Time:"));
            if (n < max_copies) profiles[n] = cur;   /* finalise this copy */
            n++;
            profile_reset(&cur);                      /* start the next one */
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

    pr->user_cpu_sec = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6;
    pr->sys_cpu_sec  = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
    pr->max_rss_kb   = ru.ru_maxrss;

    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

/* Copy the first "ERROR:"/"FATAL:" line from a captured psql output into buf, so
 * a failure in an unattended sweep says WHY in the console log rather than just
 * an exit code. buf is emptied when no such line is present. */
static void first_error(const char *path, char *buf, size_t buf_size) {
    if (buf_size) buf[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    /* Sized to match buf: a longer line is split across reads, and the first
     * chunk is the one carrying the error prefix, which is all we want. */
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

/*
 * Emit ONE copy's server-side columns for a sample row (trailing comma after
 * each field; the caller adds the "failed" column last). These are exactly the
 * figures that vary copy-to-copy within a batch; wall time and energy are
 * per-process and live on the batch (timing) row instead.
 *
 * Order matches HDR_SAMPLES after "runs":
 *   planning_ms, execution_ms, plan block, buffers block.
 * Blank rather than zero when a copy produced no plan or no BUFFERS, so "no
 * data" never reads as "no work".
 */
static void write_copy_profile(FILE *out, const run_profile *pr) {
    if (pr->planning_ms >= 0)  fprintf(out, "%.3f,", pr->planning_ms);
    else                       fprintf(out, ",");
    if (pr->execution_ms >= 0) fprintf(out, "%.3f,", pr->execution_ms);
    else                       fprintf(out, ",");

    if (pr->have_plan) {
        fprintf(out, "%ld,%ld,%lld,%lld,%lld,%lld,%lld,%ld,%s,",
                pr->plan_nodes, pr->scan_nodes, pr->rows_out,
                pr->rows_processed, pr->rows_estimated, pr->bytes_processed,
                pr->rows_removed_filter, pr->workers_launched, pr->relations);
    } else {
        fprintf(out, ",,,,,,,,,");
    }

    if (pr->have_buffers) {
        fprintf(out, "%ld,%ld,%ld,%ld,%ld,%ld,",
                pr->shared_hit, pr->shared_read, pr->shared_dirtied,
                pr->shared_written, pr->temp_read, pr->temp_written);
    } else {
        fprintf(out, ",,,,,,");
    }
}

/* ================================================================== */
/* CSV files                                                           */
/* ================================================================== */

/* The exact header of each output file. Kept as constants because they are used
 * twice: to write a new file, and to verify an existing one still matches. */
/* One row per BATCH. elapsed_sec is the batch's wall clock; avg_copy_elapsed_sec
 * is elapsed_sec/batchnum; server_sum_ms is the sum of the copies' Execution
 * Time; client_overhead_sec is elapsed - server_sum. Energy and rusage are for
 * the whole batch process. batch_index is 1..warmup within phase=warmup and
 * 1..runs within phase=measured. */
#define HDR_LOG \
    "timestamp_utc,run_id,pg_version,query,phase,batch_index,batchnum,runs,warmup," \
    "elapsed_sec,avg_copy_elapsed_sec,server_sum_ms,client_overhead_sec," \
    "client_user_cpu_sec,client_sys_cpu_sec,client_max_rss_kb,failed," \
    "rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j\n"

/* One row per COPY within a batch: that copy's own server-side figures. Join to
 * the batch row on run_id + query + phase + batch_index. copy_index is
 * 1..batchnum. */
#define HDR_SAMPLES \
    "timestamp_utc,run_id,pg_version,query,phase,batch_index,copy_index,batchnum,runs," \
    "server_planning_ms,server_execution_ms," \
    "plan_nodes,scan_nodes,rows_out,rows_processed," \
    "rows_estimated,bytes_processed,rows_removed_filter," \
    "workers_launched,relations," \
    "shared_hit_blks,shared_read_blks," \
    "shared_dirtied_blks,shared_written_blks," \
    "temp_read_blks,temp_written_blks,failed\n"

#define HDR_CATALOG \
    "timestamp_utc,run_id,pg_version,database,schema,relname," \
    "relkind,reltuples,relpages,heap_bytes,index_bytes,total_bytes\n"

/* One row per QUERY (BATCHNUM>1 only). *_small / *_large are the mean batch
 * figures at n_small=1 and n_large=BATCHNUM copies over RUNS batches each;
 * slope_* = (large-small)/(n_large-n_small) is the overhead-free marginal cost
 * per copy; intercept_* = small - slope is the fixed per-process cost. */
#define HDR_SLOPE \
    "timestamp_utc,run_id,pg_version,query,runs,n_small,n_large," \
    "wall_small_sec,wall_large_sec,slope_wall_sec,intercept_wall_sec," \
    "pkg_small_j,pkg_large_j,slope_pkg_j,intercept_pkg_j," \
    "core_small_j,core_large_j,slope_core_j,intercept_core_j,failed\n"

/*
 * Open a CSV for appending, writing the header only when the file is new.
 *
 * If the file already exists with a DIFFERENT header, refuse rather than
 * append: these logs take hours to produce, and silently mixing two column
 * layouts in one file corrupts every row that came before. Whoever changed the
 * schema should move the old file aside (or point the *_FILE knob elsewhere).
 */
static FILE *open_csv_append(const char *path, const char *header) {
    struct stat st;
    int is_new = (stat(path, &st) != 0 || st.st_size == 0);

    if (!is_new) {
        FILE *chk = fopen(path, "r");
        if (chk) {
            char have[8192];
            if (fgets(have, sizeof(have), chk)) {
                have[strcspn(have, "\r\n")] = '\0';
                char want[8192];
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
                        "  Move the old file aside, or point the matching *_FILE knob at a\n"
                        "  new path, then re-run.\n\n", path, have, want);
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

/* ================================================================== */
/* Catalog snapshot: how big was the data (Tier 2)                     */
/* ================================================================== */
/*
 * Row counts and byte sizes are a property of (server, database, relation), not
 * of an individual run - so they are written ONCE per sweep to their own CSV
 * rather than repeated on every sample row. Join it to the samples file on
 * pg_version + database + a name from the "relations" column to turn a raw
 * measurement into energy per row or per byte, which is what makes SF1/SF2/SF5
 * (or two different tables) comparable.
 *
 * Cost is ~1 ms for the whole snapshot, so it is taken on every sweep: sizes
 * drift as a database is rebuilt, and a stale snapshot would silently
 * mis-normalise every measurement joined to it.
 *
 * reltuples/relpages come from the catalog and are only as fresh as the last
 * ANALYZE (-1 means "never analyzed"); the *_bytes columns are measured from
 * the filesystem and are always exact.
 */
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
        "AND c.relkind IN ('r','i','m','p') "
        "ORDER BY n.nspname, c.relname\" 2>/dev/null",
        db_user, env_prefix, db_name);
    if (n <= 0 || n >= (int)sizeof(cmd)) { fclose(out); return; }

    FILE *p = popen(cmd, "r");
    if (!p) { fclose(out); return; }

    char ts[32];
    utc_timestamp(ts, sizeof(ts));
    char line[1024];
    int rows = 0;
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

/* ================================================================== */
/* Sigless power-meter markers (external device)                       */
/* ================================================================== */
/*
 * post_to_sigless.sh pings an external power-measurement device so its trace
 * can be lined up with our runs. It only fires when SIGLESS_ADDR is set, so by
 * default (no device attached) this is a no-op.
 */
static void sigless_post(const char *addr, const char *channel, const char *msg) {
    if (!addr || !*addr) return;

    char cmd[1024];
    int n = snprintf(cmd, sizeof(cmd),
                     "sh ./post_to_sigless.sh %s %s \"%s\" >/dev/null 2>&1",
                     addr, channel, msg);
    if (n > 0 && n < (int)sizeof(cmd)) {
        int rc = system(cmd);
        (void)rc;   /* best-effort marker; failures here must not stop a run */
    }
}

/* ================================================================== */
/* Query discovery                                                     */
/* ================================================================== */

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/*
 * Recursively collect every "*.sql" file under dir into files[] (each entry is
 * a heap-allocated full path). Recursion is what lets a single query directory
 * hold sub-folders like queries/Joins that can be targeted on their own.
 * Returns the number of files stored (capped at MAX_QUERIES).
 */
static int collect_queries(const char *dir, char **files, int count, int max) {
    DIR *d = opendir(dir);
    if (!d) {
        fprintf(stderr, "opendir(%s): %s\n", dir, strerror(errno));
        return count;
    }

    struct dirent *entry;
    while (count < max && (entry = readdir(d)) != NULL) {
        if (entry->d_name[0] == '.') continue;   /* skip ".", "..", hidden */

        char path[PATH_MAX];
        int n = snprintf(path, sizeof(path), "%s/%s", dir, entry->d_name);
        if (n <= 0 || n >= (int)sizeof(path)) continue;

        struct stat st;
        if (stat(path, &st) != 0) continue;

        if (S_ISDIR(st.st_mode)) {
            count = collect_queries(path, files, count, max);   /* descend */
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

/* ================================================================== */
/* Run one batch: measure it, write its timing + per-copy sample rows   */
/* ================================================================== */

typedef struct {
    double elapsed;      /* batch wall time                              */
    double e[4];         /* batch RAPL energy (pkg,core,gpu,dram)        */
    int    present[4];
    int    failed;
    int    ncopies;      /* copies whose plan parsed                     */
    double server_sum;   /* sum of the copies' Execution Time (ms)       */
} batch_result;

/*
 * Execute one batch (cmd runs a file holding this_batchnum copies), bracket it
 * for RAPL, parse the per-copy plans, and write ONE timing row plus one sample
 * row per copy. Returns the batch's wall/energy so the caller can accumulate
 * them for the slope fit.
 */
static batch_result run_one_batch(const char *cmd, const char *out_tmp,
                                  int this_batchnum, run_profile *profiles,
                                  FILE *log, FILE *samples,
                                  const char *run_id, const char *pg_version,
                                  const char *query_id, const char *phase,
                                  int batch_index, int runs, int warmup) {
    batch_result br;
    memset(&br, 0, sizeof(br));

    run_profile meta;
    profile_reset(&meta);                       /* rusage fields only */

    rapl_before(NULL, RAPL_CORE);
    double start = now_sec();
    int rc = run_once(cmd, &meta);
    br.elapsed = now_sec() - start;
    rapl_after_capture(RAPL_CORE, br.e, br.present);
    br.ncopies = parse_batch(out_tmp, profiles, this_batchnum);
    br.failed = (rc != 0);

    if (br.failed) {
        char err[512];
        first_error(out_tmp, err, sizeof(err));
        fprintf(stderr, "  %s batch %d FAILED (exit code %d) for %s%s%s\n",
                phase, batch_index, rc, query_id, *err ? "\n      " : "", err);
    }
    for (int c = 0; c < br.ncopies; c++)
        if (profiles[c].execution_ms >= 0) br.server_sum += profiles[c].execution_ms;

    double avg_copy = br.elapsed / this_batchnum;

    char ts[32];
    utc_timestamp(ts, sizeof(ts));

    /* --- one BATCH row --- */
    fprintf(log, "%s,%s,%s,%s,%s,%d,%d,%d,%d,%.6f,%.6f,",
            ts, run_id, pg_version, query_id, phase,
            batch_index, this_batchnum, runs, warmup, br.elapsed, avg_copy);
    if (br.ncopies > 0)
        fprintf(log, "%.3f,%.6f,", br.server_sum, br.elapsed - br.server_sum / 1000.0);
    else
        fprintf(log, ",,");
    fprintf(log, "%.6f,%.6f,%ld,%d,",
            meta.user_cpu_sec, meta.sys_cpu_sec, meta.max_rss_kb, br.failed);
    write_energy_columns(log, br.e, br.present);
    fprintf(log, "\n");
    fflush(log);

    /* --- one row per COPY --- */
    if (br.ncopies == 0) {
        run_profile empty; profile_reset(&empty);
        fprintf(samples, "%s,%s,%s,%s,%s,%d,%d,%d,%d,",
                ts, run_id, pg_version, query_id, phase, batch_index, 1, this_batchnum, runs);
        write_copy_profile(samples, &empty);
        fprintf(samples, "%d\n", br.failed);
    } else {
        for (int c = 0; c < br.ncopies; c++) {
            fprintf(samples, "%s,%s,%s,%s,%s,%d,%d,%d,%d,",
                    ts, run_id, pg_version, query_id, phase,
                    batch_index, c + 1, this_batchnum, runs);
            write_copy_profile(samples, &profiles[c]);
            fprintf(samples, "%d\n", br.failed);
        }
    }
    fflush(samples);
    return br;
}

/* ================================================================== */
/* Batch file: BATCHNUM copies of one query, generated at runtime       */
/* ================================================================== */
/*
 * Read the whole of src, then write it out batchnum times into dst (each copy
 * separated by a newline so a file without a trailing newline still parses).
 * Repeating the file verbatim keeps any leading "SET ..." lines with their
 * EXPLAIN - the SETs are session-local and idempotent, so re-applying them per
 * copy is harmless. dst is world-readable so the postgres user can read it via
 * sudo. Returns 0 on success. Called ONCE per query, outside every measurement
 * window, so its cost never lands in a timing or energy figure.
 */
static int build_batch_file(const char *src, const char *dst, int batchnum) {
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
    content[got] = '\0';

    FILE *out = fopen(dst, "wb");
    if (!out) { free(content); return -1; }
    for (int i = 0; i < batchnum; i++) {
        fwrite(content, 1, got, out);
        fputc('\n', out);
    }
    fclose(out);
    free(content);
    chmod(dst, 0644);
    return 0;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

static void print_config(const char *query_dir, const char *log_file,
                         const char *sample_file, const char *catalog_file,
                         const char *slope_file,
                         const char *db_name, const char *db_user,
                         int runs, int warmup, int batchnum, const char *sigless_addr,
                         const char *workers, const char *pg_port,
                         const char *stmt_timeout, const char *pg_version) {
    printf("query_runner configuration:\n");
    printf("  QUERY_DIR      = %s\n", query_dir);
    printf("  LOG_FILE       = %s\n", log_file);
    printf("  SAMPLE_FILE    = %s\n", sample_file);
    printf("  CATALOG_FILE   = %s\n", catalog_file);
    if (batchnum > 1) printf("  SLOPE_FILE     = %s\n", slope_file);
    printf("  DB_NAME        = %s\n", db_name);
    printf("  DB_USER        = %s\n", db_user);
    printf("  PGPORT         = %s\n",
           (pg_port && *pg_port) ? pg_port : "(psql default, 5432)");
    printf("  PG_VERSION     = %s  (as reported by the server on that port)\n", pg_version);
    if (batchnum > 1)
        printf("  BATCHNUM       = %d (slope sizes: 1 copy and %d copies)\n", batchnum, batchnum);
    else
        printf("  BATCHNUM       = 1 (single size, no slope)\n");
    printf("  RUNS           = %d (measured batches per size)\n", runs);
    printf("  WARMUP         = %d (single-copy; #1 primes cache, warm ones = N=1 anchor)\n", warmup);
    printf("  WORKERS        = %s\n",
           (workers && *workers) ? workers : "(planner default)");
    printf("  STATEMENT_TIMEOUT = %s\n",
           (stmt_timeout && *stmt_timeout) ? stmt_timeout : "(none)");
    printf("  SIGLESS_ADDR   = %s\n", (sigless_addr && *sigless_addr) ? sigless_addr : "(disabled)");
    fflush(stdout);
}

int main(void) {
    /* --- Configuration from the environment ------------------------ */
    const char *query_dir     = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *db_name       = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user       = env_or("DB_USER",   DEFAULT_DB_USER);

    /* All result CSVs default into ./logs (LOGS_DIR overrides). Created here so
     * open_csv_append's fopen("a") does not fail on a missing directory; an
     * explicit LOG_FILE/SAMPLE_FILE/CATALOG_FILE/SLOPE_FILE still overrides the
     * full path. */
    const char *logs_dir = env_or("LOGS_DIR", DEFAULT_LOGS_DIR);
    (void)mkdir(logs_dir, 0755);

    /* Log file defaults to a per-database name (query_timing_<db>.csv) so runs
     * against different databases land in separate files, while the column
     * layout stays identical for easy comparison across DB sizes. LOG_FILE
     * overrides it explicitly. */
    char log_file_buf[PATH_MAX];
    const char *log_file = getenv("LOG_FILE");
    if (!log_file || !*log_file) {
        snprintf(log_file_buf, sizeof(log_file_buf), "%s/%s%s.csv", logs_dir, DEFAULT_LOG_PREFIX, db_name);
        log_file = log_file_buf;
    }
    /* Companion per-run log: one row per individual execution, so run-to-run
     * variance (cache warming, sampling noise, CPU frequency ramp) can be
     * analysed instead of being hidden inside the aggregate. */
    char sample_file_buf[PATH_MAX];
    const char *sample_file = getenv("SAMPLE_FILE");
    if (!sample_file || !*sample_file) {
        snprintf(sample_file_buf, sizeof(sample_file_buf), "%s/%s%s.csv",
                 logs_dir, DEFAULT_SAMPLE_PREFIX, db_name);
        sample_file = sample_file_buf;
    }

    /* Relation sizes for this database, written once per sweep (Tier 2). */
    char catalog_file_buf[PATH_MAX];
    const char *catalog_file = getenv("CATALOG_FILE");
    if (!catalog_file || !*catalog_file) {
        snprintf(catalog_file_buf, sizeof(catalog_file_buf), "%s/%s%s.csv",
                 logs_dir, DEFAULT_CATALOG_PREFIX, db_name);
        catalog_file = catalog_file_buf;
    }

    /* Per-query fitted slope/intercept (written only when BATCHNUM>1). */
    char slope_file_buf[PATH_MAX];
    const char *slope_file = getenv("SLOPE_FILE");
    if (!slope_file || !*slope_file) {
        snprintf(slope_file_buf, sizeof(slope_file_buf), "%s/%s%s.csv",
                 logs_dir, DEFAULT_SLOPE_PREFIX, db_name);
        slope_file = slope_file_buf;
    }

    const char *sigless_addr  = env_or("SIGLESS_ADDR", "");
    const char *sigless_chan  = env_or("SIGLESS_CHANNEL", "CH1");

    int runs = atoi(env_or("RUNS", ""));
    if (runs <= 0) runs = DEFAULT_RUNS;

    /* Unmeasured runs executed before the measured ones. The first execution of
     * a query pays for cold binaries/libraries, a fresh backend's catalog cache
     * and uncached data pages - on this machine that is ~300 ms that has
     * nothing to do with the SQL. WARMUP=0 restores the old behaviour. */
    const char *warmup_env = getenv("WARMUP");
    int warmup = (warmup_env && *warmup_env) ? atoi(warmup_env) : DEFAULT_WARMUP;
    if (warmup < 0) warmup = 0;

    /* Copies of the query per batch. BATCHNUM=1 reproduces the old one-process-
     * per-query behaviour; larger values amortise the ~40 ms client overhead
     * across BATCHNUM copies that share one psql process. */
    const char *batchnum_env = getenv("BATCHNUM");
    int batchnum = (batchnum_env && *batchnum_env) ? atoi(batchnum_env) : DEFAULT_BATCHNUM;
    if (batchnum < 1) batchnum = 1;
    if (batchnum > MAX_BATCHNUM) {
        fprintf(stderr, "BATCHNUM capped at %d (was %d)\n", MAX_BATCHNUM, batchnum);
        batchnum = MAX_BATCHNUM;
    }

    /* Which cluster (i.e. which PostgreSQL major) and how many parallel workers
     * - see build_psql_env_prefix. Both empty => psql defaults, planner decides. */
    const char *pg_port = env_or("PGPORT", "");
    const char *workers = env_or("WORKERS", "");
    const char *stmt_timeout = env_or("STATEMENT_TIMEOUT", "");
    const char *env_prefix = build_psql_env_prefix(pg_port, workers, stmt_timeout);

    /* Stamped onto every row so results stay interpretable after an upgrade,
     * and so rows from different majors are never silently mixed. */
    const char *pg_version = query_pg_version(env_prefix, db_user, db_name);

    print_config(query_dir, log_file, sample_file, catalog_file, slope_file,
                 db_name, db_user, runs, warmup, batchnum, sigless_addr, workers,
                 pg_port, stmt_timeout, pg_version);

    /* --- Find the queries ------------------------------------------ */
    char *files[MAX_QUERIES];
    int count = collect_queries(query_dir, files, 0, MAX_QUERIES);
    if (count == 0) {
        fprintf(stderr, "No .sql files found under %s\n", query_dir);
        return 1;
    }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d queries under %s\n\n", count, query_dir);

    /* --- Prepare the RAPL energy counters -------------------------- */
    if (rapl_init(RAPL_CORE) != 0) {
        fprintf(stderr, "rapl_init failed (need root and the 'msr' module: sudo modprobe msr)\n");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    /* --- Open the CSV outputs (header written only for a new file) -- */
    FILE *log = open_csv_append(log_file, HDR_LOG);
    if (!log) {
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }
    FILE *samples = open_csv_append(sample_file, HDR_SAMPLES);
    if (!samples) {
        fclose(log);
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }
    /* The slope file exists only when there are two sizes to fit a line to. */
    FILE *slope = NULL;
    if (batchnum > 1) {
        slope = open_csv_append(slope_file, HDR_SLOPE);
        if (!slope) {
            fclose(log); fclose(samples);
            for (int i = 0; i < count; i++) free(files[i]);
            return 1;
        }
    }

    char run_id[32];
    make_run_id(run_id, sizeof(run_id));

    /* Snapshot relation sizes before measuring, so the sizes recorded are the
     * ones the sweep actually ran against. */
    write_catalog_snapshot(catalog_file, env_prefix, db_user, db_name,
                           pg_version, run_id);

    /* psql's stdout is captured rather than discarded so the EXPLAIN SUMMARY and
     * BUFFERS lines can be parsed back out of it; batch_tmp holds the BATCHNUM-
     * copy query file. Both are keyed by pid so parallel runners never collide. */
    char out_tmp[PATH_MAX], batch_tmp[PATH_MAX];
    snprintf(out_tmp,   sizeof(out_tmp),   "/tmp/query_runner_out_%d.txt",   (int)getpid());
    snprintf(batch_tmp, sizeof(batch_tmp), "/tmp/query_runner_batch_%d.sql", (int)getpid());

    /* One profile per copy in a batch, allocated once and reused. */
    run_profile *profiles = malloc((size_t)batchnum * sizeof(run_profile));
    if (!profiles) {
        fprintf(stderr, "out of memory for a %d-copy batch\n", batchnum);
        fclose(log); fclose(samples);
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    /* --- Run every query ------------------------------------------- */
    for (int q = 0; q < count; q++) {
        const char *full_path = files[q];
        /* Log the path as given rather than relative to QUERY_DIR, so a query
         * keeps the SAME identifier whether you sweep the whole tree or a
         * single sub-directory. Stripping the prefix would both collide
         * (queries/.../09-01_logical/and.sql vs .../09-06_bit_string/and.sql
         * would both log as "and.sql") and make rows from a full sweep
         * impossible to join with rows from a per-directory run. */
        const char *query_id  = full_path;

        /* The batch file is (re)built per size below, always outside the timing
         * and RAPL windows. cmd points at that file (a fixed path). */
        char cmd[MAX_CMD];
        int n = snprintf(cmd, sizeof(cmd),
                         /* ON_ERROR_STOP is what makes psql exit non-zero on a
                          * failed statement - without it psql reports the error
                          * and still exits 0, so every failure would be logged
                          * as a success. stderr joins stdout so the message is
                          * captured and can be shown (see first_error). */
                         "sudo -n -u %s %spsql -d %s -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
                         db_user, env_prefix, db_name, batch_tmp, out_tmp);
        if (n <= 0 || n >= (int)sizeof(cmd)) {
            fprintf(stderr, "Command too long for %s, skipping\n", query_id);
            continue;
        }

        /* The slope's N=1 anchor comes from the WARM warmups, not a dedicated
         * single-run phase: a warm 1-copy warmup is statistically identical to a
         * dedicated 1-copy measured run (verified <1% on every query with real
         * signal), so the two are the same measurement. The FIRST warmup primes
         * the cache and is cold, so it is excluded from the anchor whenever there
         * is a later, warm one (warmup >= 2). The N=BATCHNUM point is the
         * measured batches. index 0 = the N=1 anchor, index 1 = N=BATCHNUM. */
        if (batchnum > 1)
            printf("[%d/%d] %s (%d warmup [warm ones = N=1 anchor] + %d x%d)\n",
                   q + 1, count, query_id, warmup, runs, batchnum);
        else
            printf("[%d/%d] %s (%d warmup + %d run%s)\n",
                   q + 1, count, query_id, warmup, runs, runs == 1 ? "" : "s");
        fflush(stdout);

        char marker[PATH_MAX + 16];
        snprintf(marker, sizeof(marker), "start,%s", query_id);
        sigless_post(sigless_addr, sigless_chan, marker);

        int failures = 0;
        double acc_wall[2] = {0, 0}, acc_pkg[2] = {0, 0}, acc_core[2] = {0, 0};
        int    acc_n[2]    = {0, 0};

        /* --- warmup: WARMUP single-copy runs; the warm ones anchor N=1 --- */
        if (warmup > 0 && build_batch_file(full_path, batch_tmp, 1) == 0) {
            for (int w = 1; w <= warmup; w++) {
                batch_result br = run_one_batch(cmd, out_tmp, 1, profiles, log, samples,
                                                run_id, pg_version, query_id,
                                                "warmup", w, runs, warmup);
                /* Prime run = the first, when a warmer one follows it. */
                int is_prime = (warmup >= 2 && w == 1);
                if (batchnum > 1 && !is_prime && !br.failed) {
                    acc_wall[0] += br.elapsed;
                    acc_pkg[0]  += br.e[0];
                    acc_core[0] += br.e[1];
                    acc_n[0]++;
                }
                printf("  warmup %d/%d: %.6f sec, 1 copy (%s)\n", w, warmup, br.elapsed,
                       is_prime ? "cache prime" : (batchnum > 1 ? "N=1 anchor" : "not measured"));
                fflush(stdout);
            }
        }

        /* --- measured: RUNS batches at N=BATCHNUM (the large slope point) --- */
        if (build_batch_file(full_path, batch_tmp, batchnum) == 0) {
            for (int r = 1; r <= runs; r++) {
                batch_result br = run_one_batch(cmd, out_tmp, batchnum, profiles, log, samples,
                                                run_id, pg_version, query_id,
                                                "measured", r, runs, warmup);
                acc_wall[1] += br.elapsed;
                acc_pkg[1]  += br.e[0];
                acc_core[1] += br.e[1];
                acc_n[1]++;
                if (br.failed) failures++;

                printf("  batch %d/%d: %.6f sec, %d cop%s", r, runs,
                       br.elapsed, br.ncopies, br.ncopies == 1 ? "y" : "ies");
                if (br.server_sum > 0) printf(" (server sum %.3f ms)", br.server_sum);
                printf("\n");
                fflush(stdout);
            }
        } else {
            fprintf(stderr, "Could not build %d-copy file for %s\n", batchnum, query_id);
        }

        snprintf(marker, sizeof(marker), "end,%s", query_id);
        sigless_post(sigless_addr, sigless_chan, marker);

        /* --- fit the line: N=1 (warm warmup) to N=BATCHNUM (measured) --- */
        if (slope && acc_n[0] > 0 && acc_n[1] > 0) {
            double ws = acc_wall[0] / acc_n[0], wl = acc_wall[1] / acc_n[1];
            double ps = acc_pkg[0]  / acc_n[0], pl = acc_pkg[1]  / acc_n[1];
            double cs = acc_core[0] / acc_n[0], cl = acc_core[1] / acc_n[1];
            double denom = (double)(batchnum - 1);
            /* slope = per-copy marginal cost; intercept = fixed per-process cost
             * (= small - slope*1, since n_small is 1). */
            double sw = (wl - ws) / denom, iw = ws - sw;
            double sp = (pl - ps) / denom, ip = ps - sp;
            double sc = (cl - cs) / denom, ic = cs - sc;

            char ts[32]; utc_timestamp(ts, sizeof(ts));
            fprintf(slope,
                    "%s,%s,%s,%s,%d,%d,%d,"
                    "%.6f,%.6f,%.6f,%.6f,"
                    "%.6f,%.6f,%.6f,%.6f,"
                    "%.6f,%.6f,%.6f,%.6f,%d\n",
                    ts, run_id, pg_version, query_id, runs, 1, batchnum,
                    ws, wl, sw, iw,  ps, pl, sp, ip,  cs, cl, sc, ic,
                    failures > 0 ? 1 : 0);
            fflush(slope);

            printf("  slope: pkg %.4g J/exec (intercept %.4g J), "
                   "wall %.6f s/exec (intercept %.6f s)\n", sp, ip, sw, iw);
        } else {
            printf("  query total: %d measured batch%s (%d failure%s)\n",
                   acc_n[0] + acc_n[1], (acc_n[0] + acc_n[1]) == 1 ? "" : "es",
                   failures, failures == 1 ? "" : "s");
        }
        fflush(stdout);
    }

    unlink(out_tmp);
    unlink(batch_tmp);
    free(profiles);
    for (int i = 0; i < count; i++) free(files[i]);
    fclose(log);
    fclose(samples);
    if (slope) fclose(slope);

    printf("\nDone. Batch rows appended to %s\n", log_file);
    printf("Per-copy samples appended to %s\n", sample_file);
    printf("Relation sizes appended to %s\n", catalog_file);
    if (batchnum > 1) printf("Per-query slope/intercept appended to %s\n", slope_file);
    return 0;
}
