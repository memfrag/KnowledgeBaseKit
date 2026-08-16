import Foundation

/// Maps absolute paths onto corpus-relative ones.
///
/// This exists because macOS gives the same file more than one true absolute path.
/// `/var`, `/tmp`, and `/etc` are symlinks into `/private`, and Foundation is inconsistent
/// about which form it hands back: `standardizedFileURL` strips a leading `/private` for a
/// path that **exists**, but leaves it in place for one that does not.
///
/// That asymmetry bites exactly where it is hardest to notice. A file being created or
/// edited still exists when its event is handled, so its path normalizes to match a root
/// stored as `/var/...`. A file being *deleted* no longer exists, arrives from FSEvents as
/// `/private/var/...`, and a naive prefix comparison decides it was never in the corpus —
/// so the deletion is silently dropped.
///
/// Matching therefore happens against every spelling of every root.
struct PathMapper: Sendable {
    private let roots: [URL]
    /// Each root's path in both its plain and symlink-resolved form, longest first so that
    /// nested roots resolve to the most specific match.
    private let prefixes: [(index: Int, path: String)]

    init(roots: [URL]) {
        let standardized = roots.map { $0.standardizedFileURL }
        self.roots = standardized

        var prefixes: [(Int, String)] = []
        for (index, root) in standardized.enumerated() {
            let candidates = [
                root.path,
                root.resolvingSymlinksInPath().path,
                Self.canonical(root.path),
            ]
            for path in candidates {
                let terminated = path.hasSuffix("/") ? path : path + "/"
                if !prefixes.contains(where: { $0.1 == terminated }) {
                    prefixes.append((index, terminated))
                }
            }
        }
        self.prefixes = prefixes.sorted { $0.1.count > $1.1.count }
    }

    /// Strips a leading `/private` from the firmlinked system directories.
    ///
    /// Foundation normalizes in exactly one direction — `/private/var` becomes `/var` — and
    /// only for paths that still exist. FSEvents reports the `/private` form. Canonicalizing
    /// both sides the same way is what makes a deleted file's path comparable to a root's.
    private static func canonical(_ path: String) -> String {
        for directory in ["/var", "/tmp", "/etc"] where path.hasPrefix("/private" + directory) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    var isEmpty: Bool { roots.isEmpty }

    /// The corpus-relative path for `url`, or nil when it lies outside every root.
    ///
    /// With more than one root the result is prefixed by the root's index, so two roots each
    /// containing `notes/auth.md` do not collide.
    func relativePath(for url: URL) -> String? {
        let candidates = [
            url.standardizedFileURL.path,
            url.resolvingSymlinksInPath().path,
            Self.canonical(url.standardizedFileURL.path),
        ]

        for candidate in candidates {
            for (index, prefix) in prefixes where candidate.hasPrefix(prefix) {
                let suffix = String(candidate.dropFirst(prefix.count))
                guard !suffix.isEmpty else { continue }
                return roots.count > 1 ? "\(index)/\(suffix)" : suffix
            }
        }
        return nil
    }

    /// The inverse of ``relativePath(for:)``.
    func url(forRelativePath path: String) -> URL? {
        guard roots.count > 1 else {
            return roots.first.map { $0.appending(path: path) }
        }
        let parts = path.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let index = Int(parts[0]), roots.indices.contains(index) else {
            return nil
        }
        return roots[index].appending(path: String(parts[1]))
    }
}
