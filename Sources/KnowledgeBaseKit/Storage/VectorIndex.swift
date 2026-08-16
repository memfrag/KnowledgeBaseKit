import Foundation
import GRDB

/// The sqlite-vec tables.
///
/// These live outside ``Schema``'s migrations because a `vec0` column type embeds the
/// embedding dimension (`float[768]`), which comes from configuration. Changing the
/// embedding model is therefore a schema change *and* a data change, handled together by
/// ``ensureSchema(in:dimensions:)``.
public enum VectorIndex {
    /// Creates the vector tables, recreating them if the dimension no longer matches.
    ///
    /// Recreating drops every stored vector. That is correct: vectors from a 768-dimension
    /// model are meaningless to a 1024-dimension one, and the chunks they belonged to are
    /// marked for re-embedding by the same migration that calls this.
    public static func ensureSchema(in db: Database, dimensions: Int) throws {
        try ensureTable(in: db, name: T.chunkEmbeddings, keyColumn: "chunk_id", dimensions: dimensions)
        try ensureTable(in: db, name: T.entityEmbeddings, keyColumn: "entity_id", dimensions: dimensions)
    }

    private static func ensureTable(
        in db: Database,
        name: String,
        keyColumn: String,
        dimensions: Int
    ) throws {
        let existing = try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [name]
        )

        if let existing {
            if existing.contains("float[\(dimensions)]") { return }
            try db.execute(sql: "DROP TABLE \(name)")
        }

        try db.execute(
            sql: """
                CREATE VIRTUAL TABLE \(name) USING vec0(
                    \(keyColumn) TEXT PRIMARY KEY,
                    embedding float[\(dimensions)]
                )
                """
        )
    }

    // MARK: - Chunk vectors

    public static func upsertChunkEmbedding(
        in db: Database,
        chunkID: ChunkID,
        embedding: [Float]
    ) throws {
        // vec0 has no UPSERT, so a re-embed is delete-then-insert.
        try db.execute(
            sql: "DELETE FROM \(T.chunkEmbeddings) WHERE chunk_id = ?",
            arguments: [chunkID.rawValue]
        )
        try db.execute(
            sql: "INSERT INTO \(T.chunkEmbeddings)(chunk_id, embedding) VALUES (?, ?)",
            arguments: [chunkID.rawValue, blob(embedding)]
        )
    }

    public static func deleteChunkEmbedding(in db: Database, chunkID: ChunkID) throws {
        try db.execute(
            sql: "DELETE FROM \(T.chunkEmbeddings) WHERE chunk_id = ?",
            arguments: [chunkID.rawValue]
        )
    }

    public struct Neighbor: Sendable, Hashable {
        public var chunkID: ChunkID
        /// L2 distance. Smaller is closer.
        public var distance: Double
    }

    public static func nearestChunks(
        in db: Database,
        to embedding: [Float],
        limit: Int
    ) throws -> [Neighbor] {
        guard limit > 0, try hasRows(in: db, table: T.chunkEmbeddings) else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT chunk_id, distance
                  FROM \(T.chunkEmbeddings)
                 WHERE embedding MATCH ? AND k = ?
                 ORDER BY distance
                """,
            arguments: [blob(embedding), limit]
        )
        return rows.map {
            Neighbor(chunkID: ChunkID(rawValue: $0["chunk_id"]), distance: $0["distance"])
        }
    }

    // MARK: - Entity name vectors

    /// Name embeddings back the similarity stage of entity resolution.
    public static func upsertEntityEmbedding(
        in db: Database,
        entityID: EntityID,
        embedding: [Float]
    ) throws {
        try db.execute(
            sql: "DELETE FROM \(T.entityEmbeddings) WHERE entity_id = ?",
            arguments: [entityID.rawValue]
        )
        try db.execute(
            sql: "INSERT INTO \(T.entityEmbeddings)(entity_id, embedding) VALUES (?, ?)",
            arguments: [entityID.rawValue, blob(embedding)]
        )
    }

    public static func deleteEntityEmbedding(in db: Database, entityID: EntityID) throws {
        try db.execute(
            sql: "DELETE FROM \(T.entityEmbeddings) WHERE entity_id = ?",
            arguments: [entityID.rawValue]
        )
    }

    public struct EntityNeighbor: Sendable, Hashable {
        public var entityID: EntityID
        public var distance: Double

        /// Cosine-like similarity in 0...1, derived from the L2 distance of unit vectors.
        ///
        /// Ollama's embeddings are not guaranteed unit length, so this is a monotone
        /// re-expression of distance for threshold comparison, not a true cosine.
        public var similarity: Double {
            1.0 / (1.0 + distance)
        }
    }

    public static func nearestEntities(
        in db: Database,
        to embedding: [Float],
        limit: Int
    ) throws -> [EntityNeighbor] {
        guard limit > 0, try hasRows(in: db, table: T.entityEmbeddings) else { return [] }
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT entity_id, distance
                  FROM \(T.entityEmbeddings)
                 WHERE embedding MATCH ? AND k = ?
                 ORDER BY distance
                """,
            arguments: [blob(embedding), limit]
        )
        return rows.map {
            EntityNeighbor(entityID: EntityID(rawValue: $0["entity_id"]), distance: $0["distance"])
        }
    }

    // MARK: - Helpers

    /// A `k`-nearest query against an empty vec0 table errors rather than returning nothing,
    /// so emptiness is checked first. This is the normal state before the first embedding
    /// job completes, and retrieval must degrade to keyword-only rather than fail.
    private static func hasRows(in db: Database, table: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(table))") == 1
    }

    static func blob(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
