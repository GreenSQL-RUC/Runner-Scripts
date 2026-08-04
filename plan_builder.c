#define _GNU_SOURCE
/*
 * plan_builder.c
 *
 * A deliberately simple companion to query_runner.c. It does NOT measure time
 * or energy. It just runs every query once and saves its query plan as a text
 * file, so you have a readable record of how each statement is executed.
 *
 * For every .sql file found under a query directory it:
 *   1. reads the SQL,
 *   2. checks whether the statement already asks for a plan (EXPLAIN ANALYZE);
 *      if not, it prepends "EXPLAIN ANALYZE" so a plan is produced anyway,
 *   3. runs it through psql and writes the plan output to ./plans, mirroring
 *      the query folder structure with the query name as the .txt file name.
 *
 *   queries/Functions/09-01_logical/and.sql  ->  plans/Functions/09-01_logical/and.txt
 *
 * The queries today are written as EXPLAIN (ANALYZE, ...), but that is not
 * guaranteed to stay that way, hence the verification step in point 2.
 *
 * Configuration (all optional, via environment variables):
 *   QUERY_DIR   directory searched recursively for .sql files   (default: queries)
 *   PLANS_DIR   directory the .txt plans are written under       (default: plans)
 *   DB_NAME     database to run against                          (default: tpch)
 *   DB_USER     OS user psql is run as, via sudo                 (default: postgres)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <dirent.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>
#include <unistd.h>
#include <limits.h>

#define DEFAULT_QUERY_DIR "queries"
#define DEFAULT_PLANS_DIR "plans"
#define DEFAULT_DB_NAME   "tpch"
#define DEFAULT_DB_USER   "postgres"

#define MAX_QUERIES 8192
#define MAX_CMD     4096

/* ================================================================== */
/* Helpers (kept local so this stays a standalone, single-file tool)   */
/* ================================================================== */

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
 * Build the "env PGPORT=N PGOPTIONS='...' " fragment inserted after
 * `sudo -u USER`, so the saved plans come from the same cluster and under the
 * same worker cap the runner would use (make plans PGVER=18 WORKERS=4).
 * PGPORT selects which PostgreSQL major answers - plans differ between majors,
 * which is much of the point of keeping several around. Empty when neither is
 * set. Both are validated as non-negative integers before being spliced in.
 */
