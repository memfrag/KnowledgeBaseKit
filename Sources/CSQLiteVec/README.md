# CSQLiteVec

Two different things live in this directory, under two different licences.

## Vendored third-party code — Apache-2.0

| File | Origin |
| --- | --- |
| `sqlite-vec.c` | [sqlite-vec](https://github.com/asg017/sqlite-vec) v0.1.9 amalgamation |
| `include/sqlite-vec.h` | same |

Copyright 2024 Alex Garcia. Licensed under the Apache License, Version 2.0 —
full text in [`LICENSE-sqlite-vec.txt`](LICENSE-sqlite-vec.txt).

Both files are **unmodified** from the upstream release amalgamation
(`sqlite-vec-0.1.9-amalgamation.tar.gz`). Keep them that way: modifying them
would oblige you to carry prominent modification notices under Apache-2.0 §4(b),
and would make upgrading harder for no good reason.

To upgrade, replace both files from a newer release amalgamation and refresh
`LICENSE-sqlite-vec.txt` if upstream's licence changes.

## This package's own code — 0BSD

| File | Purpose |
| --- | --- |
| `register.c` | Registers sqlite-vec on an already-open connection |
| `include/CSQLiteVec.h` | The shim header the Swift target imports |

These are part of KnowledgeBaseKit and carry the repository's 0BSD licence.

## Why a shim exists at all

sqlite-vec is normally loaded as a runtime extension, or registered once through
`sqlite3_auto_extension`. Neither works on macOS: the system SQLite is built with
`SQLITE_OMIT_LOAD_EXTENSION`, which rules out runtime loading *and* omits the
auto-extension registry, so `sqlite3_auto_extension` returns `SQLITE_MISUSE` and
silently registers nothing.

`csqlitevec_register_on(db)` calls `sqlite3_vec_init` directly on one connection
instead. `Storage/Database.swift` invokes it from GRDB's `prepareDatabase` hook,
so every pooled connection — writer and readers alike — gets the extension.

The C target is compiled with `SQLITE_CORE` and `SQLITE_VEC_STATIC` (see
`Package.swift`), which makes sqlite-vec link against the system `sqlite3.h`
rather than the loadable-extension API.
