# ``KnowledgeBaseKitMCP``

Expose a knowledge base to agents over the Model Context Protocol.

## Overview

Four read-only tools sit on top of a `KnowledgeStore` from KnowledgeBaseKit: hybrid
search, locally generated answers, entity lookup, and graph traversal. Ingestion
is deliberately not exposed — an agent should not be able to rewrite the user's
index as a side effect of answering a question.

### Hosting in an app

The intended deployment is **in-process inside a host app**, via
``MCPHTTPHost``. That matters for the concurrency model: the app already holds
the database write lock, and a separate server process could not take it. Sharing
the app's store means the server needs no lock of its own, so an agent can query
while the app is indexing.

`StatefulHTTPServerTransport` is framework-agnostic — it turns an `HTTPRequest`
into an `HTTPResponse` and does not own a socket — so the host app brings
whatever HTTP server it already has.

```swift
let host = try await MCPHTTPHost(store: store)

// In the app's HTTP route handler:
let response = await host.handle(request)
```

### Serving over stdio

When there is no host app, `kb serve` runs ``KnowledgeBaseMCPServer`` on
`StdioTransport`, which is how agent clients spawn MCP servers anyway. It opens
the store read-only, so it can run alongside an indexing `kb sync`.

### Choosing which tools to expose

``MCPTools`` narrows the surface, because a tool an agent should not use is
better absent than merely discouraged.

A client that can already write prose — Claude Code, say — gains nothing from
`answer_question`, which would route the question through a smaller local model
and hand back the result second-hand. ``MCPTools/retrieval`` drops it and keeps
the rest.

``MCPTools/supported(by:requested:)`` also drops the graph tools when the store
is not building a graph, so an agent never discovers them by watching them
return nothing.

## Topics

### Serving

- ``KnowledgeBaseMCPServer``
- ``MCPHTTPHost``

### Choosing tools

- ``MCPTools``
