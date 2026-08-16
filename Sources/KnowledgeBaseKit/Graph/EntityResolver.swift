import Foundation
import GRDB

/// Maps an extracted name onto a canonical entity.
///
/// Three stages, cheapest first:
/// 1. **Deterministic** — normalize and match exactly against canonical names and aliases.
/// 2. **Embedding similarity** — compare name vectors, accept above `resolutionThreshold`.
/// 3. **LLM adjudication** — only for names that are still ambiguous.
///
/// Most resolutions never reach a model, which keeps ingestion cheap and keeps re-runs
/// largely reproducible. The model is a tiebreaker, not the mechanism.
public struct EntityResolver: Sendable {
    private let configuration: ExtractionConfiguration
    private let embedding: any EmbeddingProvider
    private let extraction: any ExtractionProvider

    public init(
        configuration: ExtractionConfiguration,
        embedding: any EmbeddingProvider,
        extraction: any ExtractionProvider
    ) {
        self.configuration = configuration
        self.embedding = embedding
        self.extraction = extraction
    }

    public struct Resolution: Sendable {
        public var entity: Entity
        /// True when this resolution created a row that did not exist before.
        public var isNew: Bool
        /// The surface form that resolved here, recorded as an alias when it differs from
        /// the canonical name.
        public var surfaceForm: String
    }

    /// Resolves one extracted entity.
    ///
    /// The database is read inside `readDatabase` and written by the caller, so that a single
    /// ingest transaction is not held open across an `await` on the model.
    public func resolve(
        _ extracted: ExtractedEntity,
        candidates: [EntityCandidate],
        exactMatches: [Entity]
    ) async throws -> Resolution {
        // Stage 1: an exact normalized match of the same type is decisive.
        if let match = exactMatches.first(where: { $0.type == extracted.type }) {
            return Resolution(entity: match, isNew: false, surfaceForm: extracted.name)
        }

        // A name that matches an entity of a *different* type is not the same thing —
        // a "Person" called Bridge and a "Component" called Bridge are two entities.
        let typed = candidates.filter { $0.type == extracted.type }

        // Stage 2: close enough in name-embedding space to accept without asking.
        if let confident = typed.first(where: { $0.similarity >= configuration.resolutionThreshold }) {
            return Resolution(
                entity: Entity(id: confident.id, type: confident.type, canonicalName: confident.canonicalName),
                isNew: false,
                surfaceForm: extracted.name
            )
        }

        // Stage 3: ambiguous — near enough to be suspicious, not near enough to accept.
        let ambiguous = typed.filter { $0.similarity >= configuration.adjudicationFloor }
        if !ambiguous.isEmpty {
            let decision = try await extraction.adjudicate(
                name: extracted.name,
                type: extracted.type,
                candidates: ambiguous
            )
            if let decision, let chosen = ambiguous.first(where: { $0.id == decision }) {
                return Resolution(
                    entity: Entity(id: chosen.id, type: chosen.type, canonicalName: chosen.canonicalName),
                    isNew: false,
                    surfaceForm: extracted.name
                )
            }
        }

        return Resolution(
            entity: Entity(type: extracted.type, canonicalName: extracted.name),
            isNew: true,
            surfaceForm: extracted.name
        )
    }

    /// Gathers the stored entities that could plausibly be `name`, for the stages above.
    public func candidates(
        for extracted: ExtractedEntity,
        nameEmbedding: [Float]?,
        in db: Database,
        limit: Int = 10
    ) throws -> (exact: [Entity], similar: [EntityCandidate]) {
        let normalized = NameNormalizer.normalizeForMatching(extracted.name)
        let exact = try GraphRepository.findByNormalizedName(normalized, in: db)

        guard exact.isEmpty, let nameEmbedding else { return (exact, []) }

        let neighbors = try VectorIndex.nearestEntities(in: db, to: nameEmbedding, limit: limit)
        let entities = try GraphRepository.fetch(ids: neighbors.map(\.entityID), in: db)
        let byID = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        let similar = neighbors.compactMap { neighbor -> EntityCandidate? in
            guard let entity = byID[neighbor.entityID] else { return nil }
            return EntityCandidate(
                id: entity.id,
                canonicalName: entity.canonicalName,
                type: entity.type,
                similarity: neighbor.similarity
            )
        }

        return (exact, similar)
    }

    /// The text embedded for a name.
    ///
    /// The type is included so that similarity is computed over "Component: Auth Service"
    /// rather than a bare name, keeping same-named entities of different types apart.
    public static func nameEmbeddingInput(name: String, type: String) -> String {
        "\(type): \(name)"
    }

    /// Persists a resolution: the entity, an alias when the surface form differs, and the
    /// name embedding that lets the next resolution find it by similarity.
    public func persist(
        _ resolution: Resolution,
        nameEmbedding: [Float]?,
        in db: Database
    ) throws {
        try GraphRepository.upsert(resolution.entity, in: db)

        if NameNormalizer.normalizeForMatching(resolution.surfaceForm)
            != NameNormalizer.normalizeForMatching(resolution.entity.canonicalName)
        {
            try GraphRepository.upsert(
                Alias(entityID: resolution.entity.id, name: resolution.surfaceForm),
                in: db
            )
        }

        if resolution.isNew, let nameEmbedding {
            try VectorIndex.upsertEntityEmbedding(
                in: db,
                entityID: resolution.entity.id,
                embedding: nameEmbedding
            )
        }
    }
}
