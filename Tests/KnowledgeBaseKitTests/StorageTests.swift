import Foundation
import GRDB
import Testing

@testable import KnowledgeBaseKit

/// A scratch database that cleans itself up.
struct TemporaryDatabase: ~Copyable {
    let url: URL
    let database: KnowledgeDatabase

    init(allowsWriting: Bool = true, dimensions: Int = 4) throws {
        self.url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kbkit-test-\(UUID().uuidString)")
            .appendingPathComponent("store.sqlite")
        self.database = try KnowledgeDatabase(
            url: url,
            allowsWriting: allowsWriting,
            embeddingDimensions: dimensions
        )
    }

    deinit {
        database.close()
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

private func makeDocument(path: String = "notes/auth.md", hash: String = "h1") -> Document {
    Document(
        id: DocumentID(relativePath: path),
        relativePath: path,
        contentHash: hash,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: DocumentMetadata(title: "Auth", tags: ["security"], aliases: ["AuthN"])
    )
}

private func makeChunk(
    document: Document,
    heading: [String] = ["Auth", "Tokens"],
    content: String = "Tokens are issued by the auth service.",
    ordinal: Int = 0,
    occurrence: Int = 0
) -> Chunk {
    let path = HeadingPath(heading)
    return Chunk(
        id: ChunkID(document: document.id, headingPath: path, occurrence: occurrence),
        documentID: document.id,
        ordinal: ordinal,
        headingPath: path,
        content: content,
        contentHash: ContentHash.of(content),
        occurrence: occurrence
    )
}

@Suite("Database setup")
struct DatabaseSetupTests {
    @Test("sqlite-vec is registered on every connection and FTS5 is available")
    func extensionsAvailable() throws {
        let temporary = try TemporaryDatabase()
        let version = try temporary.database.vectorExtensionVersion()
        #expect(version.hasPrefix("v0.1"))

        // Reads use a different pooled connection than writes, so this proves the
        // registration is per-connection rather than a one-off on the writer.
        try temporary.database.read { db in
            try #expect(String.fetchOne(db, sql: "SELECT vec_version()") != nil)
        }
    }

    @Test("The database opens in WAL mode so readers run during indexing")
    func walMode() throws {
        let temporary = try TemporaryDatabase()
        let mode = try temporary.database.read { db in
            try String.fetchOne(db, sql: "PRAGMA journal_mode")
        }
        #expect(mode == "wal")
    }

    @Test("Vector tables are recreated when the embedding dimension changes")
    func vectorSchemaFollowsDimensions() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            try VectorIndex.upsertChunkEmbedding(
                in: db,
                chunkID: ChunkID(rawValue: "c1"),
                embedding: [1, 0, 0, 0]
            )
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") == 1)

            // A different dimension makes the stored vectors meaningless, so the table is
            // rebuilt rather than migrated.
            try VectorIndex.ensureSchema(in: db, dimensions: 8)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") == 0)

            // Re-running with the same dimension must be a no-op, not another wipe.
            try VectorIndex.upsertChunkEmbedding(
                in: db,
                chunkID: ChunkID(rawValue: "c2"),
                embedding: Array(repeating: 0.5, count: 8)
            )
            try VectorIndex.ensureSchema(in: db, dimensions: 8)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") == 1)
        }
    }

    @Test("Nearest-neighbour search on an empty index degrades to no results, not an error")
    func emptyVectorIndex() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            let neighbors = try VectorIndex.nearestChunks(in: db, to: [1, 0, 0, 0], limit: 10)
            #expect(neighbors.isEmpty)
        }
    }

    @Test("Nearest-neighbour search ranks by distance")
    func knnRanking() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            try VectorIndex.upsertChunkEmbedding(in: db, chunkID: ChunkID(rawValue: "far"), embedding: [0, 1, 0, 0])
            try VectorIndex.upsertChunkEmbedding(in: db, chunkID: ChunkID(rawValue: "near"), embedding: [0.9, 0.1, 0, 0])
            try VectorIndex.upsertChunkEmbedding(in: db, chunkID: ChunkID(rawValue: "exact"), embedding: [1, 0, 0, 0])

            let neighbors = try VectorIndex.nearestChunks(in: db, to: [1, 0, 0, 0], limit: 3)
            #expect(neighbors.map(\.chunkID.rawValue) == ["exact", "near", "far"])
        }
    }
}

