import Foundation
import GRDB

/// What a single document's ingestion did.
public struct IngestionOutcome: Sendable, Hashable {
    public var documentID: DocumentID
    public var chunksAdded: Int
    public var chunksModified: Int
    public var chunksUnchanged: Int
    public var chunksRemoved: Int
    public var entitiesCollected: Int
    public var warnings: [String]

    /// True when nothing at all had to be written.
    public var isNoOp: Bool {
        chunksAdded == 0 && chunksModified == 0 && chunksRemoved == 0
    }

    static func skipped(_ documentID: DocumentID, chunks: Int) -> IngestionOutcome {
        IngestionOutcome(
            documentID: documentID,
            chunksAdded: 0,
            chunksModified: 0,
            chunksUnchanged: chunks,
            chunksRemoved: 0,
            entitiesCollected: 0,
            warnings: []
        )
    }
}

/// Parses one Markdown file and applies the difference to the database.
///
/// Chunks and the FTS index are written synchronously; embedding and extraction are enqueued.
/// The document is therefore keyword-searchable the moment this returns, becomes semantically
/// searchable when its embeddings land, and joins the graph when extraction completes.
public struct DocumentIngestor: Sendable {
    private let parser: MarkdownParser
    private let chunker: Chunker
    /// When false, no extraction work is queued and the graph is never built.
    private let extractsGraph: Bool

    public init(
        parser: MarkdownParser = MarkdownParser(),
        chunker: Chunker,
        extractsGraph: Bool = true
    ) {
        self.parser = parser
        self.chunker = chunker
        self.extractsGraph = extractsGraph
    }

    /// - Parameter force: bypasses the unchanged-document fast path, for re-chunking after a
    ///   chunker version change.
    public func ingest(
        source: String,
        relativePath: String,
        modifiedAt: Date,
        force: Bool = false,
        in db: Database,
        now: Date = Date()
    ) throws -> IngestionOutcome {
        let contentHash = ContentHash.of(source)
        // Identity is resolved by *path lookup* first, and only minted from the path when the
        // document is genuinely new. That is what makes rename detection work: after a
        // rename rewrites the path column, the document keeps the ID it was first indexed
        // under, so its chunks — whose IDs derive from it — survive untouched.
        let existing = try DocumentRepository.fetch(relativePath: relativePath, in: db)
        let documentID = existing?.id ?? DocumentID(relativePath: relativePath)

        // Fast path: the file is byte-identical to what was indexed. Parsing it again would
        // produce the same chunks with the same hashes, so there is nothing to learn.
        if !force, let existing, existing.contentHash == contentHash {
            let count = try ChunkRepository.fetchHashes(documentID: documentID, in: db).count
            return .skipped(documentID, chunks: count)
        }

        let stem = (relativePath as NSString).lastPathComponent
        let parsed = parser.parse(
            source: source,
            filenameStem: (stem as NSString).deletingPathExtension
        )
        let chunks = chunker.chunk(parsed, documentID: documentID)

        try DocumentRepository.insertOrReplace(
            Document(
                id: documentID,
                relativePath: relativePath,
                contentHash: contentHash,
                modifiedAt: modifiedAt,
                metadata: parsed.metadata
            ),
            in: db
        )

        var outcome = try applyChunkDiff(chunks, documentID: documentID, in: db, now: now)
        outcome.warnings = parsed.warnings

        // Aliases declared in front matter seed resolution for this document's title, so a
        // note called "Auth" answers to "Authentication Service" without a model in the loop.
        try seedTitleAliases(parsed: parsed, documentID: documentID, in: db)

        // Collection runs last, after seeding. Reference counting is unforgiving: an entity
        // created from front matter has no mentions for the instant between being written and
        // being linked to the document's chunks, and a collection pass in that window would
        // delete it again immediately.
        outcome.entitiesCollected = try GraphRepository.collectOrphanedEntities(in: db)

        return outcome
    }

