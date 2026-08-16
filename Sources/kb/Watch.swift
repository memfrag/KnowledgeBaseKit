import ArgumentParser
import Foundation
import KnowledgeBaseKit

/// Keeps the index current as files change.
///
/// Holds the write lock for as long as it runs, so other write commands are refused while it
/// is up — read commands and `kb serve` are unaffected.
struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch the corpus and re-index changes as they happen.",
        discussion: """
            Reconciles once at startup, then follows filesystem events: rapid saves are \
            coalesced, hidden directories and non-Markdown files are ignored, and a large \
            burst (a branch switch, say) collapses into a single full reconciliation.

            Holds the write lock. Reads — `kb search`, `kb answer`, `kb serve` — keep working.
            """
    )

    @OptionGroup var common: CommonOptions

    @Flag(name: .long, help: "Skip the reconciliation pass at startup.")
    var noInitialSync = false

    func run() async throws {
        let store = try common.makeStore()

        if !noInitialSync {
            let summary = try await store.sync()
            reportProgress(summary)
        }

        await store.startProcessing()
        await store.startWatching()

        let roots = store.configuration.corpusRoots.map(\.path).joined(separator: ", ")
        printError("Watching \(roots). Press Ctrl-C to stop.")

        // Ctrl-C should release the write lock rather than leave a stale one behind. The
        // kernel drops the flock on exit either way, but stopping cleanly also lets any
        // in-flight database write finish.
        let stopped = SignalBox()
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { stopped.signal() }
        source.resume()
        signal(SIGINT, SIG_IGN)

        await stopped.wait()

        printError("\nStopping...")
        await store.close()
    }
}

/// Bridges a signal handler into async/await.
private final class SignalBox: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    private let lock = NSLock()

    func signal() {
        lock.lock()
        let waiting = continuation
        continuation = nil
        fired = true
        lock.unlock()
        waiting?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
