# Local Knowledge Base Specification

## Overview

This project is a Swift package for macOS that builds and maintains a
local knowledge base from arbitrary Markdown files.

### Goals

-   Markdown files are the canonical source of truth.
-   SQLite is the only persistent datastore.
-   No external database server.
-   Use Ollama for all AI tasks.
-   Support frequent document additions, modifications, and deletions.
-   Fast hybrid retrieval using keyword search, semantic search, and a
    lightweight knowledge graph.
-   Remain useful when Ollama is unavailable.

### Non-Goals

These are explicitly out of scope for v1. They are listed so an implementer
never has to guess whether an absence is an oversight.

-   Multi-user access, permissions, or per-user views.
-   Remote or cross-device sync of the database. The database is local and
    disposable; the Markdown corpus is what gets synced, by whatever means
    the user already uses.
-   Any source format other than Markdown.
-   Any network egress other than to a local Ollama endpoint. See
    [Security and Privacy](#security-and-privacy).
-   Wikilinks, backlinks, and tag hierarchy. Links are preserved during
    parsing but not yet resolved into graph structure. See
    [Future Enhancements](#future-enhancements).

### Scale Targets

The design targets personal-notes scale on Apple Silicon:

-   ~1,000 documents
-   ~20,000 chunks
-   Full rebuild measured in tens of minutes, dominated by Ollama throughput
-   All indexes comfortably resident in memory

This target justifies several simplifications, and each one is called out
where it appears — notably that brute-force fallbacks are acceptable, that a
full `sync()` scan is cheap enough to run on demand, and that no sharding or
partial-index strategy is needed.

Corpora an order of magnitude larger are not designed against. They would
push past what local Ollama extraction can realistically cover and would
force either sampling or a remote embedding service.

## Architecture

``` text
Markdown Files
      │
      ▼
 Markdown Parser
      │
      ├── Chunking
      ├── Metadata
      └── Links
             │
             ▼
      Ingestion Pipeline
      │
      ├── FTS5
      ├── sqlite-vec
      └── Graph
             │
             ▼
      Retrieval Engine
             │
             ▼
            Agent
```

The pipeline is split at a durable job queue: chunks and keyword index land
synchronously, while embeddings and graph extraction are processed by
background workers. The store is queryable before that background work
completes.

## Platform and Dependencies

-   **macOS 26+**, **Swift 6.3**, strict concurrency enabled.
-   `KnowledgeStore` is an `actor`. All model types crossing its boundary are
    `Sendable`. Background workers are structured tasks owned by the store,
    cancelled on deinit.

| Dependency | Purpose | Notes |
| --- | --- | --- |
| `groue/GRDB.swift` | SQLite access, migrations, FTS5 | Standard SPM package, against the **system SQLite** |
| `asg017/sqlite-vec` | Vector storage and nearest-neighbor search | Vendored as a C target, compiled into the package |
| `swiftlang/swift-markdown` | Markdown parsing | cmark-gfm based; does not handle front matter |
| `jpsim/Yams` | YAML front matter | Front matter is stripped before swift-markdown sees the document |
| `apple/swift-argument-parser` | The `kb` CLI | |
| `modelcontextprotocol/swift-sdk` | MCP server | `StatefulHTTPServerTransport`, hosted in-process |

### How sqlite-vec is loaded

**No custom SQLite build is required.** An earlier draft of this spec assumed
one; measurement showed otherwise, and the simpler arrangement is the one that
works.

The macOS system SQLite (3.51.0 on macOS 26) already has FTS5 compiled in. It
is built with `SQLITE_OMIT_LOAD_EXTENSION`, which does rule out loading
sqlite-vec as a runtime `.dylib` — and, less obviously, also omits the
**auto-extension registry**: `sqlite3_auto_extension` returns `SQLITE_MISUSE`
and silently registers nothing.

What does work is calling the extension's init function directly on each
connection as it opens. sqlite-vec is compiled into this package as a C target
(`SQLITE_CORE`, `SQLITE_VEC_STATIC`), and GRDB's `Configuration.prepareDatabase`
hook invokes `sqlite3_vec_init` on every pooled connection — writer and readers
alike. See `Storage/Database.swift`.

This is better than the auto-extension route regardless of the omission: it is
explicit, has no process-global state, and fails loudly on the connection that
could not register rather than at the first query. Nothing is loaded at runtime,
so there is no `.dylib` to sign, notarize, or locate at an install path.

## Components

### Markdown Parser

Responsible for:

-   Reading Markdown files
-   Parsing front matter
-   Splitting into semantic chunks
-   Preserving headings and links

Front matter is stripped from the head of the file and parsed as YAML before
the remainder is handed to swift-markdown. Three front matter fields are
**semantic** — the rest is stored opaquely:

| Field | Meaning |
| --- | --- |
| `title` | Document title, used as the root of every heading path. Falls back to the first H1, then the filename. |
| `tags` | String list, indexed and filterable. |
| `aliases` | String list, seeded into the entity alias table for this document's title. |

Everything else is preserved verbatim in `documents.metadata_json` and is
available to callers but carries no built-in behavior.

Malformed front matter does not fail ingestion: the document is indexed with
empty metadata and a warning is recorded in diagnostics.

### Chunker

Each chunk stores:

-   Stable ID
-   Document ID
-   Heading path
-   Text
-   Content hash

Chunking is **heading-based with size bounds**:

1.  Split at headings, producing one candidate chunk per leaf section.
2.  Any section exceeding the maximum token budget is subdivided at paragraph
    boundaries into siblings that **share the same heading path**,
    disambiguated by occurrence index.
3.  Adjacent sections below the minimum token budget are merged, taking the
    heading path of the first.

Splitting at paragraph boundaries rather than truncating is deliberate: a
truncated chunk would still be fully indexed in FTS5 while its embedding
covered only the head of the text, so keyword and vector recall would silently
disagree about what the corpus contains.

> **Open Question:** Concrete default token bounds. A starting point of
> min 64 / max 512 tokens is proposed, to be tuned against a real vault.

### Identity and Change Detection

Stable IDs are deterministic so unchanged chunks survive edits.

#### Document identity

`documents.id` is a hash of the corpus-relative path **at the time the document
was first indexed**. It is not recomputed afterwards.

That distinction is what makes rename survival real rather than nominal. If the
ID were a pure function of the *current* path, a rename would mint a new
document ID — and since chunk IDs derive from the document ID, every chunk would
be retired and re-embedded, which is exactly the cost rename detection exists to
avoid. So identity is resolved by **looking the path up**, and minted from the
path only when the document is genuinely new.

`sync()` performs **content-hash rename detection**: when a scan finds a path
that has vanished and a new path whose content hash is identical, the two are
paired and the existing row's `path` is rewritten in place. Chunks, embeddings,
mentions, and relations all survive, and no work is queued. A rename is one
`UPDATE`.

Consequences, stated plainly:

-   A rename *with* an edit in the same scan is not detected and becomes a
    delete + insert. The content genuinely differs, so the work is genuinely
    needed.
-   The store never writes to the user's Markdown files. An alternative design
    would stamp a UUID into front matter to make identity durable; that was
    rejected because mutating the canonical source of truth is a larger
    promise than rename survival is worth.
-   A document ID therefore encodes where a file *was*, not where it *is*. Only
    the `path` column is authoritative for location.

#### Chunk identity

`chunks.id = hash(document_id + heading_path + occurrence_index)`

-   Editing a section's prose **keeps the chunk ID**. `content_hash` detects the
    change and the chunk is re-embedded and re-extracted in place, so mentions
    and relations keep pointing at a live chunk.
-   Renaming a heading **mints a new chunk ID** and retires the old one, which
    cascades a re-embed and re-extract of that section. This is the accepted
    cost of a scheme with no fuzzy matching.
-   Duplicate heading paths within a document are disambiguated by occurrence
    index, in document order.

### Providers

Embedding and extraction sit behind protocols:

``` swift
public protocol EmbeddingProvider: Sendable {
    var modelIdentifier: String { get }
    var dimensions: Int { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
}

public protocol ExtractionProvider: Sendable {
    var modelIdentifier: String { get }
    func extract(
        from chunk: ChunkContext,
        vocabulary: GraphVocabulary
    ) async throws -> ExtractionResult
}
```

Ollama implementations of both ship as the defaults. The protocols exist
primarily as a **testing seam**: deterministic doubles (hash-derived vectors,
fixture JSON) let the parser, chunker, differ, job queue, graph GC, and fusion
ranking be tested with no model running and no flakiness. That they also leave
room for other backends is a side benefit, not a v1 commitment.

### Ollama

Two separate models are used:

1.  Embedding model
    -   Generate vector embeddings
    -   Store in sqlite-vec
2.  LLM
    -   Extract entities
    -   Extract relationships
    -   Produce structured JSON

Defaults:

| Role | Model | Notes |
| --- | --- | --- |
| Embedding | `embeddinggemma` | 768 dimensions, confirmed against the model |
| Extraction | `qwen2.5:7b` | Structured JSON via Ollama's schema-constrained decoding |

Both are configurable, and both are version keys: changing either re-indexes the
corresponding half of the store.

Extraction reliability comes from the schema rather than the model. Ollama's
`format` parameter takes a JSON Schema and constrains decoding to it, so entity
and relation *types* cannot come back out of vocabulary. What the schema cannot
express — that every relation endpoint must be a declared entity — is enforced by
a sanitizing pass over the result.

## SQLite Schema

### documents

  Column          Purpose
  --------------- --------------------
  id              Stable document ID
  path            Markdown path
  content_hash    Detect changes
  modified_at     Last indexed
  metadata_json   Front matter

### chunks

  Column         Purpose
  -------------- ----------------------
  id             Stable chunk ID
  document_id    Parent document
  ordinal        Position
  heading        Heading
  content        Markdown text
  content_hash   Detect chunk changes

`heading` stores the full heading path, not just the leaf, since the path
participates in both the chunk ID and the embedded text.

### entities

  Column           Purpose
  ---------------- ----------------------------------
  id               Stable entity ID
  type             Component, Person, Concept, etc.
  canonical_name   Canonical name

`type` is constrained to the configured [graph vocabulary](#graph-vocabulary).

### aliases

Maps alternate names onto canonical entities. Seeded from front matter
`aliases` and from resolution decisions made during extraction.

### mentions

Maps entities to chunks. This is the reference-count edge that drives
[graph garbage collection](#graph-garbage-collection).

### relations

Stores:

-   source entity
-   relationship type
-   target entity
-   supporting chunk
-   confidence

A relation asserted by several chunks is stored once per supporting chunk, so
that deleting one supporting chunk does not silently erase a fact that other
chunks still support.

### jobs

Backs the durable background queue.

  Column        Purpose
  ------------- ------------------------------------------
  id            Job ID
  kind          `embed` or `extract`
  target_id     Chunk ID
  state         `pending`, `running`, `failed`
  attempts      Retry counter
  next_after    Backoff timestamp
  last_error    Error text for dead-lettered jobs

### metadata

Key-value store for the [version keys](#versioning-and-migration).

## SQLite Extensions

### FTS5

Used for keyword search. Indexed over chunk content plus the heading path, so
a query matching a heading ranks the section it names.

### sqlite-vec

Stores embeddings and performs nearest-neighbor search. At the stated scale a
brute-force scan over ~20k vectors is well within budget, so no ANN index
tuning is specified.

## Process and Concurrency Model

Four entry points can hold the same database open: the library embedded in a
host app, the `kb` CLI, the filesystem watcher, and the MCP server. SQLite
permits one writer.

The rule is **exclusive on writes, shared on reads**:

-   The database runs in **WAL** mode.
-   A file lock elects a single **indexer** — the process permitted to write.
    A second process attempting write access fails fast with
    `KnowledgeStoreError.databaseInUse`, naming the holder.
-   Readers are unlimited and concurrent. `search()`, `answer()`, and all
    graph queries work regardless of who holds the write lock.

The MCP server is **hosted in-process by the host app** over
`StatefulHTTPServerTransport`, not spawned as a separate stdio process. It
therefore shares the app's store instance and needs no lock of its own — an
agent can query the knowledge base while the app is indexing.

The accepted consequence: while the host app is running, the CLI cannot
ingest. `kb search` and other read commands still work. This is documented
behavior, not a defect.

## Ingestion Pipeline

For each Markdown file:

1.  Parse
2.  Chunk
3.  Compare hashes
4.  Skip unchanged chunks
5.  Write chunks and update the FTS index — **synchronous**
6.  Enqueue embedding jobs
7.  Enqueue extraction jobs

Steps 1–5 complete within the ingest transaction. Steps 6–7 hand off to the
background queue, so the document is keyword-searchable immediately, becomes
semantically searchable when its embeddings land, and joins the graph when
extraction completes. `diagnostics()` reports how far behind each stage is.

Extraction always runs — no chunk is skipped by heuristic — it simply runs
behind the queue rather than blocking ingestion.

### Embedding input

Each chunk is embedded as:

``` text
<document title> > <H1> > <H2>

<chunk content>
```

The heading path prefix gives isolated sections their context; a chunk headed
only "Overview" is otherwise a vector with no indication of what it is an
overview of. Chunks are already bounded by the chunker, so overflow is
structurally rare; when it occurs the chunk is hard-split rather than
truncated, for the reason given in [Chunker](#chunker).

## Job Queue and Failure Semantics

Background jobs are durable rows, not in-memory tasks — a crash mid-index
resumes rather than restarts.

-   **Retry:** bounded retries with exponential backoff, default 3 attempts.
-   **Dead-letter:** after the final attempt the job moves to `failed` with
    `last_error` recorded. It is skipped by the queue thereafter and never
    retried automatically.
-   **Surfacing:** dead-lettered jobs appear in `store.diagnostics()` and in
    `kb status`. They are retryable on demand, individually or in bulk.
-   **Concurrency:** a configurable worker count bounds parallel requests to
    Ollama, which is a single local process and is the pipeline's bottleneck.

This bounds the damage from poison input — a chunk that reliably makes the
extraction model emit unparseable JSON costs three attempts, not an unbounded
share of Ollama capacity for the life of the database.

### When Ollama is unavailable

An unreachable server or an unpulled model is **not treated as a failure of
ingestion**:

-   Chunks and the FTS index are written as normal.
-   Embedding and extraction jobs remain queued and retry with backoff until
    the server returns.
-   `search()` degrades to keyword-only and **flags the degradation in its
    result**, so a caller can tell a thin answer from a broken one.
-   `answer()` throws `KnowledgeStoreError.ollamaUnavailable` rather than
    degrading, since generation without a model has no meaningful fallback.

Connection failures are distinguished from malformed-output failures: a server
that is merely offline does **not** burn attempts toward the dead-letter
threshold. `ProviderError.isTransient` draws the line — transport errors, 5xx
responses, and a model that is not pulled are all transient; malformed output
and a dimension mismatch are not. A transient failure still backs off, so an
unreachable server is polled at a capped interval rather than spun on.

A model that is not pulled counts as transient deliberately: it is one
`ollama pull` away from resolving, and the corpus is not at fault.

## Update Strategy

Documents change frequently.

Updates should be incremental.

For each chunk:

-   unchanged → do nothing
-   modified → re-embed and re-extract
-   deleted → remove associated graph data
-   new → insert

Avoid rebuilding the entire database unless requested.

### Corpus reconciliation

`KnowledgeStore` is configured with one or more **corpus roots**. Deletions
that happen outside the process — a file removed in Finder, a branch switched
in Git — are caught by `sync()`, which walks the roots, diffs against the
database, and applies adds, updates, renames, and deletes in one pass. The
per-file `add`/`update`/`remove` APIs remain for fine-grained control.

### Filesystem watcher

The watcher observes the corpus roots via FSEvents and feeds the same
reconciliation logic. Raw FSEvents traffic is noisy — editors save by writing
a temp file and renaming, tools churn inside hidden directories, and a
`git checkout` can touch thousands of files at once — so the watcher applies:

-   **Debounce:** per-path, ~500ms, coalescing rapid saves into one re-index.
-   **Ignore rules:** dotfiles and dot-directories, non-`.md` extensions, and
    a configurable gitignore-style ignore list.
-   **Burst collapse:** more than a threshold of events (default 200) within
    the debounce window collapses into a single `sync()` rather than
    thousands of individual jobs. A dropped FSEvents buffer
    (`kernelDropped`, `userDropped`, `mustScanSubDirs`) collapses the same
    way — once events are lost, no path-level reasoning is trustworthy.

Two implementation details are load-bearing and easy to get wrong:

-   FSEvents delivers paths as a C `char **` unless
    `kFSEventStreamCreateFlagUseCFTypes` is set, in which case it delivers a
    `CFArray` instead. Reading one as the other yields no usable paths and a
    watcher that silently observes nothing.
-   macOS gives the same file more than one absolute path: `/var`, `/tmp`, and
    `/etc` are symlinks into `/private`. Foundation normalizes in one direction
    only — `/private/var` becomes `/var` — and **only for paths that still
    exist**. FSEvents reports the `/private` form. A file being created or
    edited therefore normalizes to match a root, while a file being *deleted*
    does not, so a naive prefix comparison drops every deletion. `PathMapper`
    matches against every spelling of every root.

## Graph

### Graph vocabulary

Entity types and relation types come from a **closed default vocabulary** that
the extraction prompt enumerates and the response parser validates against.
Values outside the vocabulary are rejected and the job is retried.

The vocabulary is **extensible via configuration** — a user indexing a corpus
the defaults do not model can extend or replace it. Doing so is an
extraction-version change and triggers re-extraction (see
[Versioning](#versioning-and-migration)).

A closed vocabulary is what makes traversal predictable. An open one yields
`uses`, `utilizes`, and `depends on` as three unrelated relation types, and
a 2-hop expansion then depends on which synonym the model happened to pick.

The default vocabulary is:

-   **Entity types:** Component, Person, Concept, Technology, Project, Document
-   **Relation types:** uses, depends-on, part-of, authored-by, related-to,
    contradicts

The vocabulary's fingerprint is order-insensitive, so reordering the lists is
not a change and does not trigger re-extraction.

### Entity resolution

Alternate names are resolved onto canonical entities in three stages, cheapest
first:

1.  **Deterministic:** normalize case, punctuation, whitespace, and simple
    plurals, then match exactly against `canonical_name` and `aliases`.
2.  **Embedding similarity:** compare the name embedding against known entity
    names; accept above a configured threshold.
3.  **LLM adjudication:** only for candidates that are ambiguous after
    stage 2 — several plausible matches, or one just below threshold.

Most resolutions therefore never reach a model, which keeps ingestion cheap
and keeps re-runs largely reproducible. The LLM is a tiebreaker, not the
mechanism.

### Graph garbage collection

The graph is **reference-counted** and cascades on zero:

-   Deleting a chunk deletes its mentions.
-   An entity with no remaining mentions and no remaining relations is
    deleted, along with its aliases.
-   A relation is deleted when its last supporting chunk is gone.

The graph therefore exactly mirrors the corpus — it can never cite a chunk
that no longer exists, and stale facts do not accumulate across edits. The
cost is that entity IDs are not permanent across a delete-and-readd cycle,
which is acceptable because no external system holds references to them.

## Retrieval

Queries use three independent indexes:

1.  FTS keyword search
2.  Vector similarity search
3.  Graph traversal

Example flow:

    Question
        │
        ├── FTS
        ├── Vector Search
        └── Entity Lookup
                │
          Merge Results
                │
          Expand Graph (1–2 hops)
                │
          Retrieve Supporting Chunks
                │
                 LLM

### Fusion

Results merge via **Reciprocal Rank Fusion**: each arm contributes
`weight / (k + rank)` per chunk, summed across arms. Per-source weights and
`k` are configurable.

RRF is chosen because it operates on ranks, not scores. BM25 magnitudes and
cosine similarities are not on comparable scales, and normalizing them makes
the result sensitive to the composition of each candidate set — a query where
the vector arm returns uniformly mediocre matches would see those matches
stretched to fill 0–1. Rank-based fusion has no such failure mode and needs no
per-corpus tuning.

### The graph arm

Entities are seeded two ways, and the results are unioned:

1.  **Name matching:** normalized n-grams from the query are matched against
    `entities.canonical_name` and `aliases`. Rank derives from match quality —
    exact, then alias, then fuzzy.
2.  **Retrieval seeding:** mentions of the top-ranked FTS and vector chunks
    are taken as entities, giving the arm reach into concepts the query never
    names literally.

Seeds are expanded 1–2 hops (configurable), and the supporting chunks of the
traversed relations enter fusion ranked by hop distance, then relation
confidence.

**No LLM runs on the `search()` path.** Query-side entity extraction was
considered and rejected: it would add an Ollama round-trip to every search,
make results non-deterministic, and — decisively — break the graph arm
entirely in the offline fallback, exactly when the user most needs retrieval
to keep working.

### Degraded retrieval

When embeddings are missing (offline, or still queued), the vector arm
contributes nothing and fusion proceeds over the remaining arms. The result
carries a flag naming which arms participated.

## Public Swift API

``` swift
let store = try await KnowledgeStore(
    databaseURL: url,
    configuration: .init(corpusRoots: [vaultURL])
)

try await store.add(url: markdownURL)
try await store.update(url: markdownURL)
try await store.remove(url: markdownURL)

try await store.sync()

let results = try await store.search(
    "How does authentication work?"
)
```

`search()` returns ranked chunks with citations — document path, heading path,
chunk ID, per-arm and fused scores — and the degradation flag. It performs no
generation and is deterministic given a fixed index.

`answer()` layers generation on top:

``` swift
let stream = try await store.answer("How does authentication work?")
for try await token in stream.tokens { … }
let citations = stream.citations   // resolved before generation begins

// Buffered convenience form, for CLI and MCP callers
let answer = try await store.answer("…").collected()
```

Streaming is the primary form so a host app can render sources immediately and
prose progressively; the buffered overload exists because the CLI and the MCP
tool both want a single value. Context is assembled to a configurable token
budget, dropping chunks by fusion rank.

Errors are typed: `.databaseInUse`, `.ollamaUnavailable`, `.modelNotFound`,
`.versionMismatch`, `.corpusRootUnreadable`.

> **Open Question:** Whether `answer()` should validate that every citation the
> model emits was actually in context, and retry on a mismatch. It guards
> against fabricated sources at the cost of an occasional extra generation
> pass; deferred pending observed behavior of the default extraction model.

## Configuration and Defaults

Configuration is a `Sendable` value type passed at store construction:

``` swift
public struct KnowledgeStoreConfiguration: Sendable {
    var corpusRoots: [URL]
    var ignorePatterns: [String]
    var embedding: EmbeddingConfiguration   // model, dimensions
    var extraction: ExtractionConfiguration // model, vocabulary
    var chunking: ChunkingConfiguration     // min/max token bounds
    var fusion: FusionConfiguration         // per-arm weights, k
    var workerCount: Int
    var ollamaEndpoint: URL                 // default http://localhost:11434
}
```

The CLI and MCP entry points additionally read an optional config file so the
same settings need not be passed on every invocation.

The config file is `.kb.json`, searched for at the corpus root first and then at
`~/.config/kb/config.json`. Root-first means the file travels with the vault, so
a machine that syncs the notes gets the settings too and two vaults can differ.
Relative paths inside it resolve against the file, so a vault can be moved
wholesale without editing it.

The database defaults to `<root>/.kb/store.sqlite` — inside the vault, in a
dot-directory the scanner ignores, so the store never indexes itself.

## CLI

The `kb` executable target:

| Command | Purpose |
| --- | --- |
| `kb index <path>` | Ingest a file or directory |
| `kb sync` | Reconcile corpus roots against the database |
| `kb watch` | Reconcile, then follow filesystem events until stopped |
| `kb search <query>` | Ranked chunks with citations |
| `kb answer <query>` | Generated answer with sources |
| `kb status` | Diagnostics: queue depth, coverage, versions, failures |
| `kb rebuild` | Drop and rebuild from the corpus |
| `kb compact` | VACUUM, FTS optimize, prune dead-lettered jobs |

Write commands fail with `databaseInUse` when a host app holds the lock; read
commands work regardless.

## MCP Server

Hosted in-process by the host app via `StatefulHTTPServerTransport`, wrapped by
`MCPHTTPHost`. That transport is framework-agnostic: it converts an `HTTPRequest`
into an `HTTPResponse` and does not own a socket. The host app brings whatever
HTTP server it already has and forwards requests to it.

This is the arrangement the concurrency model depends on. The app holds the
write lock; a separate server *process* could not take it. In-process, the
server shares the app's `KnowledgeStore` and needs no lock of its own.

For the case where no host app is running, `kb serve` exposes the same tools
over **stdio**, which is how agent clients spawn MCP servers anyway. It opens
the store read-only, so it can run alongside an indexing `kb sync`.

Tools exposed to agents:

| Tool | Arguments | Returns |
| --- | --- | --- |
| `search_knowledge_base` | `query`, `limit` | Ranked chunks with citations and degradation flag |
| `answer_question` | `query` | Buffered answer with citations |
| `lookup_entity` | `name` | Canonical entity, aliases, mention count |
| `traverse_graph` | `entity`, `hops` | Related entities, relations, supporting chunks |

All four are read-only. Ingestion is deliberately not exposed to agents.

## Observability

-   **Logging:** structured, via OSLog, with subsystems per component
    (parser, queue, retrieval, watcher).
-   **`store.diagnostics()`** reports queue depth by kind, dead-lettered job
    count with last errors, index coverage (chunks embedded / chunks
    extracted / total), current version keys, and lock holder.
-   **Progress:** long-running `sync()` and `rebuild()` report progress through
    an `AsyncStream` so a host app can show a determinate indicator.

## Security and Privacy

-   Everything is local. The only network destination is the configured Ollama
    endpoint, which defaults to `localhost`.
-   No telemetry, no analytics, no remote logging.
-   The corpus may contain secrets — notes are personal. Chunk text is sent to
    the local model for embedding and extraction, and nowhere else. A non-local
    `ollamaEndpoint` is permitted but is the user's explicit choice, and should
    be surfaced as such in the CLI and host app.
-   Ignore rules are the mechanism for excluding sensitive directories from
    indexing entirely.

## Versioning and Migration

Store metadata describing:

-   schema version
-   chunker version
-   embedding model
-   embedding dimensions
-   extraction model
-   extraction vocabulary

On open, the running configuration is compared against stored metadata and the
**narrowest sufficient migration** runs automatically, after reporting what it
intends to do:

| Changed key | Blast radius |
| --- | --- |
| schema version | GRDB migration; no re-indexing |
| embedding model or dimensions | Re-embed all chunks; graph untouched |
| extraction model or vocabulary | Re-extract all chunks; embeddings untouched |
| chunker version | Re-chunk, which cascades to both re-embed and re-extract |

Re-indexing work is enqueued as ordinary jobs, so it is incremental,
resumable, and visible in `kb status` rather than blocking on open.

## Rebuild

The database is disposable.

A complete rebuild should always be possible from the Markdown corpus.

``` swift
try await store.rebuild()
```

`rebuild()` remains the escape hatch whenever automatic migration is
undesirable or the database is suspect.

## Testing Strategy

The provider protocols make everything except the models themselves testable
without Ollama running:

-   **Deterministic doubles:** hash-derived embedding vectors, fixture JSON
    extraction results.
-   **Unit-testable without a model:** front matter parsing, chunking and size
    bounds, chunk and document ID derivation, the incremental differ, rename
    detection, job queue retry and dead-lettering, graph reference-counted GC,
    RRF fusion ranking, watcher debounce and ignore rules.
-   **Integration tests** against a live Ollama cover only what genuinely needs
    a model: embedding round-trip, extraction JSON adherence, and vocabulary
    validation. These are marked and excluded from the default test run.
-   **Corpus fixtures:** a small Markdown vault checked into the repository,
    with mutation scenarios (edit prose, rename heading, rename file, delete
    file, reorder sections) asserted against expected incremental behavior.

## Future Enhancements

-   Wikilink support
-   Backlinks
-   Tag hierarchy
-   Temporal relationships
-   Multi-project workspaces
-   Graph visualization
-   Citation generation
-   Cross-document summaries
-   Alternative embedding/extraction backends behind the existing provider
    protocols

## Open Questions

Most of the questions this spec opened were closed during implementation and are
recorded in place above. What remains genuinely undecided:

1.  **Chunk token bounds.** Currently 64–512, applied against an estimated token
    count rather than a real tokenizer (Ollama does not expose one). The bounds
    have not been tuned against a large real vault.
2.  **Citation validation.** Whether `answer()` should reject and retry a
    generation that cites a `[n]` marker not present in its context. It guards
    against fabricated sources at the cost of an occasional extra pass; deferred
    until the default model is observed misbehaving.
3.  **Similarity thresholds for entity resolution.** `resolutionThreshold` 0.92
    and `adjudicationFloor` 0.75 are starting values. The similarity measure is
    derived from L2 distance rather than a true cosine, because Ollama
    embeddings are not guaranteed unit length.
