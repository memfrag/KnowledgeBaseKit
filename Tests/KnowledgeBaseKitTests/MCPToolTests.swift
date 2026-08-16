import Foundation
import KnowledgeBaseKit
import KnowledgeBaseKitMCP
import Testing

@Suite("MCP tool set")
struct MCPToolSetTests {
    @Test("Presets and lists parse")
    func parsing() throws {
        #expect(MCPTools.parse("all") == .all)
        #expect(MCPTools.parse("retrieval") == .retrieval)
        #expect(MCPTools.parse("search") == .search)
        #expect(MCPTools.parse("search,answer") == [.search, .answer])
        #expect(MCPTools.parse("lookup, traverse") == [.entityLookup, .graphTraversal])
        #expect(MCPTools.parse("nonsense") == nil)
        #expect(MCPTools.parse("") == nil)
    }

    @Test("Retrieval preset omits local generation")
    func retrievalOmitsAnswer() {
        #expect(!MCPTools.retrieval.contains(.answer))
        #expect(MCPTools.retrieval.contains(.search))
    }

    @Test("Graph tools are dropped when the store does not build a graph")
    func graphToolsFollowConfiguration() {
        var configuration = KnowledgeStoreConfiguration()
        configuration.graphExtraction = false

        let supported = MCPTools.supported(by: configuration, requested: .all)
        #expect(supported.contains(.search))
        #expect(supported.contains(.answer))
        // Advertising these would make an agent spend calls discovering they return nothing.
        #expect(!supported.contains(.entityLookup))
        #expect(!supported.contains(.graphTraversal))

        configuration.graphExtraction = true
        #expect(MCPTools.supported(by: configuration, requested: .all) == .all)
    }

    @Test("Only exposed tools are listed")
    func listingIsFiltered() {
        let names = KnowledgeBaseMCPServer.tools(for: .retrieval).map(\.name)
        #expect(names.contains("search_knowledge_base"))
        #expect(names.contains("lookup_entity"))
        #expect(!names.contains("answer_question"))

        let searchOnly = KnowledgeBaseMCPServer.tools(for: .search).map(\.name)
        #expect(searchOnly == ["search_knowledge_base"])
    }
}
