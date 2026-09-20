#define _GNU_SOURCE
/*
 * write_runner.c
 *
 * COLD-ONLY energy/timing runner for WRITE (data-mutating) SQL. It is the
 * write-side counterpart of cold_runner.c and is deliberately kept apart from
 * the read runners so the canonical read databases can never be touched.
 *
 * Why cold only. A write changes the state it is measured on, and much of that
 * state is invisible to the SQL: dirty pages left in shared_buffers by the
 * previous execution, pending WAL, a checkpoint that lands mid-measurement,
 * autovacuum reacting to the rows the SETUP just inserted, dirty pages queued
 * in the OS writeback. Re-running the same file warm therefore drifts upward
 * from repeat to repeat, and batching several copies in one process is
 * impossible because the state must be rebuilt between copies. So every
 * measured execution here starts from the same, fully quiesced, cold state:
 *
 *   1. SETUP (not timed).  Everything above the "@MEASURE" line is run and
 *      committed: it rebuilds the disposable w_* scratch table(s) from the
 *      read-only reference copies in the scratch DB.
 *   2. QUIESCE (not timed). autovacuum is switched off on every w_* table (so
 *      it cannot fire inside the measured window - the vacuum tests measure
 *      an explicit VACUUM), then CHECKPOINT flushes the SETUP's dirty pages
 *      and WAL to disk.
 *   3. COLD START.  sync; echo 3 > drop_caches; pg_ctlcluster <PGVER> main
 *      restart; wait for pg_isready. Nothing of the SETUP is left in memory.
 *   4. MEASURE.  Only the section below "@MEASURE" is bracketed by RAPL and
 *      the wall clock. psql's \timing gives the in-session statement time and
 *      pg_current_wal_lsn() before/after gives the WAL bytes the write produced.
 *
 *          DROP TABLE IF EXISTS w_lineitem;                -- SETUP
 *          CREATE TABLE w_lineitem AS SELECT ... ;         --   (not timed)
 *          -- @MEASURE
 *          DELETE FROM w_lineitem WHERE l_quantity <= 25;  -- MEASURED
 *
 *      The marker must be a line of its own ("-- @MEASURE"); mentions of it
 *      inside other comments are ignored. A file with no marker line is
 *      measured in full (steps 2-4 only).
 *
 * There is no warm-up and no batching: one execution per cold start, RUNS
 * times per file, exactly like cold_runner. DRYRUN=1 keeps steps 1, 2 and 4
 * but skips the cache drop and restart (rows are then WARM, for plumbing tests).
 *
 * SAFETY.  The target DB_NAME must end in "_write" (the `make write-db` scratch
 * clone); anything else is refused, so a stray DB_NAME can never mutate a read
 * corpus. Restarting a cluster kills every connection to it, so the runner also
 * refuses to start when another query_runner/cold_runner/write_runner is using
 * the same PGPORT.
 *
 * Results append to write_cold_<db>.csv, one row per cold execution.
 *
 * Must run as root (RAPL MSRs, drop_caches, pg_ctlcluster) - `make write` does
 * the sudo. Configuration (environment variables; see print_config):
 *   QUERY_DIR   directory (recursive) or single .sql        (default: queries/write/tpch)
 *   DB_NAME     scratch database, must end in _write         (default: tpch_write)
 *   DB_USER     OS user psql runs as, via sudo               (default: postgres)
 *   RUNS        cold executions per file                     (default: 3)
 *   PGVER       PostgreSQL major, names the cluster to restart (required for a
 *               true cold cache; without it only the OS cache is dropped)
 *   PGPORT      cluster port                                 (default: psql's)
 *   STATEMENT_TIMEOUT  seconds before the server cancels a statement (default: none)
 *   LOGS_DIR    directory the CSV is written under           (default: logs)
 *   DRYRUN      1 = no cache drop / no restart (rows are WARM)
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

#define DEFAULT_QUERY_DIR   "queries/write/tpch"
#define DEFAULT_LOG_PREFIX  "write_cold_"
#define DEFAULT_LOGS_DIR    "logs"
#define DEFAULT_DB_NAME     "tpch_write"
#define DEFAULT_DB_USER     "postgres"
#define DEFAULT_RUNS        3
#define RAPL_CORE           0
#define SCRATCH_DB_SUFFIX   "_write"
#define READY_WAIT_SEC      30

#define MAX_QUERIES 32768
#define MAX_CMD     (2 * PATH_MAX + 512)
#define MEASURE_MARKER "@MEASURE"
#define WAL_TAG "WAL_BYTES="

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

static long require_uint(const char *name, const char *v) {
    char *end;
    long n = strtol(v, &end, 10);
    if (*end != '\0' || n < 0) {
        fprintf(stderr, "%s must be a non-negative integer, got \"%s\"\n", name, v);
        exit(1);
    }
    return n;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int ends_with(const char *s, const char *suffix) {
    size_t ls = strlen(s), lx = strlen(suffix);
    return ls >= lx && strcmp(s + ls - lx, suffix) == 0;
}

/* True only if s is blank (whitespace) up to its NUL. */
static int is_blank(const char *s) {
    for (; *s; s++) if (*s != ' ' && *s != '\t' && *s != '\r' && *s != '\n') return 0;
    return 1;
}

