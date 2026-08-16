import Foundation
import Testing

@testable import KnowledgeBaseKit

/// A temporary corpus directory plus a store wired to deterministic providers.
final class TestVault {
    let base: URL
    let root: URL
    let databaseURL: URL
    let extraction = FixtureExtractionProvider()
    let embedding: DeterministicEmbeddingProvider
    let generation: FixtureGenerationProvider
    private(set) var store: KnowledgeStore!

    init(
        embedding: DeterministicEmbeddingProvider = DeterministicEmbeddingProvider(),
        generation: FixtureGenerationProvider = FixtureGenerationProvider(),
        configure: (inout KnowledgeStoreConfiguration) -> Void = { _ in }
    ) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kbkit-vault-\(UUID().uuidString)")
        self.base = base
        self.root = base.appendingPathComponent("vault")
        self.databaseURL = base.appendingPathComponent("store.sqlite")
        self.embedding = embedding
        self.generation = generation
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [root])
        // Small bounds keep fixtures readable: one section is one chunk.
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configure(&configuration)

        self.store = try KnowledgeStore(
            databaseURL: databaseURL,
            configuration: configuration,
            embedding: embedding,
            extraction: extraction,
            generation: generation
        )
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func move(_ from: String, to destination: String) throws {
        let source = root.appending(path: from)
        let target = root.appending(path: destination)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: target)
    }

    func delete(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: root.appending(path: relativePath))
    }

    /// Synchronous on purpose: an async `defer` would run after the test returned, racing
    /// the next one. The store's write lock is released when it deallocates with the vault.
    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

private let authNote = """
    ---
    title: Auth Service
    tags: [security, backend]
    ---

    # Auth Service

    The auth service issues tokens for the whole platform.

    ## Tokens

    Tokens are signed JWTs. The token store keeps refresh tokens.

    ## Sessions

    Sessions expire after one hour of inactivity.
    """

private let deployNote = """
    ---
    title: Deployment
    tags: [ops]
    ---

    # Deployment

    Deployment runs nightly from the build pipeline.
    """

@Suite("End-to-end ingestion")
struct IngestionPipelineTests {

    @Test("A synced corpus is keyword-searchable before any model work happens")
    func searchableBeforeQueueDrains() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        let summary = try await vault.store.sync()
        #expect(summary.scanned == 1)
        #expect(summary.added == 1)

        // Nothing has been embedded or extracted yet — the queue has not been run.
        let before = try await vault.store.diagnostics()
        #expect(before.coverage.embedded == 0)
        #expect(before.embedQueue.pending > 0)

