#define _GNU_SOURCE
/*
 * plan_builder.c
 *
 * A deliberately simple companion to query_runner.c. It does NOT measure time
 * or energy. It runs every query once and saves its query plan as a text file,
 * so there is a readable record of how each statement is executed.
 *
 * For every .sql file under QUERY_DIR it:
 *   1. reads the SQL,
 *   2. checks whether the statement already asks for a plan (EXPLAIN ANALYZE);
 *      if not, it prepends "EXPLAIN ANALYZE" so a plan is produced anyway,
 *   3. runs it through psql and writes the plan to PLANS_DIR/<db>/, mirroring
 *      the query folder structure with the query name as the .txt file name.
 *
 *   queries/tpch/Functions/09-01_logical/and.sql -> plans/tpch/Functions/09-01_logical/and.txt
 *
 * APPEND MODE (APPEND=1) - plan CONSISTENCY testing. Instead of replacing the
 * .txt, each run appends a dated snapshot section:
 *
 *   -- ==== plan_builder snapshot 3  2026-09-18T12:00:00Z  pg=18.4  db=tpch ====
 *   <the plan>
 *
 * and compares the new plan's SHAPE with the previous snapshot in the file.
 * "Shape" strips the numbers that legitimately vary run to run (cost/row
 * estimates, actual times and row counts, buffers, memory, timing lines), so
 * it only changes when the planner picked a different plan (join order, scan
 * or join method, ...). Each query prints "same shape" or "SHAPE CHANGED", and
 * the final summary counts the changed ones. Run `make plans APPEND=1`
 * repeatedly (test/plan_snapshots.sh does this) to check the planner is stable.
 *
 * Configuration (environment variables):
 *   QUERY_DIR   directory searched recursively for .sql files (default: queries/tpch/tpch-queries)
 *   PLANS_DIR   root the plans are written under               (default: plans)
 *   DB_NAME     database to run against                        (default: tpch)
 *   DB_USER     OS user psql runs as, via sudo                 (default: postgres)
 *   PGPORT      cluster port (= PostgreSQL major)              (default: psql's)
 *   WORKERS     max_parallel_workers_per_gather cap            (default: planner)
 *   APPEND      1 = append snapshots + compare shapes          (default: replace)
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
#include <limits.h>
#include <stdint.h>

#define DEFAULT_QUERY_DIR "queries/tpch/tpch-queries"
#define DEFAULT_PLANS_DIR "plans"
#define DEFAULT_DB_NAME   "tpch"
#define DEFAULT_DB_USER   "postgres"

#define MAX_QUERIES 32768
#define MAX_CMD     4096
#define SNAPSHOT_PREFIX "-- ==== plan_builder snapshot "

/* ================================================================== */
/* Helpers (kept local so this stays a standalone, single-file tool)   */
/* ================================================================== */

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
}

static long require_uint(const char *name, const char *value) {
    char *end;
    long n = strtol(value, &end, 10);
    if (*end != '\0' || n < 0) {
        fprintf(stderr, "%s must be a non-negative integer, got \"%s\"\n", name, value);
        exit(1);
    }
    return n;
}

static void utc_timestamp(char *buf, size_t buf_size) {
    time_t t = time(NULL);
    struct tm tm_utc;
    if (gmtime_r(&t, &tm_utc) == NULL) { if (buf_size) buf[0] = '\0'; return; }
    strftime(buf, buf_size, "%Y-%m-%dT%H:%M:%SZ", &tm_utc);
}

/* "env PGPORT=N PGOPTIONS='...' " between `sudo -u USER` and `psql`, so the
 * plans come from the same cluster / worker cap the runner would use. */
static const char *build_psql_env_prefix(const char *port, const char *workers) {
    static char buf[160];
    char port_part[48] = "";
    char opts_part[96] = "";
    if (port && *port)
        snprintf(port_part, sizeof(port_part), "PGPORT=%ld ", require_uint("PGPORT", port));
    if (workers && *workers)
        snprintf(opts_part, sizeof(opts_part), "PGOPTIONS='-c max_parallel_workers_per_gather=%ld' ",
                 require_uint("WORKERS", workers));
    if (!*port_part && !*opts_part) buf[0] = '\0';
    else snprintf(buf, sizeof(buf), "env %s%s", port_part, opts_part);
    return buf;
}

