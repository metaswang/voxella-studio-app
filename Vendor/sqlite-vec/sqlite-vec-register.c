#include "sqlite-vec.h"
#include "sqlite3.h"

int sqlite_vec_register_db(sqlite3 *db) {
    char *error = 0;
    int status = sqlite3_vec_init(db, &error, 0);
    if (error) {
        sqlite3_free(error);
    }
    return status;
}
