import Foundation
import GRDB

/// The keys whose change forces re-indexing, and how wide that re-index reaches.
public enum VersionKey: String, Sendable, CaseIterable {
    case schema
    case chunker
    case embeddingModel = "embedding_model"
    case embeddingDimensions = "embedding_dimensions"
    case extractionModel = "extraction_model"
    case extractionVocabulary = "extraction_vocabulary"

    /// What has to be redone when this key changes.
    ///
    /// Each key maps to the *narrowest* sufficient action. Swapping the extraction model
    /// leaves embeddings alone; swapping the embedding model leaves the graph alone. Only a
    /// chunker change invalidates both, because it changes what a chunk even is.
    var blastRadius: MigrationAction {
        switch self {
        case .schema: .schemaOnly
        case .chunker: .rechunk
        case .embeddingModel, .embeddingDimensions: .reembed
        case .extractionModel, .extractionVocabulary: .reextract
        }
    }
}

public enum MigrationAction: Sendable, Hashable, Comparable {
    /// GRDB migrations only; no re-indexing.
    case schemaOnly
    /// Re-embed every chunk. The graph is untouched.
    case reembed
    /// Re-extract every chunk. Embeddings are untouched.
    case reextract
    /// Re-chunk the corpus, which cascades to both of the above.
    case rechunk

    /// Ordered by cost, so a set of pending actions collapses to the widest one.
    var severity: Int {
        switch self {
        case .schemaOnly: 0
        case .reembed: 1
        case .reextract: 1
        case .rechunk: 2
        }
    }

    public static func < (lhs: MigrationAction, rhs: MigrationAction) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// A description of what opening the store is about to do, reported before it happens.
public struct MigrationPlan: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public var key: VersionKey
        public var stored: String?
        public var running: String
        public var action: MigrationAction
    }

    public var changes: [Change]

    public var isEmpty: Bool { changes.isEmpty }

    /// True when the corpus must be re-read from disk, because chunk boundaries may move.
    public var requiresRechunk: Bool {
        changes.contains { $0.action == .rechunk }
    }

    public var requiresReembed: Bool {
        changes.contains { $0.action == .reembed || $0.action == .rechunk }
    }

    public var requiresReextract: Bool {
        changes.contains { $0.action == .reextract || $0.action == .rechunk }
    }

    public var summary: String {
        guard !isEmpty else { return "No migration required." }
        return changes
            .map { change in
                let from = change.stored ?? "(unset)"
                return "\(change.key.rawValue): \(from) → \(change.running) [\(change.action)]"
            }
            .joined(separator: "\n")
    }
}

public enum VersionMetadata {

    public static func read(_ key: VersionKey, in db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM store_metadata WHERE key = ?",
            arguments: [key.rawValue]
        )
    }

    public static func write(_ key: VersionKey, value: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO store_metadata (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key.rawValue, value]
        )
    }

    public static func readAll(in db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM store_metadata")
        return Dictionary(uniqueKeysWithValues: rows.map { ($0["key"] as String, $0["value"] as String) })
    }

    /// The values the running configuration implies for each key.
    public static func running(
        configuration: KnowledgeStoreConfiguration,
        chunker: Chunker
    ) -> [VersionKey: String] {
        [
            .schema: String(Schema.version),
            .chunker: chunker.versionKey,
            .embeddingModel: configuration.embedding.model,
            .embeddingDimensions: String(configuration.embedding.dimensions),
            .extractionModel: configuration.extraction.model,
            .extractionVocabulary: configuration.extraction.vocabulary.fingerprint,
        ]
    }

    /// Compares stored against running and produces the plan.
    ///
    /// A key that has never been written is not a migration — it is a database that has not
    /// been used with that setting yet, which is the ordinary first-open case.
    public static func plan(
        configuration: KnowledgeStoreConfiguration,
        chunker: Chunker,
        in db: Database
    ) throws -> MigrationPlan {
        let stored = try readAll(in: db)
        let running = running(configuration: configuration, chunker: chunker)

        var changes: [MigrationPlan.Change] = []
        for key in VersionKey.allCases {
            guard let runningValue = running[key] else { continue }
            let storedValue = stored[key.rawValue]
            guard let storedValue else { continue }
            guard storedValue != runningValue else { continue }
            changes.append(
                MigrationPlan.Change(
                    key: key,
                    stored: storedValue,
                    running: runningValue,
                    action: key.blastRadius
                )
            )
        }

        return MigrationPlan(changes: changes)
    }

    public static func stamp(
        configuration: KnowledgeStoreConfiguration,
        chunker: Chunker,
        in db: Database
    ) throws {
        for (key, value) in running(configuration: configuration, chunker: chunker) {
            try write(key, value: value, in: db)
        }
    }
}
