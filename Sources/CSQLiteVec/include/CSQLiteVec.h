#ifndef CSQLITEVEC_H
#define CSQLITEVEC_H
#include <sqlite3.h>
int sqlite3_vec_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi);
/* Registers sqlite-vec on an already-open connection. Returns SQLITE_OK on success. */
int csqlitevec_register_on(sqlite3 *db);
#endif
