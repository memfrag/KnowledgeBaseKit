import Foundation
import Testing

@testable import KnowledgeBaseKit

@Suite("Entity resolution")
struct EntityResolutionTests {

    private func makeResolver(
        extraction: FixtureExtractionProvider,
        threshold: Double = 0.92,
        floor: Double = 0.75
    ) -> EntityResolver {
        EntityResolver(
            configuration: ExtractionConfiguration(
                model: "test",
                resolutionThreshold: threshold,
                adjudicationFloor: floor
            ),
            embedding: DeterministicEmbeddingProvider(),
            extraction: extraction
        )
    }

    @Test("An exact normalized match resolves without consulting the model")
    func deterministicStage() async throws {
        let extraction = FixtureExtractionProvider()
        let resolver = makeResolver(extraction: extraction)
        let existing = Entity(type: "Component", canonicalName: "Auth Service")

        // Different spelling, same normalized form.
        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "auth-service", type: "Component"),
            candidates: [],
            exactMatches: [existing]
        )

        #expect(resolution.entity.id == existing.id)
        #expect(!resolution.isNew)
        // The surface form differs from the canonical name, so it becomes an alias.
        #expect(resolution.surfaceForm == "auth-service")
    }

    @Test("A same-named entity of a different type is a different entity")
    func typeSeparatesEntities() async throws {
        let extraction = FixtureExtractionProvider()
        let resolver = makeResolver(extraction: extraction)
        let person = Entity(type: "Person", canonicalName: "Bridge")

        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "Bridge", type: "Component"),
            candidates: [
                EntityCandidate(id: person.id, canonicalName: "Bridge", type: "Person", similarity: 1.0)
            ],
            exactMatches: [person]
        )

        #expect(resolution.isNew)
        #expect(resolution.entity.id != person.id)
        #expect(resolution.entity.type == "Component")
    }

    @Test("High similarity resolves without adjudication")
    func similarityStage() async throws {
        let extraction = FixtureExtractionProvider()
        let resolver = makeResolver(extraction: extraction)
        let existing = Entity(type: "Component", canonicalName: "Authentication Service")

        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "Auth Svc", type: "Component"),
            candidates: [
                EntityCandidate(
                    id: existing.id,
                    canonicalName: existing.canonicalName,
                    type: "Component",
                    similarity: 0.95
                )
            ],
            exactMatches: []
        )

        #expect(resolution.entity.id == existing.id)
        #expect(!resolution.isNew)
    }

    @Test("An ambiguous candidate is referred to the model, which can accept")
    func adjudicationAccepts() async throws {
        let extraction = FixtureExtractionProvider()
        extraction.resolve("Auth Svc", to: "Authentication Service")
        let resolver = makeResolver(extraction: extraction)
        let existing = Entity(type: "Component", canonicalName: "Authentication Service")

        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "Auth Svc", type: "Component"),
            candidates: [
                EntityCandidate(
                    id: existing.id,
                    canonicalName: existing.canonicalName,
                    type: "Component",
                    // Between the floor and the threshold: suspicious, not decisive.
                    similarity: 0.80
                )
            ],
            exactMatches: []
        )

        #expect(resolution.entity.id == existing.id)
        #expect(!resolution.isNew)
    }

    @Test("An ambiguous candidate the model rejects becomes a new entity")
    func adjudicationRejects() async throws {
        // No fixture registered, so the double answers "none of these".
        let extraction = FixtureExtractionProvider()
        let resolver = makeResolver(extraction: extraction)
        let existing = Entity(type: "Component", canonicalName: "Authentication Service")

        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "Authorization Service", type: "Component"),
            candidates: [
                EntityCandidate(
                    id: existing.id,
                    canonicalName: existing.canonicalName,
                    type: "Component",
                    similarity: 0.80
                )
            ],
            exactMatches: []
        )

        #expect(resolution.isNew)
        #expect(resolution.entity.id != existing.id)
    }

    @Test("A candidate below the floor never reaches the model")
    func belowFloorIsNew() async throws {
        let extraction = FixtureExtractionProvider()
        // Programmed to accept — but it must not be asked in the first place.
        extraction.resolve("Deployment", to: "Authentication Service")
        let resolver = makeResolver(extraction: extraction)
        let existing = Entity(type: "Component", canonicalName: "Authentication Service")

        let resolution = try await resolver.resolve(
            ExtractedEntity(name: "Deployment", type: "Component"),
            candidates: [
                EntityCandidate(
                    id: existing.id,
                    canonicalName: existing.canonicalName,
                    type: "Component",
                    similarity: 0.40
                )
            ],
            exactMatches: []
        )

        #expect(resolution.isNew)
    }

    @Test("Aliases from one document resolve names in another")
    func aliasesCrossDocuments() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        // Front matter aliases are seeded at ingest, with no model involved.
        try vault.write(
            "auth.md",
            """
            ---
            title: Authentication Service
            aliases: [AuthN, Auth Svc]
            ---

            # Authentication Service

            Issues and validates tokens.
            """
        )
        try await vault.store.sync()
        try await vault.store.processQueues()

        let byAlias = try await vault.store.lookupEntity(named: "AuthN")
        #expect(byAlias.count == 1)
        #expect(byAlias.first?.entity.canonicalName == "Authentication Service")
        #expect(byAlias.first?.aliases.contains("Auth Svc") == true)
    }
}

