import Foundation

/// A Markdown file found on disk.
public struct CorpusFile: Sendable, Hashable {
    public var url: URL
    /// Path relative to its corpus root, prefixed with the root's index when there is more
    /// than one root, so two roots containing `notes/auth.md` do not collide.
    public var relativePath: String
    public var modifiedAt: Date
}

/// Decides which files belong to the corpus.
///
/// The built-in rules are not configurable because ignoring them is never what anyone wants:
/// dotfiles and dot-directories (`.git`, `.obsidian`, `.trash`) are tooling state, and a
/// non-`.md` file is not a document this package can read.
public struct IgnoreRules: Sendable {
    private let patterns: [String]

    public init(patterns: [String]) {
        self.patterns = patterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func shouldIgnoreDirectory(named name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        return matchesAnyPattern(name) || matchesAnyPattern(name + "/")
    }

    public func shouldIgnoreFile(named name: String, relativePath: String) -> Bool {
        if name.hasPrefix(".") { return true }
        guard name.lowercased().hasSuffix(".md") else { return true }
        return matchesAnyPattern(name) || matchesAnyPattern(relativePath)
    }

    /// gitignore-flavoured matching: a leading `/` anchors to the root, a trailing `/`
    /// means directories, and `*` is a glob within one path component.
    private func matchesAnyPattern(_ value: String) -> Bool {
        patterns.contains { pattern in
            var pattern = pattern
            if pattern.hasPrefix("/") { pattern.removeFirst() }
            if pattern.hasSuffix("/") { pattern.removeLast() }

            if pattern.contains("*") {
                return fnmatch(pattern, value, 0) == 0
                    || value.split(separator: "/").contains { fnmatch(pattern, String($0), 0) == 0 }
            }
            return value == pattern
                || value.split(separator: "/").contains { $0 == pattern }
        }
    }
}

/// Walks the corpus roots and reconciles them against the database.
public struct CorpusScanner: Sendable {
    public let roots: [URL]
    private let ignoreRules: IgnoreRules
    private let mapper: PathMapper

    public init(roots: [URL], ignorePatterns: [String]) {
        self.roots = roots.map { $0.standardizedFileURL }
        self.ignoreRules = IgnoreRules(patterns: ignorePatterns)
        self.mapper = PathMapper(roots: roots)
    }

    // MARK: - Path mapping

    /// The corpus-relative path for an absolute URL, or nil when it lies outside every root.
    public func relativePath(for url: URL) -> String? {
        mapper.relativePath(for: url)
    }

    /// The inverse of ``relativePath(for:)``.
    public func url(forRelativePath path: String) -> URL? {
        mapper.url(forRelativePath: path)
    }

    // MARK: - Scanning

    public func scan() throws -> [CorpusFile] {
        var files: [CorpusFile] = []
        for root in roots {
            try scan(root: root, into: &files)
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func scan(root: URL, into files: inout [CorpusFile]) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw KnowledgeStoreError.corpusRootUnreadable(root, underlying: "not a readable directory")
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .nameKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.producesRelativePathURLs]
            )
        else {
            throw KnowledgeStoreError.corpusRootUnreadable(root, underlying: "could not enumerate")
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.name ?? url.lastPathComponent

            if values?.isDirectory == true {
                if ignoreRules.shouldIgnoreDirectory(named: name) {
                    // Skipping the subtree matters as much as skipping the file: descending
                    // into .git on a large repository is the slowest thing a scan can do.
                    enumerator.skipDescendants()
                }
                continue
            }

            guard let relativePath = relativePath(for: url) else { continue }
            guard !ignoreRules.shouldIgnoreFile(named: name, relativePath: relativePath) else { continue }

            files.append(
                CorpusFile(
                    url: url.standardizedFileURL,
                    relativePath: relativePath,
                    modifiedAt: values?.contentModificationDate ?? Date()
                )
            )
        }
    }

    // MARK: - Reconciliation

    /// The difference between what is on disk and what is indexed.
    public struct Plan: Sendable {
        /// Files to parse and ingest.
        public var upserts: [CorpusFile] = []
        /// Documents whose file is gone.
        public var deletions: [String] = []
        /// Documents that only moved: `(oldPath, newFile)`. Handled by rewriting the row,
        /// which preserves chunks, embeddings, and the graph.
        public var renames: [(from: String, to: CorpusFile)] = []

        public var isEmpty: Bool {
            upserts.isEmpty && deletions.isEmpty && renames.isEmpty
        }
    }

    /// Pairs vanished paths with new paths of identical content, so a pure rename costs one
    /// UPDATE instead of a full re-embed and re-extract of the document.
    ///
    /// A rename combined with an edit is not detected, and correctly falls back to a delete
    /// plus an insert — the content is genuinely different, so the work is genuinely needed.
    public func reconcile(
        found: [CorpusFile],
        indexed: [(id: DocumentID, path: String, hash: String)],
        hashOfFile: (CorpusFile) throws -> String
    ) rethrows -> Plan {
        var plan = Plan()

        let indexedByPath = Dictionary(uniqueKeysWithValues: indexed.map { ($0.path, $0) })
        let foundPaths = Set(found.map(\.relativePath))

        let vanished = indexed.filter { !foundPaths.contains($0.path) }
        let appeared = found.filter { indexedByPath[$0.relativePath] == nil }

        // Only hash the newly appeared files, and only when something also vanished —
        // otherwise this would read every new file twice on a first index.
        var appearedByHash: [String: CorpusFile] = [:]
        if !vanished.isEmpty {
            for file in appeared {
                let hash = try hashOfFile(file)
                // First writer wins: with two identical new files, pairing either one with
                // the vanished path is equally correct, and the other is ingested normally.
                if appearedByHash[hash] == nil { appearedByHash[hash] = file }
            }
        }

        var claimed = Set<String>()
        for old in vanished {
            if let match = appearedByHash[old.hash], !claimed.contains(match.relativePath) {
                plan.renames.append((from: old.path, to: match))
                claimed.insert(match.relativePath)
            } else {
                plan.deletions.append(old.path)
            }
        }

        for file in found where !claimed.contains(file.relativePath) {
            plan.upserts.append(file)
        }

        return plan
    }
}