    /// Inserts, updates, and deletes chunks so the database matches `chunks`.
    private func applyChunkDiff(
        _ chunks: [Chunk],
        documentID: DocumentID,
        in db: Database,
        now: Date
    ) throws -> IngestionOutcome {
        let existingHashes = try ChunkRepository.fetchHashes(documentID: documentID, in: db)
        let existingChunks = try ChunkRepository.fetchAll(documentID: documentID, in: db)
        let existingOrdinals = Dictionary(
            uniqueKeysWithValues: existingChunks.map { ($0.id, $0.ordinal) }
        )

        var added = 0
        var modified = 0
        var unchanged = 0

        for chunk in chunks {
            guard let previousHash = existingHashes[chunk.id] else {
                try ChunkRepository.insertOrReplace(chunk, in: db)
                try enqueueWork(for: chunk, in: db, now: now)
                added += 1
                continue
            }

            if previousHash == chunk.contentHash {
                // The text is identical. It may still have moved within the document, which
                // changes only its ordinal — a write, but not work for the models.
                if existingOrdinals[chunk.id] != chunk.ordinal {
                    try ChunkRepository.insertOrReplace(chunk, in: db)
                }
                unchanged += 1
                continue
            }

            // Modified: the row is updated in place, keeping its ID, and everything derived
            // from the old text is retired before the new work is queued.
            try ChunkRepository.insertOrReplace(chunk, in: db)
            try GraphRepository.clearExtraction(ofChunk: chunk.id, in: db)
            try VectorIndex.deleteChunkEmbedding(in: db, chunkID: chunk.id)
            try enqueueWork(for: chunk, in: db, now: now)
            modified += 1
        }

        let currentIDs = Set(chunks.map(\.id))
        let removedIDs = existingHashes.keys.filter { !currentIDs.contains($0) }
        try ChunkRepository.delete(ids: Array(removedIDs), in: db)

        // Orphan collection is deliberately *not* done here — see ``ingest``.
        return IngestionOutcome(
            documentID: documentID,
            chunksAdded: added,
            chunksModified: modified,
            chunksUnchanged: unchanged,
            chunksRemoved: removedIDs.count,
            entitiesCollected: 0,
            warnings: []
        )
    }

    private func enqueueWork(for chunk: Chunk, in db: Database, now: Date) throws {
        try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db, now: now)
        guard extractsGraph else { return }
        try JobRepository.enqueue(kind: .extract, targetID: chunk.id, in: db, now: now)
    }

    private func seedTitleAliases(
        parsed: ParsedDocument,
        documentID: DocumentID,
        in db: Database
    ) throws {
        guard !parsed.metadata.aliases.isEmpty else { return }
        // The document's own title is a Document-type entity; aliases attach to it. It is
        // created here rather than by extraction because front matter states it outright.
        let entity = Entity(type: "Document", canonicalName: parsed.title)
        try GraphRepository.upsert(entity, in: db)
        for alias in parsed.metadata.aliases {
            try GraphRepository.upsert(Alias(entityID: entity.id, name: alias), in: db)
        }

        // Mentioned by every chunk of its own document. This is both true — the document is
        // what those chunks are part of — and what gives the entity a reference count, so it
        // survives collection while the document exists and is collected when it does not.
        // It also means querying an alias retrieves the whole document.
        for chunk in try ChunkRepository.fetchAll(documentID: documentID, in: db) {
            try GraphRepository.upsert(
                Mention(
                    entityID: entity.id,
                    chunkID: chunk.id,
                    surfaceForm: parsed.title,
                    source: .frontMatter
                ),
                in: db
            )
        }
    }

    /// Removes a document and everything derived from it.
    public func remove(relativePath: String, in db: Database) throws -> IngestionOutcome {
        // Resolved by path rather than by recomputing the ID, for the same reason as
        // ``ingest`` — a renamed document's ID no longer matches its current path.
        guard let documentID = try DocumentRepository.fetch(relativePath: relativePath, in: db)?.id
        else {
            return IngestionOutcome(
                documentID: DocumentID(relativePath: relativePath),
                chunksAdded: 0,
                chunksModified: 0,
                chunksUnchanged: 0,
                chunksRemoved: 0,
                entitiesCollected: 0,
                warnings: []
            )
        }
        let chunkIDs = Array(try ChunkRepository.fetchHashes(documentID: documentID, in: db).keys)
        try ChunkRepository.delete(ids: chunkIDs, in: db)
        try DocumentRepository.delete(id: documentID, in: db)
        let collected = try GraphRepository.collectOrphanedEntities(in: db)

        return IngestionOutcome(
            documentID: documentID,
            chunksAdded: 0,
            chunksModified: 0,
            chunksUnchanged: 0,
            chunksRemoved: chunkIDs.count,
            entitiesCollected: collected,
            warnings: []
        )
    }
}