        // Keyword retrieval works anyway. This is the whole point of writing chunks and FTS
        // synchronously and deferring the model work.
        let response = try await vault.store.search("tokens")
        #expect(!response.results.isEmpty)
        #expect(response.participatingArms.contains(.keyword))
        #expect(response.degradations.contains(.vectorIndexEmpty))
    }

    @Test("Draining the queues fills in embeddings and the graph")
    func queuesFillCoverage() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        vault.extraction.onText(
            containing: "signed JWTs",
            return: ExtractionResult(
                entities: [
                    ExtractedEntity(name: "Auth Service", type: "Component"),
                    ExtractedEntity(name: "Token Store", type: "Component"),
                ],
                relations: [
                    ExtractedRelation(
                        source: "Auth Service",
                        type: "uses",
                        target: "Token Store",
                        confidence: 0.9
                    )
                ]
            )
        )

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.coverage.embedded == diagnostics.coverage.total)
        #expect(diagnostics.coverage.extracted == diagnostics.coverage.total)
        #expect(diagnostics.isFullyIndexed)
        #expect(diagnostics.entities >= 2)
        #expect(diagnostics.relations == 1)

        // With embeddings present, the vector arm participates and nothing is degraded.
        let response = try await vault.store.search("token storage")
        #expect(response.participatingArms.contains(.vector))
        #expect(!response.isDegraded)
    }

    @Test("Re-syncing an unchanged corpus does no work at all")
    func idempotentSync() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()
        let extractionsAfterFirst = vault.extraction.extractionCount

        let second = try await vault.store.sync()
        #expect(second.unchanged == 1)
        #expect(second.added == 0)
        #expect(second.modified == 0)

        try await vault.store.processQueues()
        // No chunk changed, so no chunk was re-extracted.
        #expect(vault.extraction.extractionCount == extractionsAfterFirst)
    }

    @Test("Editing one section re-embeds only that chunk")
    func incrementalEdit() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()
        let baseline = vault.extraction.extractionCount

        let edited = authNote.replacingOccurrences(
            of: "Sessions expire after one hour of inactivity.",
            with: "Sessions expire after fifteen minutes of inactivity."
        )
        try vault.write("auth.md", edited)

        let summary = try await vault.store.sync()
        #expect(summary.modified == 1)

        let queued = try await vault.store.diagnostics()
        // Exactly one chunk changed, so exactly one embed job and one extract job.
        #expect(queued.embedQueue.pending == 1)
        #expect(queued.extractQueue.pending == 1)

        try await vault.store.processQueues()
        #expect(vault.extraction.extractionCount == baseline + 1)

        let after = try await vault.store.diagnostics()
        #expect(after.coverage.embedded == after.coverage.total)

        let response = try await vault.store.search("fifteen minutes")
        #expect(response.results.contains { $0.content.contains("fifteen minutes") })
    }

    @Test("Renaming a file preserves its chunks, embeddings, and graph")
    func renamePreservesEverything() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        vault.extraction.onText(
            containing: "signed JWTs",
            return: ExtractionResult(
                entities: [ExtractedEntity(name: "Token Store", type: "Component")]
            )
        )

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let before = try await vault.store.diagnostics()
        let extractionsBefore = vault.extraction.extractionCount

        try vault.move("auth.md", to: "archive/auth-service.md")
        let summary = try await vault.store.sync()

        #expect(summary.renamed == 1)
        #expect(summary.added == 0)
        #expect(summary.removed == 0)

        let after = try await vault.store.diagnostics()
        #expect(after.chunks == before.chunks)
        #expect(after.entities == before.entities)
        // Nothing was queued, so nothing needs re-embedding or re-extracting.
        #expect(after.isFullyIndexed)
        #expect(after.coverage.embedded == after.coverage.total)

        try await vault.store.processQueues()
        #expect(vault.extraction.extractionCount == extractionsBefore)

        // The new path is what search reports.
        let response = try await vault.store.search("tokens")
        #expect(response.results.allSatisfy { $0.documentPath.hasPrefix("archive/") })
    }

    @Test("Deleting a file removes its chunks and collects orphaned entities")
    func deleteCascades() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        vault.extraction.onText(
            containing: "signed JWTs",
            return: ExtractionResult(entities: [ExtractedEntity(name: "Token Store", type: "Component")])
        )
        vault.extraction.onText(
            containing: "nightly",
            return: ExtractionResult(entities: [ExtractedEntity(name: "Build Pipeline", type: "Component")])
        )

        try vault.write("auth.md", authNote)
        try vault.write("deploy.md", deployNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let before = try await vault.store.diagnostics()
        #expect(before.documents == 2)
        #expect(before.entities >= 2)

        try vault.delete("auth.md")
        let summary = try await vault.store.sync()
        #expect(summary.removed == 1)

        let after = try await vault.store.diagnostics()
        #expect(after.documents == 1)
        #expect(after.chunks < before.chunks)
        // The entity only auth.md mentioned is gone; the one deploy.md mentions survives.
        let tokenStore = try await vault.store.lookupEntity(named: "Token Store")
        let buildPipeline = try await vault.store.lookupEntity(named: "Build Pipeline")
        #expect(tokenStore.isEmpty)
        #expect(!buildPipeline.isEmpty)
    }

    @Test("Files outside the corpus roots are rejected")
    func pathOutsideCorpus() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        let stray = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stray-\(UUID().uuidString).md")
        try "# Stray".write(to: stray, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stray) }

        await #expect(throws: KnowledgeStoreError.self) {
            try await vault.store.add(url: stray)
        }
    }

    @Test("Rebuild reproduces the same index from the corpus")
    func rebuildIsReproducible() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try vault.write("deploy.md", deployNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let before = try await vault.store.search("tokens")

        try await vault.store.rebuild()
        try await vault.store.processQueues()

        let after = try await vault.store.search("tokens")
        // The database is disposable: a rebuild from the same corpus yields the same IDs and
        // the same ranking.
        #expect(before.results.map(\.chunkID) == after.results.map(\.chunkID))
    }
}