@Suite("Extraction sanitizing")
struct ExtractionSanitizingTests {
    private let vocabulary = GraphVocabulary.default

    @Test("Out-of-vocabulary types are dropped")
    func vocabularyEnforced() {
        let result = OllamaExtractionProvider.sanitize(
            ExtractionResult(
                entities: [
                    ExtractedEntity(name: "Auth", type: "Component"),
                    ExtractedEntity(name: "Weird", type: "Sandwich"),
                ],
                relations: []
            ),
            vocabulary: vocabulary
        )

        #expect(result.entities.map(\.name) == ["Auth"])
    }

    @Test("Type casing is normalized rather than rejected")
    func casingNormalized() {
        let result = OllamaExtractionProvider.sanitize(
            ExtractionResult(entities: [ExtractedEntity(name: "Auth", type: "component")]),
            vocabulary: vocabulary
        )
        #expect(result.entities.first?.type == "Component")
    }

    @Test("A relation pointing at an undeclared entity is dropped")
    func danglingRelationsDropped() {
        let result = OllamaExtractionProvider.sanitize(
            ExtractionResult(
                entities: [ExtractedEntity(name: "Auth", type: "Component")],
                relations: [
                    ExtractedRelation(source: "Auth", type: "uses", target: "Ghost", confidence: 0.9)
                ]
            ),
            vocabulary: vocabulary
        )

        // Keeping it would create a dangling half of the graph.
        #expect(result.relations.isEmpty)
    }

    @Test("Self-relations and duplicate entities are dropped")
    func noiseRemoved() {
        let result = OllamaExtractionProvider.sanitize(
            ExtractionResult(
                entities: [
                    ExtractedEntity(name: "Auth Service", type: "Component"),
                    ExtractedEntity(name: "auth-service", type: "Component"),
                ],
                relations: [
                    ExtractedRelation(
                        source: "Auth Service",
                        type: "uses",
                        target: "auth-service",
                        confidence: 0.9
                    )
                ]
            ),
            vocabulary: vocabulary
        )

        #expect(result.entities.count == 1)
        // The two names normalize to the same entity, so the relation is a self-loop.
        #expect(result.relations.isEmpty)
    }

    @Test("Confidence is clamped to 0...1")
    func confidenceClamped() {
        let result = OllamaExtractionProvider.sanitize(
            ExtractionResult(
                entities: [
                    ExtractedEntity(name: "A", type: "Component"),
                    ExtractedEntity(name: "B", type: "Component"),
                ],
                relations: [
                    ExtractedRelation(source: "A", type: "uses", target: "B", confidence: 7.5)
                ]
            ),
            vocabulary: vocabulary
        )
        #expect(result.relations.first?.confidence == 1.0)
    }
}

@Suite("Version drift, end to end")
struct MigrationIntegrationTests {

    @Test("Changing the embedding model re-queues embedding but not extraction")
    func embeddingModelChange() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", "# Auth\n\n## Tokens\n\nTokens are issued here.")
        try await vault.store.sync()
        try await vault.store.processQueues()

        let before = try await vault.store.diagnostics()
        #expect(before.isFullyIndexed)
        let chunkCount = before.coverage.total

        await vault.store.close()

        // Reopen with a different embedding model, same dimensions.
        var configuration = KnowledgeStoreConfiguration(corpusRoots: [vault.root])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configuration.embedding = EmbeddingConfiguration(model: "different-model", dimensions: 8)

        let reopened = try KnowledgeStore(
            databaseURL: vault.databaseURL,
            configuration: configuration,
            embedding: DeterministicEmbeddingProvider(modelIdentifier: "different-model"),
            extraction: FixtureExtractionProvider(),
            generation: FixtureGenerationProvider()
        )

