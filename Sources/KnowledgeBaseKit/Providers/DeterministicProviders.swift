import CryptoKit
import Foundation
import Synchronization

/// A hash-derived embedding provider.
///
/// Vectors are derived from the text itself, so the same text always embeds identically and
/// similar-looking text does *not* accidentally embed similarly. That is the point: these
/// vectors carry no semantics, only identity, which is exactly what is needed to test the
/// pipeline, the job queue, and fusion ranking without a model running.
///
/// Shipped in the library rather than the test target so that callers can exercise their own
/// integrations against a store that needs no Ollama.
public struct DeterministicEmbeddingProvider: EmbeddingProvider {
    public let modelIdentifier: String
    public let dimensions: Int
    /// Texts whose embedding should fail, to exercise dead-lettering.
    private let failing: Set<String>
    private let failureIsTransient: Bool

    public init(
        modelIdentifier: String = "deterministic-test-embed",
        dimensions: Int = 8,
        failing: Set<String> = [],
        failureIsTransient: Bool = false
    ) {
        self.modelIdentifier = modelIdentifier
        self.dimensions = dimensions
        self.failing = failing
        self.failureIsTransient = failureIsTransient
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        for text in texts where failing.contains(where: { text.contains($0) }) {
            throw failureIsTransient
                ? ProviderError.transport("simulated outage")
                : ProviderError.malformedResponse("simulated permanent failure")
        }
        return texts.map { Self.vector(for: $0, dimensions: dimensions) }
    }

    /// Expands a SHA-256 digest into a unit vector of the requested width.
    public static func vector(for text: String, dimensions: Int = 8) -> [Float] {
        var bytes: [UInt8] = []
        var counter = 0
        while bytes.count < dimensions * 4 {
            let digest = SHA256.hash(data: Data("\(counter)\u{1F}\(text)".utf8))
            bytes.append(contentsOf: digest)
            counter += 1
        }

        var values: [Float] = []
        values.reserveCapacity(dimensions)
        for index in 0..<dimensions {
            let slice = bytes[(index * 4)..<(index * 4 + 4)]
            let raw = slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            // Map into -1...1 so vectors spread over the sphere rather than one octant.
            values.append(Float(Double(raw) / Double(UInt32.max) * 2 - 1))
        }

        let magnitude = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard magnitude > 0 else { return values }
        return values.map { $0 / magnitude }
    }

    /// The vector this provider would produce for `text`, at its configured width.
    public func embedding(for text: String) -> [Float] {
        Self.vector(for: text, dimensions: dimensions)
    }
}

/// Returns pre-programmed extraction results.
///
/// Fixtures are keyed by a substring of the chunk text, so a test can say "any chunk
/// mentioning the auth service extracts these entities" without reproducing chunk IDs.
public final class FixtureExtractionProvider: ExtractionProvider, Sendable {
    public let modelIdentifier: String

    private struct State {
        var fixtures: [(match: String, result: ExtractionResult)] = []
        var adjudications: [String: String] = [:]
        var failing: Set<String> = []
        var failureIsTransient = false
        var extractionCount = 0
    }

    private let state = Mutex(State())

    public init(modelIdentifier: String = "deterministic-test-extract") {
        self.modelIdentifier = modelIdentifier
    }

    /// Registers a result for any chunk whose text contains `match`.
    public func onText(containing match: String, return result: ExtractionResult) {
        state.withLock { $0.fixtures.append((match, result)) }
    }

    /// Makes extraction fail for any chunk whose text contains `match`.
    public func failOnText(containing match: String, transient: Bool = false) {
        state.withLock {
            $0.failing.insert(match)
            $0.failureIsTransient = transient
        }
    }

    /// Programs ``adjudicate(name:type:candidates:)`` to resolve `name` onto the candidate
    /// with `canonicalName`.
    public func resolve(_ name: String, to canonicalName: String) {
        state.withLock { $0.adjudications[NameNormalizer.normalizeForMatching(name)] = canonicalName }
    }

    public var extractionCount: Int {
        state.withLock { $0.extractionCount }
    }

    public func extract(
        from chunk: ChunkContext,
        vocabulary: GraphVocabulary
    ) async throws -> ExtractionResult {
        let outcome: Result<ExtractionResult, ProviderError> = state.withLock { state in
            state.extractionCount += 1

            if state.failing.contains(where: { chunk.text.contains($0) }) {
                return .failure(
                    state.failureIsTransient
                        ? .transport("simulated outage")
                        : .malformedResponse("simulated unparseable JSON")
                )
            }

            for fixture in state.fixtures where chunk.text.contains(fixture.match) {
                return .success(fixture.result)
            }
            return .success(.empty)
        }

        // Sanitizing here too, so fixtures go through the same vocabulary validation as real
        // model output and a test cannot smuggle in an out-of-vocabulary type.
        return try OllamaExtractionProvider.sanitize(outcome.get(), vocabulary: vocabulary)
    }

    public func adjudicate(
        name: String,
        type: String,
        candidates: [EntityCandidate]
    ) async throws -> EntityID? {
        let target = state.withLock { $0.adjudications[NameNormalizer.normalizeForMatching(name)] }
        guard let target else { return nil }
        return candidates.first { $0.canonicalName == target }?.id
    }
}

/// Emits a fixed answer, one word at a time, so streaming can be tested without a model.
public struct FixtureGenerationProvider: GenerationProvider {
    private let answer: String
    private let failure: (any Error)?

    public init(answer: String = "This is a fixture answer [1].", failure: (any Error)? = nil) {
        self.answer = answer
        self.failure = failure
    }

    public func generate(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        let answer = answer
        let failure = failure
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                continuation.yield(String(word) + " ")
            }
            continuation.finish()
        }
    }
}
