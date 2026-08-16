import Foundation
import Testing

@testable import KnowledgeBaseKit

/// Polls until `condition` holds or the deadline passes.
///
/// FSEvents delivery is asynchronous and its latency is not contractual, so these tests wait
/// on the observable outcome rather than sleeping for a fixed interval.
private func eventually(
    timeout: Duration = .seconds(15),
    poll: Duration = .milliseconds(100),
    _ condition: () async throws -> Bool
) async rethrows -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return true }
        try? await Task.sleep(for: poll)
    }
    return try await condition()
}

@Suite("Filesystem watcher", .serialized)
struct WatcherTests {

    @Test("A file created after watching starts is indexed")
    func detectsCreation() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("first.md", "# First\n\nOriginal content about widgets.")
        try await vault.store.sync()
        await vault.store.startWatching()

        try vault.write("second.md", "# Second\n\nSprockets are made on the assembly line.")

        let indexed = try await eventually {
            let response = try await vault.store.search("sprockets assembly")
            return response.results.contains { $0.documentPath == "second.md" }
        }
        #expect(indexed)

        await vault.store.stopWatching()
    }

    @Test("An edit to a watched file is re-indexed")
    func detectsModification() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("notes.md", "# Notes\n\nWidgets are in production.")
        try await vault.store.sync()
        await vault.store.startWatching()

        try vault.write("notes.md", "# Notes\n\nWidgets were discontinued last year.")

        let updated = try await eventually {
            let response = try await vault.store.search("discontinued")
            return !response.results.isEmpty
        }
        #expect(updated)

        await vault.store.stopWatching()
    }

    @Test("Deleting a watched file removes it from the index")
    func detectsDeletion() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("keep.md", "# Keep\n\nUnrelated content here.")
        try vault.write("gone.md", "# Gone\n\nSprockets are made on the assembly line.")
        try await vault.store.sync()

        let before = try await vault.store.diagnostics()
        #expect(before.documents == 2)

        await vault.store.startWatching()
        try vault.delete("gone.md")

        let removed = try await eventually {
            let diagnostics = try await vault.store.diagnostics()
            return diagnostics.documents == 1
        }
        #expect(removed)

        await vault.store.stopWatching()
    }

    @Test("Ignored files never reach the index")
    func ignoresNoise() async throws {
        let vault = try TestVault(configure: { $0.ignorePatterns = ["Archive"] })
        defer { vault.cleanup() }

        try vault.write("real.md", "# Real\n\nIndexed content.")
        try await vault.store.sync()
        await vault.store.startWatching()

        try vault.write("notes.txt", "not markdown")
        try vault.write(".hidden.md", "# Hidden")
        try vault.write("Archive/old.md", "# Archived")
        // A file that *is* wanted, written last: once it lands, the ignored ones have had
        // at least as long to arrive, so their absence is meaningful rather than a race.
        try vault.write("second.md", "# Second\n\nAlso indexed.")

        let arrived = try await eventually {
            let diagnostics = try await vault.store.diagnostics()
            return diagnostics.documents == 2
        }
        #expect(arrived)

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.documents == 2)

        await vault.store.stopWatching()
    }

    @Test("Stopping the watcher stops ingestion")
    func stopIsEffective() async throws {
        let vault = try TestVault()
        defer { vault.cleanup() }

        try vault.write("first.md", "# First\n\nContent.")
        try await vault.store.sync()

        await vault.store.startWatching()
        await vault.store.stopWatching()

        try vault.write("after.md", "# After\n\nShould not be indexed automatically.")
        try? await Task.sleep(for: .seconds(2))

        let diagnostics = try await vault.store.diagnostics()
        #expect(diagnostics.documents == 1)
    }
}

@Suite("Watcher event policy")
struct WatcherPolicyTests {
    @Test("A burst larger than the threshold collapses into one full sync")
    func burstCollapses() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("kbkit-burst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = CorpusWatcher(
            roots: [root],
            configuration: WatcherConfiguration(debounceInterval: 0.1, burstThreshold: 5),
            ignorePatterns: []
        )

        let events = await watcher.start()

        // Written directly rather than through FSEvents so the assertion is about the
        // collapse policy, not about delivery timing.
        for index in 0..<10 {
            try "# Note \(index)".write(
                to: root.appendingPathComponent("note-\(index).md"),
                atomically: true,
                encoding: .utf8
            )
        }

        var received: WatchEvent?
        for await event in events {
            received = event
            break
        }
        await watcher.stop()

        // Ingesting ten files one by one would queue work a single reconciliation does in
        // one walk.
        #expect(received == .bulkChange)
    }
}
