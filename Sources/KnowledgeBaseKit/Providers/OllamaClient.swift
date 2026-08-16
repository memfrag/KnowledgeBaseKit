import Foundation

/// A thin HTTP client for a local Ollama server.
///
/// Everything here maps failures onto ``ProviderError`` so that the job queue can tell a
/// server that is merely off from a response that will never parse.
public struct OllamaClient: Sendable {
    public let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL, timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // Generation of a long answer can exceed the request timeout between chunks, so the
        // resource timeout is given considerably more room.
        configuration.timeoutIntervalForResource = timeout * 10
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Health

    public func health(requiredModels: [String]) async -> ProviderHealth {
        do {
            let data = try await get("/api/tags")
            let response = try JSONDecoder().decode(TagsResponse.self, from: data)
            let available = response.models.map(\.name)
            let missing = requiredModels.filter { required in
                !available.contains { matches(available: $0, required: required) }
            }
            return ProviderHealth(
                isReachable: true,
                availableModels: available,
                message: missing.isEmpty
                    ? nil
                    : "Missing models: \(missing.joined(separator: ", ")). Pull them with: "
                        + missing.map { "ollama pull \($0)" }.joined(separator: "; ")
            )
        } catch {
            return ProviderHealth(
                isReachable: false,
                message: (error as? ProviderError).map(String.init(describing:))
                    ?? error.localizedDescription
            )
        }
    }

    /// Ollama reports `llama3.1:8b` for a model the user may have configured as `llama3.1`,
    /// where `:latest` is implied.
    private func matches(available: String, required: String) -> Bool {
        if available == required { return true }
        if !required.contains(":") { return available == "\(required):latest" }
        return false
    }

    // MARK: - Embeddings

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        struct Request: Encodable {
            let model: String
            let input: [String]
        }
        struct Response: Decodable {
            let embeddings: [[Float]]
        }

        let data = try await post("/api/embed", body: Request(model: model, input: inputs))
        do {
            return try JSONDecoder().decode(Response.self, from: data).embeddings
        } catch {
            throw ProviderError.malformedResponse("embed response: \(error.localizedDescription)")
        }
    }

    // MARK: - Structured generation

    /// Non-streaming generation constrained to a JSON schema.
    ///
    /// Ollama enforces the schema during decoding, which is what makes extraction reliable
    /// enough to be worth retrying only three times before dead-lettering.
    public func generateJSON(
        model: String,
        prompt: String,
        system: String?,
        schema: JSONSchema,
        temperature: Double = 0
    ) async throws -> Data {
        struct Options: Encodable {
            let temperature: Double
        }
        struct Request: Encodable {
            let model: String
            let prompt: String
            let system: String?
            let stream: Bool
            let format: JSONSchema
            let options: Options
        }
        struct Response: Decodable {
            let response: String
        }

        let data = try await post(
            "/api/generate",
            body: Request(
                model: model,
                prompt: prompt,
                system: system,
                stream: false,
                format: schema,
                options: Options(temperature: temperature)
            )
        )

        do {
            let envelope = try JSONDecoder().decode(Response.self, from: data)
            return Data(envelope.response.utf8)
        } catch {
            throw ProviderError.malformedResponse("generate response: \(error.localizedDescription)")
        }
    }

    // MARK: - Streaming generation

    public func generateStream(
        model: String,
        prompt: String,
        system: String?,
        temperature: Double,
        maximumTokens: Int?
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    struct Options: Encodable {
                        let temperature: Double
                        let num_predict: Int?
                    }
                    struct Request: Encodable {
                        let model: String
                        let prompt: String
                        let system: String?
                        let stream: Bool
                        let options: Options
                    }

                    var request = URLRequest(url: endpoint.appending(path: "/api/generate"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        Request(
                            model: model,
                            prompt: prompt,
                            system: system,
                            stream: true,
                            options: Options(temperature: temperature, num_predict: maximumTokens)
                        )
                    )

                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response: response, body: Data())

                    // Ollama streams newline-delimited JSON objects, one per token group.
                    for try await line in bytes.lines {
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        struct Chunk: Decodable {
                            let response: String?
                            let done: Bool?
                            let error: String?
                        }
                        let chunk = try JSONDecoder().decode(Chunk.self, from: data)
                        if let error = chunk.error {
                            throw ProviderError.serverError(status: 200, body: error)
                        }
                        if let text = chunk.response, !text.isEmpty {
                            continuation.yield(text)
                        }
                        if chunk.done == true { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as ProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: Self.mapTransport(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transport

    private func get(_ path: String) async throws -> Data {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = "GET"
        return try await perform(request)
    }

    private func post(_ path: String, body: some Encodable) async throws -> Data {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.mapTransport(error)
        }
        try validate(response: response, body: data)
        return data
    }

    private func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        let text = String(decoding: body, as: UTF8.self)
        // Ollama answers 404 with `model "x" not found` when the model is not pulled, which
        // is a user action away from being fixed rather than a corpus problem.
        if http.statusCode == 404, text.localizedCaseInsensitiveContains("not found") {
            throw ProviderError.modelNotFound(text)
        }
        throw ProviderError.serverError(status: http.statusCode, body: text)
    }

    private static func mapTransport(_ error: any Error) -> ProviderError {
        .transport((error as NSError).localizedDescription)
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }
}

// MARK: - JSON Schema

/// The subset of JSON Schema Ollama's structured-output mode needs.
public indirect enum JSONSchema: Encodable, Sendable {
    case object(properties: [String: JSONSchema], required: [String])
    case array(items: JSONSchema)
    case string(enumeration: [String]? = nil)
    case number
    case boolean

    private enum CodingKeys: String, CodingKey {
        case type, properties, required, items, `enum`
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .object(let properties, let required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
        case .array(let items):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
        case .string(let enumeration):
            try container.encode("string", forKey: .type)
            if let enumeration { try container.encode(enumeration, forKey: .enum) }
        case .number:
            try container.encode("number", forKey: .type)
        case .boolean:
            try container.encode("boolean", forKey: .type)
        }
    }
}
