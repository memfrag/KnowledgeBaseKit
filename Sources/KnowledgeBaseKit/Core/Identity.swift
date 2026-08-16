import CryptoKit
import Foundation

/// A namespaced, deterministic identifier.
///
/// All identifiers in the store are derived by hashing a canonical string form, so that
/// re-indexing the same corpus from scratch reproduces exactly the same IDs. Nothing in
/// the database depends on insertion order or on a random generator.
public protocol StableIdentifier: Hashable, Sendable, Codable, CustomStringConvertible {
    var rawValue: String { get }
    init(rawValue: String)
}

extension StableIdentifier {
    public var description: String { rawValue }

    /// Truncated SHA-256, hex encoded. 128 bits is far beyond collision range for a corpus
    /// of the size this package targets, and keeps IDs short enough to read in a log.
    static func digest(_ components: String...) -> String {
        digest(components)
    }

    static func digest(_ components: [String]) -> String {
        // Components are joined with a delimiter that cannot occur in the inputs after
        // normalization, so ("a", "bc") and ("ab", "c") can never collide.
        let canonical = components.joined(separator: "\u{1F}")
        let hash = SHA256.hash(data: Data(canonical.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// Identifies a document by its corpus-relative path.
///
/// Path-derived identity means a rename would ordinarily read as a delete plus an insert.
/// ``CorpusScanner`` recovers from that with content-hash rename detection, pairing a
/// vanished path with a new one of identical content and rewriting the row in place.
public struct DocumentID: StableIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(relativePath: String) {
        self.rawValue = Self.digest("document", relativePath)
    }
}

/// Identifies a chunk by its position in the document's heading structure.
///
/// Deliberately *not* derived from content: editing a section's prose keeps the ID, so the
/// chunk is re-embedded in place and its mentions and relations keep pointing at a live
/// row. Renaming a heading does mint a new ID, which retires the old chunk and cascades a
/// re-embed and re-extract of that section.
public struct ChunkID: StableIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(document: DocumentID, headingPath: HeadingPath, occurrence: Int) {
        self.rawValue = Self.digest(
            "chunk",
            document.rawValue,
            headingPath.canonicalForm,
            String(occurrence)
        )
    }
}

/// Identifies an entity by its type and normalized canonical name.
///
/// Two documents naming the same thing therefore resolve to the same row without any
/// coordination between them.
public struct EntityID: StableIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(type: String, canonicalName: String) {
        self.rawValue = Self.digest("entity", type, NameNormalizer.normalize(canonicalName))
    }
}

/// Identifies a relation by its full triple plus the chunk that supports it.
///
/// Including the supporting chunk means the same claim asserted by three chunks is three
/// rows. That is what lets ``GraphGarbageCollector`` delete a fact when its last supporting
/// chunk disappears without erasing it while other chunks still assert it.
public struct RelationID: StableIdentifier {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(source: EntityID, type: String, target: EntityID, supportingChunk: ChunkID) {
        self.rawValue = Self.digest(
            "relation",
            source.rawValue,
            type,
            target.rawValue,
            supportingChunk.rawValue
        )
    }
}

/// The chain of headings leading to a chunk, starting with the document title.
public struct HeadingPath: Hashable, Sendable, Codable {
    public var components: [String]

    public init(_ components: [String] = []) {
        self.components = components
    }

    public var isEmpty: Bool { components.isEmpty }
    public var leaf: String? { components.last }

    /// Human-facing form, also used as the prefix of the embedded text.
    public var displayForm: String {
        components.joined(separator: " > ")
    }

    /// Case- and whitespace-normalized form used for ID derivation, so that fixing the
    /// capitalization of a heading does not retire every chunk beneath it.
    public var canonicalForm: String {
        components
            .map { NameNormalizer.normalize($0) }
            .joined(separator: "\u{1E}")
    }

    public func appending(_ component: String) -> HeadingPath {
        HeadingPath(components + [component])
    }

    /// Truncates to `depth` components, used when walking back up the heading stack.
    public func prefix(_ depth: Int) -> HeadingPath {
        HeadingPath(Array(components.prefix(depth)))
    }
}

extension HeadingPath: CustomStringConvertible {
    public var description: String { displayForm }
}

/// Content hashing, used to decide whether anything actually changed.
public enum ContentHash {
    public static func of(_ string: String) -> String {
        // Normalize line endings so a CRLF/LF conversion is not mistaken for an edit.
        let normalized = string.replacingOccurrences(of: "\r\n", with: "\n")
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public static func of(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared name normalization, used by entity resolution and by ID derivation.
///
/// Kept deliberately conservative: it folds only differences that are never semantic in
/// prose. Anything more aggressive belongs in ``EntityResolver``, where a wrong merge can
/// be caught by the similarity and adjudication stages.
public enum NameNormalizer {
    public static func normalize(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        // Collapse internal runs of whitespace, including newlines inside a wrapped heading.
        value = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Drop punctuation that varies freely in prose. Hyphens and slashes become spaces
        // rather than vanishing, so "read-only" and "read only" agree.
        value = value.map { character -> String in
            if character == "-" || character == "/" || character == "_" { return " " }
            if character.isPunctuation || character.isSymbol { return "" }
            return String(character)
        }.joined()
        value = value.split(separator: " ").joined(separator: " ")
        return value
    }

    /// Adds naive singularization on top of ``normalize(_:)``.
    ///
    /// Only used for entity resolution candidate matching, never for ID derivation — an ID
    /// must not depend on a heuristic this rough.
    public static func normalizeForMatching(_ name: String) -> String {
        let normalized = normalize(name)
        let words = normalized.split(separator: " ").map(singularize)
        return words.joined(separator: " ")
    }

    private static func singularize(_ word: Substring) -> String {
        let value = String(word)
        guard value.count > 3 else { return value }
        if value.hasSuffix("ies") { return String(value.dropLast(3)) + "y" }
        if value.hasSuffix("ses") || value.hasSuffix("xes") || value.hasSuffix("zes") {
            return String(value.dropLast(2))
        }
        if value.hasSuffix("s") && !value.hasSuffix("ss") && !value.hasSuffix("us") {
            return String(value.dropLast())
        }
        return value
    }
}
