#define _GNU_SOURCE
/*
 * cold_runner.c
 *
 * A SEPARATE runner for COLD-CACHE energy/timing measurements. It deliberately
 * has nothing to do with the warm slope runner (query_runner.c): cold mode is a
 * different experiment, so it lives in its own program and writes its own CSV.
 *
 * For every .sql file under QUERY_DIR it runs the query RUNS times, and BEFORE
 * EACH run it forces a cold cache:
 *   1. drops the OS page cache   (sync; echo 3 > /proc/sys/vm/drop_caches), and
 *   2. restarts the PostgreSQL cluster (pg_ctlcluster <PGVER> main restart),
 *      which empties shared_buffers.
 * So every measured run reads its data from disk into an empty buffer pool - the
 * true cold-start cost. There is NO batching and NO warmup here; cold mode is
 * one query, one process, one cold execution, repeated RUNS times for variance.
 *
 * Results append to query_cold_<db>.csv (one row per cold run). A cold run's
 * shared_read_blks is large (data came from disk), which is exactly the signal.
 *
 * SAFETY: restarting a cluster kills every connection to it, so cold_runner
 * REFUSES to start if a query_runner/cold_runner is already using the target
 * PGPORT (e.g. a matrix sweep) - it will not restart a server out from under a
 * running sweep. DRYRUN=1 runs the queries WITHOUT dropping caches or restarting
 * (so the rows are warm, not cold) to validate the plumbing safely.
 *
 * Must run as root (RAPL MSRs, drop_caches, pg_ctlcluster) - the Makefile's
 * `make cold` handles the sudo.
 *
 * Configuration (environment variables; see print_config):
 *   QUERY_DIR   directory searched recursively for .sql files (default: queries)
 *   DB_NAME     database to run against                       (default: tpch)
 *   DB_USER     OS user psql runs as, via sudo                (default: postgres)
 *   RUNS        cold runs per query                           (default: 3)
 *   PGVER       PostgreSQL major, used to restart the cluster (required for the
 *               buffer reset; without it only the OS cache is dropped)
 *   PGPORT      cluster port                                  (default: psql's)
 *   STATEMENT_TIMEOUT  seconds before the server cancels a query (default: none)
 *   WORKERS     max_parallel_workers_per_gather for every query (default: planner)
 *   COLD_LOG    override the default query_cold_<db>.csv
 *   DRYRUN      1 = skip cache drop + restart (warm rows, for testing)
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

#define DEFAULT_QUERY_DIR  "queries"
#define DEFAULT_COLD_PREFIX "query_cold_"
#define DEFAULT_DB_NAME    "tpch"
#define DEFAULT_DB_USER    "postgres"
#define DEFAULT_RUNS       3
#define RAPL_CORE          0

#define MAX_QUERIES 8192
#define MAX_CMD     (2 * PATH_MAX + 512)
#define MAX_RELATIONS_LEN 480

/* ================================================================== */
/* Small helpers (kept local so this stays a standalone program)       */
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

/* Parse a non-negative integer, exiting on bad input; used for anything spliced
 * into a shell command line. */
static long require_uint(const char *name, const char *value) {
    char *end;
    long n = strtol(value, &end, 10);
    if (*end != '\0' || n < 0) {
        fprintf(stderr, "%s must be a non-negative integer, got \"%s\"\n", name, value);
        exit(1);
    }
    return n;
}

/* "env PGPORT=N PGOPTIONS='...' " prefix between `sudo -u USER` and `psql`. */
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
        line[strcspn(line, "\r\n, ")] = '\0';
        if (*line) snprintf(buf, sizeof(buf), "%s", line);
    }
    pclose(p);
    return buf;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Recursively collect "*.sql" files under dir (heap-allocated full paths). */
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

/* ================================================================== */
/* RAPL capture                                                        */
/* ================================================================== */

static int is_blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\t' && *s != '\r' && *s != '\n') return 0;
    return 1;
}

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
/* Plan profile: same fields the warm runner records                   */
/* ================================================================== */

