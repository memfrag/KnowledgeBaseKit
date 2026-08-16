import Foundation
import GRDB
import OSLog

/// Drains the embedding and extraction queues.
///
/// Both workers follow the same shape: claim a batch, do the model work *outside* any
/// transaction, then write the results. Holding a write transaction across an `await` on
/// Ollama would block every other writer for the duration of a model call.
public struct JobWorkers: Sendable {
    private let database: KnowledgeDatabase
    private let configuration: KnowledgeStoreConfiguration
    private let embedding: any EmbeddingProvider
    private let extraction: any ExtractionProvider
    private let resolver: EntityResolver
    private let logger = Logger(subsystem: "KnowledgeBaseKit", category: "queue")

    public init(
        database: KnowledgeDatabase,
        configuration: KnowledgeStoreConfiguration,
        embedding: any EmbeddingProvider,
        extraction: any ExtractionProvider
    ) {
        self.database = database
        self.configuration = configuration
        self.embedding = embedding
        self.extraction = extraction
        self.resolver = EntityResolver(
            configuration: configuration.extraction,
            embedding: embedding,
            extraction: extraction
        )
    }

    /// Result of one pass over a queue.
    public struct Pass: Sendable, Hashable {
        public var claimed: Int
        public var succeeded: Int
        public var failed: Int

        public var didWork: Bool { claimed > 0 }
    }

    // MARK: - Embedding