@Suite("Write lock")
struct WriteLockTests {
    @Test("A second writer is refused and told who holds the lock")
    func exclusiveWrites() throws {
        let temporary = try TemporaryDatabase()

        #expect(throws: KnowledgeStoreError.self) {
            _ = try KnowledgeDatabase(url: temporary.url, allowsWriting: true, embeddingDimensions: 4)
        }

        do {
            _ = try KnowledgeDatabase(url: temporary.url, allowsWriting: true, embeddingDimensions: 4)
            Issue.record("Expected the second writer to be refused")
        } catch let error as KnowledgeStoreError {
            guard case .databaseInUse(let holder) = error else {
                Issue.record("Expected databaseInUse, got \(error)")
                return
            }
            #expect(holder.contains("pid"))
        }
    }

    @Test("Readers are admitted while a writer holds the lock")
    func sharedReads() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(makeDocument(), in: db)
        }

        // This is the case that matters in practice: the host app is indexing, and the
        // in-process MCP server or a `kb search` still needs to answer.
        let reader = try KnowledgeDatabase(url: temporary.url, allowsWriting: false, embeddingDimensions: 4)
        defer { reader.close() }
        let count = try reader.read { try DocumentRepository.count(in: $0) }
        #expect(count == 1)
    }

    @Test("Releasing the lock lets the next writer in")
    func lockIsReleased() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kbkit-lock-\(UUID().uuidString)")
            .appendingPathComponent("store.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try KnowledgeDatabase(url: url, allowsWriting: true, embeddingDimensions: 4)
        first.close()

        let second = try KnowledgeDatabase(url: url, allowsWriting: true, embeddingDimensions: 4)
        second.close()
    }
}