typedef struct {
    double planning_ms, execution_ms;
    double user_cpu_sec, sys_cpu_sec;
    long   max_rss_kb;
    long   shared_hit, shared_read, shared_dirtied, shared_written;
    long   temp_read, temp_written;
    int    have_buffers;
    long      plan_nodes, scan_nodes;
    long long rows_out, rows_estimated, rows_processed, bytes_processed, rows_removed_filter;
    long      workers_launched;
    int       have_plan;
    char      relations[MAX_RELATIONS_LEN];
} run_profile;

static void profile_reset(run_profile *pr) {
    memset(pr, 0, sizeof(*pr));
    pr->planning_ms = pr->execution_ms = -1.0;
}

static void add_relation(run_profile *pr, const char *start) {
    char name[64];
    size_t i = 0;
    while (start[i] && start[i] != ' ' && start[i] != '(' && start[i] != ','
           && start[i] != '\n' && start[i] != '\r' && i < sizeof(name) - 1) {
        name[i] = start[i]; i++;
    }
    name[i] = '\0';
    if (i == 0) return;
    for (const char *t = pr->relations; *t; ) {
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

static void parse_plan_node(const char *line, const char *cost, run_profile *pr) {
    pr->plan_nodes++;
    pr->have_plan = 1;
    if (strstr(line, "Scan")) pr->scan_nodes++;
    const char *er = strstr(cost, "rows=");
    long long est = er ? atoll(er + 5) : 0;
    const char *wp = strstr(cost, "width=");
    long long width = wp ? atoll(wp + 6) : 0;
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

/* Parse ONE EXPLAIN plan (a cold run is a single query -> a single plan). */
static void parse_plan(const char *path, run_profile *pr) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[8192];
    while (fgets(line, sizeof(line), f)) {
        const char *p;
        const char *cost = strstr(line, "(cost=");
        if (cost) parse_plan_node(line, cost, pr);
        if ((p = strstr(line, "Planning Time:")) != NULL) {
            pr->planning_ms = atof(p + strlen("Planning Time:"));
        } else if ((p = strstr(line, "Execution Time:")) != NULL) {
            pr->execution_ms = atof(p + strlen("Execution Time:"));
        } else if ((p = strstr(line, "Workers Launched:")) != NULL) {
            pr->workers_launched = atol(p + strlen("Workers Launched:"));
        } else if ((p = strstr(line, "Rows Removed by Filter:")) != NULL) {
            pr->rows_removed_filter += atoll(p + strlen("Rows Removed by Filter:"));
        } else if (!pr->have_buffers && (p = strstr(line, "Buffers:")) != NULL) {
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
    }
    fclose(f);
}

/* Run cmd, fill pr's rusage; return child exit status (0 ok, -1 spawn fail). */
static int run_once(const char *cmd, run_profile *pr) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) { execl("/bin/sh", "sh", "-c", cmd, (char *)NULL); _exit(127); }
    int status = 0;
    struct rusage ru; memset(&ru, 0, sizeof(ru));
    if (wait4(pid, &status, 0, &ru) < 0) return -1;
    pr->user_cpu_sec = ru.ru_utime.tv_sec + ru.ru_utime.tv_usec * 1e-6;
    pr->sys_cpu_sec  = ru.ru_stime.tv_sec + ru.ru_stime.tv_usec * 1e-6;
    pr->max_rss_kb   = ru.ru_maxrss;
    if (WIFEXITED(status))   return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}

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

/* ================================================================== */
/* Cold CSV                                                            */
/* ================================================================== */

#define HDR_COLD \
    "timestamp_utc,run_id,pg_version,query,run_index,runs," \
    "elapsed_sec,server_planning_ms,server_execution_ms,client_overhead_sec," \
    "client_user_cpu_sec,client_sys_cpu_sec,client_max_rss_kb," \
    "shared_hit_blks,shared_read_blks,shared_dirtied_blks,shared_written_blks," \
    "temp_read_blks,temp_written_blks," \
    "plan_nodes,scan_nodes,rows_out,rows_processed,rows_estimated," \
    "bytes_processed,rows_removed_filter,workers_launched,relations,failed," \
    "rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j\n"

/* Open for append, writing the header only for a new file; refuse to append to
 * an existing file whose header differs (a schema change must not corrupt an
 * older log). */
static FILE *open_csv_append(const char *path, const char *header) {
    struct stat st;
    int is_new = (stat(path, &st) != 0 || st.st_size == 0);
    if (!is_new) {
        FILE *chk = fopen(path, "r");
        if (chk) {
            char have[8192];
            if (fgets(have, sizeof(have), chk)) {
                have[strcspn(have, "\r\n")] = '\0';
                char want[8192]; snprintf(want, sizeof(want), "%s", header);
                want[strcspn(want, "\r\n")] = '\0';
                if (strcmp(have, want) != 0) {
                    fclose(chk);
                    fprintf(stderr, "\nREFUSING to append to %s (header mismatch); "
                                    "move the old file aside.\n\n", path);
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
/* Cold mechanics: drop OS cache, restart cluster, safety guard        */
/* ================================================================== */

/* Drop the OS page cache so the next read comes from disk. Best-effort. */
static void drop_os_caches(void) {
    sync();
    FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
    if (!f) { fprintf(stderr, "  WARN: cannot drop OS cache: %s\n", strerror(errno)); return; }
    fputs("3\n", f);
    fclose(f);
}

/* Restart the cluster for PGVER to empty shared_buffers. Returns 0 on success.
 * Without PGVER there is no safe way to name the cluster, so shared_buffers is
 * left as-is (only the OS cache is cold) and a warning is printed once. */
static int reset_cluster(const char *pgver) {
    if (!pgver || !*pgver) return 1;   /* caller warns once */
    for (const char *c = pgver; *c; c++)
        if (*c < '0' || *c > '9') {
            fprintf(stderr, "  WARN: PGVER \"%s\" is not a version number; skipping restart\n", pgver);
            return 1;
        }
    char cmd[128];
    snprintf(cmd, sizeof(cmd), "pg_ctlcluster %s main restart > /dev/null 2>&1", pgver);
    int rc = system(cmd);
    if (rc != 0)
        fprintf(stderr, "  WARN: 'pg_ctlcluster %s main restart' failed (rc=%d); "
                        "shared_buffers not cleared\n", pgver, rc);
    return rc;
}

/* Return the pid of a running query_runner/cold_runner whose environment has
 * PGPORT=<port> (i.e. it is using the cluster we are about to restart), or 0.
 * Reads /proc, so it must run as root to see other users' processes. */
static long runner_using_port(const char *port) {
    if (!port || !*port) return 0;
    char want[64];
    snprintf(want, sizeof(want), "PGPORT=%s", port);
    DIR *d = opendir("/proc");
    if (!d) return 0;
    long found = 0;
    long self = (long)getpid();
    struct dirent *e;
    while ((e = readdir(d)) != NULL && !found) {
        char *end; long pid = strtol(e->d_name, &end, 10);
        if (*end != '\0' || pid <= 0 || pid == self) continue;
        char path[64], comm[64] = "";
        snprintf(path, sizeof(path), "/proc/%ld/comm", pid);
        FILE *cf = fopen(path, "r");
        if (!cf) continue;
        if (fgets(comm, sizeof(comm), cf)) comm[strcspn(comm, "\n")] = '\0';
        fclose(cf);
        if (strcmp(comm, "query_runner") != 0 && strcmp(comm, "cold_runner") != 0) continue;
        snprintf(path, sizeof(path), "/proc/%ld/environ", pid);
        FILE *ef = fopen(path, "r");
        if (!ef) continue;
        char buf[16384];
        size_t n = fread(buf, 1, sizeof(buf) - 1, ef);
        buf[n] = '\0';
        fclose(ef);
        for (size_t i = 0; i < n; ) {
            if (strcmp(buf + i, want) == 0) { found = pid; break; }
            i += strlen(buf + i) + 1;
        }
    }
    closedir(d);
    return found;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

static void print_config(const char *query_dir, const char *cold_log,
                         const char *db_name, const char *db_user, int runs,
                         const char *pgver, const char *pg_port,
                         const char *stmt_timeout, const char *pg_version, int dryrun) {
    printf("cold_runner configuration:\n");
    printf("  QUERY_DIR      = %s\n", query_dir);
    printf("  COLD_LOG       = %s\n", cold_log);
    printf("  DB_NAME        = %s\n", db_name);
    printf("  DB_USER        = %s\n", db_user);
    printf("  PGVER          = %s%s\n", (pgver && *pgver) ? pgver : "(unset)",
           (pgver && *pgver) ? "" : "  -> shared_buffers will NOT be cleared");
    printf("  PGPORT         = %s\n", (pg_port && *pg_port) ? pg_port : "(psql default)");
    printf("  PG_VERSION     = %s\n", pg_version);
    printf("  RUNS           = %d (cold runs per query)\n", runs);
    printf("  STATEMENT_TIMEOUT = %s\n", (stmt_timeout && *stmt_timeout) ? stmt_timeout : "(none)");
    printf("  MODE           = %s\n", dryrun ? "DRYRUN (no cache drop / no restart; rows are WARM)" : "COLD");
    fflush(stdout);
}

int main(void) {
    const char *query_dir = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *db_name   = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user   = env_or("DB_USER",   DEFAULT_DB_USER);
    const char *pgver     = env_or("PGVER", "");
    const char *pg_port   = env_or("PGPORT", "");
    const char *workers   = env_or("WORKERS", "");
    const char *stmt_timeout = env_or("STATEMENT_TIMEOUT", "");
    const char *dryrun_env = getenv("DRYRUN");
    int dryrun = (dryrun_env && *dryrun_env && strcmp(dryrun_env, "0") != 0);

    int runs = atoi(env_or("RUNS", ""));
    if (runs <= 0) runs = DEFAULT_RUNS;

    char cold_log_buf[PATH_MAX];
    const char *cold_log = getenv("COLD_LOG");
    if (!cold_log || !*cold_log) {
        snprintf(cold_log_buf, sizeof(cold_log_buf), "%s%s.csv", DEFAULT_COLD_PREFIX, db_name);
        cold_log = cold_log_buf;
    }

    const char *env_prefix = build_psql_env_prefix(pg_port, workers, stmt_timeout);
    const char *pg_version = query_pg_version(env_prefix, db_user, db_name);

    print_config(query_dir, cold_log, db_name, db_user, runs, pgver, pg_port,
                 stmt_timeout, pg_version, dryrun);

    /* SAFETY: never restart a cluster that a running sweep is using. */
    if (!dryrun) {
        long busy = runner_using_port(pg_port && *pg_port ? pg_port : "5432");
        if (busy > 0) {
            fprintf(stderr,
                "\nREFUSING to run: a runner (PID %ld) is using PGPORT=%s.\n"
                "Cold mode restarts that cluster, which would kill the running sweep.\n"
                "Wait until it finishes, or target a different PGVER/PGPORT.\n\n",
                busy, (pg_port && *pg_port) ? pg_port : "5432");
            return 1;
        }
        if (!pgver || !*pgver)
            fprintf(stderr, "  NOTE: PGVER unset - only the OS cache is dropped; "
                            "shared_buffers stays warm. Set PGVER for a true cold cache.\n");
    }

    char *files[MAX_QUERIES];
    int count = collect_queries(query_dir, files, 0, MAX_QUERIES);
    if (count == 0) { fprintf(stderr, "No .sql files under %s\n", query_dir); return 1; }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d queries under %s\n\n", count, query_dir);

    if (rapl_init(RAPL_CORE) != 0) {
        fprintf(stderr, "rapl_init failed (need root and the 'msr' module: sudo modprobe msr)\n");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    FILE *cold = open_csv_append(cold_log, HDR_COLD);
    if (!cold) { for (int i = 0; i < count; i++) free(files[i]); return 1; }

    char run_id[32];
    make_run_id(run_id, sizeof(run_id));

    char out_tmp[PATH_MAX];
    snprintf(out_tmp, sizeof(out_tmp), "/tmp/cold_runner_out_%d.txt", (int)getpid());

    int pgver_warned = 0;

    for (int q = 0; q < count; q++) {
        const char *query_id = files[q];

        char cmd[MAX_CMD];
        int n = snprintf(cmd, sizeof(cmd),
                         "sudo -n -u %s %spsql -d %s -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
                         db_user, env_prefix, db_name, query_id, out_tmp);
        if (n <= 0 || n >= (int)sizeof(cmd)) {
            fprintf(stderr, "Command too long for %s, skipping\n", query_id);
            continue;
        }

        printf("[%d/%d] %s (%d cold run%s)\n", q + 1, count, query_id,
               runs, runs == 1 ? "" : "s");
        fflush(stdout);

        for (int r = 1; r <= runs; r++) {
            /* Force a cold cache before EACH run (skipped in dryrun). */
            if (!dryrun) {
                drop_os_caches();
                int rc = reset_cluster(pgver);
                if (rc != 0 && (!pgver || !*pgver) && !pgver_warned) pgver_warned = 1;
            }

            double e[4]; int p[4];
            run_profile pr;
            profile_reset(&pr);

            rapl_before(NULL, RAPL_CORE);
            double start = now_sec();
            int rc = run_once(cmd, &pr);
            double elapsed = now_sec() - start;
            rapl_after_capture(RAPL_CORE, e, p);
            parse_plan(out_tmp, &pr);

            int failed = (rc != 0);
            if (failed) {
                char err[512];
                first_error(out_tmp, err, sizeof(err));
                fprintf(stderr, "  run %d FAILED (exit %d) for %s%s%s\n",
                        r, rc, query_id, *err ? "\n      " : "", err);
            }

            printf("  cold %d/%d: %.6f sec", r, runs, elapsed);
            if (pr.execution_ms >= 0) printf(" (server %.3f ms)", pr.execution_ms);
            if (pr.have_buffers) printf(" [read=%ld hit=%ld blks]", pr.shared_read, pr.shared_hit);
            printf("\n");
            fflush(stdout);

            char ts[32];
            utc_timestamp(ts, sizeof(ts));
            fprintf(cold, "%s,%s,%s,%s,%d,%d,%.6f,", ts, run_id, pg_version, query_id, r, runs, elapsed);
            if (pr.planning_ms >= 0)  fprintf(cold, "%.3f,", pr.planning_ms); else fprintf(cold, ",");
            if (pr.execution_ms >= 0) fprintf(cold, "%.3f,", pr.execution_ms); else fprintf(cold, ",");
            if (pr.execution_ms >= 0) {
                double srv = (pr.execution_ms + (pr.planning_ms > 0 ? pr.planning_ms : 0.0)) / 1000.0;
                fprintf(cold, "%.6f,", elapsed - srv);
            } else fprintf(cold, ",");
            fprintf(cold, "%.6f,%.6f,%ld,", pr.user_cpu_sec, pr.sys_cpu_sec, pr.max_rss_kb);
            if (pr.have_buffers)
                fprintf(cold, "%ld,%ld,%ld,%ld,%ld,%ld,", pr.shared_hit, pr.shared_read,
                        pr.shared_dirtied, pr.shared_written, pr.temp_read, pr.temp_written);
            else fprintf(cold, ",,,,,,");
            if (pr.have_plan)
                fprintf(cold, "%ld,%ld,%lld,%lld,%lld,%lld,%lld,%ld,%s,",
                        pr.plan_nodes, pr.scan_nodes, pr.rows_out, pr.rows_processed,
                        pr.rows_estimated, pr.bytes_processed, pr.rows_removed_filter,
                        pr.workers_launched, pr.relations);
            else fprintf(cold, ",,,,,,,,,");
            fprintf(cold, "%d,", failed);
            write_energy_columns(cold, e, p);
            fprintf(cold, "\n");
            fflush(cold);
        }
    }

    unlink(out_tmp);
    for (int i = 0; i < count; i++) free(files[i]);
    fclose(cold);

    printf("\nDone. Cold rows appended to %s\n", cold_log);
    return 0;
}
