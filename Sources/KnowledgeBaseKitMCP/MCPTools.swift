import Foundation
import KnowledgeBaseKit

/// Which tools a server exposes.
///
/// Worth narrowing rather than always serving everything, because a tool an agent should not
/// use is better absent than merely discouraged. Two cases in particular:
///
/// - **A capable agent client** (Claude Code and the like) writes better prose than a local
///   7B model does. Exposing `answer_question` there invites it to route a question through
///   a weaker model and read the result second-hand. Retrieval is what it actually wants.
/// - **A store built without the graph** (`graphExtraction: false`) has nothing behind
///   `lookup_entity` or `traverse_graph`. Advertising them means an agent spends calls
///   discovering they always return nothing.
public struct MCPTools: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Hybrid search returning ranked excerpts with citations.
    public static let search = MCPTools(rawValue: 1 << 0)
    /// Locally generated prose with citations.
    public static let answer = MCPTools(rawValue: 1 << 1)
    /// Entity lookup by name or alias.
    public static let entityLookup = MCPTools(rawValue: 1 << 2)
    /// Graph traversal from an entity.
    public static let graphTraversal = MCPTools(rawValue: 1 << 3)

    public static let all: MCPTools = [.search, .answer, .entityLookup, .graphTraversal]
    /// Everything the graph backs.
    public static let graph: MCPTools = [.entityLookup, .graphTraversal]
    /// Retrieval only — no local generation. The sensible set for an agent that reasons over
    /// the excerpts itself.
    public static let retrieval: MCPTools = [.search, .entityLookup, .graphTraversal]

    /// The set that makes sense for a given store.
    ///
    /// Drops the graph tools when the store is not building a graph, so a configuration can
    /// be described once and the tool surface follows from it.
    public static func supported(
        by configuration: KnowledgeStoreConfiguration,
        requested: MCPTools = .all
    ) -> MCPTools {
        configuration.graphExtraction ? requested : requested.subtracting(.graph)
    }

    /// Parses a comma-separated list such as `search,answer` or a preset name.
    public static func parse(_ text: String) -> MCPTools? {
        let normalized = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "all": return .all
        case "retrieval": return .retrieval
        case "graph": return .graph
        default: break
        }

        var result: MCPTools = []
        for name in normalized.split(separator: ",") {
            switch name.trimmingCharacters(in: .whitespaces) {
            case "search": result.insert(.search)
            case "answer": result.insert(.answer)
            case "lookup", "entity": result.insert(.entityLookup)
            case "traverse", "graph": result.insert(.graphTraversal)
            default: return nil
            }
        }
        return result.isEmpty ? nil : result
    }

    public var names: [String] {
        var result: [String] = []
        if contains(.search) { result.append("search") }
        if contains(.answer) { result.append("answer") }
        if contains(.entityLookup) { result.append("lookup") }
        if contains(.graphTraversal) { result.append("traverse") }
        return result
    }
}