@Suite("Repositories")
struct RepositoryTests {
    @Test("Documents and chunks round-trip, including metadata")
    func roundTrip() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        let chunk = makeChunk(document: document)

        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunk, in: db)
        }

        try temporary.database.read { db in
            let loaded = try #require(try DocumentRepository.fetch(id: document.id, in: db))
            #expect(loaded.relativePath == "notes/auth.md")
            #expect(loaded.metadata.title == "Auth")
            #expect(loaded.metadata.tags == ["security"])
            #expect(loaded.metadata.aliases == ["AuthN"])

            let loadedChunk = try #require(try ChunkRepository.fetch(id: chunk.id, in: db))
            #expect(loadedChunk.headingPath.components == ["Auth", "Tokens"])
            #expect(loadedChunk.content == chunk.content)
        }
    }

    @Test("Renaming a document preserves its chunks")
    func renamePreservesChunks() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        let chunk = makeChunk(document: document)

        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunk, in: db)
            try DocumentRepository.updatePath(
                of: document.id,
                to: "archive/auth.md",
                modifiedAt: Date(),
                in: db
            )
        }

        try temporary.database.read { db in
            let loaded = try #require(try DocumentRepository.fetch(id: document.id, in: db))
            #expect(loaded.relativePath == "archive/auth.md")
            try #expect(ChunkRepository.fetchAll(documentID: document.id, in: db).count == 1)
        }
    }

    @Test("FTS5 index is kept in sync by triggers, including deletes")
    func ftsTriggers() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        var chunk = makeChunk(document: document)
        let original = chunk

        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(original, in: db)
        }

        func ftsMatches(_ query: String) throws -> [String] {
            try temporary.database.read { db in
                try String.fetchAll(
                    db,
                    sql: "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH ?",
                    arguments: [query]
                )
            }
        }

        try #expect(ftsMatches("issued") == [original.id.rawValue])

        // Update: the trigger must replace, not duplicate.
        chunk.content = "Sessions expire after an hour."
        chunk.contentHash = ContentHash.of(chunk.content)
        let edited = chunk
        try temporary.database.write { db in
            try ChunkRepository.insertOrReplace(edited, in: db)
        }
        try #expect(ftsMatches("issued").isEmpty)
        try #expect(ftsMatches("expire") == [original.id.rawValue])

        let deleted = chunk.id
        try temporary.database.write { db in
            try ChunkRepository.delete(ids: [deleted], in: db)
        }
        try #expect(ftsMatches("expire").isEmpty)
    }

    @Test("Deleting a document cascades to chunks, mentions, relations, and jobs")
    func cascadingDelete() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        let chunk = makeChunk(document: document)
        let entity = Entity(type: "Component", canonicalName: "Auth Service")
        let other = Entity(type: "Component", canonicalName: "Token Store")

        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunk, in: db)
            try VectorIndex.upsertChunkEmbedding(in: db, chunkID: chunk.id, embedding: [1, 0, 0, 0])
            try GraphRepository.upsert(entity, in: db)
            try GraphRepository.upsert(other, in: db)
            try GraphRepository.upsert(Mention(entityID: entity.id, chunkID: chunk.id, surfaceForm: "auth service"), in: db)
            try GraphRepository.upsert(
                Relation(
                    sourceID: entity.id,
                    type: "uses",
                    targetID: other.id,
                    supportingChunkID: chunk.id,
                    confidence: 0.9
                ),
                in: db
            )
            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)
        }

        try temporary.database.write { db in
            try ChunkRepository.delete(ids: [chunk.id], in: db)
            try DocumentRepository.delete(id: document.id, in: db)
        }

        try temporary.database.read { db in
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM chunks") == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM mentions") == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM relations") == 0)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM jobs") == 0)
            // vec0 rows are outside the foreign-key graph and must be removed explicitly.
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") == 0)
        }
    }

    @Test("Orphaned entities are collected once their last mention and relation are gone")
    func orphanCollection() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        let chunkA = makeChunk(document: document, heading: ["Auth", "A"], content: "First.", ordinal: 0)
        let chunkB = makeChunk(document: document, heading: ["Auth", "B"], content: "Second.", ordinal: 1)
        let shared = Entity(type: "Component", canonicalName: "Shared")
        let lonely = Entity(type: "Component", canonicalName: "Lonely")

        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunkA, in: db)
            try ChunkRepository.insertOrReplace(chunkB, in: db)
            try GraphRepository.upsert(shared, in: db)
            try GraphRepository.upsert(lonely, in: db)
            try GraphRepository.upsert(Alias(entityID: lonely.id, name: "Solo"), in: db)
            // `shared` is mentioned twice; `lonely` only by chunk A.
            try GraphRepository.upsert(Mention(entityID: shared.id, chunkID: chunkA.id, surfaceForm: "shared"), in: db)
            try GraphRepository.upsert(Mention(entityID: shared.id, chunkID: chunkB.id, surfaceForm: "shared"), in: db)
            try GraphRepository.upsert(Mention(entityID: lonely.id, chunkID: chunkA.id, surfaceForm: "lonely"), in: db)
        }

        try temporary.database.write { db in
            try ChunkRepository.delete(ids: [chunkA.id], in: db)
            let collected = try GraphRepository.collectOrphanedEntities(in: db)
            #expect(collected == 1)
        }

        try temporary.database.read { db in
            // The still-mentioned entity survives; the orphan and its alias are gone.
            try #expect(GraphRepository.fetch(id: shared.id, in: db) != nil)
            try #expect(GraphRepository.fetch(id: lonely.id, in: db) == nil)
            try #expect(Int.fetchOne(db, sql: "SELECT count(*) FROM aliases") == 0)
        }
    }

    @Test("A relation survives while any supporting chunk remains")
    func relationSupport() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        let chunkA = makeChunk(document: document, heading: ["Auth", "A"], content: "First.", ordinal: 0)
        let chunkB = makeChunk(document: document, heading: ["Auth", "B"], content: "Second.", ordinal: 1)
        let source = Entity(type: "Component", canonicalName: "API")
        let target = Entity(type: "Component", canonicalName: "Database")

        try temporary.database.write { db in
            try VectorIndex.ensureSchema(in: db, dimensions: 4)
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunkA, in: db)
            try ChunkRepository.insertOrReplace(chunkB, in: db)
            try GraphRepository.upsert(source, in: db)
            try GraphRepository.upsert(target, in: db)
            // The same claim, asserted independently by two chunks.
            for chunk in [chunkA, chunkB] {
                try GraphRepository.upsert(
                    Relation(
                        sourceID: source.id,
                        type: "uses",
                        targetID: target.id,
                        supportingChunkID: chunk.id,
                        confidence: 0.8
                    ),
                    in: db
                )
            }
        }

        try temporary.database.write { db in
            try ChunkRepository.delete(ids: [chunkA.id], in: db)
        }

        try temporary.database.read { db in
            // One support gone, one remains: the fact is still asserted.
            try #expect(GraphRepository.relationCount(in: db) == 1)
        }

        try temporary.database.write { db in
            try ChunkRepository.delete(ids: [chunkB.id], in: db)
        }

        try temporary.database.read { db in
            try #expect(GraphRepository.relationCount(in: db) == 0)
        }
    }

    @Test("Coverage counts an edited chunk as stale, not done")
    func coverageTracksStaleness() throws {
        let temporary = try TemporaryDatabase()
        let document = makeDocument()
        var chunk = makeChunk(document: document)
        let indexed = chunk

        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(indexed, in: db)
            try ChunkRepository.markEmbedded(id: indexed.id, contentHash: indexed.contentHash, in: db)
            try ChunkRepository.markExtracted(id: indexed.id, contentHash: indexed.contentHash, in: db)
        }

        try temporary.database.read { db in
            let coverage = try ChunkRepository.coverage(in: db)
            #expect(coverage == ChunkRepository.Coverage(total: 1, embedded: 1, extracted: 1))
        }

        chunk.content = "Rewritten entirely."
        chunk.contentHash = ContentHash.of(chunk.content)
        let rewritten = chunk
        try temporary.database.write { db in
            try ChunkRepository.insertOrReplace(rewritten, in: db)
        }

        try temporary.database.read { db in
            let coverage = try ChunkRepository.coverage(in: db)
            #expect(coverage == ChunkRepository.Coverage(total: 1, embedded: 0, extracted: 0))
        }
    }
}

