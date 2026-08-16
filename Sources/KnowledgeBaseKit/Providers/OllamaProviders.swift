import Foundation

// MARK: - Embedding

public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let modelIdentifier: String
    public let dimensions: Int
    private let client: OllamaClient

    public init(client: OllamaClient, configuration: EmbeddingConfiguration) {
        self.client = client
        self.modelIdentifier = configuration.model
        self.dimensions = configuration.dimensions
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let embeddings = try await client.embed(model: modelIdentifier, inputs: texts)

        guard embeddings.count == texts.count else {
            throw ProviderError.malformedResponse(
                "expected \(texts.count) embeddings, got \(embeddings.count)"
            )
        }
        // A dimension mismatch means the configuration disagrees with the model. Surfacing it
        // here keeps a vector of the wrong width from ever reaching the vec0 table, where the
        // failure would be far less legible.
        for embedding in embeddings where embedding.count != dimensions {
            throw ProviderError.dimensionMismatch(expected: dimensions, actual: embedding.count)
        }
        return embeddings
    }
}

// MARK: - Extraction

public struct OllamaExtractionProvider: ExtractionProvider {
    public let modelIdentifier: String
    private let client: OllamaClient

    public init(client: OllamaClient, configuration: ExtractionConfiguration) {
        self.client = client
        self.modelIdentifier = configuration.model
    }

    public func extract(
        from chunk: ChunkContext,
        vocabulary: GraphVocabulary
    ) async throws -> ExtractionResult {
        let schema = JSONSchema.object(
            properties: [
                "entities": .array(
                    items: .object(
                        properties: [
                            "name": .string(),
                            "type": .string(enumeration: vocabulary.entityTypes),
                        ],
                        required: ["name", "type"]
                    )
                ),
                "relations": .array(
                    items: .object(
                        properties: [
                            "source": .string(),
                            "type": .string(enumeration: vocabulary.relationTypes),
                            "target": .string(),
                            "confidence": .number,
                        ],
                        required: ["source", "type", "target", "confidence"]
                    )
                ),
            ],
            required: ["entities", "relations"]
        )

        let data = try await client.generateJSON(
            model: modelIdentifier,
            prompt: Self.prompt(for: chunk),
            system: Self.systemPrompt(vocabulary: vocabulary),
            schema: schema
        )

        let decoded: ExtractionResult
        do {
            decoded = try JSONDecoder().decode(ExtractionResult.self, from: data)
        } catch {
            throw ProviderError.malformedResponse(
                "extraction JSON did not decode: \(error.localizedDescription)"
            )
        }

        return Self.sanitize(decoded, vocabulary: vocabulary)
    }

    public func adjudicate(
        name: String,
        type: String,
        candidates: [EntityCandidate]
    ) async throws -> EntityID? {
        guard !candidates.isEmpty else { return nil }

        let schema = JSONSchema.object(
            properties: [
                "match": .string(enumeration: candidates.map(\.canonicalName) + ["NONE"])
            ],
            required: ["match"]
        )

        let list = candidates
            .enumerated()
            .map { "\($0.offset + 1). \($0.element.canonicalName) (\($0.element.type))" }
            .joined(separator: "\n")

        let data = try await client.generateJSON(
            model: modelIdentifier,
            prompt: """
                Name to resolve: "\(name)" (type: \(type))

                Known entities:
                \(list)

                Does the name refer to exactly one of the known entities? Answer with its \
                name, or NONE if it refers to something different.
                """,
            system: """
                You resolve whether two names refer to the same thing in a document corpus. \
                Answer NONE unless you are confident they are the same entity. Different \
                versions, environments, or components of a larger system are different \
                entities.
                """,
            schema: schema
        )

        struct Answer: Decodable { let match: String }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
            answer.match != "NONE"
        else {
            return nil
        }
        return candidates.first { $0.canonicalName == answer.match }?.id
    }

    // MARK: - Prompting

    private static func systemPrompt(vocabulary: GraphVocabulary) -> String {
        """
        You extract a knowledge graph from a section of a Markdown document.

        Entity types (use exactly these): \(vocabulary.entityTypes.joined(separator: ", "))
        Relation types (use exactly these): \(vocabulary.relationTypes.joined(separator: ", "))

        Rules:
        - Extract only entities that the text actually discusses, not every noun.
        - Use the most complete name the text gives for an entity.
        - Every relation's source and target must appear in the entities list.
        - confidence is 0.0-1.0: how clearly the text states the relation.
        - Return empty lists when the section is boilerplate, navigation, or has no content \
        worth recording.
        """
    }

    private static func prompt(for chunk: ChunkContext) -> String {
        """
        Document: \(chunk.documentTitle)
        Section: \(chunk.headingPath.displayForm)

        ---
        \(chunk.text)
        ---
        """
    }

    // MARK: - Sanitizing

    /// Drops anything the schema could not constrain.
    ///
    /// The schema pins relation and entity *types*, but it cannot express "every relation
    /// endpoint must be a declared entity" — and a relation pointing at an entity that was
    /// never extracted would create a dangling half of the graph.
    static func sanitize(_ result: ExtractionResult, vocabulary: GraphVocabulary) -> ExtractionResult {
        var entities: [ExtractedEntity] = []
        var seen = Set<String>()

        for entity in result.entities {
            let name = entity.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let type = vocabulary.canonicalEntityType(entity.type) else { continue }
            let key = "\(type)|\(NameNormalizer.normalize(name))"
            guard seen.insert(key).inserted else { continue }
            entities.append(ExtractedEntity(name: name, type: type))
        }

        let names = Set(entities.map { NameNormalizer.normalize($0.name) })
        var relations: [ExtractedRelation] = []

        for relation in result.relations {
            guard let type = vocabulary.canonicalRelationType(relation.type) else { continue }
            let source = relation.source.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = relation.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard names.contains(NameNormalizer.normalize(source)),
                names.contains(NameNormalizer.normalize(target))
            else { continue }
            // A self-relation carries no information and would add a cycle to every traversal.
            guard NameNormalizer.normalize(source) != NameNormalizer.normalize(target) else { continue }

            relations.append(
                ExtractedRelation(
                    source: source,
                    type: type,
                    target: target,
                    confidence: min(max(relation.confidence, 0), 1)
                )
            )
        }

        return ExtractionResult(entities: entities, relations: relations)
    }
}

// MARK: - Generation

public struct OllamaGenerationProvider: GenerationProvider {
    private let client: OllamaClient

    public init(client: OllamaClient) {
        self.client = client
    }

    public func generate(
        prompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, any Error> {
        client.generateStream(
            model: options.model,
            prompt: prompt,
            system: Self.systemPrompt,
            temperature: options.temperature,
            maximumTokens: options.maximumTokens
        )
    }

    static let systemPrompt = """
        You answer questions using only the provided excerpts from the user's notes.

        - Cite sources inline as [1], [2] matching the numbered excerpts.
        - If the excerpts do not contain the answer, say so plainly rather than guessing.
        - Be concise and concrete. Do not repeat the question back.
        """
}
