import Foundation
import GRDB
import OSLog

/// Runs the three arms, fuses them, and hydrates the results.
///
/// No model call is made on this path except embedding the query, and a failure there
/// degrades the vector arm rather than failing the search.
public struct RetrievalEngine: Sendable {
    private let database: KnowledgeDatabase
    private let configuration: KnowledgeStoreConfiguration
    private let embedding: any EmbeddingProvider
    private let fusion: ReciprocalRankFusion
    private let logger = Logger(subsystem: "KnowledgeBaseKit", category: "retrieval")

    public init(
        database: KnowledgeDatabase,
        configuration: KnowledgeStoreConfiguration,
        embedding: any EmbeddingProvider
    ) {
        self.database = database
        self.configuration = configuration
        self.embedding = embedding
        self.fusion = ReciprocalRankFusion(configuration: configuration.fusion)
    }

    public func search(_ query: String, options: SearchOptions = .default) async throws -> SearchResponse {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResponse(query: query, results: [], participatingArms: [], degradations: [])
        }

        let perArm = configuration.fusion.candidatesPerArm
        var degradations: [Degradation] = []

        // Arm 1: keyword. Always available — it needs no model and no embeddings.
        let keywordHits = try database.read { db in
            try KeywordArm.search(query: trimmed, limit: perArm, in: db)
        }

        // Arm 2: vector. Two independent ways to be unavailable: the query cannot be
        // embedded, or nothing has been embedded yet.
        var vectorHits: [ChunkID] = []
        do {
            let queryEmbedding = try await embedding.embed(trimmed)
            vectorHits = try database.read { db in
                try VectorArm.search(embedding: queryEmbedding, limit: perArm, in: db)
            }
            if vectorHits.isEmpty {
                let hasEmbeddings = try database.read { db in
                    try Int.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM chunk_embeddings)") == 1
                }
                if !hasEmbeddings { degradations.append(.vectorIndexEmpty) }
            }
        } catch {
            let reason = (error as? ProviderError).map(String.init(describing:)) ?? error.localizedDescription
            logger.notice("Vector arm unavailable: \(reason, privacy: .public)")
            degradations.append(.embeddingUnavailable(reason))
        }

        // Arm 3: graph, seeded both from the query text and from the other arms' best hits.
        let seedChunks = Array((keywordHits + vectorHits).prefix(10))
        let (graphHits, matchedNames) = try database.read { db -> ([ChunkID], [String]) in
            let named = try GraphArm.seedsFromQueryText(trimmed, in: db)
            let fromChunks = try GraphArm.seedsFromChunks(seedChunks, in: db)

            var seeds = named.entityIDs
            var seen = Set(seeds)
            for id in fromChunks where seen.insert(id).inserted { seeds.append(id) }

            guard !seeds.isEmpty else { return ([], named.matchedNames) }

            let chunks = try GraphArm.expand(
                seeds: seeds,
                hops: configuration.fusion.graphHops,
                limit: perArm,
                in: db
            )
            return (chunks, named.matchedNames)
        }

        if graphHits.isEmpty {
            let entityCount = try database.read { db in try GraphRepository.entityCount(in: db) }
            if entityCount == 0 { degradations.append(.graphEmpty) }
        }

        var lists: [RetrievalArm: [ChunkID]] = [:]
        if !keywordHits.isEmpty { lists[.keyword] = keywordHits }
        if !vectorHits.isEmpty { lists[.vector] = vectorHits }
        if !graphHits.isEmpty { lists[.graph] = graphHits }

        let ranked = fusion.fuse(lists)
        let results = try hydrate(ranked, matchedNames: matchedNames, options: options)

        return SearchResponse(
            query: query,
            results: results,
            participatingArms: Set(lists.keys),
            degradations: degradations
        )
    }

    /// Loads chunk and document rows for the fused ranking, applies tag filtering, and trims
    /// to the requested limit.
    private func hydrate(
        _ ranked: [ReciprocalRankFusion.Ranked],
        matchedNames: [String],
        options: SearchOptions
    ) throws -> [SearchResult] {
        guard !ranked.isEmpty else { return [] }

        // Filtering happens after fusion, so a tag filter narrows the ranking rather than
        // changing what each arm considered. Over-fetching keeps the limit meaningful when
        // a filter is applied.
        let candidateCount = options.requiredTags.isEmpty ? options.limit : ranked.count
        let considered = Array(ranked.prefix(max(candidateCount, options.limit)))

        return try database.read { db in
            let chunks = try ChunkRepository.fetch(ids: considered.map(\.chunkID), in: db)
            let chunksByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
            let documents = try DocumentRepository.fetchAll(in: db)
            let documentsByID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })

            var results: [SearchResult] = []
            for entry in considered {
                guard let chunk = chunksByID[entry.chunkID],
                    let document = documentsByID[chunk.documentID]
                else { continue }

                if !options.requiredTags.isEmpty {
                    let tags = Set(document.metadata.tags.map { $0.lowercased() })
                    let required = Set(options.requiredTags.map { $0.lowercased() })
                    guard required.isSubset(of: tags) else { continue }
                }

                let mentioned = try mentionedNames(of: chunk.id, limitedTo: matchedNames, in: db)

                results.append(
                    SearchResult(
                        chunkID: chunk.id,
                        documentPath: document.relativePath,
                        documentTitle: document.metadata.title,
                        headingPath: chunk.headingPath,
                        content: chunk.content,
                        score: entry.score,
                        ranks: entry.ranks,
                        matchedEntities: mentioned
                    )
                )
                if results.count == options.limit { break }
            }
            return results
        }
    }

    private func mentionedNames(
        of chunkID: ChunkID,
        limitedTo matchedNames: [String],
        in db: Database
    ) throws -> [String] {
        guard !matchedNames.isEmpty else { return [] }
        let entityIDs = try GraphRepository.entityIDs(mentionedIn: [chunkID], in: db)
        let entities = try GraphRepository.fetch(ids: entityIDs, in: db)
        let wanted = Set(matchedNames.map { NameNormalizer.normalizeForMatching($0) })
        return entities
            .filter { wanted.contains(NameNormalizer.normalizeForMatching($0.canonicalName)) }
            .map(\.canonicalName)
    }
}
