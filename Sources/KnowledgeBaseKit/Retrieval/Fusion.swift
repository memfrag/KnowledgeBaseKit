import Foundation

/// Reciprocal Rank Fusion.
///
/// Each arm contributes `weight / (k + rank)` per chunk, summed across arms.
///
/// Fusion operates on ranks rather than scores because BM25 magnitudes and vector distances
/// are not on comparable scales. Normalizing them to 0–1 would make the outcome depend on the
/// composition of each candidate set — a query where the vector arm returns uniformly
/// mediocre matches would see those matches stretched to fill the whole range and outvote a
/// keyword arm that found something genuinely good. Rank-based fusion has no such failure
/// mode and needs no per-corpus tuning.
public struct ReciprocalRankFusion: Sendable {
    public let configuration: FusionConfiguration

    public init(configuration: FusionConfiguration = .default) {
        self.configuration = configuration
    }

    public struct Ranked: Sendable, Hashable {
        public var chunkID: ChunkID
        public var score: Double
        public var ranks: [RetrievalArm: Int]
    }

    /// - Parameter lists: candidates per arm, already in that arm's preferred order.
    public func fuse(_ lists: [RetrievalArm: [ChunkID]]) -> [Ranked] {
        var scores: [ChunkID: Double] = [:]
        var ranks: [ChunkID: [RetrievalArm: Int]] = [:]

        for (arm, candidates) in lists {
            let weight = weight(for: arm)
            guard weight > 0 else { continue }

            for (index, chunkID) in candidates.enumerated() {
                let rank = index + 1
                scores[chunkID, default: 0] += weight / (configuration.k + Double(rank))
                // A chunk can appear only once per arm; keep its best rank if a caller ever
                // passes duplicates.
                let existing = ranks[chunkID, default: [:]][arm]
                if existing == nil || rank < existing! {
                    ranks[chunkID, default: [:]][arm] = rank
                }
            }
        }

        return scores
            .map { Ranked(chunkID: $0.key, score: $0.value, ranks: ranks[$0.key] ?? [:]) }
            .sorted {
                // Ties broken by ID so ordering is stable across runs rather than following
                // dictionary iteration order.
                $0.score == $1.score ? $0.chunkID.rawValue < $1.chunkID.rawValue : $0.score > $1.score
            }
    }

    private func weight(for arm: RetrievalArm) -> Double {
        switch arm {
        case .keyword: configuration.keywordWeight
        case .vector: configuration.vectorWeight
        case .graph: configuration.graphWeight
        }
    }
}
