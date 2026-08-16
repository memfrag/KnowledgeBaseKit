import ArgumentParser
import Foundation
import KnowledgeBaseKit

@main
struct KB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kb",
        abstract: "A local knowledge base built from Markdown files.",
        discussion: """
            Write commands (index, sync, rebuild, compact) take an exclusive lock. \
            Read commands (search, answer, status) work even while another process is indexing.
            """,
        version: "0.1.0",
        subcommands: [
            Index.self, Sync.self, Watch.self, Search.self, Answer.self,
            Status.self, Rebuild.self, Compact.self, Serve.self,
        ]
    )
}

// MARK: - Shared output helpers

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Turns a store error into a message that says what to do about it.
func describe(_ error: any Error) -> String {
    guard let error = error as? KnowledgeStoreError else { return error.localizedDescription }
    switch error {
    case .databaseInUse(let holder):
        return """
            The knowledge base is locked for writing by \(holder).
            Read commands (search, answer, status) still work.
            """
    case .modelNotFound(let model, _):
        return "Model '\(model)' is not available. Run: ollama pull \(model)"
    default:
        return error.localizedDescription
    }
}

/// Left-aligns without truncating, unlike `padding(toLength:)`.
func pad(_ text: String, to width: Int) -> String {
    text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
}

func reportProgress(_ summary: KnowledgeStore.SyncSummary) {
    print(
        """
        Scanned \(summary.scanned) file(s): \
        \(summary.added) added, \(summary.modified) modified, \
        \(summary.renamed) renamed, \(summary.removed) removed, \
        \(summary.unchanged) unchanged.
        """
    )
    for warning in summary.warnings.prefix(10) {
        printError("warning: \(warning)")
    }
}

/// Drains the queues with a progress line, so a long first index is not a silent wait.
func drainQueues(_ store: KnowledgeStore, quiet: Bool) async throws {
    let before = try await store.diagnostics()
    let pending = before.embedQueue.pending + before.extractQueue.pending
    guard pending > 0 else { return }

    if !quiet {
        print("Processing \(pending) queued job(s)...")
    }

    let health = await store.checkProviders()
    if !health.isReachable {
        printError(
            """
            warning: Ollama is unreachable at \(store.configuration.ollamaEndpoint.absoluteString).
            The corpus is indexed and keyword search works; embeddings and the graph stay \
            queued and will resume when the server is back.
            """
        )
        return
    }
    if let message = health.message {
        printError("warning: \(message)")
        return
    }

    let result = try await store.processQueues()
    if !quiet {
        print("Embedded \(result.embedded) chunk(s), extracted \(result.extracted).")
    }

    let after = try await store.diagnostics()
    if after.embedQueue.failed + after.extractQueue.failed > 0 {
        printError(
            "warning: \(after.embedQueue.failed + after.extractQueue.failed) job(s) failed. "
                + "See `kb status` for details; retry with `kb status --retry-failed`."
        )
    }
}

// MARK: - index

struct Index: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ingest a file or directory."
    )

    @OptionGroup var common: CommonOptions

    @Argument(help: "Files or directories to ingest.")
    var paths: [String]

    @Flag(name: .long, help: "Leave the queued embedding and extraction work for later.")
    var deferProcessing = false

    func run() async throws {
        let store = try common.makeStore()
        defer { Task { await store.close() } }

        var total = IngestionTotals()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if isDirectory.boolValue {
                // A directory argument is reconciled rather than walked here, so deletions
                // inside it are handled too.
                let summary = try await store.sync()
                reportProgress(summary)
            } else {
                let outcome = try await store.add(url: url)
                total.add(outcome)
            }
        }

        if total.touched > 0 {
            print(
                "\(total.added) chunk(s) added, \(total.modified) modified, "
                    + "\(total.removed) removed."
            )
        }

        if !deferProcessing {
            try await drainQueues(store, quiet: false)
        }
    }

    struct IngestionTotals {
        var added = 0
        var modified = 0
        var removed = 0
        var touched: Int { added + modified + removed }

        mutating func add(_ outcome: IngestionOutcome) {
            added += outcome.chunksAdded
            modified += outcome.chunksModified
            removed += outcome.chunksRemoved
        }
    }
}

// MARK: - sync

struct Sync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reconcile the corpus roots against the database."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Re-parse every file even when its content hash is unchanged.")
    var force = false

    @Flag(name: .long, help: "Leave the queued embedding and extraction work for later.")
    var deferProcessing = false

    func run() async throws {
        let store = try common.makeStore()
        defer { Task { await store.close() } }

        let summary = try await store.sync(force: force)
        reportProgress(summary)

        if !deferProcessing {
            try await drainQueues(store, quiet: false)
        }
    }
}

// MARK: - search

struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hybrid search across keyword, vector, and graph indexes."
    )

    @OptionGroup var common: CommonOptions

    @Argument(parsing: .remaining, help: "The query.")
    var query: [String]

    @Option(name: [.customShort("n"), .long], help: "Maximum results.")
    var limit = 10

    @Option(name: .long, help: "Only match documents with all of these tags.")
    var tag: [String] = []

    @Flag(name: .long, help: "Print full chunk text rather than an excerpt.")
    var full = false

    func run() async throws {
        // Searching never writes, so it opens read-only and works while indexing is running.
        var options = common
        options.readOnly = true
        let store = try options.makeStore()
        defer { Task { await store.close() } }

        let response = try await store.search(
            query.joined(separator: " "),
            options: SearchOptions(limit: limit, requiredTags: tag)
        )

        for degradation in response.degradations {
            printError("note: \(degradation.message)")
        }

        guard !response.results.isEmpty else {
            print("No matches.")
            return
        }

        for (index, result) in response.results.enumerated() {
            let arms = RetrievalArm.allCases
                .compactMap { arm in result.ranks[arm].map { "\(arm.rawValue):\($0)" } }
                .joined(separator: " ")

            print("\(index + 1). \(result.citation)")
            print("   score \(String(format: "%.4f", result.score))  [\(arms)]")
            if !result.matchedEntities.isEmpty {
                print("   entities: \(result.matchedEntities.joined(separator: ", "))")
            }
            let body = full ? result.content : excerpt(result.content)
            for line in body.components(separatedBy: "\n") {
                print("   \(line)")
            }
            print("")
        }
    }

    private func excerpt(_ text: String, limit: Int = 240) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count <= limit
            ? collapsed
            : String(collapsed.prefix(limit)) + "…"
    }
}

// MARK: - answer

struct Answer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Answer a question from the corpus, with citations."
    )

    @OptionGroup var common: CommonOptions

    @Argument(parsing: .remaining, help: "The question.")
    var question: [String]

    @Option(name: .long, help: "Maximum tokens of retrieved context.")
    var contextBudget = 3000

    func run() async throws {
        var options = common
        options.readOnly = true
        let store = try options.makeStore()
        defer { Task { await store.close() } }

        let stream = try await store.answer(
            question.joined(separator: " "),
            options: AnswerOptions(contextTokenBudget: contextBudget)
        )

        for degradation in stream.searchResponse.degradations {
            printError("note: \(degradation.message)")
        }

        // Streamed rather than collected, so a long answer appears as it is produced.
        for try await token in stream.tokens {
            print(token, terminator: "")
            fflush(stdout)
        }
        print("")

        guard !stream.citations.isEmpty else { return }
        print("\nSources:")
        for citation in stream.citations {
            print("  [\(citation.index)] \(citation.label)")
        }
    }
}

// MARK: - status

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Index coverage, queue depth, failures, and versions."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Return dead-lettered jobs to the queue.")
    var retryFailed = false

    func run() async throws {
        var options = common
        if !retryFailed { options.readOnly = true }
        let store = try options.makeStore()
        defer { Task { await store.close() } }

        if retryFailed {
            let count = try await store.retryFailedJobs()
            print("Re-queued \(count) failed job(s).")
            return
        }

        let diagnostics = try await store.diagnostics()

        print("Corpus")
        print("  documents           \(diagnostics.documents)")
        print("  chunks              \(diagnostics.chunks)")
        print("  entities            \(diagnostics.entities)")
        print("  relations           \(diagnostics.relations)")

        print("\nCoverage")
        print("  embedded            \(diagnostics.coverage.embedded)/\(diagnostics.coverage.total)")
        print("  extracted           \(diagnostics.coverage.extracted)/\(diagnostics.coverage.total)")

        print("\nQueues")
        print(
            "  embed               pending \(diagnostics.embedQueue.pending), "
                + "running \(diagnostics.embedQueue.running), failed \(diagnostics.embedQueue.failed)"
        )
        print(
            "  extract             pending \(diagnostics.extractQueue.pending), "
                + "running \(diagnostics.extractQueue.running), failed \(diagnostics.extractQueue.failed)"
        )

        if !diagnostics.failures.isEmpty {
            print("\nFailed jobs")
            for job in diagnostics.failures.prefix(10) {
                print("  \(job.kind.rawValue) \(job.targetID) — \(job.lastError ?? "unknown")")
            }
            print("  Retry with: kb status --retry-failed")
        }

        print("\nVersions")
        var versions = diagnostics.versions
        versions["sqlite-vec"] = diagnostics.vectorExtensionVersion
        // Padded to the widest key rather than a fixed width, so a long key is aligned
        // rather than truncated.
        let width = (versions.keys.map(\.count).max() ?? 0) + 2
        for key in versions.keys.sorted() {
            print("  \(pad(key, to: width))\(versions[key]!)")
        }

        let health = await store.checkProviders()
        print("\nOllama")
        print("  endpoint            \(store.configuration.ollamaEndpoint.absoluteString)")
        print("  reachable           \(health.isReachable ? "yes" : "no")")
        if let message = health.message {
            print("  note                \(message)")
        }

        let pending = try await store.pendingMigration()
        if !pending.isEmpty {
            print("\nPending migration")
            for line in pending.summary.components(separatedBy: "\n") {
                print("  \(line)")
            }
        }
    }
}

// MARK: - rebuild

struct Rebuild: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Drop everything derived and re-index the corpus from scratch."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Do not ask for confirmation.")
    var yes = false

    func run() async throws {
        let store = try common.makeStore()
        defer { Task { await store.close() } }

        if !yes {
            let diagnostics = try await store.diagnostics()
            print(
                "This will discard \(diagnostics.chunks) chunk(s), \(diagnostics.entities) "
                    + "entities, and every embedding, then re-index from the corpus."
            )
            print("The Markdown files are not touched. Continue? [y/N] ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Cancelled.")
                throw ExitCode.failure
            }
        }

        let summary = try await store.rebuild()
        reportProgress(summary)
        try await drainQueues(store, quiet: false)
    }
}

// MARK: - compact

struct Compact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Reclaim space and optimize the keyword index."
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Also discard dead-lettered jobs.")
    var discardFailed = false

    func run() async throws {
        let store = try common.makeStore()
        defer { Task { await store.close() } }

        try await store.compact(discardingFailedJobs: discardFailed)
        print("Compacted.")
    }
}
