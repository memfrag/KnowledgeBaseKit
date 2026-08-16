import Foundation

/// The closed set of entity and relation types the extraction model may emit.
///
/// A closed vocabulary is what makes traversal predictable. An open one yields `uses`,
/// `utilizes`, and `depends on` as three unrelated relation types, so a 2-hop expansion
/// depends on whichever synonym the model happened to pick that run.
///
/// The vocabulary is part of the extraction version key: replacing it re-extracts the
/// corpus.
public struct GraphVocabulary: Sendable, Hashable, Codable {
    public var entityTypes: [String]
    public var relationTypes: [String]

    public init(entityTypes: [String], relationTypes: [String]) {
        self.entityTypes = entityTypes
        self.relationTypes = relationTypes
    }

    public static let `default` = GraphVocabulary(
        entityTypes: [
            "Component",
            "Person",
            "Concept",
            "Technology",
            "Project",
            "Document",
        ],
        relationTypes: [
            "uses",
            "depends-on",
            "part-of",
            "authored-by",
            "related-to",
            "contradicts",
        ]
    )

    public func isValidEntityType(_ type: String) -> Bool {
        entityTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    public func isValidRelationType(_ type: String) -> Bool {
        relationTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    /// Maps a model-supplied type onto its canonical spelling, or nil if out of vocabulary.
    ///
    /// Case is normalized rather than rejected: an out-of-vocabulary *word* is a real
    /// extraction error worth retrying, but `Component` vs `component` is not.
    public func canonicalEntityType(_ type: String) -> String? {
        entityTypes.first { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    public func canonicalRelationType(_ type: String) -> String? {
        relationTypes.first { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    /// Stable fingerprint used as the vocabulary half of the extraction version key.
    /// Order-insensitive, so reordering the lists does not trigger a re-extraction.
    public var fingerprint: String {
        let entities = entityTypes.map { $0.lowercased() }.sorted().joined(separator: ",")
        let relations = relationTypes.map { $0.lowercased() }.sorted().joined(separator: ",")
        return ContentHash.of("entities:\(entities)|relations:\(relations)").prefix(16).description
    }
}