/*
 * "env PGPORT=N PGOPTIONS='-c statement_timeout=...' " fragment inserted after
 * `sudo -u USER`, selecting the cluster (= PostgreSQL major) and the per-session
 * GUCs. Empty means psql's default, 5432.
 */
static const char *build_psql_env_prefix(const char *port, const char *stmt_timeout) {
    static char buf[256];
    char port_part[48] = "";
    char opts[128] = "";
    if (port && *port)
        snprintf(port_part, sizeof(port_part), "PGPORT=%ld ", require_uint("PGPORT", port));
    if (stmt_timeout && *stmt_timeout)
        snprintf(opts, sizeof(opts), "-c statement_timeout=%ld000",
                 require_uint("STATEMENT_TIMEOUT", stmt_timeout));
    if (!*port_part && !*opts) buf[0] = '\0';
    else if (!*opts) snprintf(buf, sizeof(buf), "env %s", port_part);
    else snprintf(buf, sizeof(buf), "env %sPGOPTIONS='%s' ", port_part, opts);
    return buf;
}

/* Run one psql -tAc query and return its first output line (static buffer),
 * or "" on failure. Used for SHOW server_version only - never inside a
 * measured window, and never before a cold start (it would warm the catalog). */
static const char *psql_scalar(const char *env_prefix, const char *db_user,
                               const char *db_name, const char *sql) {
    static char buf[128];
    buf[0] = '\0';
    char cmd[MAX_CMD];
    int n = snprintf(cmd, sizeof(cmd),
                     "sudo -n -u %s %spsql -d %s -tAc \"%s\" 2>/dev/null",
                     db_user, env_prefix, db_name, sql);
    if (n <= 0 || n >= (int)sizeof(cmd)) return buf;
    FILE *p = popen(cmd, "r");
    if (!p) return buf;
    if (fgets(buf, sizeof(buf), p)) buf[strcspn(buf, "\r\n")] = '\0';
    pclose(p);
    return buf;
}

static const char *query_pg_version(const char *env_prefix,
                                    const char *db_user, const char *db_name) {
    static char buf[128] = "unknown";
    const char *v = psql_scalar(env_prefix, db_user, db_name, "SHOW server_version");
    char tmp[128];
    snprintf(tmp, sizeof(tmp), "%s", v);
    /* "16.14 (Ubuntu ...)" -> "16.14", CSV-safe */
    tmp[strcspn(tmp, ", ")] = '\0';
    if (*tmp) snprintf(buf, sizeof(buf), "%s", tmp);
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

/* Return the start of the first line that is exactly the @MEASURE marker:
 * optional whitespace, optional "--", optional whitespace, "@MEASURE", then
 * only whitespace to the end of the line. NULL if there is none. */
static char *find_marker_line(char *sql) {
    for (char *line = sql; line && *line; ) {
        char *nl = strchr(line, '\n');
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        while (*p == '-') p++;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, MEASURE_MARKER, strlen(MEASURE_MARKER)) == 0) {
            p += strlen(MEASURE_MARKER);
            while (*p == ' ' || *p == '\t' || *p == '\r') p++;
            if (*p == '\n' || *p == '\0') return line;
        }
        line = nl ? nl + 1 : NULL;
    }
    return NULL;
}

/* Write a temp SQL file the postgres user can read via sudo. */
static int write_temp_sql(const char *path, const char *head, const char *body, const char *tail) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    if (head) fputs(head, f);
    fputs(body, f);
    if (tail) fputs(tail, f);
    fclose(f);
    chmod(path, 0644);
    return 0;
}