@Suite("Job queue")
struct JobQueueTests {
    private func seed(_ temporary: borrowing TemporaryDatabase) throws -> Chunk {
        let document = makeDocument()
        let chunk = makeChunk(document: document)
        try temporary.database.write { db in
            try DocumentRepository.insertOrReplace(document, in: db)
            try ChunkRepository.insertOrReplace(chunk, in: db)
        }
        return chunk
    }

    @Test("Claiming marks jobs running so they are not taken twice")
    func claiming() throws {
        let temporary = try TemporaryDatabase()
        let chunk = try seed(temporary)

        try temporary.database.write { db in
            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)
            let first = try JobRepository.claim(kind: .embed, limit: 10, in: db)
            #expect(first.count == 1)

            let second = try JobRepository.claim(kind: .embed, limit: 10, in: db)
            #expect(second.isEmpty)
        }
    }

    @Test("A permanent failure dead-letters after the configured attempts")
    func deadLettering() throws {
        let temporary = try TemporaryDatabase()
        let chunk = try seed(temporary)
        let retry = RetryConfiguration(maximumAttempts: 3, initialBackoff: 0)

        try temporary.database.write { db in
            try JobRepository.enqueue(kind: .extract, targetID: chunk.id, in: db)

            for attempt in 1...3 {
                let jobs = try JobRepository.claim(kind: .extract, limit: 1, in: db, now: Date().addingTimeInterval(60))
                let job = try #require(jobs.first)
                try JobRepository.fail(
                    job,
                    error: "unparseable JSON",
                    isTransient: false,
                    retry: retry,
                    in: db
                )
                let depth = try JobRepository.depth(kind: .extract, in: db)
                #expect(depth.failed == (attempt == 3 ? 1 : 0))
            }

            // Dead-lettered jobs are skipped by the queue thereafter.
            let afterwards = try JobRepository.claim(kind: .extract, limit: 1, in: db, now: Date().addingTimeInterval(3600))
            #expect(afterwards.isEmpty)

            let failed = try JobRepository.failedJobs(limit: 10, in: db)
            #expect(failed.first?.lastError == "unparseable JSON")
        }
    }

    @Test("A transient failure backs off without consuming an attempt")
    func transientFailure() throws {
        let temporary = try TemporaryDatabase()
        let chunk = try seed(temporary)
        let retry = RetryConfiguration(maximumAttempts: 3, initialBackoff: 1)

        try temporary.database.write { db in
            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)

            // An unreachable Ollama must not burn through the retry budget while the user
            // is away from the machine.
            for _ in 1...10 {
                let jobs = try JobRepository.claim(kind: .embed, limit: 1, in: db, now: Date().addingTimeInterval(3600))
                let job = try #require(jobs.first)
                try JobRepository.fail(
                    job,
                    error: "connection refused",
                    isTransient: true,
                    retry: retry,
                    in: db
                )
            }

            let depth = try JobRepository.depth(kind: .embed, in: db)
            #expect(depth.failed == 0)
            #expect(depth.pending == 1)
        }
    }

    @Test("Re-enqueuing a dead-lettered job resets it, because the content changed")
    func reenqueueResets() throws {
        let temporary = try TemporaryDatabase()
        let chunk = try seed(temporary)
        let retry = RetryConfiguration(maximumAttempts: 1, initialBackoff: 0)

        try temporary.database.write { db in
            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)
            let job = try #require(try JobRepository.claim(kind: .embed, limit: 1, in: db).first)
            try JobRepository.fail(job, error: "boom", isTransient: false, retry: retry, in: db)
            try #expect(JobRepository.depth(kind: .embed, in: db).failed == 1)

            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)
            let depth = try JobRepository.depth(kind: .embed, in: db)
            #expect(depth.failed == 0)
            #expect(depth.pending == 1)
        }
    }

    @Test("Jobs left running by a dead process are reclaimed on open")
    func reclaimAbandoned() throws {
        let temporary = try TemporaryDatabase()
        let chunk = try seed(temporary)

        try temporary.database.write { db in
            try JobRepository.enqueue(kind: .embed, targetID: chunk.id, in: db)
            _ = try JobRepository.claim(kind: .embed, limit: 1, in: db)
            try #expect(JobRepository.depth(kind: .embed, in: db).running == 1)

            let reclaimed = try JobRepository.reclaimAbandoned(in: db)
            #expect(reclaimed == 1)
            try #expect(JobRepository.depth(kind: .embed, in: db).pending == 1)
        }
    }
}

