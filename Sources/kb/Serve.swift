import ArgumentParser
import Foundation
import KnowledgeBaseKit
import KnowledgeBaseKitMCP
import MCP

/// Runs the MCP server standalone over stdio.
///
/// The intended deployment is in-process inside a host app, over
/// `StatefulHTTPServerTransport` — see ``MCPHTTPHost``. That transport is framework-agnostic
/// and does not own a socket, so serving it from a CLI would mean bringing in a web server
/// this package otherwise has no use for. Stdio is what agent clients spawn anyway, so this
/// command uses it.
///
/// The store is opened read-only, so this can run alongside a host app or an indexing
/// `kb sync` without competing for the write lock.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Serve the knowledge base to agents over MCP (stdio).",
        discussion: """
            Exposes search, answering, and graph lookup as MCP tools. Opens the store \
            read-only, so it can run while a host app or `kb sync` is indexing.

            Register it with an MCP client as: kb serve --root /path/to/vault

            To serve over HTTP instead, host MCPHTTPHost from KnowledgeBaseKitMCP inside \
            your app's own HTTP stack.
            """
    )

    @OptionGroup var common: CommonOptions

    @Option(
        name: .long,
        help: """
            Which tools to expose: 'all', 'retrieval' (no local generation), 'graph', or a \
            comma-separated list of search,answer,lookup,traverse.
            """
    )
    var tools: String = "all"

    func run() async throws {
        guard let requested = MCPTools.parse(tools) else {
            throw ValidationError(
                "Unrecognized --tools value '\(tools)'. Use all, retrieval, graph, or a list of "
                    + "search,answer,lookup,traverse."
            )
        }

        var options = common
        options.readOnly = true
        let store = try options.makeStore()
        defer { Task { await store.close() } }

        // Graph tools are dropped when the store is not building a graph, so an agent never
        // discovers them by watching them return nothing.
        let exposed = MCPTools.supported(by: store.configuration, requested: requested)
        guard !exposed.isEmpty else {
            throw ValidationError("No tools left to expose. Check --tools and --no-graph.")
        }

        let server = KnowledgeBaseMCPServer(store: store, tools: exposed)
        // stdout is the protocol channel, so any diagnostics must go to stderr.
        printError(
            "knowledge-base MCP server ready (read-only) on stdio. "
                + "Tools: \(exposed.names.joined(separator: ", "))"
        )

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
