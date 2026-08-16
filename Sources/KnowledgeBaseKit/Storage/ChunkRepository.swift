import Foundation
import GRDB

public enum ChunkRepository {
    public static func insertOrReplace(_ chunk: Chunk, in db: Database) throws {
        let headingJSON = try encodeHeading(chunk.headingPath)
        try db.execute(
            sql: """
                INSERT INTO chunks (
                    id, document_id, ordinal, heading_path, heading_display,
                    content, content_hash, occurrence
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    ordinal         = excluded.ordinal,
                    heading_path    = excluded.heading_path,
                    heading_display = excluded.heading_display,
                    content         = excluded.content,
                    content_hash    = excluded.content_hash,
                    occurrence      = excluded.occurrence
                """,
            arguments: [
                chunk.id.rawValue,
                chunk.documentID.rawValue,
                chunk.ordinal,
                headingJSON,
                chunk.headingPath.displayForm,
                chunk.content,
                chunk.contentHash,
                chunk.occurrence,
            ]
        )
    }

    public static func fetch(id: ChunkID, in db: Database) throws -> Chunk? {
        try Row.fetchOne(db, sql: "SELECT * FROM chunks WHERE id = ?", arguments: [id.rawValue])
            .map(decode)
    }

    public static func fetch(ids: [ChunkID], in db: Database) throws -> [Chunk] {
        guard !ids.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: ids.count)
        return try Row.fetchAll(
            db,
            sql: "SELECT * FROM chunks WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids.map(\.rawValue))
        ).map(decode)
    }

    public static func fetchAll(documentID: DocumentID, in db: Database) throws -> [Chunk] {
        try Row.fetchAll(
            db,
            sql: "SELECT * FROM chunks WHERE document_id = ? ORDER BY ordinal",
            arguments: [documentID.rawValue]
        ).map(decode)
    }

    /// ID and content hash for a document's chunks — the input to the incremental differ.
    public static func fetchHashes(
        documentID: DocumentID,
        in db: Database
    ) throws -> [ChunkID: String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT id, content_hash FROM chunks WHERE document_id = ?",
            arguments: [documentID.rawValue]
        )
        return Dictionary(uniqueKeysWithValues: rows.map {
            (ChunkID(rawValue: $0["id"]), $0["content_hash"] as String)
        })
    }

    /// Deletes chunks and everything reachable from them.
    ///
    /// Mentions, relations, and queued jobs cascade by foreign key and trigger. The vec0
    /// tables are virtual and outside that graph, so their rows are removed explicitly.
    public static func delete(ids: [ChunkID], in db: Database) throws {
        guard !ids.isEmpty else { return }
        for id in ids {
            try VectorIndex.deleteChunkEmbedding(in: db, chunkID: id)
        }
        let placeholders = databaseQuestionMarks(count: ids.count)
        try db.execute(
            sql: "DELETE FROM chunks WHERE id IN (\(placeholders))",
            arguments: StatementArguments(ids.map(\.rawValue))
        )
    }

    // MARK: - Coverage bookkeeping

    public static func markEmbedded(id: ChunkID, contentHash: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE chunks SET embedded_hash = ? WHERE id = ?",
            arguments: [contentHash, id.rawValue]
        )
    }

    public static func markExtracted(id: ChunkID, contentHash: String, in db: Database) throws {
        try db.execute(
            sql: "UPDATE chunks SET extracted_hash = ? WHERE id = ?",
            arguments: [contentHash, id.rawValue]
        )
    }

    /// Clears embedding coverage for every chunk, used when the embedding model changes.
    public static func invalidateAllEmbeddings(in db: Database) throws {
        try db.execute(sql: "UPDATE chunks SET embedded_hash = NULL")
    }

    public static func invalidateAllExtractions(in db: Database) throws {
        try db.execute(sql: "UPDATE chunks SET extracted_hash = NULL")
    }

    public struct Coverage: Sendable, Hashable {
        public var total: Int
        public var embedded: Int
        public var extracted: Int
    }

    /// A chunk counts as covered only when the hash recorded at embed/extract time still
    /// matches its current content, so an edited-but-not-yet-reprocessed chunk reads as
    /// stale rather than done.
    public static func coverage(in db: Database) throws -> Coverage {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT count(*) AS total,
                       sum(CASE WHEN embedded_hash = content_hash THEN 1 ELSE 0 END) AS embedded,
                       sum(CASE WHEN extracted_hash = content_hash THEN 1 ELSE 0 END) AS extracted
                  FROM chunks
                """
        )
        return Coverage(
            total: row?["total"] ?? 0,
            embedded: row?["embedded"] ?? 0,
            extracted: row?["extracted"] ?? 0
        )
    }

    public static func allIDs(in db: Database) throws -> [ChunkID] {
        try String.fetchAll(db, sql: "SELECT id FROM chunks").map(ChunkID.init(rawValue:))
    }

    // MARK: - Coding

    static func decode(_ row: Row) -> Chunk {
        Chunk(
            id: ChunkID(rawValue: row["id"]),
            documentID: DocumentID(rawValue: row["document_id"]),
            ordinal: row["ordinal"],
            headingPath: decodeHeading(row["heading_path"]),
            content: row["content"],
            contentHash: row["content_hash"],
            occurrence: row["occurrence"]
        )
    }

    private static func encodeHeading(_ path: HeadingPath) throws -> String {
        let data = try JSONEncoder().encode(path.components)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeHeading(_ json: String) -> HeadingPath {
        guard let data = json.data(using: .utf8),
            let components = try? JSONDecoder().decode([String].self, from: data)
        else {
            return HeadingPath()
        }
        return HeadingPath(components)
    }
}

/// `?, ?, ?` for an `IN` clause.
func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}