/* ================================================================== */
/* RAPL: capture one before/after reading as accumulable numbers       */
/* ================================================================== */

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

static void write_energy_columns(FILE *out, const double e[4], const int present[4]) {
    fprintf(out, "%.18f,%.18f,", e[0], e[1]);
    if (present[2]) fprintf(out, "%.18f", e[2]);
    fprintf(out, ",");
    if (present[3]) fprintf(out, "%.18f", e[3]);
}

/* ================================================================== */
/* Per-execution profile                                               */
/* ================================================================== */
/*
 * stmt_ms   sum of every "Time: N ms" psql printed for the measured section
 *           (server work plus one round trip each, no process start-up).
 * wal_bytes pg_wal_lsn_diff() across the measured section, captured inside
 *           the same session so no extra connection warms anything first.
 * wait4() supplies the client tree's CPU and peak RSS; the backend is not our
 * descendant so its CPU is not included (RAPL covers it).
 */
typedef struct {
    double stmt_ms;          /* < 0 when psql printed no timing line */
    double wal_bytes;        /* < 0 when not captured */
    double user_cpu_sec;
    double sys_cpu_sec;
    long   max_rss_kb;
} run_profile;

static void profile_reset(run_profile *pr) {
    memset(pr, 0, sizeof(*pr));
    pr->stmt_ms = -1.0;
    pr->wal_bytes = -1.0;
}

static void parse_output(const char *path, run_profile *pr) {
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[4096];
    while (fgets(line, sizeof(line), f)) {
        const char *p = strstr(line, "Time: ");
        if (p && strstr(p, " ms")) {
            if (pr->stmt_ms < 0) pr->stmt_ms = 0.0;
            pr->stmt_ms += atof(p + strlen("Time: "));
            continue;
        }
        p = strstr(line, WAL_TAG);
        if (p) pr->wal_bytes = atof(p + strlen(WAL_TAG));
    }
    fclose(f);
}

/* Copy the first "ERROR:" line of a psql output into err (for the console). */
static void first_error(const char *path, char *err, size_t n) {
    err[0] = '\0';
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "ERROR:")) {
            line[strcspn(line, "\r\n")] = '\0';
            snprintf(err, n, "%s", line);
            break;
        }
    }
    fclose(f);
}

/*
 * Run one shell command, filling pr (if given) with the child's resource usage.
 * Returns the exit status (0 on success), or -1 if it could not run.
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

/* ================================================================== */
/* Cold mechanics: quiesce, drop OS cache, restart cluster, guard      */
/* ================================================================== */

/*
 * Run after every SETUP, before the cold start. Disables autovacuum on the
 * scratch tables so it cannot run inside the measured window (the SETUP just
 * inserted or updated 100k+ rows, which is exactly what triggers autoanalyse
 * and autovacuum), then checkpoints so the SETUP's dirty pages and WAL are on
 * disk and the restart is quick. Reference tables are never touched.
 */
static const char *QUIESCE_SQL =
    "DO $q$ DECLARE r record; BEGIN\n"
    "  FOR r IN SELECT schemaname, tablename FROM pg_tables\n"
    "           WHERE schemaname = 'public' AND tablename LIKE 'w\\_%' LOOP\n"
    "    EXECUTE format('ALTER TABLE %I.%I SET (autovacuum_enabled = false)', r.schemaname, r.tablename);\n"
    "  END LOOP;\n"
    "END $q$;\n"
    "CHECKPOINT;\n";

static void drop_os_caches(void) {
    sync();
    FILE *f = fopen("/proc/sys/vm/drop_caches", "w");
    if (!f) { fprintf(stderr, "  WARN: cannot drop OS cache: %s\n", strerror(errno)); return; }
    fputs("3\n", f);
    fclose(f);
}

/* Restart the cluster for PGVER (empties shared_buffers) and wait until it
 * accepts connections again, without opening one (pg_isready). 0 on success. */
