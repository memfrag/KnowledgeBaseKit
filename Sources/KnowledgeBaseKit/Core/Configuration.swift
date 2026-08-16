import Foundation

/// Everything the store needs to know that is not in the database.
///
/// Several fields participate in ``VersionKeys`` and therefore in migration: changing the
/// embedding model re-embeds, changing the chunker bounds re-chunks, and so on. Those are
/// marked below.
public struct KnowledgeStoreConfiguration: Sendable {
    /// Directories scanned by ``KnowledgeStore/sync()`` and watched by ``CorpusWatcher``.
    public var corpusRoots: [URL]
    /// gitignore-style patterns, applied on top of the built-in rules (dotfiles,
    /// dot-directories, and non-`.md` extensions are always skipped).
    public var ignorePatterns: [String]
    public var ollamaEndpoint: URL
    /// Version key: changing the model or dimensions re-embeds every chunk.
    public var embedding: EmbeddingConfiguration
    /// Version key: changing the model or vocabulary re-extracts every chunk.
    public var extraction: ExtractionConfiguration
    /// Whether to build the knowledge graph at all.
    ///
    /// Extraction is one model call per chunk, while embedding is batched, so extraction
    /// dominates the cost of a first index. Turning it off leaves keyword and vector
    /// retrieval fully working and skips the extraction model entirely — which is the right
    /// trade when the consumer is an agent that reasons over the retrieved chunks itself.
    ///
    /// Toggling it is reconciled on open: turning it off retires queued extraction work,
    /// turning it on backfills the chunks that never got extracted.
    public var graphExtraction: Bool
    /// Version key: changing these bounds re-chunks, cascading to re-embed and re-extract.
    public var chunking: ChunkingConfiguration
    public var fusion: FusionConfiguration
    public var retry: RetryConfiguration
    public var watcher: WatcherConfiguration
    /// Bounds concurrent requests to Ollama, which is a single local process and is the
    /// pipeline's bottleneck.
    public var workerCount: Int
    /// When false, the store opens read-only: it will not take the write lock and any
    /// ingesting call throws ``KnowledgeStoreError/databaseInUse(holder:)``.
    public var allowsWriting: Bool

    public init(
        corpusRoots: [URL] = [],
        ignorePatterns: [String] = [],
        ollamaEndpoint: URL = URL(string: "http://localhost:11434")!,
        embedding: EmbeddingConfiguration = .default,
        extraction: ExtractionConfiguration = .default,
        graphExtraction: Bool = true,
        chunking: ChunkingConfiguration = .default,
        fusion: FusionConfiguration = .default,
        retry: RetryConfiguration = .default,
        watcher: WatcherConfiguration = .default,
        workerCount: Int = 2,
        allowsWriting: Bool = true
    ) {
        self.corpusRoots = corpusRoots.map { $0.standardizedFileURL }
        self.ignorePatterns = ignorePatterns
        self.ollamaEndpoint = ollamaEndpoint
        self.embedding = embedding
        self.extraction = extraction
        self.graphExtraction = graphExtraction
        self.chunking = chunking
        self.fusion = fusion
        self.retry = retry
        self.watcher = watcher
        self.workerCount = workerCount
        self.allowsWriting = allowsWriting
    }
}

public struct EmbeddingConfiguration: Sendable, Hashable {
    public var model: String
    public var dimensions: Int
    /// How many chunks are sent to the embedding endpoint per request.
    public var batchSize: Int

    public init(model: String, dimensions: Int, batchSize: Int = 16) {
        self.model = model
        self.dimensions = dimensions
        self.batchSize = batchSize
    }

    public static let `default` = EmbeddingConfiguration(model: "embeddinggemma", dimensions: 768)
}

public struct ExtractionConfiguration: Sendable, Hashable {
    public var model: String
    public var vocabulary: GraphVocabulary
    /// Similarity above which two entity names are considered the same without asking the
    /// model. Below this but above ``adjudicationFloor`` the LLM is asked to decide.
    public var resolutionThreshold: Double
    public var adjudicationFloor: Double

    public init(
        model: String,
        vocabulary: GraphVocabulary = .default,
        resolutionThreshold: Double = 0.92,
        adjudicationFloor: Double = 0.75
    ) {
        self.model = model
        self.vocabulary = vocabulary
        self.resolutionThreshold = resolutionThreshold
        self.adjudicationFloor = adjudicationFloor
    }

    public static let `default` = ExtractionConfiguration(model: "qwen2.5:7b")
}

public struct ChunkingConfiguration: Sendable, Hashable {
    /// Sections below this are merged with an adjacent sibling.
    public var minimumTokens: Int
    /// Sections above this are subdivided at paragraph boundaries.
    public var maximumTokens: Int

    public init(minimumTokens: Int = 64, maximumTokens: Int = 512) {
        self.minimumTokens = minimumTokens
        self.maximumTokens = maximumTokens
    }

    public static let `default` = ChunkingConfiguration()
}

/// Reciprocal Rank Fusion parameters.
///
/// RRF combines arms by rank rather than score, because BM25 magnitudes and cosine
/// similarities are not on comparable scales and normalizing them makes the outcome depend
/// on the composition of each candidate set.
public struct FusionConfiguration: Sendable, Hashable {
    public var keywordWeight: Double
    public var vectorWeight: Double
    public var graphWeight: Double
    /// The RRF damping constant. Larger values flatten the contribution of top ranks.
    public var k: Double
    /// How many candidates each arm contributes before fusion.
    public var candidatesPerArm: Int
    /// Hops of graph expansion from the seed entities.
    public var graphHops: Int

    public init(
        keywordWeight: Double = 1.0,
        vectorWeight: Double = 1.0,
        graphWeight: Double = 0.7,
        k: Double = 60,
        candidatesPerArm: Int = 50,
        graphHops: Int = 2
    ) {
        self.keywordWeight = keywordWeight
        self.vectorWeight = vectorWeight
        self.graphWeight = graphWeight
        self.k = k
        self.candidatesPerArm = candidatesPerArm
        self.graphHops = graphHops
    }

    public static let `default` = FusionConfiguration()
}

public struct RetryConfiguration: Sendable, Hashable {
    /// Attempts before a job is dead-lettered.
    public var maximumAttempts: Int
    public var initialBackoff: TimeInterval
    public var backoffMultiplier: Double
    public var maximumBackoff: TimeInterval

    public init(
        maximumAttempts: Int = 3,
        initialBackoff: TimeInterval = 2,
        backoffMultiplier: Double = 4,
        maximumBackoff: TimeInterval = 300
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialBackoff = initialBackoff
        self.backoffMultiplier = backoffMultiplier
        self.maximumBackoff = maximumBackoff
    }

    public static let `default` = RetryConfiguration()

    func backoff(forAttempt attempt: Int) -> TimeInterval {
        let raw = initialBackoff * pow(backoffMultiplier, Double(max(0, attempt - 1)))
        return min(raw, maximumBackoff)
    }
}

public struct WatcherConfiguration: Sendable, Hashable {
    /// Rapid saves to the same path within this window collapse into one re-index.
    public var debounceInterval: TimeInterval
    /// More than this many events in a debounce window collapse into a single full
    /// `sync()` rather than thousands of per-file jobs — the `git checkout` case.
    public var burstThreshold: Int

    public init(debounceInterval: TimeInterval = 0.5, burstThreshold: Int = 200) {
        self.debounceInterval = debounceInterval
        self.burstThreshold = burstThreshold
    }

    public static let `default` = WatcherConfiguration()
}