    public func runEmbeddingPass(now: Date = Date()) async throws -> Pass {
        let jobs = try database.write { db in
            try JobRepository.claim(
                kind: .embed,
                limit: configuration.embedding.batchSize,
                in: db,
                now: now
            )
        }
        guard !jobs.isEmpty else { return Pass(claimed: 0, succeeded: 0, failed: 0) }

        // A chunk may have been deleted between enqueueing and claiming.
        let chunks = try database.read { db in
            try ChunkRepository.fetch(ids: jobs.map(\.targetID), in: db)
        }
        let chunksByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })

        let live = jobs.filter { chunksByID[$0.targetID] != nil }
        let orphaned = jobs.filter { chunksByID[$0.targetID] == nil }
        if !orphaned.isEmpty {
            try database.write { db in
                for job in orphaned { try JobRepository.complete(job, in: db) }
            }
        }
        guard !live.isEmpty else { return Pass(claimed: jobs.count, succeeded: 0, failed: 0) }

        let inputs = live.map { chunksByID[$0.targetID]!.embeddingInput }

        do {
            let vectors = try await embedding.embed(inputs)
            try database.write { db in
                for (job, vector) in zip(live, vectors) {
                    guard let chunk = chunksByID[job.targetID] else { continue }
                    try VectorIndex.upsertChunkEmbedding(in: db, chunkID: chunk.id, embedding: vector)
                    try ChunkRepository.markEmbedded(
                        id: chunk.id,
                        contentHash: chunk.contentHash,
                        in: db
                    )
                    try JobRepository.complete(job, in: db)
                }
            }
            return Pass(claimed: jobs.count, succeeded: live.count, failed: 0)
        } catch {
            try recordFailure(error, for: live, now: now)
            return Pass(claimed: jobs.count, succeeded: 0, failed: live.count)
        }
    }

    // MARK: - Extraction

    public func runExtractionPass(now: Date = Date()) async throws -> Pass {
        // Extraction is one chunk per model call, so the batch is the worker count rather
        // than the embedding batch size.
        let jobs = try database.write { db in
            try JobRepository.claim(kind: .extract, limit: configuration.workerCount, in: db, now: now)
        }
        guard !jobs.isEmpty else { return Pass(claimed: 0, succeeded: 0, failed: 0) }

        var succeeded = 0
        var failed = 0

        for job in jobs {
            let context = try database.read { db -> ChunkContext? in
                guard let chunk = try ChunkRepository.fetch(id: job.targetID, in: db) else { return nil }
                let document = try DocumentRepository.fetch(id: chunk.documentID, in: db)
                return ChunkContext(
                    chunkID: chunk.id,
                    documentTitle: document?.metadata.title ?? chunk.headingPath.components.first ?? "",
                    headingPath: chunk.headingPath,
                    text: chunk.content
                )
            }

            guard let context else {
                try database.write { db in try JobRepository.complete(job, in: db) }
                continue
            }

            do {
                let result = try await extraction.extract(
                    from: context,
                    vocabulary: configuration.extraction.vocabulary
                )
                try await applyExtraction(result, for: context, job: job)
                succeeded += 1
            } catch {
                try recordFailure(error, for: [job], now: now)
                failed += 1
            }
        }

        return Pass(claimed: jobs.count, succeeded: succeeded, failed: failed)
    }

    /// Resolves every extracted name, then writes mentions and relations in one transaction.
    private func applyExtraction(
        _ result: ExtractionResult,
        for context: ChunkContext,
        job: Job
    ) async throws {
        // Name embeddings for entities that need the similarity stage. Batched so a chunk
        // with eight entities costs one embedding call, not eight.
        var nameEmbeddings: [String: [Float]] = [:]
        if !result.entities.isEmpty {
            let inputs = result.entities.map {
                EntityResolver.nameEmbeddingInput(name: $0.name, type: $0.type)
            }
            let vectors = try await embedding.embed(inputs)
            for (input, vector) in zip(inputs, vectors) {
                nameEmbeddings[input] = vector
            }
        }

        // Resolution reads the database and may call the model, so it happens before the
        // write transaction opens.
        var resolutions: [(ExtractedEntity, EntityResolver.Resolution, [Float]?)] = []
        for extracted in result.entities {
            let key = EntityResolver.nameEmbeddingInput(name: extracted.name, type: extracted.type)
            let nameEmbedding = nameEmbeddings[key]
            let (exact, similar) = try database.read { db in
                try resolver.candidates(for: extracted, nameEmbedding: nameEmbedding, in: db)
            }
            let resolution = try await resolver.resolve(
                extracted,
                candidates: similar,
                exactMatches: exact
            )
            resolutions.append((extracted, resolution, nameEmbedding))
        }

        var names: [String: EntityID] = [:]
        for (extracted, resolution, _) in resolutions {
            names[NameNormalizer.normalize(extracted.name)] = resolution.entity.id
        }

        // Frozen before the transaction: the write closure is @Sendable and cannot capture
        // the mutable state that resolution built up.
        let resolved = resolutions
        let byExtractedName = names

        try database.write { db in
            // The chunk's previous assertions are cleared first, so re-extracting a modified
            // chunk replaces its contribution to the graph rather than adding to it.
            try GraphRepository.clearExtraction(ofChunk: context.chunkID, in: db)

            for (_, resolution, nameEmbedding) in resolved {
                try resolver.persist(resolution, nameEmbedding: nameEmbedding, in: db)
                try GraphRepository.upsert(
                    Mention(
                        entityID: resolution.entity.id,
                        chunkID: context.chunkID,
                        surfaceForm: resolution.surfaceForm
                    ),
                    in: db
                )
            }

            for relation in result.relations {
                guard let source = byExtractedName[NameNormalizer.normalize(relation.source)],
                    let target = byExtractedName[NameNormalizer.normalize(relation.target)]
                else { continue }
                try GraphRepository.upsert(
                    Relation(
                        sourceID: source,
                        type: relation.type,
                        targetID: target,
                        supportingChunkID: context.chunkID,
                        confidence: relation.confidence
                    ),
                    in: db
                )
            }

            if let chunk = try ChunkRepository.fetch(id: context.chunkID, in: db) {
                try ChunkRepository.markExtracted(
                    id: chunk.id,
                    contentHash: chunk.contentHash,
                    in: db
                )
            }
            try JobRepository.complete(job, in: db)
            try GraphRepository.collectOrphanedEntities(in: db)
        }
    }

    // MARK: - Failure handling

    private func recordFailure(_ error: any Error, for jobs: [Job], now: Date) throws {
        let providerError = error as? ProviderError
        let isTransient = providerError?.isTransient ?? false
        let description = providerError.map(String.init(describing:)) ?? error.localizedDescription

        if isTransient {
            logger.notice("Deferring \(jobs.count) job(s): \(description, privacy: .public)")
        } else {
            logger.error("Failing \(jobs.count) job(s): \(description, privacy: .public)")
        }

        try database.write { db in
            for job in jobs {
                try JobRepository.fail(
                    job,
                    error: description,
                    isTransient: isTransient,
                    retry: configuration.retry,
                    in: db,
                    now: now
                )
            }
        }
    }
}
