import Foundation
import OSLog

/// What the watcher decided to do about a burst of filesystem events.
public enum WatchEvent: Sendable, Hashable {
    /// These specific paths changed and should be re-ingested or removed.
    case changed([URL])
    /// Too much moved at once to handle file by file — the caller should run a full
    /// reconciliation instead. This is the `git checkout` case.
    case bulkChange
}

/// Watches the corpus roots and turns raw FSEvents into ingestion work.
///
/// Raw FSEvents traffic is noisy in three specific ways, each handled here:
/// - editors save by writing a temporary file and renaming, so one save is several events;
/// - tools churn inside hidden directories that hold no documents;
/// - a branch switch can touch thousands of files at once.
public actor CorpusWatcher {
    private let roots: [URL]
    private let configuration: WatcherConfiguration
    private let ignoreRules: IgnoreRules
    private let mapper: PathMapper
    private let logger = Logger(subsystem: "KnowledgeBaseKit", category: "watcher")

    private var stream: FSEventStreamRef?
    private var pending: Set<URL> = []
    private var flushTask: Task<Void, Never>?
    private var continuation: AsyncStream<WatchEvent>.Continuation?

    public init(roots: [URL], configuration: WatcherConfiguration, ignorePatterns: [String]) {
        self.roots = roots.map { $0.standardizedFileURL }
        self.configuration = configuration
        self.ignoreRules = IgnoreRules(patterns: ignorePatterns)
        self.mapper = PathMapper(roots: roots)
    }

    /// Starts watching. The stream finishes when ``stop()`` is called.
    public func start() -> AsyncStream<WatchEvent> {
        stop()

        let (stream, continuation) = AsyncStream<WatchEvent>.makeStream()
        self.continuation = continuation

        guard !roots.isEmpty else {
            continuation.finish()
            return stream
        }

        // FSEvents calls back on a dispatch queue with a raw context pointer, so the actor is
        // bridged through an unmanaged reference that the stream owns for its lifetime.
        let context = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
        context.initialize(
            to: FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(Box(watcher: self)).toOpaque(),
                retain: nil,
                release: { pointer in
                    guard let pointer else { return }
                    Unmanaged<Box>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
        )
        defer {
            context.deinitialize(count: 1)
            context.deallocate()
        }

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()

            // Without `kFSEventStreamCreateFlagUseCFTypes` the paths arrive as a plain
            // `char **`. With that flag they would be a CFArray of CFStrings instead — the
            // two are not interchangeable, and reading one as the other yields no usable
            // paths at all.
            let paths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)

            var urls: [URL] = []
            var needsFullScan = false

            for index in 0..<count {
                let eventFlags = flags[index]
                // A dropped event buffer or a root that itself moved invalidates
                // path-by-path reasoning; only a full reconciliation can recover.
                if eventFlags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0
                    || eventFlags & UInt32(kFSEventStreamEventFlagRootChanged) != 0
                    || eventFlags & UInt32(kFSEventStreamEventFlagKernelDropped) != 0
                    || eventFlags & UInt32(kFSEventStreamEventFlagUserDropped) != 0
                {
                    needsFullScan = true
                    continue
                }
                urls.append(URL(fileURLWithPath: String(cString: paths[index])))
            }

            let watcher = box.watcher
            Task { await watcher.enqueue(urls, needsFullScan: needsFullScan) }
        }

        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                context,
                roots.map(\.path) as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                configuration.debounceInterval / 2,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                )
            )
        else {
            logger.error("Could not create an FSEvents stream for the corpus roots")
            continuation.finish()
            return stream
        }

        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "KnowledgeBaseKit.watcher"))
        FSEventStreamStart(created)
        self.stream = created

        continuation.onTermination = { [weak self] _ in
            Task { await self?.stop() }
        }

        return stream
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Debouncing

    fileprivate func enqueue(_ urls: [URL], needsFullScan: Bool = false) {
        if needsFullScan {
            // Nothing path-level is trustworthy after a dropped buffer.
            pending.removeAll()
            flushTask?.cancel()
            flushTask = nil
            continuation?.yield(.bulkChange)
            return
        }

        for url in urls {
            let standardized = url.standardizedFileURL
            let name = standardized.lastPathComponent

            // Ignore rules are applied to the path *below the root*. Applying them to the
            // absolute path would reject everything under a root that itself lives beneath a
            // dot-directory, which is common for scratch and container paths.
            guard let relative = mapper.relativePath(for: standardized) else { continue }
            guard !ignoreRules.shouldIgnoreFile(named: name, relativePath: relative) else {
                continue
            }
            // A rename-into-place fires on the temporary file too; skipping hidden segments
            // is what turns one save into one re-ingest rather than three.
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
                continue
            }
            pending.insert(standardized)
        }

        guard !pending.isEmpty else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let interval = configuration.debounceInterval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()

        if batch.count >= configuration.burstThreshold {
            // Ingesting these one by one would queue thousands of jobs for work a single
            // reconciliation pass does in one walk.
            logger.notice("Collapsing \(batch.count) filesystem events into a full sync")
            continuation?.yield(.bulkChange)
        } else {
            continuation?.yield(.changed(Array(batch).sorted { $0.path < $1.path }))
        }
    }

    /// Holds a strong reference to the actor across the C callback boundary.
    private final class Box {
        let watcher: CorpusWatcher
        init(watcher: CorpusWatcher) { self.watcher = watcher }
    }
}
