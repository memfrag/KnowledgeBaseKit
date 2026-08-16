import Foundation

/// A source the answer was generated from.
public struct Citation: Sendable, Hashable {
    /// 1-based, matching the `[n]` markers the model is asked to emit.
    public var index: Int
    public var chunkID: ChunkID
    public var documentPath: String
    public var documentTitle: String?
    public var headingPath: HeadingPath
    public var excerpt: String

    public var label: String {
        headingPath.isEmpty ? documentPath : "\(documentPath) — \(headingPath.displayForm)"
    }
}

/// A streaming answer.
///
/// Citations are resolved *before* generation begins, so a host app can render its sources
/// list immediately and fill the prose in progressively.
public struct AnswerStream: Sendable {
    public let citations: [Citation]
    public let searchResponse: SearchResponse
    public let tokens: AsyncThrowingStream<String, any Error>

    /// Collects the stream into a finished answer, for callers that want one value —
    /// the CLI and the MCP tool both do.
    public func collected() async throws -> Answer {
        var text = ""
        for try await token in tokens {
            text += token
        }
        return Answer(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            citations: citations,
            searchResponse: searchResponse
        )
    }
}

public struct Answer: Sendable, Hashable {
    public var text: String
    public var citations: [Citation]
    public var searchResponse: SearchResponse
}

public struct AnswerOptions: Sendable, Hashable {
    /// How many retrieved chunks may be packed into the prompt.
    public var contextTokenBudget: Int
    public var search: SearchOptions
    public var temperature: Double
    public var maximumTokens: Int?

    public init(
        contextTokenBudget: Int = 3000,
        search: SearchOptions = SearchOptions(limit: 8),
        temperature: Double = 0.2,
        maximumTokens: Int? = nil
    ) {
        self.contextTokenBudget = contextTokenBudget
        self.search = search
        self.temperature = temperature
        self.maximumTokens = maximumTokens
    }

    public static let `default` = AnswerOptions()
}

/// Layers generation on top of retrieval.
///
/// Unlike ``RetrievalEngine``, this does not degrade when Ollama is unavailable: an answer
/// without a model has no meaningful fallback, so the call throws.
public struct AnswerEngine: Sendable {
    private let retrieval: RetrievalEngine
    private let generation: any GenerationProvider
    private let model: String
    private let endpoint: URL

    public init(
        retrieval: RetrievalEngine,
        generation: any GenerationProvider,
        model: String,
        endpoint: URL
    ) {
        self.retrieval = retrieval
        self.generation = generation
        self.model = model
        self.endpoint = endpoint
    }

    public func answer(_ question: String, options: AnswerOptions = .default) async throws -> AnswerStream {
        let response = try await retrieval.search(question, options: options.search)

        // Context is packed by fusion rank until the budget runs out, so the best-ranked
        // chunks are the ones that survive truncation.
        var citations: [Citation] = []
        var used = 0
        for result in response.results {
            let cost = TokenEstimator.estimate(result.content)
            guard used + cost <= options.contextTokenBudget || citations.isEmpty else { break }
            used += cost
            citations.append(
                Citation(
                    index: citations.count + 1,
                    chunkID: result.chunkID,
                    documentPath: result.documentPath,
                    documentTitle: result.documentTitle,
                    headingPath: result.headingPath,
                    excerpt: result.content
                )
            )
        }

        guard !citations.isEmpty else {
            // Nothing retrieved: say so rather than inviting the model to invent an answer
            // from no context at all.
            return AnswerStream(
                citations: [],
                searchResponse: response,
                tokens: AsyncThrowingStream { continuation in
                    continuation.yield(
                        "No indexed content matched that question."
                            + (response.isDegraded
                                ? " " + response.degradations.map(\.message).joined(separator: " ")
                                : "")
                    )
                    continuation.finish()
                }
            )
        }

        let prompt = Self.prompt(question: question, citations: citations)
        let stream = generation.generate(
            prompt: prompt,
            options: GenerationOptions(
                model: model,
                temperature: options.temperature,
                maximumTokens: options.maximumTokens
            )
        )

        return AnswerStream(citations: citations, searchResponse: response, tokens: stream)
    }

    static func prompt(question: String, citations: [Citation]) -> String {
        let excerpts = citations
            .map { citation in
                """
                [\(citation.index)] \(citation.label)
                \(citation.excerpt)
                """
            }
            .joined(separator: "\n\n")

        return """
            Excerpts from the user's notes:

            \(excerpts)

            ---

            Question: \(question)
            """
    }
}