        let after = try await reopened.diagnostics()
        // Everything needs re-embedding; nothing needs re-extraction.
        #expect(after.embedQueue.pending == chunkCount)
        #expect(after.extractQueue.pending == 0)
        #expect(after.coverage.embedded == 0)
        #expect(after.coverage.extracted == chunkCount)

        await reopened.close()
    }

    @Test("Changing the embedding dimensions rebuilds the vector table")
    func dimensionChange() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", "# Auth\n\n## Tokens\n\nTokens are issued here.")
        try await vault.store.sync()
        try await vault.store.processQueues()
        await vault.store.close()

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [vault.root])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configuration.embedding = EmbeddingConfiguration(model: "wide-model", dimensions: 16)

        let reopened = try KnowledgeStore(
            databaseURL: vault.databaseURL,
            configuration: configuration,
            embedding: DeterministicEmbeddingProvider(modelIdentifier: "wide-model", dimensions: 16),
            extraction: FixtureExtractionProvider(),
            generation: FixtureGenerationProvider()
        )

        // Vectors of the old width are meaningless at the new one, so they are discarded and
        // re-computed rather than migrated.
        let after = try await reopened.diagnostics()
        #expect(after.coverage.embedded == 0)

        try await reopened.processQueues()
        let drained = try await reopened.diagnostics()
        #expect(drained.coverage.embedded == drained.coverage.total)

        // The rebuilt index is queryable at the new width.
        let response = try await reopened.search("tokens")
        #expect(response.participatingArms.contains(.vector))

        await reopened.close()
    }

    @Test("A migration handler can veto and the store refuses to open")
    func migrationVeto() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("auth.md", "# Auth\n\nBody.")
        try await vault.store.sync()
        await vault.store.close()

        var configuration = KnowledgeStoreConfiguration(corpusRoots: [vault.root])
        configuration.chunking = ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512)
        configuration.embedding = EmbeddingConfiguration(model: "other", dimensions: 8)

        #expect(throws: KnowledgeStoreError.self) {
            _ = try KnowledgeStore(
                databaseURL: vault.databaseURL,
                configuration: configuration,
                embedding: DeterministicEmbeddingProvider(modelIdentifier: "other"),
                extraction: FixtureExtractionProvider(),
                generation: FixtureGenerationProvider(),
                migrationHandler: { _ in false }
            )
        }
    }
}

@Suite("Ignore rules")
struct IgnoreRuleTests {
    @Test("Built-in rules cover dotfiles and non-Markdown")
    func builtIns() {
        let rules = IgnoreRules(patterns: [])
        #expect(rules.shouldIgnoreDirectory(named: ".git"))
        #expect(rules.shouldIgnoreDirectory(named: ".obsidian"))
        #expect(!rules.shouldIgnoreDirectory(named: "notes"))
        #expect(rules.shouldIgnoreFile(named: "notes.txt", relativePath: "notes.txt"))
        #expect(rules.shouldIgnoreFile(named: ".hidden.md", relativePath: ".hidden.md"))
        #expect(!rules.shouldIgnoreFile(named: "notes.md", relativePath: "notes.md"))
    }

    @Test("Extension matching is case-insensitive")
    func caseInsensitiveExtension() {
        let rules = IgnoreRules(patterns: [])
        #expect(!rules.shouldIgnoreFile(named: "README.MD", relativePath: "README.MD"))
    }

    @Test("Glob and directory-name patterns are honored")
    func globPatterns() {
        let rules = IgnoreRules(patterns: ["*.draft.md", "Archive", "templates/"])
        #expect(rules.shouldIgnoreFile(named: "plan.draft.md", relativePath: "plan.draft.md"))
        #expect(!rules.shouldIgnoreFile(named: "plan.md", relativePath: "plan.md"))
        #expect(rules.shouldIgnoreDirectory(named: "Archive"))
        #expect(rules.shouldIgnoreDirectory(named: "templates"))
        // A pattern matches a path component anywhere, as gitignore does.
        #expect(rules.shouldIgnoreFile(named: "old.md", relativePath: "Archive/old.md"))
    }
}

@Suite("Rename detection")
struct RenameDetectionTests {
    private let scanner = CorpusScanner(roots: [URL(fileURLWithPath: "/vault")], ignorePatterns: [])

