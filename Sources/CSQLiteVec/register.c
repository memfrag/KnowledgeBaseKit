#include "include/CSQLiteVec.h"
int csqlitevec_register_on(sqlite3 *db) {
    return sqlite3_vec_init(db, 0, 0);
}