static const char *query_pg_version(const char *env_prefix, const char *db_user, const char *db_name) {
    static char buf[64] = "unknown";
    char cmd[MAX_CMD];
    int n = snprintf(cmd, sizeof(cmd), "sudo -n -u %s %spsql -d %s -tAc \"SHOW server_version\" 2>/dev/null",
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

/* Every *.sql under dir, recursively (mirrors query_runner.c). */
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

/* Give a file/dir back to the human who ran us under sudo. */
static void chown_to_invoker(const char *path) {
    if (geteuid() != 0) return;
    const char *uid_s = getenv("SUDO_UID");
    const char *gid_s = getenv("SUDO_GID");
    if (!uid_s || !gid_s) return;
    if (chown(path, (uid_t)atoi(uid_s), (gid_t)atoi(gid_s)) != 0) { /* best effort */ }
}

/* mkdir -p, chowning each level we create. */
static int ensure_dir(const char *dir_path) {
    char tmp[PATH_MAX];
    size_t len = strlen(dir_path);
    if (len == 0 || len >= sizeof(tmp)) return -1;
    memcpy(tmp, dir_path, len + 1);
    if (tmp[len - 1] == '/') tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) == 0) chown_to_invoker(tmp);
            else if (errno != EEXIST) return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) == 0) chown_to_invoker(tmp);
    else if (errno != EEXIST) return -1;
    return 0;
}

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

/* ================================================================== */
/* Verification: does the SQL already produce a plan?                  */
/* ================================================================== */

static int is_ident_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

/* Skip whitespace and SQL comments. */
static const char *skip_noise(const char *s) {
    for (;;) {
        while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
        if (s[0] == '-' && s[1] == '-') { s += 2; while (*s && *s != '\n') s++; continue; }
        if (s[0] == '/' && s[1] == '*') {
            s += 2;
            while (*s && !(s[0] == '*' && s[1] == '/')) s++;
            if (*s) s += 2;
            continue;
        }
        break;
    }
    return s;
}

static int region_has_analyze(const char *start, const char *end) {
    for (const char *p = start; p + 7 <= end; p++) {
        if (strncasecmp(p, "ANALYZE", 7) == 0) {
            char before = (p == start) ? ' ' : p[-1];
            if (!is_ident_char(before) && !is_ident_char(p[7])) return 1;
        }
    }
    return 0;
}

typedef enum { PLAN_HAS_ANALYZE, PLAN_EXPLAIN_ONLY, PLAN_NO_EXPLAIN } plan_kind;

static plan_kind classify(const char *sql) {
    const char *p = skip_noise(sql);
    if (strncasecmp(p, "EXPLAIN", 7) != 0 || is_ident_char(p[7])) return PLAN_NO_EXPLAIN;
    const char *q = p + 7;
    while (*q == ' ' || *q == '\t' || *q == '\r' || *q == '\n') q++;
    const char *region_start, *region_end;
    if (*q == '(') {
        region_start = q + 1;
        const char *close = strchr(q, ')');
        region_end = close ? close : (q + strlen(q));
    } else {
        region_start = q; region_end = q;
        while (*region_end && *region_end != '\n' && (size_t)(region_end - q) < 40) region_end++;
    }
    return region_has_analyze(region_start, region_end) ? PLAN_HAS_ANALYZE : PLAN_EXPLAIN_ONLY;
}

/* ================================================================== */
/* Plan shape hashing (APPEND mode)                                    */
/* ================================================================== */
/*
 * The shape of a plan = its text with everything that varies between runs of
 * the SAME plan removed: "(cost=...)" and "(actual ...)" groups, and the
 * lines that report timings, buffers, memory or per-worker detail. What is
 * left is the tree of node types, the relations and the join/scan methods -
 * which is what "did the planner pick the same plan" means.
 */
static int is_noise_line(const char *line) {
    static const char *prefixes[] = {
        "Planning Time", "Execution Time", "Buffers:", "Planning:", "Sort Method",
        "Heap Blocks", "Rows Removed", "Workers Launched", "Workers Planned", "Worker ",
        "Memory Usage", "Batches", "Peak Memory", "I/O Timings", "JIT", "Timing:",
        "Functions:", "Options:", "Hash Batches", "Heap Fetches", "Storage:",
        "Maximum Storage", "Presorted Key", "Full-sort Groups", "Pre-sorted Groups",
        "Index Searches", "Disk Usage", NULL };
    while (*line == ' ' || *line == '\t') line++;
    if (strncmp(line, "->", 2) == 0) { line += 2; while (*line == ' ') line++; }
    for (int i = 0; prefixes[i]; i++)
        if (strncmp(line, prefixes[i], strlen(prefixes[i])) == 0) return 1;
    return 0;
}

/* Copy line into out without its "(cost=...)" / "(actual ...)" groups. */
static void strip_estimates(const char *line, char *out, size_t out_size) {
    size_t o = 0;
    for (const char *p = line; *p && o + 1 < out_size; ) {
        if (strncmp(p, "(cost=", 6) == 0 || strncmp(p, "(actual ", 8) == 0) {
            const char *close = strchr(p, ')');
            if (!close) break;
            p = close + 1;
            continue;
        }
        out[o++] = *p++;
    }
    out[o] = '\0';
    while (o > 0 && (out[o - 1] == ' ' || out[o - 1] == '\r' || out[o - 1] == '\n')) out[--o] = '\0';
}