static int reset_cluster(const char *pgver, const char *port) {
    if (!pgver || !*pgver) return 1;
    for (const char *c = pgver; *c; c++)
        if (*c < '0' || *c > '9') {
            fprintf(stderr, "  WARN: PGVER \"%s\" is not a version number; skipping restart\n", pgver);
            return 1;
        }
    char cmd[192];
    snprintf(cmd, sizeof(cmd), "pg_ctlcluster %s main restart > /dev/null 2>&1", pgver);
    int rc = system(cmd);
    if (rc != 0) {
        fprintf(stderr, "  WARN: 'pg_ctlcluster %s main restart' failed (rc=%d); "
                        "shared_buffers not cleared\n", pgver, rc);
        return rc;
    }
    if (port && *port) snprintf(cmd, sizeof(cmd), "pg_isready -q -p %s", port);
    else               snprintf(cmd, sizeof(cmd), "pg_isready -q");
    for (int i = 0; i < READY_WAIT_SEC; i++) {
        if (system(cmd) == 0) return 0;
        sleep(1);
    }
    fprintf(stderr, "  WARN: cluster not ready %d s after restart\n", READY_WAIT_SEC);
    return 1;
}

/* Pid of a RUNNING query_runner/cold_runner/write_runner whose environment has
 * PGPORT=<port>, or 0. Stopped (state T) or zombie processes are ignored: they
 * hold no connection. Reads /proc, so it must run as root. */
static long runner_using_port(const char *port) {
    if (!port || !*port) return 0;
    char want[64];
    snprintf(want, sizeof(want), "PGPORT=%s", port);
    DIR *d = opendir("/proc");
    if (!d) return 0;
    long found = 0, self = (long)getpid();
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
        if (strcmp(comm, "query_runner") != 0 && strcmp(comm, "cold_runner") != 0 &&
            strcmp(comm, "write_runner") != 0) continue;

        char state = '?';
        snprintf(path, sizeof(path), "/proc/%ld/stat", pid);
        FILE *sf = fopen(path, "r");
        if (sf) {
            char line[512];
            if (fgets(line, sizeof(line), sf)) {
                char *rp = strrchr(line, ')');
                if (rp && rp[1] == ' ') state = rp[2];
            }
            fclose(sf);
        }
        if (state == 'T' || state == 't' || state == 'Z') continue;

        snprintf(path, sizeof(path), "/proc/%ld/environ", pid);
        FILE *ef = fopen(path, "r");
        if (!ef) continue;
        char env[4096]; size_t got = fread(env, 1, sizeof(env) - 1, ef);
        fclose(ef);
        env[got] = '\0';
        for (size_t i = 0; i < got; i += strlen(env + i) + 1)
            if (strcmp(env + i, want) == 0) { found = pid; break; }
    }
    closedir(d);
    return found;
}

/* ================================================================== */
/* CSV                                                                 */
/* ================================================================== */

#define HDR_WRITE \
    "timestamp_utc,run_id,pg_version,query,run_index,runs,mode," \
    "setup_sec,elapsed_sec,stmt_ms,client_overhead_sec," \
    "client_user_cpu_sec,client_sys_cpu_sec,client_max_rss_kb,wal_bytes," \
    "failed,failed_stage,rapl_pkg_j,rapl_core_j,rapl_gpu_j,rapl_dram_j\n"

