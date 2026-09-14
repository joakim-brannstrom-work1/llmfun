/* Probe: how does LIMIT interact with row_number() OVER (ORDER BY rank) on FTS5?
 * Compiled against llmfun's vendored sqlite3 (FTS5 enabled).
 */
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int count_cb(void* arg, int n, char** vals, char** cols) {
    int* c = (int*)arg;
    for (int i = 0; i < n; i++) {
        printf("  %s=%s\n", cols[i], vals[i]);
    }
    (*c)++;
    return 0;
}

#define EXEC(db, sql)                                                                              \
    do {                                                                                           \
        char* err = 0;                                                                             \
        int rc = sqlite3_exec(db, sql, 0, 0, &err);                                                \
        if (rc != SQLITE_OK) {                                                                     \
            printf("SQL ERROR: %s -- %s\n", sql, err);                                             \
            sqlite3_free(err);                                                                     \
        }                                                                                          \
    } while (0)

int main() {
    sqlite3* db;
    sqlite3_open(":memory:", &db);

    EXEC(db, "CREATE VIRTUAL TABLE f USING fts5(text)");

    /* doc 1: needle appears once among many words -> worst bm25
       doc 10: needle appears many times in a short text -> best bm25 (most negative rank) */
    {
        char sql[65536];
        for (int i = 1; i <= 10; i++) {
            char body[60000];
            body[0] = 0;
            if (i == 1) {
                strcat(body, "needle ");
                for (int j = 0; j < 200; j++)
                    strcat(body, "filler word sequence token ");
            } else if (i == 10) {
                for (int j = 0; j < 30; j++)
                    strcat(body, "needle ");
            } else {
                /* docs 2..9: needle appears a moderate number of times */
                for (int j = 0; j < i; j++)
                    strcat(body, "needle ");
                for (int j = 0; j < 50; j++)
                    strcat(body, "other content here ");
            }
            snprintf(sql, sizeof(sql), "INSERT INTO f(rowid, text) VALUES (%d, '%s')", i, body);
            EXEC(db, sql);
        }
    }

    printf("== ORDER BY rank (top 5) ==\n");
    {
        int c = 0;
        char* err = 0;
        sqlite3_exec(db, "SELECT rowid, rank FROM f WHERE f MATCH 'needle' ORDER BY rank LIMIT 5",
                     count_cb, &c, &err);
        if (err) {
            printf("err: %s\n", err);
            sqlite3_free(err);
        }
    }

    printf("== window + LIMIT 3, no explicit order (production shape) ==\n");
    {
        int c = 0;
        char* err = 0;
        sqlite3_exec(db,
                     "SELECT rowid, rank, row_number() OVER (ORDER BY rank) AS rn FROM f WHERE f "
                     "MATCH 'needle' LIMIT 3",
                     count_cb, &c, &err);
        if (err) {
            printf("err: %s\n", err);
            sqlite3_free(err);
        }
    }

    printf("== window + LIMIT 3 + ORDER BY rn (to observe rn values as produced) ==\n");
    {
        int c = 0;
        char* err = 0;
        sqlite3_exec(db,
                     "SELECT rowid, rn FROM (SELECT rowid, row_number() OVER (ORDER BY rank) AS rn "
                     "FROM f WHERE f MATCH 'needle') ORDER BY rn LIMIT 3",
                     count_cb, &c, &err);
        if (err) {
            printf("err: %s\n", err);
            sqlite3_free(err);
        }
    }

    printf("== full set rn values ordered by rn ==\n");
    {
        int c = 0;
        char* err = 0;
        sqlite3_exec(db,
                     "SELECT rowid, rn FROM (SELECT rowid, row_number() OVER (ORDER BY rank) AS rn "
                     "FROM f WHERE f MATCH 'needle') ORDER BY rn",
                     count_cb, &c, &err);
        if (err) {
            printf("err: %s\n", err);
            sqlite3_free(err);
        }
    }

    printf("sqlite version: %s\n", sqlite3_libversion());
    sqlite3_close(db);
    return 0;
}
