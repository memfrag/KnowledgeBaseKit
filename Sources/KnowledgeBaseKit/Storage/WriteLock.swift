import Darwin
import Foundation
import Synchronization

/// An advisory `flock` on a sidecar file, held for the lifetime of a writing store.
///
/// The rule is exclusive on writes, shared on reads: one indexer at a time, unlimited
/// concurrent readers. A second process that wants to *write* fails fast and is told who
/// holds the lock; a process that only wants to read never comes here at all.
///
/// The lock lives beside the database rather than in it, so that discovering the holder does
/// not require opening the database that may be mid-write.
final class WriteLock: Sendable {
    /// Nil once released. Held behind a mutex because releasing twice would `close()` a
    /// descriptor the process may since have reused — quite possibly one of the pooled
    /// SQLite connections.
    private let descriptor: Mutex<Int32?>
    private let path: String

    private init(descriptor: Int32, path: String) {
        self.descriptor = Mutex(descriptor)
        self.path = path
    }

    static func lockURL(for databaseURL: URL) -> URL {
        databaseURL.appendingPathExtension("lock")
    }

    static func acquire(for databaseURL: URL) throws -> WriteLock {
        let lockPath = lockURL(for: databaseURL).path
        let handle = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else {
            throw KnowledgeStoreError.corpusRootUnreadable(
                databaseURL,
                underlying: "could not open lock file at \(lockPath): \(String(cString: strerror(errno)))"
            )
        }

        if flock(handle, LOCK_EX | LOCK_NB) != 0 {
            let holder = readHolder(descriptor: handle)
            close(handle)
            throw KnowledgeStoreError.databaseInUse(holder: holder)
        }

        // Stamp the holder so the next process can name it rather than reporting a bare
        // "locked". Written after acquiring, so it always describes the current owner.
        let description =
            "\(ProcessInfo.processInfo.processName) (pid \(ProcessInfo.processInfo.processIdentifier))"
        ftruncate(handle, 0)
        lseek(handle, 0, SEEK_SET)
        _ = description.withCString { pointer in
            Darwin.write(handle, pointer, strlen(pointer))
        }
        fsync(handle)

        return WriteLock(descriptor: handle, path: lockPath)
    }

    private static func readHolder(descriptor: Int32) -> String {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        guard count > 0 else { return "another process" }
        let text = String(decoding: buffer[0..<count], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "another process" : text
    }

    /// Idempotent: releasing an already-released lock does nothing.
    func release() {
        descriptor.withLock { handle in
            guard let open = handle else { return }
            flock(open, LOCK_UN)
            close(open)
            handle = nil
        }
    }

    deinit {
        // The kernel drops the lock when the descriptor closes, including on crash, so a
        // process that dies mid-index never leaves the database permanently locked.
        release()
    }
}
