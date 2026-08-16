# ``KnowledgeBaseKit``

Build and maintain a local knowledge base from Markdown files.

## Overview

Markdown files are the source of truth, SQLite is the only datastore, and Ollama
does the AI work. Nothing leaves the machine.

Retrieval is hybrid: FTS5 keyword search, sqlite-vec semantic search, and a
knowledge graph extracted from the notes, combined by Reciprocal Rank Fusion.

```swift
let store = try KnowledgeStore(
    databaseURL: url,
    configuration: KnowledgeStoreConfiguration(corpusRoots: [vaultURL])
)

try await store.sync()          // reconcile the corpus
await store.startProcessing()   // drain embedding/extraction in the background
await store.startWatching()     // re-index on filesystem changes

let results = try await store.search("How does authentication work?")
```

### Ingestion is incremental

``ChunkID`` derives from the document, heading path, and occurrence index — not
from content. Editing a section's prose therefore keeps its identity, and only
that chunk is re-embedded. Renaming a heading mints a new ID and retires the old
one, which is the accepted cost of a scheme with no fuzzy matching.

``DocumentID`` derives from the corpus-relative path *at first index*, so
``KnowledgeStore/sync(force:)`` can pair a vanished path with a new path of
identical content and rewrite one column. Chunks, embeddings, and the graph all
survive a rename, and nothing is queued.

### The store is queryable before the models catch up

Chunks and the keyword index are written synchronously. Embedding and extraction
are enqueued on a durable job queue and processed behind it, so a document is
searchable by keyword the moment ingestion returns.

### Ollama being unavailable is not a failure

Ingestion still completes, jobs stay queued and retry, and
``KnowledgeStore/search(_:options:)`` degrades to keyword-only while reporting
that in ``SearchResponse/degradations``. ``KnowledgeStore/answer(_:options:)``
does throw, since generation without a model has no meaningful fallback.

### Testing without a model

``DeterministicEmbeddingProvider``, ``FixtureExtractionProvider``, and
``FixtureGenerationProvider`` ship in the library, so the parser, chunker,
differ, job queue, graph collection, and fusion are all exercisable with no
Ollama running.

## Topics

### Essentials

- ``KnowledgeStore``
- ``KnowledgeStoreConfiguration``
- ``KnowledgeStoreError``

### Retrieval

- ``SearchResponse``
- ``SearchResult``
- ``SearchOptions``
- ``RetrievalArm``
- ``Degradation``
- ``ReciprocalRankFusion``
- ``FusionConfiguration``

### Answering

- ``AnswerStream``
- ``Answer``
- ``Citation``
- ``AnswerOptions``

### Documents and chunks

- ``Document``
- ``DocumentMetadata``
- ``Chunk``
- ``DocumentID``
- ``ChunkID``
- ``HeadingPath``
- ``ContentHash``

### Parsing and chunking

- ``MarkdownParser``
- ``ParsedDocument``
- ``ParsedSection``
- ``Chunker``
- ``ChunkingConfiguration``
- ``FrontMatterParser``
- ``TokenEstimator``

### The knowledge graph

- ``Entity``
- ``EntityID``
- ``Alias``
- ``Mention``
- ``MentionSource``
- ``Relation``
- ``RelationID``
- ``GraphVocabulary``
- ``EntityResolver``

### Model providers

- ``EmbeddingProvider``
- ``ExtractionProvider``
- ``GenerationProvider``
- ``ProviderError``
- ``ProviderHealth``
- ``OllamaClient``
- ``OllamaEmbeddingProvider``
- ``OllamaExtractionProvider``
- ``OllamaGenerationProvider``

### Deterministic providers for testing

- ``DeterministicEmbeddingProvider``
- ``FixtureExtractionProvider``
- ``FixtureGenerationProvider``

### The corpus

- ``CorpusScanner``
- ``CorpusFile``
- ``CorpusWatcher``
- ``WatchEvent``
- ``IgnoreRules``
- ``WatcherConfiguration``

### Ingestion pipeline

- ``DocumentIngestor``
- ``IngestionOutcome``
- ``JobWorkers``
- ``Job``
- ``JobKind``
- ``JobState``
- ``RetryConfiguration``

### Storage

- ``KnowledgeDatabase``
- ``Schema``
- ``VectorIndex``
- ``DocumentRepository``
- ``ChunkRepository``
- ``GraphRepository``
- ``JobRepository``

### Versioning and migration

- ``VersionMetadata``
- ``VersionKey``
- ``MigrationPlan``
- ``MigrationAction``