@Suite("Version drift")
struct VersionMetadataTests {
    private let configuration = KnowledgeStoreConfiguration()

    @Test("A first open is not a migration")
    func firstOpen() throws {
        let temporary = try TemporaryDatabase()
        let plan = try temporary.database.read { db in
            try VersionMetadata.plan(configuration: configuration, chunker: Chunker(), in: db)
        }
        #expect(plan.isEmpty)
    }

    @Test("Changing the embedding model re-embeds and leaves the graph alone")
    func embeddingChange() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VersionMetadata.stamp(configuration: configuration, chunker: Chunker(), in: db)
        }

        var mutable = configuration
        mutable.embedding = EmbeddingConfiguration(model: "mxbai-embed-large", dimensions: 1024)
        let changed = mutable

        let plan = try temporary.database.read { db in
            try VersionMetadata.plan(configuration: changed, chunker: Chunker(), in: db)
        }

        #expect(plan.requiresReembed)
        #expect(!plan.requiresReextract)
        #expect(!plan.requiresRechunk)
        #expect(plan.changes.count == 2)  // model and dimensions
    }

    @Test("Changing the extraction vocabulary re-extracts and leaves embeddings alone")
    func vocabularyChange() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VersionMetadata.stamp(configuration: configuration, chunker: Chunker(), in: db)
        }

        var mutable = configuration
        mutable.extraction.vocabulary = GraphVocabulary(
            entityTypes: ["Component", "Person", "Concept", "Technology", "Project", "Document", "Team"],
            relationTypes: GraphVocabulary.default.relationTypes
        )
        let changed = mutable

        let plan = try temporary.database.read { db in
            try VersionMetadata.plan(configuration: changed, chunker: Chunker(), in: db)
        }

        #expect(plan.requiresReextract)
        #expect(!plan.requiresReembed)
    }

    @Test("Reordering the vocabulary is not a change")
    func vocabularyOrderIsIrrelevant() throws {
        let reversed = GraphVocabulary(
            entityTypes: GraphVocabulary.default.entityTypes.reversed(),
            relationTypes: GraphVocabulary.default.relationTypes.reversed()
        )
        #expect(reversed.fingerprint == GraphVocabulary.default.fingerprint)
    }

    @Test("Changing the chunker cascades to both re-embed and re-extract")
    func chunkerChange() throws {
        let temporary = try TemporaryDatabase()
        try temporary.database.write { db in
            try VersionMetadata.stamp(configuration: configuration, chunker: Chunker(), in: db)
        }

        let widerChunker = Chunker(configuration: ChunkingConfiguration(minimumTokens: 32, maximumTokens: 1024))
        let plan = try temporary.database.read { db in
            try VersionMetadata.plan(configuration: configuration, chunker: widerChunker, in: db)
        }

        #expect(plan.requiresRechunk)
        #expect(plan.requiresReembed)
        #expect(plan.requiresReextract)
    }
}
