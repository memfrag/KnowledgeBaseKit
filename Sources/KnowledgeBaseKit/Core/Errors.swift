import Foundation

public enum KnowledgeStoreError: Error, Sendable {
    /// Another process holds the write lock. Reads remain available.
    case databaseInUse(holder: String)
    /// The Ollama server could not be reached. Ingestion tolerates this by leaving jobs
    /// queued; ``KnowledgeStore/answer(_:options:)`` does not, since generation has no
    /// meaningful fallback.
    case ollamaUnavailable(endpoint: URL, underlying: String)
    /// The server is reachable but the configured model is not pulled.
    case modelNotFound(model: String, endpoint: URL)
    /// Stored version metadata is incompatible in a way automatic migration cannot resolve.
    case versionMismatch(key: String, stored: String, running: String)
    case corpusRootUnreadable(URL, underlying: String)
    /// A path was handed to a per-file API but lies outside every configured corpus root.
    case pathOutsideCorpus(URL)
    case documentNotFound(path: String)
    /// The extraction model returned output that could not be parsed after every retry.
    case extractionFailed(chunk: ChunkID, underlying: String)
    case invalidConfiguration(String)
}

extension KnowledgeStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseInUse(let holder):
            return "The knowledge base is open for writing by \(holder). Reads are still available."
        case .ollamaUnavailable(let endpoint, let underlying):
            return "Ollama at \(endpoint.absoluteString) is unreachable: \(underlying)"
        case .modelNotFound(let model, let endpoint):
            return "Model '\(model)' is not available at \(endpoint.absoluteString). Run: ollama pull \(model)"
        case .versionMismatch(let key, let stored, let running):
            return "Version mismatch for \(key): database has '\(stored)', configuration has '\(running)'."
        case .corpusRootUnreadable(let url, let underlying):
            return "Corpus root \(url.path) could not be read: \(underlying)"
        case .pathOutsideCorpus(let url):
            return "\(url.path) is not inside any configured corpus root."
        case .documentNotFound(let path):
            return "No indexed document at \(path)."
        case .extractionFailed(let chunk, let underlying):
            return "Extraction failed for chunk \(chunk): \(underlying)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        }
    }
}
