import Foundation
import GRDB

public enum GraphRepository {

    // MARK: - Entities

    public static func upsert(_ entity: Entity, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO entities (id, type, canonical_name, normalized_name)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type            = excluded.type,
                    canonical_name  = excluded.canonical_name,
                    normalized_name = excluded.normalized_name
                """,
            arguments: [
                entity.id.rawValue,
                entity.type,
                entity.canonicalName,
                NameNormalizer.normalizeForMatching(entity.canonicalName),
            ]
        )
    }

    public static func fetch(id: EntityID, in db: Database) throws -> Entity? {
        try Row.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [id.rawValue])
            .map(decodeEntity)
    }

    public static func fetch(ids: [EntityID], in db: Database) throws -> [Entity] {
        guard !ids.isEmpty else { return [] }
        return try Row.fetchAll(
            db,
            sql: "SELECT * FROM entities WHERE id IN (\(databaseQuestionMarks(count: ids.count)))",
            arguments: StatementArguments(ids.map(\.rawValue))
        ).map(decodeEntity)
    }

    /// Exact match on the normalized name, across both canonical names and aliases.
    ///
    /// This is stage one of entity resolution and the first seeding path of the graph
    /// retrieval arm — both want the same lookup.
    public static func findByNormalizedName(_ normalized: String, in db: Database) throws -> [Entity] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT DISTINCT e.*
                  FROM entities e
                  LEFT JOIN aliases a ON a.entity_id = e.id
                 WHERE e.normalized_name = ? OR a.normalized_name = ?
                """,
            arguments: [normalized, normalized]
        ).map(decodeEntity)
    }

    public static func allEntities(in db: Database) throws -> [Entity] {
        try Row.fetchAll(db, sql: "SELECT * FROM entities ORDER BY canonical_name").map(decodeEntity)
    }

    public static func entityCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM entities") ?? 0
    }

    // MARK: - Aliases

    public static func upsert(_ alias: Alias, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO aliases (entity_id, name, normalized_name)
                VALUES (?, ?, ?)
                ON CONFLICT(entity_id, normalized_name) DO UPDATE SET name = excluded.name
                """,
            arguments: [alias.entityID.rawValue, alias.name, alias.normalizedName]
        )
    }

    public static func aliases(of entityID: EntityID, in db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT name FROM aliases WHERE entity_id = ? ORDER BY name",
            arguments: [entityID.rawValue]
        )
    }

    // MARK: - Mentions

    public static func upsert(_ mention: Mention, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO mentions (entity_id, chunk_id, surface_form, source)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(entity_id, chunk_id, surface_form) DO UPDATE SET source = excluded.source
                """,
            arguments: [
                mention.entityID.rawValue,
                mention.chunkID.rawValue,
                mention.surfaceForm,
                mention.source.rawValue,
            ]
        )
    }

    /// - Parameter source: when given, only mentions from that source are removed.
    public static func deleteMentions(
        ofChunk chunkID: ChunkID,
        source: MentionSource? = nil,
        in db: Database
    ) throws {
        if let source {
            try db.execute(
                sql: "DELETE FROM mentions WHERE chunk_id = ? AND source = ?",
                arguments: [chunkID.rawValue, source.rawValue]
            )
        } else {
            try db.execute(
                sql: "DELETE FROM mentions WHERE chunk_id = ?",
                arguments: [chunkID.rawValue]
            )
        }
    }

    public static func entityIDs(mentionedIn chunkIDs: [ChunkID], in db: Database) throws -> [EntityID] {
        guard !chunkIDs.isEmpty else { return [] }
        return try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT entity_id FROM mentions
                 WHERE chunk_id IN (\(databaseQuestionMarks(count: chunkIDs.count)))
                """,
            arguments: StatementArguments(chunkIDs.map(\.rawValue))
        ).map(EntityID.init(rawValue:))
    }

    public static func chunkIDs(mentioning entityIDs: [EntityID], in db: Database) throws -> [ChunkID] {
        guard !entityIDs.isEmpty else { return [] }
        return try String.fetchAll(
            db,
            sql: """
                SELECT DISTINCT chunk_id FROM mentions
                 WHERE entity_id IN (\(databaseQuestionMarks(count: entityIDs.count)))
                """,
            arguments: StatementArguments(entityIDs.map(\.rawValue))
        ).map(ChunkID.init(rawValue:))
    }

    public static func mentionCount(of entityID: EntityID, in db: Database) throws -> Int {
        try Int.fetchOne(
            db,
            sql: "SELECT count(*) FROM mentions WHERE entity_id = ?",
            arguments: [entityID.rawValue]
        ) ?? 0
    }

    // MARK: - Relations

    public static func upsert(_ relation: Relation, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO relations (id, source_id, type, target_id, supporting_chunk_id, confidence)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET confidence = excluded.confidence
                """,
            arguments: [
                relation.id.rawValue,
                relation.sourceID.rawValue,
                relation.type,
                relation.targetID.rawValue,
                relation.supportingChunkID.rawValue,
                relation.confidence,
            ]
        )
    }

    public static func deleteRelations(supportedBy chunkID: ChunkID, in db: Database) throws {
        try db.execute(
            sql: "DELETE FROM relations WHERE supporting_chunk_id = ?",
            arguments: [chunkID.rawValue]
        )
    }

    /// One hop outward from a set of entities, in either direction.
    ///
    /// Traversal is undirected because a question about a component is equally well answered
    /// by what depends on it as by what it depends on.
    public static func neighbors(of entityIDs: [EntityID], in db: Database) throws -> [Relation] {
        guard !entityIDs.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: entityIDs.count)
        let raw = entityIDs.map(\.rawValue)
        return try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM relations
                 WHERE source_id IN (\(placeholders)) OR target_id IN (\(placeholders))
                """,
            arguments: StatementArguments(raw + raw)
        ).map(decodeRelation)
    }

    public static func relationCount(in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT count(*) FROM relations") ?? 0
    }

    // MARK: - Garbage collection

    /// Deletes entities that no chunk mentions and no relation references.
    ///
    /// Reference counting is what keeps the graph a mirror of the corpus: it can never cite a
    /// chunk that no longer exists, and stale facts do not accumulate across edits. Aliases
    /// and name embeddings follow their entity.
    ///
    /// - Returns: the number of entities collected.
    @discardableResult
    public static func collectOrphanedEntities(in db: Database) throws -> Int {
        let orphaned = try String.fetchAll(
            db,
            sql: """
                SELECT e.id FROM entities e
                 WHERE NOT EXISTS (SELECT 1 FROM mentions m WHERE m.entity_id = e.id)
                   AND NOT EXISTS (SELECT 1 FROM relations r WHERE r.source_id = e.id OR r.target_id = e.id)
                """
        ).map(EntityID.init(rawValue:))

        guard !orphaned.isEmpty else { return 0 }

        for id in orphaned {
            try VectorIndex.deleteEntityEmbedding(in: db, entityID: id)
        }
        // Aliases cascade by foreign key.
        try db.execute(
            sql: "DELETE FROM entities WHERE id IN (\(databaseQuestionMarks(count: orphaned.count)))",
            arguments: StatementArguments(orphaned.map(\.rawValue))
        )
        return orphaned.count
    }

    /// Removes everything the *model* asserted about a chunk, ahead of re-extracting it.
    ///
    /// Front-matter mentions are left alone: they were asserted by the document, and
    /// re-running extraction says nothing about whether they still hold.
    public static func clearExtraction(ofChunk chunkID: ChunkID, in db: Database) throws {
        try deleteRelations(supportedBy: chunkID, in: db)
        try deleteMentions(ofChunk: chunkID, source: .extraction, in: db)
    }

    // MARK: - Coding

    private static func decodeEntity(_ row: Row) -> Entity {
        Entity(
            id: EntityID(rawValue: row["id"]),
            type: row["type"],
            canonicalName: row["canonical_name"]
        )
    }

    private static func decodeRelation(_ row: Row) -> Relation {
        var relation = Relation(
            sourceID: EntityID(rawValue: row["source_id"]),
            type: row["type"],
            targetID: EntityID(rawValue: row["target_id"]),
            supportingChunkID: ChunkID(rawValue: row["supporting_chunk_id"]),
            confidence: row["confidence"]
        )
        relation.id = RelationID(rawValue: row["id"])
        return relation
    }
}
