import Foundation
import GRDB

// MARK: - Keyword

/// The FTS5 arm.
public enum KeywordArm {

    /// Turns a natural-language question into an FTS5 MATCH expression.
    ///
    /// User text cannot go into MATCH directly: bare `AND`, `OR`, `NEAR`, `*`, `:`, `"` and
    /// `-` are query operators, and a stray one is a syntax error rather than a poor result.
    /// Terms are therefore extracted and re-quoted.
    ///
    /// They are joined with `OR` rather than the FTS5 default of `AND`, because a question
    /// phrased in prose contains words the document never uses, and requiring all of them
    /// would return nothing. BM25 still ranks a chunk matching more (and rarer) terms above
    /// one matching a single common word.
    public static func makeMatchExpression(from query: String) -> String? {
        let terms =
            query
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 && !stopWords.contains($0) }

        // Everything was a stop word — fall back to the raw tokens rather than returning
        // nothing, so a query like "how to" still searches for something.
        let usable =
            terms.isEmpty
            ? query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            : terms

        guard !usable.isEmpty else { return nil }

        var seen = Set<String>()
        let quoted = usable.filter { seen.insert($0).inserted }.map { "\"\($0)\"" }
        return quoted.joined(separator: " OR ")
    }

    public static func search(
        query: String,
        limit: Int,
        in db: Database
    ) throws -> [ChunkID] {
        guard let expression = makeMatchExpression(from: query) else { return [] }

        // bm25() returns a negative score where more negative is better, so ascending order
        // is best-first. The column weights favour a heading match over a body match.
        return try String.fetchAll(
            db,
            sql: """
                SELECT chunk_id FROM chunks_fts
                 WHERE chunks_fts MATCH ?
                 ORDER BY bm25(chunks_fts, 0.0, 2.0, 1.0)
                 LIMIT ?
                """,
            arguments: [expression, limit]
        ).map(ChunkID.init(rawValue:))
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can", "her", "was", "one",
        "our", "out", "his", "has", "how", "its", "who", "did", "does", "why", "what", "when",
        "where", "which", "with", "that", "this", "from", "have", "been", "were", "they",
        "would", "there", "their", "about", "into", "than", "then", "them", "these", "those",
        "will", "your", "some", "such", "only", "other", "more", "most", "much", "very",
    ]
}

// MARK: - Vector

/// The sqlite-vec arm.
public enum VectorArm {
    public static func search(
        embedding: [Float],
        limit: Int,
        in db: Database
    ) throws -> [ChunkID] {
        try VectorIndex.nearestChunks(in: db, to: embedding, limit: limit).map(\.chunkID)
    }
}

// MARK: - Graph

/// The knowledge-graph arm.
///
/// Entities are seeded two ways and unioned:
/// 1. **Name matching** — normalized n-grams of the query against canonical names and aliases.
/// 2. **Retrieval seeding** — mentions of the top-ranked keyword and vector hits.
///
/// The first finds things the query names outright; the second reaches concepts the query
/// never mentions literally. Deliberately, **no model runs here**: query-side entity
/// extraction would add an Ollama round-trip to every search, make results non-deterministic,
/// and break this arm entirely in the offline fallback — exactly when retrieval matters most.
public enum GraphArm {

    public struct Seeds: Sendable {
        public var entityIDs: [EntityID]
        /// Canonical names that matched the query text, for citation.
        public var matchedNames: [String]
    }

    /// Stage one: entities the query names.
    ///
    /// Longer n-grams are tried first so "auth service" resolves as one entity rather than
    /// matching "service" on its own.
    public static func seedsFromQueryText(
        _ query: String,
        in db: Database,
        maximumNGram: Int = 4
    ) throws -> Seeds {
        let words = query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" })
            .map(String.init)
        guard !words.isEmpty else { return Seeds(entityIDs: [], matchedNames: []) }

        var found: [EntityID] = []
        var names: [String] = []
        var seen = Set<EntityID>()
        var consumed = Set<Int>()

        for length in stride(from: min(maximumNGram, words.count), through: 1, by: -1) {
            for start in 0...(words.count - length) {
                let indices = Set(start..<(start + length))
                // A word already claimed by a longer n-gram is not matched again.
                guard indices.isDisjoint(with: consumed) else { continue }

                let phrase = words[start..<(start + length)].joined(separator: " ")
                let normalized = NameNormalizer.normalizeForMatching(phrase)
                guard normalized.count > 1 else { continue }

                let matches = try GraphRepository.findByNormalizedName(normalized, in: db)
                guard !matches.isEmpty else { continue }

                consumed.formUnion(indices)
                for entity in matches where seen.insert(entity.id).inserted {
                    found.append(entity.id)
                    names.append(entity.canonicalName)
                }
            }
        }

        return Seeds(entityIDs: found, matchedNames: names)
    }

    /// Stage two: entities mentioned by the best hits from the other arms.
    public static func seedsFromChunks(
        _ chunkIDs: [ChunkID],
        in db: Database
    ) throws -> [EntityID] {
        try GraphRepository.entityIDs(mentionedIn: chunkIDs, in: db)
    }

    /// Expands outward and returns supporting chunks, best first.
    ///
    /// Ordering is by hop distance, then by the confidence of the relation that brought the
    /// chunk in — a directly-mentioned chunk outranks one reached through two inferences.
    public static func expand(
        seeds: [EntityID],
        hops: Int,
        limit: Int,
        in db: Database
    ) throws -> [ChunkID] {
        guard !seeds.isEmpty, hops > 0 else {
            return try Array(GraphRepository.chunkIDs(mentioning: seeds, in: db).prefix(limit))
        }

        var visited = Set(seeds)
        var frontier = seeds
        // chunk -> (hop it was first reached at, best confidence at that hop)
        var reached: [ChunkID: (hop: Int, confidence: Double)] = [:]

        for chunkID in try GraphRepository.chunkIDs(mentioning: seeds, in: db) {
            reached[chunkID] = (0, 1.0)
        }

        for hop in 1...hops {
            guard !frontier.isEmpty else { break }
            let relations = try GraphRepository.neighbors(of: frontier, in: db)
            var nextFrontier: [EntityID] = []

            for relation in relations {
                let existing = reached[relation.supportingChunkID]
                if existing == nil || hop < existing!.hop
                    || (hop == existing!.hop && relation.confidence > existing!.confidence)
                {
                    reached[relation.supportingChunkID] = (hop, relation.confidence)
                }

                for endpoint in [relation.sourceID, relation.targetID]
                where visited.insert(endpoint).inserted {
                    nextFrontier.append(endpoint)
                }
            }

            frontier = nextFrontier
        }

        return reached
            .sorted { lhs, rhs in
                if lhs.value.hop != rhs.value.hop { return lhs.value.hop < rhs.value.hop }
                if lhs.value.confidence != rhs.value.confidence {
                    return lhs.value.confidence > rhs.value.confidence
                }
                return lhs.key.rawValue < rhs.key.rawValue
            }
            .prefix(limit)
            .map(\.key)
    }
}
