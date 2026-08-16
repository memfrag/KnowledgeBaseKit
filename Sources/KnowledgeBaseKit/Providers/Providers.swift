import Foundation

// MARK: - Errors

/// Failures from a model backend, classified by whether retrying can help.
///
/// The distinction is load-bearing: a transient failure is rescheduled without consuming a
/// retry attempt, so an unreachable Ollama does not dead-letter the whole queue while the
/// user is away from the machine. A permanent failure counts toward the attempt budget and
/// eventually dead-letters, which is what bounds the damage from a poison chunk.
public enum ProviderError: Error, Sendable {
    /// The server could not be reached, or the request timed out.
    case transport(String)
    /// The server answered, but the model is not pulled.
    case modelNotFound(String)
    /// The server answered with a non-success status.
    case serverError(status: Int, body: String)
    /// The response could not be decoded, or violated the requested schema.
    case malformedResponse(String)
    /// The embedding came back with the wrong number of dimensions.
    case dimensionMismatch(expected: Int, actual: Int)

    public var isTransient: Bool {
        switch self {
        case .transport:
            return true
        case .serverError(let status, _):
            // 5xx is the server having a bad time; 4xx is us asking for something wrong.
            return status >= 500
        case .modelNotFound:
            // Recoverable without changing the corpus: the user runs `ollama pull` and the
            // queue drains. Burning retries on it would be wrong.
            return true
        case .malformedResponse, .dimensionMismatch:
            return false
        }
    }
}

// MARK: - Embedding

public protocol EmbeddingProvider: Sendable {
    /// Recorded as the embedding version key. Changing it re-embeds the corpus.
    var modelIdentifier: String { get }
    var dimensions: Int { get }

    /// Embeds a batch. The result is parallel to the input, same order, same count.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

extension EmbeddingProvider {
    public func embed(_ text: String) async throws -> [Float] {
        let result = try await embed([text])
        guard let first = result.first else {
            throw ProviderError.malformedResponse("empty embedding response")
        }
        return first
    }
}

// MARK: - Extraction

/// What the extraction model sees. The heading path is included because a section titled
/// "Overview" means very little without the document it belongs to.
public struct ChunkContext: Sendable, Hashable {
    public var chunkID: ChunkID
    public var documentTitle: String
    public var headingPath: HeadingPath
    public var text: String

    public init(chunkID: ChunkID, documentTitle: String, headingPath: HeadingPath, text: String) {
        self.chunkID = chunkID
        self.documentTitle = documentTitle
        self.headingPath = headingPath
        self.text = text
    }
}

public struct ExtractedEntity: Sendable, Hashable, Codable {
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}

public struct ExtractedRelation: Sendable, Hashable, Codable {
    public var source: String
    public var type: String
    public var target: String
    public var confidence: Double

    public init(source: String, type: String, target: String, confidence: Double) {
        self.source = source
        self.type = type
        self.target = target
        self.confidence = confidence
    }
}

public struct ExtractionResult: Sendable, Hashable, Codable {
    public var entities: [ExtractedEntity]
    public var relations: [ExtractedRelation]

    public init(entities: [ExtractedEntity] = [], relations: [ExtractedRelation] = []) {
        self.entities = entities
        self.relations = relations
    }

    public static let empty = ExtractionResult()
}

/// A stored entity offered to the model as a possible match for an unresolved name.
public struct EntityCandidate: Sendable, Hashable {
    public var id: EntityID
    public var canonicalName: String
    public var type: String
    public var similarity: Double

    public init(id: EntityID, canonicalName: String, type: String, similarity: Double) {
        self.id = id
        self.canonicalName = canonicalName
        self.type = type
        self.similarity = similarity
    }
}

public protocol ExtractionProvider: Sendable {
    /// Recorded as the extraction version key. Changing it re-extracts the corpus.
    var modelIdentifier: String { get }

    func extract(
        from chunk: ChunkContext,
        vocabulary: GraphVocabulary
    ) async throws -> ExtractionResult

    /// Decides whether an unresolved name refers to one of the candidates.
    ///
    /// Only reached for names that deterministic matching and embedding similarity left
    /// genuinely ambiguous — the model is a tiebreaker here, not the mechanism.
    /// Returning nil means "none of these", and a new entity is created.
    func adjudicate(
        name: String,
        type: String,
        candidates: [EntityCandidate]
    ) async throws -> EntityID?
}

// MARK: - Generation

public struct GenerationOptions: Sendable {
    public var model: String
    public var temperature: Double
    public var maximumTokens: Int?

    public init(model: String, temperature: Double = 0.2, maximumTokens: Int? = nil) {
        self.model = model
        self.temperature = temperature
        self.maximumTokens = maximumTokens
    }
}

/// Backs ``KnowledgeStore/answer(_:options:)``. Separate from extraction because generation
/// streams and extraction does not.
public protocol GenerationProvider: Sendable {
    func generate(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error>
}

// MARK: - Health

public struct ProviderHealth: Sendable, Hashable {
    public var isReachable: Bool
    public var availableModels: [String]
    public var message: String?

    public init(isReachable: Bool, availableModels: [String] = [], message: String? = nil) {
        self.isReachable = isReachable
        self.availableModels = availableModels
        self.message = message
    }
}
