#define _GNU_SOURCE
/*
 * output_runner.c
 *
 * A simple companion to plan_builder.c. Where plan_builder saves each query's
 * PLAN, this saves each query's OUTPUT (the result rows), mirroring the query
 * folder structure with the query name as the .txt file name:
 *
 *   queries/Functions/09-01_logical/and.sql  ->  outputs/Functions/09-01_logical/and.txt
 *
 * Verification step (the inverse of plan_builder's): the queries are currently
 * written as "EXPLAIN (ANALYZE, ...) SELECT ...", which returns a PLAN and
 * throws the rows away. To capture real output we STRIP a leading EXPLAIN
 * clause so the underlying statement runs and returns its rows. A query with no
 * EXPLAIN is run unchanged. Everything stays read-only: EXPLAIN is simply
 * removed, no statement is otherwise rewritten.
 *
 * ---- OUTPUT SIZE ----
 * These queries have no LIMIT and scan ~6M rows, so a single one can emit
 * hundreds of MB (e.g. sha256 over lineitem ~400MB). By default output is
 * therefore capped to MAX_ROWS rows per query. Set MAX_ROWS=0 for the full,
 * uncapped result (can total tens of GB across the whole set). psql streams via
 * a server-side cursor (FETCH_COUNT) so client memory stays bounded either way.
 *
 * Configuration (all optional, via environment variables):
 *   QUERY_DIR    directory searched recursively for .sql files (default: queries)
 *   OUTPUTS_DIR  directory the .txt outputs are written under   (default: outputs)
 *   DB_NAME      database to run against                        (default: tpch)
 *   DB_USER      OS user psql is run as, via sudo               (default: postgres)
 *   MAX_ROWS     rows to keep per query, 0 = unlimited          (default: 1000)
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

#define DEFAULT_QUERY_DIR   "queries"
#define DEFAULT_OUTPUTS_DIR "outputs"
#define DEFAULT_DB_NAME     "tpch"
#define DEFAULT_DB_USER     "postgres"
#define DEFAULT_MAX_ROWS    1000
#define FETCH_COUNT         1000   /* psql cursor batch size -> bounded memory   */

#define MAX_QUERIES 8192
#define MAX_CMD     4096

/* ================================================================== */
/* Helpers (kept local so this stays a standalone, single-file tool)   */
/* ================================================================== */

