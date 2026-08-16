import CSQLiteVec
import Foundation
import GRDB
import SQLite3

/// Owns the SQLite connection pool and the sqlite-vec registration.
///
/// ## Why sqlite-vec is registered per connection
///
/// The usual way to link a static SQLite extension is `sqlite3_auto_extension`, which runs an
/// entry point on every connection opened thereafter. macOS builds its system SQLite with
/// `SQLITE_OMIT_LOAD_EXTENSION`, and that omits the auto-extension registry too — the call
/// returns `SQLITE_MISUSE` and nothing is registered. Calling `sqlite3_vec_init` directly on
/// each connection works, and GRDB's `prepareDatabase` hook is invoked for exactly that.
///
/// This also removes the need for a custom SQLite build: the system library already has FTS5,
/// and sqlite-vec is compiled into this package as a C target rather than loaded at runtime,
/// so there is no `.dylib` to sign, notarize, or locate.
public final class KnowledgeDatabase: Sendable {
    let pool: DatabasePool
    let url: URL
    private let writeLock: WriteLock?

    /// - Parameters:
    ///   - url: where the SQLite file lives. Its parent directory is created if needed.
    ///   - allowsWriting: when false, no write lock is taken and the connection is opened
    ///     read-only. Readers are unlimited and concurrent; only indexing is exclusive.
    ///   - embeddingDimensions: the width of the vector tables. Passed here rather than
    ///     created on demand so that every code path can rely on the tables existing — a
    ///     chunk delete has to clear its vector whether or not anything has been embedded yet.
    public init(url: URL, allowsWriting: Bool, embeddingDimensions: Int) throws {
        self.url = url

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if allowsWriting {
            self.writeLock = try WriteLock.acquire(for: url)
        } else {
            self.writeLock = nil
        }

        var configuration = Configuration()
        configuration.readonly = !allowsWriting
        // Long enough to ride out another connection's write transaction, short enough that a
        // genuinely stuck writer surfaces as an error rather than a hang.
        configuration.busyMode = .timeout(5)
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            let code = csqlitevec_register_on(db.sqliteConnection)
            guard code == SQLITE_OK else {
                throw DatabaseError(
                    resultCode: ResultCode(rawValue: code),
                    message: "sqlite-vec could not be registered on this connection"
                )
            }
        }

        self.pool = try DatabasePool(path: url.path, configuration: configuration)

        if allowsWriting {
            // WAL is what allows readers to run while the indexer writes.
            try pool.writeWithoutTransaction { db in
                try db.execute(sql: "PRAGMA journal_mode = WAL")
            }
            try Schema.migrator.migrate(pool)
            try pool.write { db in
                try VectorIndex.ensureSchema(in: db, dimensions: embeddingDimensions)
                // Any job still marked running belonged to a process that died. Since only
                // one process may write, nothing else can still be working on it.
                try JobRepository.reclaimAbandoned(in: db)
            }
        }
    }

    /// Releases the write lock. The pool itself is torn down when the last reference drops.
    public func close() {
        writeLock?.release()
    }

    public func read<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try pool.read(body)
    }

    public func write<T: Sendable>(_ body: @Sendable (Database) throws -> T) throws -> T {
        try pool.write(body)
    }

    /// Runs `VACUUM` and an FTS5 optimize. Both need to be outside a transaction.
    public func compact() throws {
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "INSERT INTO chunks_fts(chunks_fts) VALUES('optimize')")
            try db.execute(sql: "VACUUM")
        }
    }

    /// The sqlite-vec version actually linked in, for diagnostics.
    public func vectorExtensionVersion() throws -> String {
        try pool.read { db in
            try String.fetchOne(db, sql: "SELECT vec_version()") ?? "unknown"
        }
    }
}
