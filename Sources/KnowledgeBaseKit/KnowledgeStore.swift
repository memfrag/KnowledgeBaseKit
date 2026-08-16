import Foundation
import GRDB
import OSLog

/// The package's front door.
///
/// An actor because ingestion, the background workers, and retrieval all touch the same
/// database and the same job queue. Reads go through the connection pool concurrently; the
/// actor serializes the bookkeeping around them.
public actor KnowledgeStore {
    public let databaseURL: URL
    public nonisolated let configuration: KnowledgeStoreConfiguration

    private let database: KnowledgeDatabase
    private let chunker: Chunker
    private let ingestor: DocumentIngestor
    private let scanner: CorpusScanner
    private let workers: JobWorkers
    private let retrieval: RetrievalEngine
    private let answerEngine: AnswerEngine
    private let embedding: any EmbeddingProvider
    private let logger = Logger(subsystem: "KnowledgeBaseKit", category: "store")

    private var pumpTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?
    private var watcher: CorpusWatcher?

    /// Opens a store backed by Ollama.
    ///
    /// - Parameter migrationHandler: called with the migration plan *before* any re-indexing
    ///   work is queued, so a host can report or veto it. Returning false throws
    ///   ``KnowledgeStoreError/versionMismatch(key:stored:running:)``.
    public init(
        databaseURL: URL,
        configuration: KnowledgeStoreConfiguration = KnowledgeStoreConfiguration(),
        migrationHandler: (@Sendable (MigrationPlan) -> Bool)? = nil
    ) throws {
        let client = OllamaClient(endpoint: configuration.ollamaEndpoint)
        try self.init(
            databaseURL: databaseURL,
            configuration: configuration,
            embedding: OllamaEmbeddingProvider(client: client, configuration: configuration.embedding),
            extraction: OllamaExtractionProvider(client: client, configuration: configuration.extraction),
            generation: OllamaGenerationProvider(client: client),
            migrationHandler: migrationHandler
        )
    }

    /// Opens a store with explicit providers.
    ///
    /// This is the seam the deterministic providers plug into: the parser, chunker, differ,
    /// job queue, graph collection, and fusion ranking are all exercisable with no model
    /// running and no flakiness.
    public init(
        databaseURL: URL,
        configuration: KnowledgeStoreConfiguration = KnowledgeStoreConfiguration(),
        embedding: any EmbeddingProvider,
        extraction: any ExtractionProvider,
        generation: any GenerationProvider,
        migrationHandler: (@Sendable (MigrationPlan) -> Bool)? = nil
    ) throws {
        self.databaseURL = databaseURL
        self.configuration = configuration
        self.embedding = embedding
        self.chunker = Chunker(configuration: configuration.chunking)

        self.database = try KnowledgeDatabase(
            url: databaseURL,
            allowsWriting: configuration.allowsWriting,
            embeddingDimensions: embedding.dimensions
        )
        self.ingestor = DocumentIngestor(
            chunker: chunker,
            extractsGraph: configuration.graphExtraction
        )
        self.scanner = CorpusScanner(
            roots: configuration.corpusRoots,
            ignorePatterns: configuration.ignorePatterns
        )
        self.workers = JobWorkers(
            database: database,
            configuration: configuration,
            embedding: embedding,
            extraction: extraction
        )
        self.retrieval = RetrievalEngine(
            database: database,
            configuration: configuration,
            embedding: embedding
        )
        self.answerEngine = AnswerEngine(
            retrieval: retrieval,
            generation: generation,
            model: configuration.extraction.model,
            endpoint: configuration.ollamaEndpoint
        )

        if configuration.allowsWriting {
            try Self.applyMigrations(
                database: database,
                configuration: configuration,
                chunker: chunker,
                handler: migrationHandler
            )
            try Self.reconcileGraphExtraction(database: database, configuration: configuration)
        }
    }

    /// Brings queued extraction work in line with ``KnowledgeStoreConfiguration/graphExtraction``.
    ///
    /// Both directions need handling. Turning the graph off would otherwise leave extraction
    /// jobs queued forever — and since a missing model is classified transient, they would
    /// retry indefinitely rather than drain. Turning it back on has the mirror problem: chunks
    /// ingested while it was off were never queued, so they would stay outside the graph until
    /// something happened to edit them.
    private static func reconcileGraphExtraction(
        database: KnowledgeDatabase,
        configuration: KnowledgeStoreConfiguration
    ) throws {
        try database.write { db in
            guard configuration.graphExtraction else {
                try db.execute(
                    sql: "DELETE FROM jobs WHERE kind = ?",
                    arguments: [JobKind.extract.rawValue]
                )
                return
            }

            // Backfill only what is genuinely missing, so an up-to-date store finds nothing.
            let missing = try String.fetchAll(
                db,
                sql: "SELECT id FROM chunks WHERE extracted_hash IS NULL OR extracted_hash <> content_hash"
            ).map(ChunkID.init(rawValue:))

            guard !missing.isEmpty else { return }
            try JobRepository.enqueueAll(kind: .extract, targetIDs: missing, in: db)
        }
    }

    deinit {
        pumpTask?.cancel()
        watcherTask?.cancel()
    }

    /// Releases the write lock and stops background work.
    public func close() async {
        pumpTask?.cancel()
        pumpTask = nil
        watcherTask?.cancel()
        watcherTask = nil
        await watcher?.stop()
        watcher = nil
        database.close()
    }

    // MARK: - Migration

    private static func applyMigrations(
        database: KnowledgeDatabase,
        configuration: KnowledgeStoreConfiguration,
        chunker: Chunker,
        handler: (@Sendable (MigrationPlan) -> Bool)?
    ) throws {
        let plan = try database.read { db in
            try VersionMetadata.plan(configuration: configuration, chunker: chunker, in: db)
        }

        guard !plan.isEmpty else {
            try database.write { db in
                try VersionMetadata.stamp(configuration: configuration, chunker: chunker, in: db)
            }
            return
        }

        if let handler, !handler(plan) {
            let change = plan.changes[0]
            throw KnowledgeStoreError.versionMismatch(
                key: change.key.rawValue,
                stored: change.stored ?? "(unset)",
                running: change.running
            )
        }

        try database.write { db in
            // Re-indexing is enqueued rather than performed here, so it is incremental,
            // resumable, and visible in `kb status` instead of blocking the open call.
            if plan.requiresReembed {
                try ChunkRepository.invalidateAllEmbeddings(in: db)
                try JobRepository.enqueueAll(
                    kind: .embed,
                    targetIDs: try ChunkRepository.allIDs(in: db),
                    in: db
                )
            }
            if plan.requiresReextract {
                try ChunkRepository.invalidateAllExtractions(in: db)
                try JobRepository.enqueueAll(
                    kind: .extract,
                    targetIDs: try ChunkRepository.allIDs(in: db),
                    in: db
                )
            }
            try VersionMetadata.stamp(configuration: configuration, chunker: chunker, in: db)
        }

        // A chunker change moves chunk boundaries, so the corpus has to be re-read from disk.
        // Chunks are left in place until then: they remain searchable, just stale.
    }

    /// The migration that opening the store *would* perform, without performing it.
    public func pendingMigration() throws -> MigrationPlan {
        try database.read { db in
            try VersionMetadata.plan(configuration: configuration, chunker: chunker, in: db)
        }
    }

    // MARK: - Per-file ingestion

    @discardableResult
    public func add(url: URL) async throws -> IngestionOutcome {
        try await ingest(url: url, force: false)
    }

    @discardableResult
    public func update(url: URL) async throws -> IngestionOutcome {
        try await ingest(url: url, force: false)
    }

    @discardableResult
    public func remove(url: URL) async throws -> IngestionOutcome {
        try requireWritable()
        guard let relativePath = scanner.relativePath(for: url) else {
            throw KnowledgeStoreError.pathOutsideCorpus(url)
        }
        return try database.write { db in
            try ingestor.remove(relativePath: relativePath, in: db)
        }
    }

    private func ingest(url: URL, force: Bool) async throws -> IngestionOutcome {
        try requireWritable()
        guard let relativePath = scanner.relativePath(for: url) else {
            throw KnowledgeStoreError.pathOutsideCorpus(url)
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw KnowledgeStoreError.corpusRootUnreadable(url, underlying: error.localizedDescription)
        }
        let modifiedAt =
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()

        return try database.write { db in
            try ingestor.ingest(
                source: source,
                relativePath: relativePath,
                modifiedAt: modifiedAt,
                force: force,
                in: db
            )
        }
    }

    // MARK: - Corpus reconciliation

    public struct SyncSummary: Sendable, Hashable {
        public var scanned: Int
        public var added: Int
        public var modified: Int
        public var renamed: Int
        public var removed: Int
        public var unchanged: Int
        public var warnings: [String]
    }

    /// Walks the corpus roots and applies every difference.
    ///
    /// This is what catches changes made outside the process — a file deleted in Finder, a
    /// branch switched in Git — which per-file calls cannot see.
    @discardableResult
    public func sync(force: Bool = false) async throws -> SyncSummary {
        try requireWritable()
        guard !configuration.corpusRoots.isEmpty else {
            throw KnowledgeStoreError.invalidConfiguration("sync() requires at least one corpus root")
        }

        let found = try scanner.scan()
        let indexed = try database.read { db in try DocumentRepository.fetchPathIndex(in: db) }

        let plan = try scanner.reconcile(found: found, indexed: indexed) { file in
            ContentHash.of(try String(contentsOf: file.url, encoding: .utf8))
        }

        var summary = SyncSummary(
            scanned: found.count,
            added: 0,
            modified: 0,
            renamed: 0,
            removed: 0,
            unchanged: 0,
            warnings: []
        )

        // A rename is one UPDATE. The document keeps the ID it was first indexed under, so
        // its chunks, embeddings, mentions, and relations are all untouched — and because
        // rename detection matched on content hash, the text is by definition unchanged.
        for rename in plan.renames {
            guard
                let documentID = try database.read({ db in
                    try DocumentRepository.fetch(relativePath: rename.from, in: db)?.id
                })
            else { continue }

            try database.write { db in
                try DocumentRepository.updatePath(
                    of: documentID,
                    to: rename.to.relativePath,
                    modifiedAt: rename.to.modifiedAt,
                    in: db
                )
            }
            summary.renamed += 1
        }

        for path in plan.deletions {
            try database.write { db in
                _ = try ingestor.remove(relativePath: path, in: db)
            }
            summary.removed += 1
        }

        for file in plan.upserts {
            let outcome = try await ingest(url: file.url, force: force)
            if outcome.chunksAdded > 0 && outcome.chunksModified == 0 && outcome.chunksUnchanged == 0 {
                summary.added += 1
            } else if !outcome.isNoOp {
                summary.modified += 1
            } else {
                summary.unchanged += 1
            }
            summary.warnings.append(contentsOf: outcome.warnings)
        }

        return summary
    }

    // MARK: - Background processing

    /// Runs the queues until both are empty or the deadline passes.
    ///
    /// Used by the CLI, which wants indexing to be finished when the command returns, and by
    /// tests. A host app usually calls ``startProcessing()`` instead.
    @discardableResult
    public func processQueues(until deadline: Date? = nil) async throws -> (embedded: Int, extracted: Int) {
        try requireWritable()
        var embedded = 0
        var extracted = 0

        while true {
            if let deadline, Date() >= deadline { break }
            if Task.isCancelled { break }

            let embedPass = try await workers.runEmbeddingPass()
            let extractPass = try await workers.runExtractionPass()
            embedded += embedPass.succeeded
            extracted += extractPass.succeeded

            if !embedPass.didWork && !extractPass.didWork { break }
        }

        return (embedded, extracted)
    }

    /// Starts draining the queues in the background.
    ///
    /// Idle polling backs off to the next eligible job rather than spinning, so a store with
    /// nothing to do costs nothing.
    public func startProcessing() {
        guard configuration.allowsWriting, pumpTask == nil else { return }

        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    let didWork = try await self.runOnePass()
                    if !didWork {
                        let wait = await self.idleInterval()
                        try? await Task.sleep(for: .seconds(wait))
                    }
                } catch {
                    // A pass only throws on a database failure; provider failures are already
                    // recorded on the jobs themselves.
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    public func stopProcessing() {
        pumpTask?.cancel()
        pumpTask = nil
    }

    private func runOnePass() async throws -> Bool {
        let embedPass = try await workers.runEmbeddingPass()
        let extractPass = try await workers.runExtractionPass()
        return embedPass.didWork || extractPass.didWork
    }

    private func idleInterval() -> TimeInterval {
        let next = try? database.read { db -> Date? in
            let embed = try JobRepository.nextEligibleDate(kind: .embed, in: db)
            let extract = try JobRepository.nextEligibleDate(kind: .extract, in: db)
            return [embed, extract].compactMap { $0 }.min()
        }
        guard let next = next ?? nil else { return 5 }
        return max(1, min(next.timeIntervalSinceNow, 60))
    }

    // MARK: - Watching

    /// Starts the filesystem watcher, re-ingesting changes as they happen.
    ///
    /// Returns only once the event stream is actually running, so a change made immediately
    /// afterwards is observed. Starting the stream inside the consuming task instead would
    /// leave a window in which events are silently missed — FSEvents delivers from the moment
    /// the stream starts, not from when it was asked for.
    public func startWatching() async {
        guard configuration.allowsWriting, watcherTask == nil, !configuration.corpusRoots.isEmpty
        else { return }

        let watcher = CorpusWatcher(
            roots: configuration.corpusRoots,
            configuration: configuration.watcher,
            ignorePatterns: configuration.ignorePatterns
        )
        self.watcher = watcher

        let events = await watcher.start()

        watcherTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func stopWatching() async {
        watcherTask?.cancel()
        watcherTask = nil
        await watcher?.stop()
        watcher = nil
    }

    private func handle(_ event: WatchEvent) async {
        do {
            switch event {
            case .bulkChange:
                _ = try await sync()
            case .changed(let urls):
                for url in urls {
                    if FileManager.default.fileExists(atPath: url.path) {
                        _ = try? await ingest(url: url, force: false)
                    } else {
                        _ = try? await remove(url: url)
                    }
                }
            }
        } catch {
            logger.error("Watcher ingestion failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Retrieval

    /// Ranked chunks with citations. Deterministic given a fixed index, and functional while
    /// Ollama is down — degrading to keyword-only rather than failing.
    public func search(_ query: String, options: SearchOptions = .default) async throws -> SearchResponse {
        try await retrieval.search(query, options: options)
    }

    /// A generated answer with citations resolved before generation begins.
    public func answer(_ question: String, options: AnswerOptions = .default) async throws -> AnswerStream {
        try await answerEngine.answer(question, options: options)
    }

    // MARK: - Graph queries

    public struct EntityDetail: Sendable, Hashable {
        public var entity: Entity
        public var aliases: [String]
        public var mentionCount: Int
    }

    public func lookupEntity(named name: String) throws -> [EntityDetail] {
        try database.read { db in
            let normalized = NameNormalizer.normalizeForMatching(name)
            let entities = try GraphRepository.findByNormalizedName(normalized, in: db)
            return try entities.map { entity in
                EntityDetail(
                    entity: entity,
                    aliases: try GraphRepository.aliases(of: entity.id, in: db),
                    mentionCount: try GraphRepository.mentionCount(of: entity.id, in: db)
                )
            }
        }
    }

    public struct GraphNeighborhood: Sendable, Hashable {
        public var origin: Entity
        public var relations: [Relation]
        public var entities: [Entity]
        public var supportingChunks: [SearchResult]
    }

    public func traverse(from name: String, hops: Int = 1) throws -> [GraphNeighborhood] {
        try database.read { db in
            let origins = try GraphRepository.findByNormalizedName(
                NameNormalizer.normalizeForMatching(name),
                in: db
            )

            return try origins.map { origin in
                let chunkIDs = try GraphArm.expand(
                    seeds: [origin.id],
                    hops: max(1, hops),
                    limit: 20,
                    in: db
                )
                let relations = try GraphRepository.neighbors(of: [origin.id], in: db)
                let endpoints = Set(relations.flatMap { [$0.sourceID, $0.targetID] })
                    .subtracting([origin.id])
                let chunks = try ChunkRepository.fetch(ids: chunkIDs, in: db)
                let documents = try DocumentRepository.fetchAll(in: db)
                let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

                return GraphNeighborhood(
                    origin: origin,
                    relations: relations,
                    entities: try GraphRepository.fetch(ids: Array(endpoints), in: db),
                    supportingChunks: chunks.compactMap { chunk in
                        guard let document = documentsByID[chunk.documentID] else { return nil }
                        return SearchResult(
                            chunkID: chunk.id,
                            documentPath: document.relativePath,
                            documentTitle: document.metadata.title,
                            headingPath: chunk.headingPath,
                            content: chunk.content,
                            score: 0,
                            ranks: [:],
                            matchedEntities: [origin.canonicalName]
                        )
                    }
                )
            }
        }
    }

    // MARK: - Rebuild and maintenance

    /// Drops everything derived and re-reads the corpus.
    ///
    /// The database is disposable; this is the escape hatch whenever automatic migration is
    /// undesirable or the database is suspect.
    @discardableResult
    public func rebuild() async throws -> SyncSummary {
        try requireWritable()
        try database.write { db in
            // Order matters: chunks first, so their vectors are cleared through the
            // repository rather than left behind in the virtual tables.
            try ChunkRepository.delete(ids: try ChunkRepository.allIDs(in: db), in: db)
            try db.execute(sql: "DELETE FROM documents")
            try GraphRepository.collectOrphanedEntities(in: db)
            try db.execute(sql: "DELETE FROM jobs")
        }
        return try await sync(force: true)
    }

    /// Reclaims space and optimizes the FTS index.
    public func compact(discardingFailedJobs: Bool = false) async throws {
        try requireWritable()
        if discardingFailedJobs {
            _ = try database.write { db in try JobRepository.deleteFailed(in: db) }
        }
        try database.compact()
    }

    @discardableResult
    public func retryFailedJobs(kind: JobKind? = nil) throws -> Int {
        try requireWritable()
        return try database.write { db in try JobRepository.retryFailed(kind: kind, in: db) }
    }

    // MARK: - Diagnostics

    public struct Diagnostics: Sendable, Hashable {
        public var documents: Int
        public var chunks: Int
        public var entities: Int
        public var relations: Int
        public var coverage: ChunkRepository.Coverage
        public var embedQueue: JobRepository.QueueDepth
        public var extractQueue: JobRepository.QueueDepth
        public var failures: [Job]
        public var versions: [String: String]
        public var vectorExtensionVersion: String
        public var isWritable: Bool

        /// True when everything queued has been processed.
        public var isFullyIndexed: Bool {
            embedQueue.isEmpty && extractQueue.isEmpty
        }
    }

    public func diagnostics() throws -> Diagnostics {
        // Resolved before the read block: GRDB connections are not reentrant, and this opens
        // a read of its own.
        let vectorVersion = (try? database.vectorExtensionVersion()) ?? "unknown"

        return try database.read { db in
            Diagnostics(
                documents: try DocumentRepository.count(in: db),
                chunks: try ChunkRepository.coverage(in: db).total,
                entities: try GraphRepository.entityCount(in: db),
                relations: try GraphRepository.relationCount(in: db),
                coverage: try ChunkRepository.coverage(in: db),
                embedQueue: try JobRepository.depth(kind: .embed, in: db),
                extractQueue: try JobRepository.depth(kind: .extract, in: db),
                failures: try JobRepository.failedJobs(limit: 20, in: db),
                versions: try VersionMetadata.readAll(in: db),
                vectorExtensionVersion: vectorVersion,
                isWritable: configuration.allowsWriting
            )
        }
    }

    /// Checks that Ollama is reachable and the models this configuration needs are pulled.
    ///
    /// The extraction model is only *required* when the graph is being built. With
    /// `graphExtraction` off it is still used by ``answer(_:options:)``, but that is a
    /// call-time concern — reporting it missing here would nag a setup that never generates
    /// anything locally, which is the whole point of turning the graph off.
    public func checkProviders() async -> ProviderHealth {
        let client = OllamaClient(endpoint: configuration.ollamaEndpoint)
        var required = [configuration.embedding.model]
        if configuration.graphExtraction {
            required.append(configuration.extraction.model)
        }
        return await client.health(requiredModels: required)
    }

    // MARK: - Helpers

    private func requireWritable() throws {
        guard configuration.allowsWriting else {
            throw KnowledgeStoreError.databaseInUse(holder: "another process (this store is read-only)")
        }
    }
}
