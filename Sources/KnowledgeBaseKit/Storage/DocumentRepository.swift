import Foundation
import GRDB

public enum DocumentRepository {
    public static func insertOrReplace(_ document: Document, in db: Database) throws {
        let metadataJSON = try encodeMetadata(document.metadata)
        try db.execute(
            sql: """
                INSERT INTO documents (id, relative_path, content_hash, modified_at, title, metadata_json)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    relative_path = excluded.relative_path,
                    content_hash  = excluded.content_hash,
                    modified_at   = excluded.modified_at,
                    title         = excluded.title,
                    metadata_json = excluded.metadata_json
                """,
            arguments: [
                document.id.rawValue,
                document.relativePath,
                document.contentHash,
                document.modifiedAt.timeIntervalSince1970,
                document.metadata.title,
                metadataJSON,
            ]
        )
    }

    /// Rewrites a document's path in place, preserving its chunks, embeddings, and graph.
    ///
    /// This is the payoff of content-hash rename detection: moving a file costs one UPDATE
    /// instead of a full re-embed and re-extract of the document.
    public static func updatePath(
        of id: DocumentID,
        to relativePath: String,
        modifiedAt: Date,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE documents SET relative_path = ?, modified_at = ? WHERE id = ?",
            arguments: [relativePath, modifiedAt.timeIntervalSince1970, id.rawValue]
        )
    }

    public static func fetch(id: DocumentID, in db: Database) throws -> Document? {
        try Row.fetchOne(db, sql: "SELECT * FROM documents WHERE id = ?", arguments: [id.rawValue])
            .map(decode)
    }

    public static func fetch(relativePath: String, in db: Database) throws -> Document? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM documents WHERE relative_path = ?",
            arguments: [relativePath]
        ).map(decode)
    }

    public static func fetchAll(in db: Database) throws -> [Document] {
        try Row.fetchAll(db, sql: "SELECT * FROM documents ORDER BY relative_path").map(decode)
    }

    /// Path and content hash for every document, the input to rename detection.
    public static func fetchPathIndex(in db: Database) throws -> [(id: DocumentID, path: String, hash: String)] {
        try Row.fetchAll(db, sql: "SELECT id, relative_path, content_hash FROM documents").map {
            (DocumentID(rawValue: $0["id"]), $0["relative_path"], $0["content_hash"])
        }
    }

    public static func delete(id: DocumentID, in db: Database) throws {
        // Chunk rows cascade, which cascades mentions and relations; the vec0 tables are not
        // reachable by foreign key, so ``ChunkRepository/delete(ids:in:)`` handles those and
        // must run first.
        try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id.rawValue])
    }

    public static func count(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM documents") ?? 0
    }

    // MARK: - Coding

    private static func decode(_ row: Row) -> Document {
        Document(
            id: DocumentID(rawValue: row["id"]),
            relativePath: row["relative_path"],
            contentHash: row["content_hash"],
            modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
            metadata: decodeMetadata(row["metadata_json"], title: row["title"])
        )
    }

    private static func encodeMetadata(_ metadata: DocumentMetadata) throws -> String {
        let data = try JSONEncoder().encode(metadata)
        return String(decoding: data, as: UTF8.self)
    }

    private static func decodeMetadata(_ json: String, title: String?) -> DocumentMetadata {
        guard let data = json.data(using: .utf8),
            var metadata = try? JSONDecoder().decode(DocumentMetadata.self, from: data)
        else {
            return DocumentMetadata(title: title)
        }
        metadata.title = title ?? metadata.title
        return metadata
    }
}