static uint64_t fnv1a(uint64_t h, const char *s) {
    for (; *s; s++) { h ^= (unsigned char)*s; h *= 1099511628211ULL; }
    return h;
}

/* Hash the shape of the LAST snapshot section in an appended plan file (or of
 * the whole file when it holds no snapshot markers). Returns 0 for "no plan
 * found"; *snapshots gets the number of snapshot sections present. */
static uint64_t last_snapshot_shape(const char *path, int *snapshots) {
    *snapshots = 0;
    char *text = read_file(path);
    if (!text) return 0;
    const char *last = NULL;
    for (const char *p = text; (p = strstr(p, SNAPSHOT_PREFIX)) != NULL; p += strlen(SNAPSHOT_PREFIX)) {
        if (p == text || p[-1] == '\n') { (*snapshots)++; last = p; }
    }
    const char *start = last ? strchr(last, '\n') : text;
    if (!start) { free(text); return 0; }
    if (last) start++;

    uint64_t h = 1469598103934665603ULL;
    int lines = 0;
    char line[8192], stripped[8192];
    const char *p = start;
    while (*p) {
        const char *nl = strchr(p, '\n');
        size_t len = nl ? (size_t)(nl - p) : strlen(p);
        if (len >= sizeof(line)) len = sizeof(line) - 1;
        memcpy(line, p, len); line[len] = '\0';
        p = nl ? nl + 1 : p + len;
        if (is_noise_line(line)) continue;
        strip_estimates(line, stripped, sizeof(stripped));
        if (!*stripped) continue;
        h = fnv1a(h, stripped);
        h = fnv1a(h, "\n");
        lines++;
    }
    free(text);
    return lines ? h : 0;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

int main(void) {
    const char *query_dir  = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *plans_dir  = env_or("PLANS_DIR", DEFAULT_PLANS_DIR);
    const char *db_name    = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user    = env_or("DB_USER",   DEFAULT_DB_USER);
    const char *workers    = env_or("WORKERS",   "");
    const char *pg_port    = env_or("PGPORT",    "");
    const char *append_env = getenv("APPEND");
    int append = (append_env && *append_env && strcmp(append_env, "0") != 0);
    const char *env_prefix = build_psql_env_prefix(pg_port, workers);
    const char *pg_version = query_pg_version(env_prefix, db_user, db_name);

    /* Plans go under <PLANS_DIR>/<DB_NAME>/ so tpch and tpch_idx never overwrite each other. */
    char plans_base[PATH_MAX];
    snprintf(plans_base, sizeof(plans_base), "%s/%s", plans_dir, db_name);

    printf("plan_builder configuration:\n");
    printf("  QUERY_DIR = %s\n", query_dir);
    printf("  PLANS_DIR = %s  (plans -> %s/)\n", plans_dir, plans_base);
    printf("  DB_NAME   = %s   DB_USER = %s\n", db_name, db_user);
    printf("  PGPORT    = %s  (server reports %s)\n", *pg_port ? pg_port : "(psql default, 5432)", pg_version);
    printf("  WORKERS   = %s\n", *workers ? workers : "(planner default)");
    printf("  MODE      = %s\n\n", append ? "APPEND (snapshot appended, shape compared with the previous one)"
                                          : "replace (each plan file overwritten)");

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
    printf("Found %d queries under %s\n\n", count, query_dir);

    /* Mirror the layout below QUERY_DIR (for a single file: just its name). */
    size_t dir_prefix = 0;
    if (!S_ISREG(st_q.st_mode)) {
        dir_prefix = strlen(query_dir);
        if (dir_prefix > 0 && query_dir[dir_prefix - 1] != '/') dir_prefix++;
    }

    if (ensure_dir(plans_base) != 0) { fprintf(stderr, "Failed to create plans dir: %s\n", plans_base); return 1; }
    chown_to_invoker(plans_dir);
    chown_to_invoker(plans_base);

    char temp_sql[PATH_MAX];
    snprintf(temp_sql, sizeof(temp_sql), "/tmp/plan_builder_%d.sql", (int)getpid());

    int failures = 0, wrapped = 0, explain_only = 0, changed = 0, compared = 0;

    for (int q = 0; q < count; q++) {
        const char *full_path = files[q];
        const char *rel = S_ISREG(st_q.st_mode) ? strrchr(full_path, '/') : full_path + dir_prefix;
        if (S_ISREG(st_q.st_mode)) rel = rel ? rel + 1 : full_path;

        char plan_path[PATH_MAX];
        int rel_len = (int)strlen(rel);
        int stem_len = (rel_len >= 4) ? rel_len - 4 : rel_len;
        int n = snprintf(plan_path, sizeof(plan_path), "%s/%.*s.txt", plans_base, stem_len, rel);
        if (n <= 0 || n >= (int)sizeof(plan_path)) { fprintf(stderr, "Plan path too long for %s, skipping\n", rel); failures++; continue; }

        char plan_dir[PATH_MAX];
        snprintf(plan_dir, sizeof(plan_dir), "%s", plan_path);
        char *slash = strrchr(plan_dir, '/');
        if (slash) {
            *slash = '\0';
            if (ensure_dir(plan_dir) != 0) { fprintf(stderr, "Failed to create %s, skipping\n", plan_dir); failures++; continue; }
        }

        char *sql = read_file(full_path);
        if (!sql) { fprintf(stderr, "Could not read %s, skipping\n", full_path); failures++; continue; }
        plan_kind kind = classify(sql);
        const char *label = "explain analyze present";
        int wrap = (kind == PLAN_NO_EXPLAIN);
        if (kind == PLAN_EXPLAIN_ONLY) { label = "EXPLAIN without ANALYZE (as-is)"; explain_only++; }
        if (wrap) { label = "wrapped in EXPLAIN ANALYZE"; wrapped++; }

        FILE *tf = fopen(temp_sql, "wb");
        if (!tf) { fprintf(stderr, "Could not write temp SQL for %s, skipping\n", rel); free(sql); failures++; continue; }
        if (wrap) fputs("EXPLAIN ANALYZE\n", tf);
        fputs(sql, tf);
        fclose(tf);
        chmod(temp_sql, 0644);
        free(sql);

        /* APPEND: remember the previous snapshot's shape, write the section header. */
        uint64_t prev_shape = 0; int prev_snapshots = 0;
        if (append) {
            prev_shape = last_snapshot_shape(plan_path, &prev_snapshots);
            FILE *pf = fopen(plan_path, "a");
            if (!pf) { fprintf(stderr, "Could not open %s for append, skipping\n", plan_path); failures++; continue; }
            char ts[32]; utc_timestamp(ts, sizeof(ts));
            if (prev_snapshots == 0 && prev_shape != 0) {
                /* An older, un-snapshotted plan file: label it as snapshot 1 in place
                 * by treating it as the previous section (it has no header). */
            }
            fprintf(pf, "%s%d  %s  pg=%s  db=%s  query=%s ====\n",
                    SNAPSHOT_PREFIX, prev_snapshots + 1, ts, pg_version, db_name, rel);
            fclose(pf);
        }

        char cmd[MAX_CMD];
        n = snprintf(cmd, sizeof(cmd),
                     "sudo -n -u %s %spsql -d %s -X -q -P pager=off -f \"%s\" %s \"%s\" 2>&1",
                     db_user, env_prefix, db_name, temp_sql, append ? ">>" : ">", plan_path);
        if (n <= 0 || n >= (int)sizeof(cmd)) { fprintf(stderr, "Command too long for %s, skipping\n", rel); failures++; continue; }

        int rc = system(cmd);
        chown_to_invoker(plan_path);

        if (rc != 0) {
            fprintf(stderr, "  [%d/%d] FAILED (exit %d) %s (see %s)\n", q + 1, count, rc, rel, plan_path);
            failures++;
            continue;
        }

        if (append && prev_shape != 0) {
            int now_snapshots = 0;
            uint64_t new_shape = last_snapshot_shape(plan_path, &now_snapshots);
            compared++;
            if (new_shape != prev_shape) {
                changed++;
                printf("  [%d/%d] %s -> snapshot %d  SHAPE CHANGED vs previous\n", q + 1, count, rel, now_snapshots);
            } else {
                printf("  [%d/%d] %s -> snapshot %d  same shape\n", q + 1, count, rel, now_snapshots);
            }
        } else if (append) {
            printf("  [%d/%d] %s -> snapshot 1  (first snapshot; %s)\n", q + 1, count, rel, label);
        } else {
            printf("  [%d/%d] %s -> %s  (%s)\n", q + 1, count, rel, plan_path, label);
        }
        fflush(stdout);
    }

    unlink(temp_sql);
    for (int i = 0; i < count; i++) free(files[i]);

    printf("\nDone. %d plans written under %s (%d wrapped, %d EXPLAIN-only, %d failed)\n",
           count - failures, plans_base, wrapped, explain_only, failures);
    if (append)
        printf("Shape check: %d compared with their previous snapshot, %d CHANGED\n", compared, changed);
    return failures ? 1 : 0;
}