/* Append; write the header for a new file; refuse a file with another header. */
static FILE *open_csv_append(const char *path, const char *header) {
    struct stat st;
    int is_new = (stat(path, &st) != 0 || st.st_size == 0);
    if (!is_new) {
        FILE *chk = fopen(path, "r");
        if (chk) {
            char have[8192];
            if (!fgets(have, sizeof(have), chk)) have[0] = '\0';
            fclose(chk);
            if (strcmp(have, header) != 0) {
                fprintf(stderr, "REFUSING to append to %s: its header differs from this runner's.\n"
                                "Move it aside or use another LOGS_DIR.\n", path);
                return NULL;
            }
        }
    }
    FILE *f = fopen(path, "a");
    if (!f) { perror(path); return NULL; }
    if (is_new) { fputs(header, f); fflush(f); }
    return f;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

static void print_config(const char *query_dir, const char *log_file,
                         const char *db_name, const char *db_user, int runs,
                         const char *pgver, const char *pg_port,
                         const char *stmt_timeout, const char *pg_version, int dryrun) {
    printf("write_runner configuration:\n");
    printf("  QUERY_DIR         = %s\n", query_dir);
    printf("  LOG_FILE          = %s\n", log_file);
    printf("  DB_NAME           = %s  (scratch; must end in %s)\n", db_name, SCRATCH_DB_SUFFIX);
    printf("  DB_USER           = %s\n", db_user);
    printf("  PGVER             = %s  (cluster restarted before every execution)\n",
           (pgver && *pgver) ? pgver : "(unset: OS cache only)");
    printf("  PGPORT            = %s\n", (pg_port && *pg_port) ? pg_port : "(psql default, 5432)");
    printf("  PG_VERSION        = %s\n", pg_version);
    printf("  STATEMENT_TIMEOUT = %s\n", (stmt_timeout && *stmt_timeout) ? stmt_timeout : "(none)");
    printf("  RUNS              = %d cold execution%s per file (SETUP, quiesce, cold start, measure)\n",
           runs, runs == 1 ? "" : "s");
    printf("  MODE              = %s\n", dryrun ? "DRYRUN (no cache drop / no restart; rows are WARM)" : "COLD");
    fflush(stdout);
}

int main(void) {
    const char *query_dir    = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *db_name      = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user      = env_or("DB_USER",   DEFAULT_DB_USER);
    const char *pgver        = env_or("PGVER",     "");
    const char *pg_port      = env_or("PGPORT",    "");
    const char *stmt_timeout = env_or("STATEMENT_TIMEOUT", "");
    const char *logs_dir     = env_or("LOGS_DIR",  DEFAULT_LOGS_DIR);
    const char *dry          = env_or("DRYRUN",    "");
    int dryrun = (*dry && strcmp(dry, "0") != 0 && strcasecmp(dry, "false") != 0);
    int runs = atoi(env_or("RUNS", ""));
    if (runs <= 0) runs = DEFAULT_RUNS;

    /* SAFETY: only ever write to a scratch clone. */
    if (!ends_with(db_name, SCRATCH_DB_SUFFIX)) {
        fprintf(stderr,
            "REFUSING to run: DB_NAME=\"%s\" does not end in \"%s\".\n"
            "The write runner only targets a disposable scratch DB made by `make write-db`\n"
            "(WRITE_DB=<name>%s).\n", db_name, SCRATCH_DB_SUFFIX, SCRATCH_DB_SUFFIX);
        return 1;
    }

    const char *env_prefix = build_psql_env_prefix(pg_port, stmt_timeout);
    const char *pg_version = query_pg_version(env_prefix, db_user, db_name);

    (void)mkdir(logs_dir, 0755);
    char log_file[PATH_MAX];
    snprintf(log_file, sizeof(log_file), "%s/%s%s.csv", logs_dir, DEFAULT_LOG_PREFIX, db_name);

    print_config(query_dir, log_file, db_name, db_user, runs, pgver, pg_port,
                 stmt_timeout, pg_version, dryrun);

    if (strcmp(pg_version, "unknown") == 0) {
        fprintf(stderr, "Cannot connect to %s (port %s). Does the scratch DB exist? `make write-db`\n",
                db_name, *pg_port ? pg_port : "5432");
        return 1;
    }

    /* SAFETY: never restart a cluster that a running sweep is using. */
    if (!dryrun) {
        long busy = runner_using_port(*pg_port ? pg_port : "5432");
        if (busy > 0) {
            fprintf(stderr,
                "\nREFUSING to run: a runner (PID %ld) is using PGPORT=%s.\n"
                "Cold mode restarts that cluster, which would kill the running sweep.\n"
                "Wait until it finishes, or target a different PGVER/PGPORT.\n\n",
                busy, *pg_port ? pg_port : "5432");
            return 1;
        }
        if (!*pgver)
            fprintf(stderr, "  NOTE: PGVER unset - only the OS cache is dropped; "
                            "shared_buffers stays warm. Set PGVER for a true cold cache.\n");
    }

    /* QUERY_DIR may name a directory (searched recursively) or a single .sql. */
    char *files[MAX_QUERIES];
    int count;
    struct stat st_q;
    if (stat(query_dir, &st_q) == 0 && S_ISREG(st_q.st_mode)) {
        files[0] = strdup(query_dir);
        count = files[0] ? 1 : 0;
    } else {
        count = collect_queries(query_dir, files, 0, MAX_QUERIES);
        if (count >= MAX_QUERIES)
            fprintf(stderr, "warning: hit the MAX_QUERIES cap (%d) - files beyond it under %s were NOT collected\n", MAX_QUERIES, query_dir);
    }
    if (count == 0) { fprintf(stderr, "No .sql files under %s\n", query_dir); return 1; }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d write files under %s\n\n", count, query_dir);

    if (rapl_init(RAPL_CORE) != 0) {
        fprintf(stderr, "rapl_init failed (need root and the 'msr' module: sudo modprobe msr)\n");
        for (int i = 0; i < count; i++) free(files[i]);
        return 1;
    }

    FILE *log = open_csv_append(log_file, HDR_WRITE);
    if (!log) { for (int i = 0; i < count; i++) free(files[i]); return 1; }

    char run_id[32];
    make_run_id(run_id, sizeof(run_id));

    /* Temp files (world-readable) so the postgres user can read them via sudo. */
    char setup_tmp[PATH_MAX], quiesce_tmp[PATH_MAX], measure_tmp[PATH_MAX], out_tmp[PATH_MAX];
    snprintf(setup_tmp,   sizeof(setup_tmp),   "/tmp/write_runner_setup_%d.sql",   (int)getpid());
    snprintf(quiesce_tmp, sizeof(quiesce_tmp), "/tmp/write_runner_quiesce_%d.sql", (int)getpid());
    snprintf(measure_tmp, sizeof(measure_tmp), "/tmp/write_runner_measure_%d.sql", (int)getpid());
    snprintf(out_tmp,     sizeof(out_tmp),     "/tmp/write_runner_out_%d.txt",     (int)getpid());
    if (write_temp_sql(quiesce_tmp, NULL, QUIESCE_SQL, NULL) != 0) {
        perror("quiesce temp file");
        return 1;
    }

    char setup_cmd[MAX_CMD], quiesce_cmd[MAX_CMD], measure_cmd[MAX_CMD];
    snprintf(setup_cmd, sizeof(setup_cmd),
             "sudo -n -u %s %spsql -d %s -q -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
             db_user, env_prefix, db_name, setup_tmp, out_tmp);
    snprintf(quiesce_cmd, sizeof(quiesce_cmd),
             "sudo -n -u %s %spsql -d %s -q -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
             db_user, env_prefix, db_name, quiesce_tmp, out_tmp);
    /* The measured file captures the WAL position before \timing is switched on
     * and reports the difference after it is switched off, so both bookends
     * stay out of stmt_ms and no extra connection is opened. */
    snprintf(measure_cmd, sizeof(measure_cmd),
             "sudo -n -u %s %spsql -d %s -q -v ON_ERROR_STOP=1 -f \"%s\" > \"%s\" 2>&1",
             db_user, env_prefix, db_name, measure_tmp, out_tmp);

    static const char MEASURE_HEAD[] =
        "SELECT pg_current_wal_lsn() AS wal_start \\gset\n"
        "\\timing on\n";
    static const char MEASURE_TAIL[] =
        "\n\\timing off\n"
        "SELECT '" WAL_TAG "' || pg_wal_lsn_diff(pg_current_wal_lsn(), :'wal_start');\n";

    const char *mode = dryrun ? "dryrun" : "cold";
    int total_failed = 0;

    for (int q = 0; q < count; q++) {
        const char *query_id = files[q];

        char *sql = read_file(query_id);
        if (!sql) { fprintf(stderr, "Could not read %s, skipping\n", query_id); continue; }

        /* Split at the marker LINE ("-- @MEASURE" and nothing else on it). A
         * plain substring search is not enough: the files' header comments
         * mention @MEASURE in prose, which would put the whole SETUP inside
         * the measured window. */
        char *line_start = find_marker_line(sql);
        const char *setup_sql = NULL;
        const char *measure_sql = sql;
        char *setup_buf = NULL;
        if (line_start) {
            char *line_end = strchr(line_start, '\n');
            measure_sql = line_end ? line_end + 1 : "";
            size_t setup_len = (size_t)(line_start - sql);
            setup_buf = malloc(setup_len + 1);
            if (setup_buf) {
                memcpy(setup_buf, sql, setup_len);
                setup_buf[setup_len] = '\0';
                if (!is_blank(setup_buf)) setup_sql = setup_buf;
            }
        }

        if (write_temp_sql(measure_tmp, MEASURE_HEAD, measure_sql, MEASURE_TAIL) != 0 ||
            (setup_sql && write_temp_sql(setup_tmp, NULL, setup_sql, NULL) != 0)) {
            fprintf(stderr, "temp write failed for %s, skipping\n", query_id);
            free(sql); free(setup_buf);
            continue;
        }

        printf("[%d/%d] %s (%d %s execution%s%s)\n", q + 1, count, query_id,
               runs, mode, runs == 1 ? "" : "s",
               setup_sql ? ", SETUP before each" : ", no SETUP section");
        fflush(stdout);

        for (int r = 1; r <= runs; r++) {
            run_profile pr;
            profile_reset(&pr);
            double setup_sec = 0.0, elapsed = 0.0;
            double e[4] = {0, 0, 0, 0}; int p[4] = {0, 0, 0, 0};
            const char *failed_stage = "";
            char err[512] = "";

            /* 1. SETUP: rebuild the scratch state (not timed, but recorded). */
            if (setup_sql) {
                double t0 = now_sec();
                int src = run_once(setup_cmd, NULL);
                setup_sec = now_sec() - t0;
                if (src != 0) {
                    first_error(out_tmp, err, sizeof(err));
                    fprintf(stderr, "  run %d SETUP FAILED (exit %d) for %s%s%s\n",
                            r, src, query_id, *err ? "\n      " : "", err);
                    failed_stage = "setup";
                }
            }

            /* 2. QUIESCE: autovacuum off on w_* tables, CHECKPOINT. */
            if (!*failed_stage) {
                int qrc = run_once(quiesce_cmd, NULL);
                if (qrc != 0) {
                    first_error(out_tmp, err, sizeof(err));
                    fprintf(stderr, "  run %d QUIESCE FAILED (exit %d) for %s%s%s\n",
                            r, qrc, query_id, *err ? "\n      " : "", err);
                    failed_stage = "quiesce";
                }
            }

            /* 3. COLD START (skipped in dryrun). */
            if (!*failed_stage && !dryrun) {
                drop_os_caches();
                if (reset_cluster(pgver, pg_port) != 0 && *pgver) {
                    fprintf(stderr, "  run %d: restart failed, skipping this execution\n", r);
                    failed_stage = "restart";
                }
            }

            /* 4. MEASURE. */
            if (!*failed_stage) {
                rapl_before(NULL, RAPL_CORE);
                double start = now_sec();
                int rc = run_once(measure_cmd, &pr);
                elapsed = now_sec() - start;
                rapl_after_capture(RAPL_CORE, e, p);
                parse_output(out_tmp, &pr);
                if (rc != 0) {
                    first_error(out_tmp, err, sizeof(err));
                    fprintf(stderr, "  run %d FAILED (exit %d) for %s%s%s\n",
                            r, rc, query_id, *err ? "\n      " : "", err);
                    failed_stage = "measure";
                }
                printf("  %s %d/%d: %.6f sec", mode, r, runs, elapsed);
                if (pr.stmt_ms >= 0)   printf(" (stmt %.3f ms)", pr.stmt_ms);
                if (pr.wal_bytes >= 0) printf(" [wal %.1f MB]", pr.wal_bytes / 1048576.0);
                if (setup_sql)         printf(" setup %.2f s", setup_sec);
                printf("\n");
                fflush(stdout);
            }

            int failed = (*failed_stage != '\0');
            if (failed) total_failed++;

            char ts[32];
            utc_timestamp(ts, sizeof(ts));
            fprintf(log, "%s,%s,%s,%s,%d,%d,%s,%.3f,%.6f,",
                    ts, run_id, pg_version, query_id, r, runs, mode, setup_sec, elapsed);
            if (pr.stmt_ms >= 0) fprintf(log, "%.3f,%.6f,", pr.stmt_ms, elapsed - pr.stmt_ms / 1000.0);
            else                 fprintf(log, ",,");
            fprintf(log, "%.6f,%.6f,%ld,", pr.user_cpu_sec, pr.sys_cpu_sec, pr.max_rss_kb);
            if (pr.wal_bytes >= 0) fprintf(log, "%.0f,", pr.wal_bytes); else fprintf(log, ",");
            fprintf(log, "%d,%s,", failed, failed_stage);
            write_energy_columns(log, e, p);
            fprintf(log, "\n");
            fflush(log);
        }

        free(sql);
        free(setup_buf);
    }

    unlink(setup_tmp);
    unlink(quiesce_tmp);
    unlink(measure_tmp);
    unlink(out_tmp);
    for (int i = 0; i < count; i++) free(files[i]);
    fclose(log);

    printf("\nDone. %d failed execution%s. Rows appended to %s\n",
           total_failed, total_failed == 1 ? "" : "s", log_file);
    return 0;
}