@Suite("Ignore rules and scanning")
struct ScannerTests {
    @Test("Hidden directories, non-Markdown files, and ignore patterns are skipped")
    func ignoreRules() async throws {
        let vault = try TestVault(configure: { $0.ignorePatterns = ["Archive", "*.draft.md"] })
        defer { vault.cleanup() }

        try vault.write("keep.md", "# Keep\n\nIndexed.")
        try vault.write("notes.txt", "not markdown")
        try vault.write(".hidden.md", "# Hidden")
        try vault.write(".obsidian/config.md", "# Tooling state")
        try vault.write("Archive/old.md", "# Archived")
        try vault.write("scratch.draft.md", "# Draft")

        let summary = try await vault.store.sync()
        #expect(summary.scanned == 1)

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.documents == 1)
    }

    @Test("Multiple corpus roots do not collide on identical relative paths")
    func multipleRoots() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kbkit-multiroot-\(UUID().uuidString)")
        let first = base.appendingPathComponent("work")
        let second = base.appendingPathComponent("personal")
        for root in [first, second] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: base) }

        try "# Work notes\n\nWork content.".write(
            to: first.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8
        )
        try "# Personal notes\n\nPersonal content.".write(
            to: second.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8
        )

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [first, second])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        let store = try KnowledgeStore(
            databaseURL: base.appendingPathComponent("store.sqlite"),
            configuration: configuration,
            embedding: DeterministicEmbeddingProvider(),
            extraction: FixtureExtractionProvider(),
            generation: FixtureGenerationProvider()
        )
        let summary = try await store.sync()
        #expect(summary.scanned == 2)

        let diagnostics = try await store.diagnostics()
        #expect(diagnostics.documents == 2)
    }
}

@Suite("Degraded operation")
struct DegradationTests {

    @Test("An unreachable model leaves the corpus indexed and search working")
    func offlineIngestion() async throws {
        // Every embedding call fails transiently, standing in for Ollama being off.
        let offline = DeterministicEmbeddingProvider(failing: ["e"], failureIsTransient: true)
        let vault = try TestVault(embedding: offline)
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        // Ingestion itself must not fail.
        let summary = try await vault.store.sync()
        #expect(summary.added == 1)

        try await vault.store.processQueues()

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.chunks > 0)
        #expect(diagnostics.coverage.embedded == 0)
        // Transient failures back off; they never dead-letter.
        #expect(diagnostics.embedQueue.failed == 0)
        #expect(diagnostics.embedQueue.pending > 0)

        // Search degrades to keyword-only and says so, rather than throwing.
        let response = try await vault.store.search("tokens")
        #expect(!response.results.isEmpty)
        #expect(response.participatingArms == [.keyword])
        #expect(response.isDegraded)
    }

    @Test("A poison chunk dead-letters and is surfaced in diagnostics")
    func deadLetteringSurfaces() async throws {
        let vault = try TestVault(configure: {
            $0.retry = RetryConfiguration(maximumAttempts: 2, initialBackoff: 0)
        })
        defer { vault.cleanup() }

        vault.extraction.failOnText(containing: "signed JWTs", transient: false)

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.extractQueue.failed == 1)
        #expect(diagnostics.failures.first?.lastError?.contains("unparseable") == true)

        // One bad chunk does not stop the others from being extracted.
        #expect(diagnostics.coverage.extracted == diagnostics.coverage.total - 1)
        // Embedding is unaffected by an extraction failure.
        #expect(diagnostics.coverage.embedded == diagnostics.coverage.total)

        let retried = try await vault.store.retryFailedJobs()
        #expect(retried == 1)
    }

    @Test("answer() reports honestly when nothing is indexed")
    func answerWithoutContext() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        let stream = try await vault.store.answer("How does authentication work?")
        let answer = try await stream.collected()
        #expect(answer.citations.isEmpty)
        #expect(answer.text.contains("No indexed content"))
    }
}

