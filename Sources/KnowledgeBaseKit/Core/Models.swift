import Foundation

// MARK: - Documents

/// A Markdown file as recorded in the store.
public struct Document: Hashable, Sendable, Codable {
    public var id: DocumentID
    /// Path relative to the corpus root that contains it. The absolute path is derived by
    /// resolving against the configured roots, so moving an entire vault does not
    /// invalidate the database.
    public var relativePath: String
    public var contentHash: String
    public var modifiedAt: Date
    public var metadata: DocumentMetadata

    public init(
        id: DocumentID,
        relativePath: String,
        contentHash: String,
        modifiedAt: Date,
        metadata: DocumentMetadata
    ) {
        self.id = id
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.modifiedAt = modifiedAt
        self.metadata = metadata
    }
}

/// Front matter, split into the fields the store understands and everything else.
public struct DocumentMetadata: Hashable, Sendable, Codable {
    /// Document title. Falls back to the first H1, then the filename stem.
    public var title: String?
    public var tags: [String]
    /// Alternate names for this document's title, seeded into the alias table.
    public var aliases: [String]
    /// Every other front matter key, preserved verbatim for callers.
    public var additional: [String: JSONValue]

    public init(
        title: String? = nil,
        tags: [String] = [],
        aliases: [String] = [],
        additional: [String: JSONValue] = [:]
    ) {
        self.title = title
        self.tags = tags
        self.aliases = aliases
        self.additional = additional
    }

    public static let empty = DocumentMetadata()
}

// MARK: - Chunks

/// A semantic slice of a document: one heading section, possibly subdivided.
public struct Chunk: Hashable, Sendable, Codable {
    public var id: ChunkID
    public var documentID: DocumentID
    /// Position within the document, in reading order. Used for ordering output, never for
    /// identity — see ``ChunkID``.
    public var ordinal: Int
    public var headingPath: HeadingPath
    public var content: String
    public var contentHash: String
    /// Which repetition of `headingPath` this is, within its document. Part of the ID.
    public var occurrence: Int

    public init(
        id: ChunkID,
        documentID: DocumentID,
        ordinal: Int,
        headingPath: HeadingPath,
        content: String,
        contentHash: String,
        occurrence: Int
    ) {
        self.id = id
        self.documentID = documentID
        self.ordinal = ordinal
        self.headingPath = headingPath
        self.content = content
        self.contentHash = contentHash
        self.occurrence = occurrence
    }

    /// The text handed to the embedding model.
    ///
    /// The heading path prefix gives an isolated section its context — a chunk headed only
    /// "Overview" would otherwise embed with no indication of what it is an overview of.
    public var embeddingInput: String {
        headingPath.isEmpty ? content : "\(headingPath.displayForm)\n\n\(content)"
    }
}

// MARK: - Graph

public struct Entity: Hashable, Sendable, Codable {
    public var id: EntityID
    public var type: String
    public var canonicalName: String

    public init(id: EntityID, type: String, canonicalName: String) {
        self.id = id
        self.type = type
        self.canonicalName = canonicalName
    }

    public init(type: String, canonicalName: String) {
        self.init(
            id: EntityID(type: type, canonicalName: canonicalName),
            type: type,
            canonicalName: canonicalName
        )
    }
}

public struct Alias: Hashable, Sendable, Codable {
    public var entityID: EntityID
    public var name: String
    /// Normalized form, the column actually matched against during resolution.
    public var normalizedName: String

    public init(entityID: EntityID, name: String) {
        self.entityID = entityID
        self.name = name
        self.normalizedName = NameNormalizer.normalizeForMatching(name)
    }
}

/// Who asserted a mention.
///
/// Provenance decides what a re-extraction may erase: the model's own output is replaced
/// wholesale each time a chunk is re-extracted, while a fact the document states in its front
/// matter survives, because nothing about the model's run makes it untrue.
public enum MentionSource: String, Hashable, Sendable, Codable {
    case extraction
    case frontMatter = "front_matter"
}

public struct Mention: Hashable, Sendable, Codable {
    public var entityID: EntityID
    public var chunkID: ChunkID
    /// The surface form as it appeared in the chunk, before resolution.
    public var surfaceForm: String
    public var source: MentionSource

    public init(
        entityID: EntityID,
        chunkID: ChunkID,
        surfaceForm: String,
        source: MentionSource = .extraction
    ) {
        self.entityID = entityID
        self.chunkID = chunkID
        self.surfaceForm = surfaceForm
        self.source = source
    }
}

public struct Relation: Hashable, Sendable, Codable {
    public var id: RelationID
    public var sourceID: EntityID
    public var type: String
    public var targetID: EntityID
    public var supportingChunkID: ChunkID
    public var confidence: Double

    public init(
        sourceID: EntityID,
        type: String,
        targetID: EntityID,
        supportingChunkID: ChunkID,
        confidence: Double
    ) {
        self.id = RelationID(
            source: sourceID,
            type: type,
            target: targetID,
            supportingChunk: supportingChunkID
        )
        self.sourceID = sourceID
        self.type = type
        self.targetID = targetID
        self.supportingChunkID = supportingChunkID
        self.confidence = confidence
    }
}

// MARK: - JSON

/// A minimal JSON value, used to preserve arbitrary front matter without erasing its shape.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrepresentable JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Best-effort conversion from the loosely typed values Yams produces.
    public init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let value as Bool:
            self = .bool(value)
        case let value as Int:
            self = .number(Double(value))
        case let value as Double:
            self = .number(value)
        case let value as String:
            self = .string(value)
        case let value as Date:
            self = .string(ISO8601DateFormatter().string(from: value))
        case let value as [Any]:
            self = .array(value.map { JSONValue(any: $0) })
        case let value as [String: Any]:
            self = .object(value.mapValues { JSONValue(any: $0) })
        case let value as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, element) in value {
                object[String(describing: key)] = JSONValue(any: element)
            }
            self = .object(object)
        default:
            self = .string(String(describing: value))
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Front matter fields like `tags` are written both as a list and as a bare string.
    /// Both spellings are accepted rather than silently dropping the scalar form.
    public var stringListValue: [String]? {
        switch self {
        case .string(let value):
            return [value]
        case .array(let values):
            return values.compactMap(\.stringValue)
        default:
            return nil
        }
    }
}
