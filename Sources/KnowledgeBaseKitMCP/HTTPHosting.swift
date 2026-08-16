import Foundation
import KnowledgeBaseKit
import MCP

/// Hosts the MCP server on `StatefulHTTPServerTransport` inside an app's HTTP stack.
///
/// `StatefulHTTPServerTransport` is framework-agnostic: it does not own a socket. The host
/// app brings its own HTTP server — whatever it already uses — and forwards each request
/// here, converting the returned `HTTPResponse` to its framework's own response type.
///
/// This is the deployment the concurrency model is designed around. The app holds the
/// database write lock; a separate server *process* could not take it. Running in-process,
/// the server shares the app's `KnowledgeStore` and needs no lock of its own, so agents can
/// query while the app indexes.
///
/// ```swift
/// let host = try await MCPHTTPHost(store: store)
///
/// // In the app's HTTP route handler:
/// let mcpResponse = await host.handle(request)
/// ```
public actor MCPHTTPHost {
    public let server: KnowledgeBaseMCPServer
    private let transport: StatefulHTTPServerTransport

    public init(
        store: KnowledgeStore,
        tools: MCPTools = .all,
        name: String = "knowledge-base",
        version: String = "0.1.0"
    ) async throws {
        self.transport = StatefulHTTPServerTransport()
        self.server = KnowledgeBaseMCPServer(
            store: store,
            tools: MCPTools.supported(by: store.configuration, requested: tools),
            name: name,
            version: version
        )
        try await server.start(transport: transport)
    }

    /// Handles one MCP HTTP request. Safe to call concurrently.
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        await transport.handleRequest(request)
    }

    public func stop() async {
        await server.stop()
    }
}