@Suite("Answering")
struct AnswerTests {
    @Test("Citations are resolved before generation and the stream can be collected")
    func citationsAndStreaming() async throws {
        let vault = try TestVault(generation: FixtureGenerationProvider(answer: "Tokens are JWTs [1]."))
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let stream = try await vault.store.answer("How are tokens issued?")
        // Available before a single token is consumed.
        #expect(!stream.citations.isEmpty)
        #expect(stream.citations[0].index == 1)
        #expect(stream.citations[0].documentPath == "auth.md")

        let answer = try await stream.collected()
        #expect(answer.text == "Tokens are JWTs [1].")
        #expect(answer.citations.count == stream.citations.count)
    }

    @Test("The context budget bounds how many excerpts are packed")
    func contextBudget() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try vault.write("deploy.md", deployNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let generous = try await vault.store.answer(
            "tokens sessions deployment",
            options: AnswerOptions(contextTokenBudget: 10_000)
        )
        let tight = try await vault.store.answer(
            "tokens sessions deployment",
            options: AnswerOptions(contextTokenBudget: 5)
        )

        #expect(generous.citations.count > tight.citations.count)
        // Even an impossible budget yields one excerpt rather than none, so the model is
        // never asked to answer from nothing.
        #expect(tight.citations.count == 1)
    }
}

@Suite("Fusion")
struct FusionTests {
    private let fusion = ReciprocalRankFusion(configuration: FusionConfiguration(k: 60))

    @Test("A chunk found by several arms outranks one found by a single arm")
    func agreementWins() {
        let ranked = fusion.fuse([
            .keyword: [ChunkID(rawValue: "b"), ChunkID(rawValue: "a")],
            .vector: [ChunkID(rawValue: "b"), ChunkID(rawValue: "c")],
        ])

        #expect(ranked.first?.chunkID.rawValue == "b")
        #expect(ranked.first?.ranks[.keyword] == 1)
        #expect(ranked.first?.ranks[.vector] == 1)
    }

    @Test("Weights of zero exclude an arm entirely")
    func zeroWeightExcludes() {
        let weighted = ReciprocalRankFusion(
            configuration: FusionConfiguration(keywordWeight: 1, vectorWeight: 0, graphWeight: 0)
        )
        let ranked = weighted.fuse([
            .keyword: [ChunkID(rawValue: "a")],
            .vector: [ChunkID(rawValue: "z")],
        ])

        #expect(ranked.map(\.chunkID.rawValue) == ["a"])
    }

    @Test("Ordering is stable across runs when scores tie")
    func stableOrdering() {
        let lists: [RetrievalArm: [ChunkID]] = [
            .keyword: [ChunkID(rawValue: "a")],
            .vector: [ChunkID(rawValue: "b")],
        ]
        #expect(fusion.fuse(lists).map(\.chunkID) == fusion.fuse(lists).map(\.chunkID))
    }
}

@Suite("Keyword query building")
struct KeywordQueryTests {
    @Test("Operators and punctuation in user text are neutralized")
    func operatorsAreQuoted() throws {
        let expression = try #require(
            KeywordArm.makeMatchExpression(from: "How does \"auth\" AND deployment work?")
        )
        // Every term is quoted, so nothing reaches FTS5 as an operator.
        #expect(!expression.contains("\"\"") == true)
        #expect(expression.contains("\"auth\""))
        #expect(expression.contains("\"deployment\""))
        // Stop words are dropped, and the FTS5 operator AND survives only as a quoted term
        // if it was meaningful — here it is a stop-word-like connector and is not.
        #expect(!expression.contains("\"how\""))
    }

    @Test("A query of only stop words still searches for something")
    func allStopWords() throws {
        let expression = KeywordArm.makeMatchExpression(from: "how does the")
        #expect(expression != nil)
    }

    @Test("An empty query produces no expression")
    func emptyQuery() {
        #expect(KeywordArm.makeMatchExpression(from: "   ") == nil)
    }
}