    private func file(_ path: String) -> CorpusFile {
        CorpusFile(
            url: URL(fileURLWithPath: "/vault/\(path)"),
            relativePath: path,
            modifiedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("A vanished path and a new path with identical content pair up")
    func detectsRename() throws {
        let plan = try scanner.reconcile(
            found: [file("archive/auth.md")],
            indexed: [(DocumentID(relativePath: "auth.md"), "auth.md", "hash-a")],
            hashOfFile: { _ in "hash-a" }
        )

        #expect(plan.renames.count == 1)
        #expect(plan.renames[0].from == "auth.md")
        #expect(plan.renames[0].to.relativePath == "archive/auth.md")
        #expect(plan.deletions.isEmpty)
        #expect(plan.upserts.isEmpty)
    }

    @Test("A rename with an edit is a delete plus an insert")
    func renameWithEdit() throws {
        let plan = try scanner.reconcile(
            found: [file("archive/auth.md")],
            indexed: [(DocumentID(relativePath: "auth.md"), "auth.md", "hash-a")],
            hashOfFile: { _ in "hash-b" }
        )

        #expect(plan.renames.isEmpty)
        #expect(plan.deletions == ["auth.md"])
        #expect(plan.upserts.map(\.relativePath) == ["archive/auth.md"])
    }

    @Test("A plain deletion is not mistaken for a rename")
    func plainDeletion() throws {
        let plan = try scanner.reconcile(
            found: [],
            indexed: [(DocumentID(relativePath: "auth.md"), "auth.md", "hash-a")],
            hashOfFile: { _ in "unused" }
        )

        #expect(plan.deletions == ["auth.md"])
        #expect(plan.renames.isEmpty)
    }

    @Test("Files are not hashed at all when nothing vanished")
    func noHashingOnFirstIndex() throws {
        // Hashing every new file on a first index would read the whole corpus twice.
        var hashCalls = 0
        _ = try scanner.reconcile(
            found: [file("a.md"), file("b.md")],
            indexed: [],
            hashOfFile: { _ in
                hashCalls += 1
                return "hash"
            }
        )
        #expect(hashCalls == 0)
    }

    @Test("Two identical new files pair one rename and ingest the other")
    func duplicateContent() throws {
        let plan = try scanner.reconcile(
            found: [file("x.md"), file("y.md")],
            indexed: [(DocumentID(relativePath: "old.md"), "old.md", "same")],
            hashOfFile: { _ in "same" }
        )

        #expect(plan.renames.count == 1)
        #expect(plan.upserts.count == 1)
        #expect(plan.deletions.isEmpty)
    }
}

@Suite("Path mapping")
struct PathMapperTests {
    @Test("A file below the root maps to a relative path")
    func basicMapping() {
        let mapper = PathMapper(roots: [URL(fileURLWithPath: "/vault")])
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/vault/notes/auth.md")) == "notes/auth.md")
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/elsewhere/auth.md")) == nil)
        // The root itself is not a document.
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/vault")) == nil)
    }

    @Test("A /private-prefixed path still matches a root spelled without it")
    func privatePrefixIsCanonicalized() {
        // This is the deleted-file case. FSEvents reports /private/var/..., while the root
        // was standardized to /var/... — Foundation only strips /private for paths that
        // still exist, so a naive prefix compare drops every deletion.
        let mapper = PathMapper(roots: [URL(fileURLWithPath: "/var/folders/abc/T/vault")])
        let deleted = URL(fileURLWithPath: "/private/var/folders/abc/T/vault/gone.md")
        #expect(mapper.relativePath(for: deleted) == "gone.md")
    }

    @Test("A root spelled with /private matches an event without it")
    func reverseDirection() {
        let mapper = PathMapper(roots: [URL(fileURLWithPath: "/private/tmp/vault")])
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/tmp/vault/a.md")) == "a.md")
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/private/tmp/vault/a.md")) == "a.md")
    }

    @Test("Multiple roots are disambiguated by index and round-trip")
    func multipleRoots() {
        let mapper = PathMapper(roots: [
            URL(fileURLWithPath: "/work"),
            URL(fileURLWithPath: "/personal"),
        ])
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/work/notes.md")) == "0/notes.md")
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/personal/notes.md")) == "1/notes.md")
        #expect(mapper.url(forRelativePath: "1/notes.md")?.path == "/personal/notes.md")
    }

    @Test("Nested roots resolve to the most specific one")
    func nestedRoots() {
        let mapper = PathMapper(roots: [
            URL(fileURLWithPath: "/vault"),
            URL(fileURLWithPath: "/vault/inner"),
        ])
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/vault/inner/a.md")) == "1/a.md")
        #expect(mapper.relativePath(for: URL(fileURLWithPath: "/vault/outer/a.md")) == "0/outer/a.md")
    }
}
