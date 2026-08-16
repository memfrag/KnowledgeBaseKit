import Foundation

public enum RetrievalArm: String, Sendable, Hashable, CaseIterable, Codable {
    case keyword
    case vector
    case graph
}

/// Why a search returned less than it could have.
///
/// Surfaced in the result rather than thrown, so a caller can tell a thin answer from a
/// broken one — the whole point of degrading to keyword-only instead of failing.
public enum Degradation: Sendable, Hashable, Codable {
    /// Nothing has been embedded yet, or the embeddings were invalidated by a model change.
    case vectorIndexEmpty
    /// The query itself could not be embedded, typically because Ollama is unreachable.
    case embeddingUnavailable(String)
    /// The graph has no entities, usually because extraction has not caught up.
    case graphEmpty

    public var message: String {
        switch self {
        case .vectorIndexEmpty:
            return "Semantic search is unavailable: no embeddings have been indexed yet."
        case .embeddingUnavailable(let reason):
            return "Semantic search is unavailable: \(reason)"
        case .graphEmpty:
            return "Graph expansion is unavailable: no entities have been extracted yet."
        }
    }
}

public struct SearchResult: Sendable, Hashable {
    public var chunkID: ChunkID
    public var documentPath: String
    public var documentTitle: String?
    public var headingPath: HeadingPath
    public var content: String
    /// The fused Reciprocal Rank Fusion score. Higher is better.
    public var score: Double
    /// The rank this chunk held in each arm that returned it, 1-based.
    public var ranks: [RetrievalArm: Int]
    /// Canonical names of entities mentioned by this chunk that the query touched.
    public var matchedEntities: [String]

    public var citation: String {
        headingPath.isEmpty ? documentPath : "\(documentPath) — \(headingPath.displayForm)"
    }
}

public struct SearchResponse: Sendable, Hashable {
    public var query: String
    public var results: [SearchResult]
    /// Which arms actually contributed candidates.
    public var participatingArms: Set<RetrievalArm>
    public var degradations: [Degradation]

    public var isDegraded: Bool { !degradations.isEmpty }

    public init(
        query: String,
        results: [SearchResult],
        participatingArms: Set<RetrievalArm>,
        degradations: [Degradation]
    ) {
        self.query = query
        self.results = results
        self.participatingArms = participatingArms
        self.degradations = degradations
    }
}

public struct SearchOptions: Sendable, Hashable {
    public var limit: Int
    /// Restricts results to documents carrying all of these front matter tags.
    public var requiredTags: [String]

    public init(limit: Int = 10, requiredTags: [String] = []) {
        self.limit = limit
        self.requiredTags = requiredTags
    }

    public static let `default` = SearchOptions()
}