static const char *env_or(const char *name, const char *fallback) {
    const char *v = getenv(name);
    return (v && *v) ? v : fallback;
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

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

static int collect_queries(const char *dir, char **files, int count, int max) {
    DIR *d = opendir(dir);
    if (!d) {
        fprintf(stderr, "opendir(%s): %s\n", dir, strerror(errno));
        return count;
    }

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

/* Give a file/dir back to the human who ran us under sudo, so ./outputs is not
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
/* Verification: strip a leading EXPLAIN so the query returns rows     */
/* ================================================================== */

static int is_ident_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

static const char *skip_noise(const char *s) {
    for (;;) {
        while (*s == ' ' || *s == '\t' || *s == '\r' || *s == '\n') s++;
        if (s[0] == '-' && s[1] == '-') {
            s += 2;
            while (*s && *s != '\n') s++;
            continue;
        }
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

/*
 * If the statement begins with EXPLAIN, return a pointer to the underlying
 * statement (past "EXPLAIN (...)" or "EXPLAIN ANALYZE VERBOSE"); otherwise
 * return sql unchanged. *did_strip reports whether an EXPLAIN was removed.
 */
static const char *strip_explain(const char *sql, int *did_strip) {
    *did_strip = 0;
    const char *p = skip_noise(sql);

    if (strncasecmp(p, "EXPLAIN", 7) != 0 || is_ident_char(p[7])) {
        return sql;                     /* not an EXPLAIN -> run as written */
    }

    const char *q = p + 7;
    while (*q == ' ' || *q == '\t' || *q == '\r' || *q == '\n') q++;

    if (*q == '(') {
        /* New syntax: skip the whole "( ... )" option list. */
        const char *close = strchr(q, ')');
        if (!close) return sql;         /* malformed -> leave untouched (safe) */
        q = close + 1;
    } else {
        /* Old syntax: only ANALYZE / VERBOSE may appear as bare keywords. */
        for (;;) {
            while (*q == ' ' || *q == '\t' || *q == '\r' || *q == '\n') q++;
            if (strncasecmp(q, "ANALYZE", 7) == 0 && !is_ident_char(q[7])) { q += 7; continue; }
            if (strncasecmp(q, "VERBOSE", 7) == 0 && !is_ident_char(q[7])) { q += 7; continue; }
            break;
        }
    }

    *did_strip = 1;
    return q;                           /* start of the real statement */
}

/* Best-effort error check: psql sends errors to the same file (2>&1); they show
 * up as a line starting "ERROR:" or "psql:". Only the head of the file is read
 * so this stays cheap even for very large outputs. */
static int output_has_error(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) return 0;

    char buf[8192];
    size_t got = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[got] = '\0';

    const char *line = buf;
    while (line) {
        if (strncmp(line, "ERROR:", 6) == 0 || strncmp(line, "psql:", 5) == 0) return 1;
        line = strchr(line, '\n');
        if (line) line++;
    }
    return 0;
}

/* ================================================================== */
/* Main                                                                */
/* ================================================================== */

int main(void) {
    const char *query_dir   = env_or("QUERY_DIR",   DEFAULT_QUERY_DIR);
    const char *outputs_dir = env_or("OUTPUTS_DIR", DEFAULT_OUTPUTS_DIR);
    const char *db_name     = env_or("DB_NAME",     DEFAULT_DB_NAME);
    const char *db_user     = env_or("DB_USER",     DEFAULT_DB_USER);
    /* Which cluster (i.e. which PostgreSQL major) to talk to; empty = 5432. */
    const char *pg_port     = env_or("PGPORT",      "");
    const char *env_prefix  = build_psql_env_prefix(pg_port);

    int max_rows = DEFAULT_MAX_ROWS;
    const char *mr = getenv("MAX_ROWS");
    if (mr && *mr) {
        char *end = NULL;
        long v = strtol(mr, &end, 10);
        if (end != mr && *end == '\0' && v >= 0) max_rows = (int)v;
    }

    printf("output_runner configuration:\n");
    printf("  QUERY_DIR   = %s\n", query_dir);
    printf("  OUTPUTS_DIR = %s\n", outputs_dir);
    printf("  DB_NAME     = %s\n", db_name);
    printf("  DB_USER     = %s\n", db_user);
    if (max_rows > 0)
        printf("  MAX_ROWS    = %d rows/query\n\n", max_rows);
    else
        printf("  MAX_ROWS    = 0 (UNLIMITED - full results, may be tens of GB)\n\n");

    char *files[MAX_QUERIES];
    int count = collect_queries(query_dir, files, 0, MAX_QUERIES);
    if (count == 0) {
        fprintf(stderr, "No .sql files found under %s\n", query_dir);
        return 1;
    }
    qsort(files, count, sizeof(char *), cmp_str);
    printf("Found %d queries under %s\n\n", count, query_dir);

    size_t dir_prefix = strlen(query_dir);
    if (dir_prefix > 0 && query_dir[dir_prefix - 1] != '/') dir_prefix++;

    if (ensure_dir(outputs_dir) != 0) {
        fprintf(stderr, "Failed to create outputs dir: %s\n", outputs_dir);
        return 1;
    }

    char temp_sql[PATH_MAX];
    snprintf(temp_sql, sizeof(temp_sql), "/tmp/output_runner_%d.sql", (int)getpid());

    int failures = 0, stripped_n = 0;
    long long total_bytes = 0;

    for (int q = 0; q < count; q++) {
        const char *full_path = files[q];
        const char *rel = full_path + dir_prefix;

        char out_path[PATH_MAX];
        int rel_len = (int)strlen(rel);
        int stem_len = (rel_len >= 4) ? rel_len - 4 : rel_len;   /* drop ".sql" */
        int n = snprintf(out_path, sizeof(out_path), "%s/%.*s.txt",
                         outputs_dir, stem_len, rel);
        if (n <= 0 || n >= (int)sizeof(out_path)) {
            fprintf(stderr, "Output path too long for %s, skipping\n", rel);
            failures++;
            continue;
        }

        char out_dir[PATH_MAX];
        strncpy(out_dir, out_path, sizeof(out_dir));
        out_dir[sizeof(out_dir) - 1] = '\0';
        char *slash = strrchr(out_dir, '/');
        if (slash) {
            *slash = '\0';
            if (ensure_dir(out_dir) != 0) {
                fprintf(stderr, "Failed to create %s, skipping\n", out_dir);
                failures++;
                continue;
            }
        }

        /* Verification step: strip a leading EXPLAIN so the query returns rows. */
        char *sql = read_file(full_path);
        if (!sql) {
            fprintf(stderr, "Could not read %s, skipping\n", full_path);
            failures++;
            continue;
        }
        int did_strip = 0;
        const char *stmt = strip_explain(sql, &did_strip);
        if (did_strip) stripped_n++;

        /* Write the underlying statement to a world-readable temp file so the
         * postgres user can read it via sudo. */
        FILE *tf = fopen(temp_sql, "wb");
        if (!tf) {
            fprintf(stderr, "Could not write temp SQL for %s, skipping\n", rel);
            free(sql);
            failures++;
            continue;
        }
        fputs(stmt, tf);
        fclose(tf);
        chmod(temp_sql, 0644);
        free(sql);

        /* Run psql. -A unaligned + FETCH_COUNT cursor => streamed, bounded
         * memory. When MAX_ROWS>0, head caps the saved output (and, because the
         * pipe closes, stops the query early). One header line is kept, hence
         * the "+1". */
        char cmd[MAX_CMD];
        if (max_rows > 0) {
            n = snprintf(cmd, sizeof(cmd),
                         "sudo -n -u %s %spsql -d %s -X -q -A -P pager=off "
                         "-v FETCH_COUNT=%d -f \"%s\" 2>&1 | head -n %d > \"%s\"",
                         db_user, env_prefix, db_name, FETCH_COUNT, temp_sql,
                         max_rows + 1, out_path);
        } else {
            n = snprintf(cmd, sizeof(cmd),
                         "sudo -n -u %s %spsql -d %s -X -q -A -P pager=off "
                         "-v FETCH_COUNT=%d -f \"%s\" > \"%s\" 2>&1",
                         db_user, env_prefix, db_name, FETCH_COUNT, temp_sql, out_path);
        }
        if (n <= 0 || n >= (int)sizeof(cmd)) {
            fprintf(stderr, "Command too long for %s, skipping\n", rel);
            failures++;
            continue;
        }

        int rc = system(cmd);
        chown_to_invoker(out_path);

        int errored = output_has_error(out_path) || (max_rows == 0 && rc != 0);

        struct stat ost;
        long long bytes = (stat(out_path, &ost) == 0) ? (long long)ost.st_size : -1;
        if (bytes > 0) total_bytes += bytes;

        if (errored) {
            fprintf(stderr, "  [%d/%d] FAILED %s (see %s)\n", q + 1, count, rel, out_path);
            failures++;
        } else {
            printf("  [%d/%d] %s -> %s  (%lld bytes%s)\n",
                   q + 1, count, rel, out_path, bytes,
                   did_strip ? ", EXPLAIN stripped" : "");
        }
        fflush(stdout);
    }

    unlink(temp_sql);
    for (int i = 0; i < count; i++) free(files[i]);

    printf("\nDone. %d outputs written to %s (%d EXPLAIN-stripped, %d failed, %.1f MB total)\n",
           count - failures, outputs_dir, stripped_n, failures, total_bytes / (1024.0 * 1024.0));
    return failures ? 1 : 0;
}
