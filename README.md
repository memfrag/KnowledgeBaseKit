# KnowledgeBaseKit

A Swift package for macOS that builds and maintains a local knowledge base from
Markdown files. Markdown is the source of truth, SQLite is the only datastore,
and Ollama does all the AI work. Nothing leaves the machine.

Retrieval is hybrid: FTS5 keyword search, sqlite-vec semantic search, and a
knowledge graph extracted from the notes, fused by Reciprocal Rank Fusion.

## Requirements

- macOS 26+, Swift 6.3
- [Ollama](https://ollama.com) running locally, with two models:

```sh
ollama pull embeddinggemma   # embedding, 768 dimensions
ollama pull qwen2.5:7b       # extraction and answering
```

No custom SQLite build is needed. sqlite-vec is compiled into the package and
registered per connection; the system SQLite already has FTS5.

## Quick start

```sh
swift build -c release

kb sync   --root ~/Notes          # index the vault
kb watch  --root ~/Notes          # index, then follow changes
kb search --root ~/Notes "how does authentication work"
kb answer --root ~/Notes "how does authentication work"
kb status --root ~/Notes
```

The database defaults to `<root>/.kb/store.sqlite` — inside the vault, in a
dot-directory the scanner ignores, so the store never indexes itself.

Settings can live in `.kb.json` at the corpus root so they travel with the vault:

```json
{
  "ignore": ["Archive", "*.draft.md"],
  "embeddingModel": "embeddinggemma",
  "embeddingDimensions": 768,
  "extractionModel": "qwen2.5:7b"
}
```

## Library use

```swift
import KnowledgeBaseKit

let store = try KnowledgeStore(
    databaseURL: url,
    configuration: KnowledgeStoreConfiguration(corpusRoots: [vaultURL])
)

try await store.sync()          // reconcile the corpus
await store.startProcessing()   // drain embedding/extraction in the background
await store.startWatching()     // re-index on filesystem changes

// Ranked chunks with citations. Deterministic, and works with Ollama offline.
let results = try await store.search("How does authentication work?")

// Generated prose with citations resolved before the first token arrives.
let stream = try await store.answer("How does authentication work?")
for citation in stream.citations { print(citation.label) }
for try await token in stream.tokens { print(token, terminator: "") }
```

`add(url:)`, `update(url:)`, and `remove(url:)` remain available for driving
ingestion file by file.

## How it behaves

- **Ingestion is incremental.** Chunk IDs derive from `document + heading path +
occurrence`, not from content, so editing a section's prose keeps its identity and
re-embeds only that chunk. On a real vault, adding one section to an indexed
document costs ~2s against ~2min for the initial index.

- **Renames are free.** `sync()` pairs a vanished path with a new path of identical
content and rewrites one column. Chunks, embeddings, and the graph all survive,
and nothing is queued.

- **The store is queryable before the models catch up.** Chunks and the keyword
index are written synchronously; embedding and extraction run on a durable job
queue behind them.

- **Ollama being offline is not a failure.** Ingestion still completes, jobs stay
queued and retry, and `search()` degrades to keyword-only while saying so in its
result. `answer()` does throw — generation without a model has no fallback.

- **The graph mirrors the corpus.** Entities and relations are reference-counted:
when the last chunk supporting a fact is deleted, the fact goes with it.

- **One writer, many readers.** WAL plus an advisory lock: a second *writer* is
refused and told who holds the lock, while readers are unlimited. This is what
lets the MCP server answer while the app indexes.

## MCP

The MCP server is designed to run **in-process in a host app** via
`StatefulHTTPServerTransport`, which is framework-agnostic — your app brings its
own HTTP server:

```swift
import KnowledgeBaseKitMCP

let host = try await MCPHTTPHost(store: store)
// In your HTTP route handler:
let response = await host.handle(request)
```

When there is no host app, `kb serve` exposes the same tools over stdio and opens
the store read-only, so it can run alongside an indexing `kb sync`:

```sh
kb serve --root ~/Notes
```

Tools: `search_knowledge_base`, `answer_question`, `lookup_entity`,
`traverse_graph`. All read-only — ingestion is deliberately not exposed to agents.

## Testing

```sh
swift test
```

The suite needs no Ollama. `DeterministicEmbeddingProvider`, 
`FixtureExtractionProvider`, and `FixtureGenerationProvider` ship in the library,
so the parser, chunker, differ, job queue, graph collection, and fusion are all
exercisable — and so you can test your own integration without a model running.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/CSQLiteVec` | Vendored sqlite-vec, compiled in |
| `Sources/KnowledgeBaseKit/Core` | Identity, models, configuration, errors |
| `Sources/KnowledgeBaseKit/Markdown` | Front matter, parsing, chunking |
| `Sources/KnowledgeBaseKit/Storage` | Database, schema, repositories, lock, versioning |
| `Sources/KnowledgeBaseKit/Providers` | Ollama clients and deterministic doubles |
| `Sources/KnowledgeBaseKit/Pipeline` | Incremental ingestion and job workers |
| `Sources/KnowledgeBaseKit/Graph` | Vocabulary and entity resolution |
| `Sources/KnowledgeBaseKit/Retrieval` | Arms, fusion, search, answering |
| `Sources/KnowledgeBaseKit/Corpus` | Scanning, ignore rules, FSEvents watcher |
| `Sources/KnowledgeBaseKitMCP` | MCP server and HTTP hosting |
| `Sources/kb` | The CLI |

## License

KnowledgeBaseKit is released under the [Zero-Clause BSD](LICENSE) licence (0BSD):
use it for anything, no attribution required.

Third-party code is catalogued in **[ATTRIBUTIONS.md](ATTRIBUTIONS.md)** —
vendored source, direct and transitive dependencies, their licences and
copyright holders, and the NOTICE files Apache-2.0 requires be carried forward.
If you distribute a built binary of `kb` or an app linking this package, ship
that file with it.

One exception below is not mine to relicense. `Sources/CSQLiteVec/sqlite-vec.c`
and `sqlite-vec.h` are vendored from [sqlite-vec](https://github.com/asg017/sqlite-vec)
(v0.1.9, Copyright 2024 Alex Garcia) and remain under **Apache-2.0** — see
[`Sources/CSQLiteVec/LICENSE-sqlite-vec.txt`](Sources/CSQLiteVec/LICENSE-sqlite-vec.txt).
Redistributing this repository redistributes that file, so keep its licence with it.

Dependencies resolved by SwiftPM rather than vendored, for reference:

- GRDB.swift (MIT)
- swift-markdown (Apache-2.0)
- Yams (MIT)
- swift-argument-parser (Apache-2.0)
- MCP Swift SDK

Dependencies are pinned deliberately, in two layers, primarily as supply-chain
hardening.

`Package.swift` uses `exact:` rather than `from:`. A `from:` range authorizes
SwiftPM to pull any later minor or patch release automatically, so a compromised
upstream publish enters the build with no review and no diff. `exact:` means
every version bump is a commit somebody has to make on purpose.

`Package.resolved` is committed as well, and for security it is the stronger of
the two. `exact:` resolves a *tag*, and a git tag is mutable — an attacker who
can force-push a tag can change what `7.11.1` points at. `Package.resolved`
records the commit **revision**, which is not forgeable that way. It also pins
the transitive graph (swift-nio, swift-collections, and friends), which direct
pins do not reach at all, and its `originHash` detects tampering with the
dependency declarations themselves.

Two limits:

- **Downstream consumers are not protected.** SwiftPM ignores a dependency's
  `Package.resolved`, so a package that depends on KnowledgeBaseKit resolves the
  transitive graph itself. These pins secure builds *of this repository*.
- **The branch dependency is the soft spot.** swift-markdown publishes no
  semantic-version tags, so it can only be depended on by branch
  (`release/6.3`), and swift-cmark follows on `gfm`. A branch tip moves whenever
  upstream pushes. Only the revision in `Package.resolved` fixes those.

The vendored sqlite-vec is in the strongest position of anything here: the
source is in-tree and verified byte-identical to the upstream v0.1.9
amalgamation, so there is no fetch to intercept.

The cost of `exact:` is resolver rigidity — a downstream package needing a
different GRDB fails to resolve rather than negotiating a compatible version.
That is the intended trade. Run `swift package update` to move the pins
deliberately, and review the diff when you do.