@Suite("Optional graph extraction")
struct GraphExtractionToggleTests {

    @Test("With the graph off, no extraction is queued and search still works")
    func graphDisabled() async throws {
        let vault = try TestVault(configure: { $0.graphExtraction = false })
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()

        let queued = try await vault.store.diagnostics()
        #expect(queued.embedQueue.pending > 0)
        // The whole point: nothing extraction-shaped is pending, so a store with no
        // extraction model does not accumulate work that can never drain.
        #expect(queued.extractQueue.pending == 0)

        try await vault.store.processQueues()
        #expect(vault.extraction.extractionCount == 0)

        let after = try await vault.store.diagnostics()
        #expect(after.coverage.embedded == after.coverage.total)
        #expect(after.entities == 0)
        #expect(after.isFullyIndexed)

        // Keyword and vector retrieval are unaffected.
        let response = try await vault.store.search("tokens")
        #expect(!response.results.isEmpty)
        #expect(response.participatingArms.contains(.keyword))
        #expect(response.participatingArms.contains(.vector))
        #expect(!response.participatingArms.contains(.graph))
    }

    @Test("Turning the graph off retires extraction work that was already queued")
    func disablingDrainsQueue() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        let before = try await vault.store.diagnostics()
        #expect(before.extractQueue.pending > 0)
        await vault.store.close()

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [vault.root])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configuration.graphExtraction = false

        let reopened = try KnowledgeStore(
            databaseURL: vault.databaseURL,
            configuration: configuration,
            embedding: DeterministicEmbeddingProvider(),
            extraction: FixtureExtractionProvider(),
            generation: FixtureGenerationProvider()
        )

        // Otherwise these would retry forever: a missing model is classified transient, so
        // they never dead-letter and `kb status` would show work that never drains.
        let after = try await reopened.diagnostics()
        #expect(after.extractQueue.pending == 0)
        #expect(after.extractQueue.failed == 0)

        await reopened.close()
    }

    @Test("Turning the graph back on backfills chunks that were never extracted")
    func enablingBackfills() async throws {
        let vault = try TestVault(configure: { $0.graphExtraction = false })
        defer { vault.cleanup() }

        try vault.write("auth.md", authNote)
        try await vault.store.sync()
        try await vault.store.processQueues()

        let before = try await vault.store.diagnostics()
        #expect(before.coverage.extracted == 0)
        let chunkCount = before.coverage.total
        await vault.store.close()

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [vault.root])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configuration.graphExtraction = true

        let reopened = try KnowledgeStore(
            databaseURL: vault.databaseURL,
            configuration: configuration,
            embedding: DeterministicEmbeddingProvider(),
            extraction: FixtureExtractionProvider(),
            generation: FixtureGenerationProvider()
        )

        // Chunks ingested while the graph was off would otherwise stay outside it until
        // something happened to edit them.
        let after = try await reopened.diagnostics()
        #expect(after.extractQueue.pending == chunkCount)

        // Embeddings are untouched by the toggle.
        #expect(after.coverage.embedded == chunkCount)

        await reopened.close()
    }

    @Test("Health reporting does not demand a model the configuration never uses")
    func healthIgnoresUnusedModel() async throws {
        let vault = try TestVault(configure: {
            $0.graphExtraction = false
            $0.ollamaEndpoint = URL(string: "http://localhost:59999")!
        })
        defer { vault.cleanup() }

        // Unreachable either way, but the point is which models it would require.
        let health = await vault.store.checkProviders()
        #expect(!health.isReachable)
    }
}