static const char *build_psql_env_prefix(const char *port, const char *workers) {
    static char buf[160];
    char port_part[48] = "";
    char opts_part[96] = "";

    if (port && *port) {
        snprintf(port_part, sizeof(port_part), "PGPORT=%ld ", require_uint("PGPORT", port));
    }
    if (workers && *workers) {
        snprintf(opts_part, sizeof(opts_part),
                 "PGOPTIONS='-c max_parallel_workers_per_gather=%ld' ",
                 require_uint("WORKERS", workers));
    }

    if (!*port_part && !*opts_part) buf[0] = '\0';
    else snprintf(buf, sizeof(buf), "env %s%s", port_part, opts_part);
    return buf;
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Recursively collect every "*.sql" file under dir into files[] (heap-allocated
 * full paths). Mirrors query_runner.c so the two tools see the same queries. */
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

/* Give a file/dir back to the human who ran us under sudo, so ./plans is not
 * left owned by root. No-op when not running as root or SUDO_UID is unset. */
static void chown_to_invoker(const char *path) {
    if (geteuid() != 0) return;
    const char *uid_s = getenv("SUDO_UID");
    const char *gid_s = getenv("SUDO_GID");
    if (!uid_s || !gid_s) return;
    if (chown(path, (uid_t)atoi(uid_s), (gid_t)atoi(gid_s)) != 0) {
        /* best effort only */
    }
}

/* Create dir_path and any missing parents (like "mkdir -p"), giving each level
 * we actually create back to the invoking user. */
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

/* ================================================================== */
/* Verification: does the SQL already produce a plan?                  */
/* ================================================================== */

static int is_ident_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* Advance past whitespace and SQL comments (-- line and block comments). */
static const char *skip_noise(const char *s) {
    for (;;) {
        while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
        if (s[0] == '-' && s[1] == '-') {          /* line comment */
            s += 2;
            while (*s && *s != '\n') s++;
            continue;
        }
        if (s[0] == '/' && s[1] == '*') {          /* block comment */
            s += 2;
            while (*s && !(s[0] == '*' && s[1] == '/')) s++;
            if (*s) s += 2;
            continue;
        }
        break;
    }
    return s;
}

/* Case-insensitive search for "ANALYZE" as a whole word within [start, end). */
static int region_has_analyze(const char *start, const char *end) {
    for (const char *p = start; p + 7 <= end; p++) {
        if (strncasecmp(p, "ANALYZE", 7) == 0) {
            char before = (p == start) ? ' ' : p[-1];
            char after  = p[7];
            if (!is_ident_char(before) && !is_ident_char(after)) return 1;
        }
    }
    return 0;
}

typedef enum { PLAN_HAS_ANALYZE, PLAN_EXPLAIN_ONLY, PLAN_NO_EXPLAIN } plan_kind;

/*
 * Classify the statement so we know whether to run it as-is or wrap it:
 *   PLAN_HAS_ANALYZE   already "EXPLAIN (ANALYZE ...)" / "EXPLAIN ANALYZE" -> as-is
 *   PLAN_EXPLAIN_ONLY  an EXPLAIN without ANALYZE -> run as-is (still a plan,
 *                      just without execution stats; we cannot safely wrap an
 *                      existing EXPLAIN, so we leave it and warn)
 *   PLAN_NO_EXPLAIN    not an EXPLAIN at all -> prepend "EXPLAIN ANALYZE"
 */
static plan_kind classify(const char *sql) {
    const char *p = skip_noise(sql);

    if (strncasecmp(p, "EXPLAIN", 7) != 0 || is_ident_char(p[7])) {
        return PLAN_NO_EXPLAIN;
    }

    const char *q = p + 7;
    while (*q == ' ' || *q == '\t' || *q == '\r' || *q == '\n') q++;

    const char *region_start, *region_end;
    if (*q == '(') {
        /* New syntax: search only inside the option list "( ... )". */
        region_start = q + 1;
        const char *close = strchr(q, ')');
        region_end = close ? close : (q + strlen(q));
    } else {
        /* Old syntax: options are bare words right after EXPLAIN. Look at the
         * short run of tokens before the statement body begins. */
        region_start = q;
        region_end = q;
        while (*region_end && *region_end != '\n' &&
               (size_t)(region_end - q) < 40) {
            region_end++;
        }
    }

    return region_has_analyze(region_start, region_end) ? PLAN_HAS_ANALYZE
                                                        : PLAN_EXPLAIN_ONLY;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

int main(void) {
    const char *query_dir = env_or("QUERY_DIR", DEFAULT_QUERY_DIR);
    const char *plans_dir = env_or("PLANS_DIR", DEFAULT_PLANS_DIR);
    const char *db_name   = env_or("DB_NAME",   DEFAULT_DB_NAME);
    const char *db_user   = env_or("DB_USER",   DEFAULT_DB_USER);
    const char *workers   = env_or("WORKERS",   "");
    const char *pg_port   = env_or("PGPORT",    "");
    const char *env_prefix = build_psql_env_prefix(pg_port, workers);

    printf("plan_builder configuration:\n");
    printf("  PGPORT    = %s\n",
           (pg_port && *pg_port) ? pg_port : "(psql default, 5432)");
    printf("  QUERY_DIR = %s\n", query_dir);
    printf("  PLANS_DIR = %s\n", plans_dir);
    printf("  DB_NAME   = %s\n", db_name);
    printf("  DB_USER   = %s\n", db_user);
    printf("  WORKERS   = %s\n\n",
           (workers && *workers) ? workers : "(planner default)");

    char *files[MAX_QUERIES];
    int count = collect_queries(query_dir, files, 0, MAX_QUERIES);
    if (count == 0) {
        fprintf(stderr, "No .sql files found under %s\n", query_dir);
        return 1;
    }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d queries under %s\n\n", count, query_dir);

    /* Length of the "queries/" prefix, to mirror the sub-folder layout. */
    size_t dir_prefix = strlen(query_dir);
    if (dir_prefix > 0 && query_dir[dir_prefix - 1] != '/') dir_prefix++;

    if (ensure_dir(plans_dir) != 0) {
        fprintf(stderr, "Failed to create plans dir: %s\n", plans_dir);
        return 1;
    }
    chown_to_invoker(plans_dir);

    char temp_sql[PATH_MAX];
    snprintf(temp_sql, sizeof(temp_sql), "/tmp/plan_builder_%d.sql", (int)getpid());

    int failures = 0, wrapped = 0, explain_only = 0;

    for (int q = 0; q < count; q++) {
        const char *full_path = files[q];
        const char *rel = full_path + dir_prefix;      /* e.g. Functions/.../and.sql */

        /* Build the plan path: plans/<rel with .sql -> .txt>. */
        char plan_path[PATH_MAX];
        int rel_len = (int)strlen(rel);
        int stem_len = (rel_len >= 4) ? rel_len - 4 : rel_len;   /* drop ".sql" */
        int n = snprintf(plan_path, sizeof(plan_path), "%s/%.*s.txt",
                         plans_dir, stem_len, rel);
        if (n <= 0 || n >= (int)sizeof(plan_path)) {
            fprintf(stderr, "Plan path too long for %s, skipping\n", rel);
            failures++;
            continue;
        }

        /* Ensure the mirrored sub-directory exists. */
        char plan_dir[PATH_MAX];
        strncpy(plan_dir, plan_path, sizeof(plan_dir));
        plan_dir[sizeof(plan_dir) - 1] = '\0';
        char *slash = strrchr(plan_dir, '/');
        if (slash) {
            *slash = '\0';
            if (ensure_dir(plan_dir) != 0) {
                fprintf(stderr, "Failed to create %s, skipping\n", plan_dir);
                failures++;
                continue;
            }
        }

        /* Verification step: classify the SQL and decide the statement to run. */
        char *sql = read_file(full_path);
        if (!sql) {
            fprintf(stderr, "Could not read %s, skipping\n", full_path);
            failures++;
            continue;
        }
        plan_kind kind = classify(sql);
        const char *label = "explain analyze present";
        int wrap = (kind == PLAN_NO_EXPLAIN);
        if (kind == PLAN_EXPLAIN_ONLY) { label = "EXPLAIN without ANALYZE (as-is)"; explain_only++; }
        if (wrap) { label = "wrapped in EXPLAIN ANALYZE"; wrapped++; }

        /* Always run the statement from a temp file in /tmp (world-readable, so
         * the postgres user can read it via sudo regardless of where the query
         * itself lives). When wrapping, "EXPLAIN ANALYZE" is prepended here. */
        FILE *tf = fopen(temp_sql, "wb");
        if (!tf) {
            fprintf(stderr, "Could not write temp SQL for %s, skipping\n", rel);
            free(sql);
            failures++;
            continue;
        }
        if (wrap) fputs("EXPLAIN ANALYZE\n", tf);
        fputs(sql, tf);
        fclose(tf);
        chmod(temp_sql, 0644);
        free(sql);

        /* Run psql, capturing the plan (and any error) into the .txt file. */
        char cmd[MAX_CMD];
        n = snprintf(cmd, sizeof(cmd),
                     "sudo -n -u %s %spsql -d %s -X -q -P pager=off -f \"%s\" > \"%s\" 2>&1",
                     db_user, env_prefix, db_name, temp_sql, plan_path);
        if (n <= 0 || n >= (int)sizeof(cmd)) {
            fprintf(stderr, "Command too long for %s, skipping\n", rel);
            failures++;
            continue;
        }

        int rc = system(cmd);
        chown_to_invoker(plan_path);

        if (rc != 0) {
            fprintf(stderr, "  [%d/%d] FAILED (exit %d) %s (see %s)\n",
                    q + 1, count, rc, rel, plan_path);
            failures++;
        } else {
            printf("  [%d/%d] %s -> %s  (%s)\n",
                   q + 1, count, rel, plan_path, label);
        }
        fflush(stdout);
    }

    unlink(temp_sql);
    for (int i = 0; i < count; i++) free(files[i]);

    printf("\nDone. %d plans written to %s (%d wrapped, %d EXPLAIN-only, %d failed)\n",
           count - failures, plans_dir, wrapped, explain_only, failures);
    return failures ? 1 : 0;
}
