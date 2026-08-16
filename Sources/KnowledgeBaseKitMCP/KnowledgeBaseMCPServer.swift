import Foundation
import KnowledgeBaseKit
import MCP
import OSLog

/// Exposes the knowledge base to agents over MCP.
///
/// Designed to be hosted **in-process by the host app** over `StatefulHTTPServerTransport`,
/// not spawned as a separate stdio process. That is what makes the concurrency model work:
/// the app already holds the write lock, and a separate server process could not take it. In
/// process, the server shares the app's store and needs no lock of its own, so an agent can
/// query the knowledge base while the app is indexing.
///
/// Every tool here is read-only. Ingestion is deliberately not exposed — an agent should not
/// be able to rewrite the user's index as a side effect of answering a question.
public actor KnowledgeBaseMCPServer {
    private let store: KnowledgeStore
    private let server: Server
    private let exposed: MCPTools
    private let logger = Logger(subsystem: "KnowledgeBaseKit", category: "mcp")

    public init(
        store: KnowledgeStore,
        tools: MCPTools = .all,
        name: String = "knowledge-base",
        version: String = "0.1.1"
    ) {
        self.store = store
        self.exposed = tools
        self.server = Server(
            name: name,
            version: version,
            capabilities: .init(tools: .init(listChanged: false))
        )
    }

    /// Registers handlers and starts serving on `transport`.
    public func start(transport: any Transport) async throws {
        await registerHandlers()
        try await server.start(transport: transport)
    }

    public func stop() async {
        await server.stop()
    }

    /// Waits until the server finishes, for a host that wants to block on it.
    public func waitUntilCompleted() async {
        await server.waitUntilCompleted()
    }

    /// The plain-text content case.
    ///
    /// Written out rather than using the `.text(_:)` convenience, which is deprecated in
    /// favour of the fuller case; neither annotations nor metadata are needed here.
    private static func textContent(_ text: String) -> Tool.Content {
        .text(text: text, annotations: nil, _meta: nil)
    }

    // MARK: - Tools

    private func registerHandlers() async {
        let exposed = self.exposed
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.tools(for: exposed))
        }

        await server.withMethodHandler(CallTool.self) { [weak self] parameters in
            guard let self else {
                return CallTool.Result(content: [Self.textContent("Server is shutting down.")], isError: true)
            }
            do {
                return try await self.call(name: parameters.name, arguments: parameters.arguments)
            } catch {
                // Errors are returned as tool results rather than thrown, so the agent sees a
                // readable failure instead of a dropped connection.
                return CallTool.Result(
                    content: [Self.textContent("Tool failed: \(error.localizedDescription)")],
                    isError: true
                )
            }
        }
    }

    static let allTools: [Tool] = [
        Tool(
            name: "search_knowledge_base",
            description: """
                Hybrid search over the user's Markdown notes, combining keyword, semantic, and \
                knowledge-graph retrieval. Returns ranked excerpts with their source files. \
                Use this to find relevant material; use answer_question when you want prose.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object([
                        "type": .string("string"),
                        "description": .string("What to search for."),
                    ]),
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum results. Defaults to 8."),
                    ]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Only match documents carrying all of these tags."),
                    ]),
                ]),
                "required": .array([.string("query")]),
            ])
        ),
        Tool(
            name: "answer_question",
            description: """
                Answer a question using the user's notes, returning prose with numbered \
                citations. Requires a reachable local model; use search_knowledge_base if you \
                only need the source material.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "question": .object([
                        "type": .string("string"),
                        "description": .string("The question to answer."),
                    ])
                ]),
                "required": .array([.string("question")]),
            ])
        ),
        Tool(
            name: "lookup_entity",
            description: """
                Look up a component, person, concept, or other entity in the knowledge graph \
                extracted from the notes. Returns its canonical name, known aliases, and how \
                often it is mentioned.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "name": .object([
                        "type": .string("string"),
                        "description": .string("Entity name or alias."),
                    ])
                ]),
                "required": .array([.string("name")]),
            ])
        ),
        Tool(
            name: "traverse_graph",
            description: """
                Explore what an entity is connected to in the knowledge graph — what it uses, \
                depends on, or is part of — along with the note excerpts that support each \
                relation.
                """,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "entity": .object([
                        "type": .string("string"),
                        "description": .string("Entity name or alias to start from."),
                    ]),
                    "hops": .object([
                        "type": .string("integer"),
                        "description": .string("How far to expand, 1 or 2. Defaults to 1."),
                    ]),
                ]),
                "required": .array([.string("entity")]),
            ])
        ),
    ]

    /// Maps each tool name onto the capability that gates it.
    static let gating: [String: MCPTools] = [
        "search_knowledge_base": .search,
        "answer_question": .answer,
        "lookup_entity": .entityLookup,
        "traverse_graph": .graphTraversal,
    ]

    /// The tool definitions an exposed set advertises.
    public static func tools(for exposed: MCPTools) -> [Tool] {
        allTools.filter { tool in
            guard let required = gating[tool.name] else { return false }
            return exposed.contains(required)
        }
    }

    private func call(name: String, arguments: [String: Value]?) async throws -> CallTool.Result {
        // A client that ignores tools/list and calls a withheld tool anyway is refused here
        // too, so the exposed set is an actual boundary rather than a listing hint.
        guard let required = Self.gating[name], exposed.contains(required) else {
            return CallTool.Result(
                content: [Self.textContent("Unknown tool: \(name)")],
                isError: true
            )
        }

        switch name {
        case "search_knowledge_base":
            return try await search(arguments)
        case "answer_question":
            return try await answer(arguments)
        case "lookup_entity":
            return try await lookupEntity(arguments)
        case "traverse_graph":
            return try await traverse(arguments)
        default:
            return CallTool.Result(content: [Self.textContent("Unknown tool: \(name)")], isError: true)
        }
    }

    // MARK: - Implementations

    private func search(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return CallTool.Result(content: [Self.textContent("Missing required argument: query")], isError: true)
        }
        let limit = arguments?["limit"]?.intValue ?? 8
        let tags = arguments?["tags"]?.arrayValue?.compactMap(\.stringValue) ?? []

        let response = try await store.search(
            query,
            options: SearchOptions(limit: max(1, min(limit, 50)), requiredTags: tags)
        )

        var output = ""
        // Degradation is reported to the agent, not hidden: a thin answer for a known reason
        // is very different from a thin answer because nothing matched.
        for degradation in response.degradations {
            output += "Note: \(degradation.message)\n"
        }

        guard !response.results.isEmpty else {
            output += "No matches in the knowledge base."
            return CallTool.Result(content: [Self.textContent(output)])
        }

        for (index, result) in response.results.enumerated() {
            output += "\n[\(index + 1)] \(result.citation)\n"
            if !result.matchedEntities.isEmpty {
                output += "Entities: \(result.matchedEntities.joined(separator: ", "))\n"
            }
            output += result.content + "\n"
        }

        return CallTool.Result(content: [Self.textContent(output)])
    }

    private func answer(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let question = arguments?["question"]?.stringValue, !question.isEmpty else {
            return CallTool.Result(content: [Self.textContent("Missing required argument: question")], isError: true)
        }

        // Buffered rather than streamed: an MCP tool result is a single value.
        let stream = try await store.answer(question)
        let answer = try await stream.collected()

        var output = answer.text
        if !answer.citations.isEmpty {
            output += "\n\nSources:\n"
            for citation in answer.citations {
                output += "[\(citation.index)] \(citation.label)\n"
            }
        }
        return CallTool.Result(content: [Self.textContent(output)])
    }

    private func lookupEntity(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
            return CallTool.Result(content: [Self.textContent("Missing required argument: name")], isError: true)
        }

        let details = try await store.lookupEntity(named: name)
        guard !details.isEmpty else {
            return CallTool.Result(content: [Self.textContent("No entity named '\(name)' in the knowledge graph.")])
        }

        var output = ""
        for detail in details {
            output += "\(detail.entity.canonicalName) (\(detail.entity.type))\n"
            if !detail.aliases.isEmpty {
                output += "  aliases: \(detail.aliases.joined(separator: ", "))\n"
            }
            output += "  mentioned in \(detail.mentionCount) chunk(s)\n"
        }
        return CallTool.Result(content: [Self.textContent(output)])
    }

    private func traverse(_ arguments: [String: Value]?) async throws -> CallTool.Result {
        guard let entity = arguments?["entity"]?.stringValue, !entity.isEmpty else {
            return CallTool.Result(content: [Self.textContent("Missing required argument: entity")], isError: true)
        }
        let hops = min(max(arguments?["hops"]?.intValue ?? 1, 1), 2)

        let neighborhoods = try await store.traverse(from: entity, hops: hops)
        guard !neighborhoods.isEmpty else {
            return CallTool.Result(content: [Self.textContent("No entity named '\(entity)' in the knowledge graph.")])
        }

        var output = ""
        for neighborhood in neighborhoods {
            let byID = Dictionary(
                uniqueKeysWithValues: neighborhood.entities.map { ($0.id, $0) }
            )
            output += "\(neighborhood.origin.canonicalName) (\(neighborhood.origin.type))\n"

            if neighborhood.relations.isEmpty {
                output += "  no relations recorded\n"
            }
            for relation in neighborhood.relations {
                let isOutgoing = relation.sourceID == neighborhood.origin.id
                let otherID = isOutgoing ? relation.targetID : relation.sourceID
                let other = byID[otherID]?.canonicalName ?? "(unknown)"
                let arrow = isOutgoing ? "->" : "<-"
                output += "  \(arrow) \(relation.type) \(arrow == "->" ? "" : "from ")\(other)"
                output += " (confidence \(String(format: "%.2f", relation.confidence)))\n"
            }

            if !neighborhood.supportingChunks.isEmpty {
                output += "\nSupporting excerpts:\n"
                for chunk in neighborhood.supportingChunks.prefix(5) {
                    output += "  \(chunk.citation)\n  \(chunk.content)\n\n"
                }
            }
        }
        return CallTool.Result(content: [Self.textContent(output)])
    }
}
