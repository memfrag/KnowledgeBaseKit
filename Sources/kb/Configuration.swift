import ArgumentParser
import Foundation
import KnowledgeBaseKit

/// The on-disk config file.
///
/// Lives at the corpus root by default so that it travels with the vault — a machine that
/// syncs the notes gets the settings too, and two vaults can differ.
struct ConfigFile: Codable {
    var roots: [String]?
    var database: String?
    var ignore: [String]?
    var endpoint: String?
    var embeddingModel: String?
    var embeddingDimensions: Int?
    var extractionModel: String?
    var graphExtraction: Bool?
    var minimumTokens: Int?
    var maximumTokens: Int?
    var workerCount: Int?

    static let fileName = ".kb.json"

    /// Searches the explicit path, then the corpus root, then the user config directory.
    static func load(explicit: String?, roots: [URL]) throws -> (ConfigFile, URL)? {
        var candidates: [URL] = []
        if let explicit {
            candidates.append(URL(fileURLWithPath: explicit))
        } else {
            candidates.append(contentsOf: roots.map { $0.appendingPathComponent(fileName) })
            candidates.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appending(path: ".config/kb/config.json")
            )
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            let data = try Data(contentsOf: candidate)
            return (try JSONDecoder().decode(ConfigFile.self, from: data), candidate)
        }
        return nil
    }
}

/// Flags shared by every subcommand.
struct CommonOptions: ParsableArguments {
    @Option(
        name: [.customShort("r"), .long],
        help: "A corpus root directory. Repeat for several. Defaults to the config file, then the current directory."
    )
    var root: [String] = []

    @Option(name: [.customShort("d"), .long], help: "Database path. Defaults to <root>/.kb/store.sqlite")
    var database: String?

    @Option(name: .long, help: "Path to a config file. Defaults to <root>/.kb.json, then ~/.config/kb/config.json")
    var config: String?

    @Option(name: .long, help: "Ollama endpoint.")
    var endpoint: String?

    @Option(name: .long, help: "Embedding model.")
    var embeddingModel: String?

    @Option(name: .long, help: "Embedding dimensions. Must match the model.")
    var embeddingDimensions: Int?

    @Option(name: .long, help: "Extraction and answering model.")
    var extractionModel: String?

    @Flag(
        name: .long,
        help: """
            Do not build the knowledge graph. Skips the extraction model entirely and indexes \
            far faster; keyword and vector search keep working, graph tools do not.
            """
    )
    var noGraph = false

    @Flag(name: .long, help: "Open read-only. Never takes the write lock.")
    var readOnly = false

    /// Resolves flags over config file over defaults.
    func resolve() throws -> (configuration: KnowledgeStoreConfiguration, databaseURL: URL) {
        var roots = root.map { URL(fileURLWithPath: $0).standardizedFileURL }

        let loaded = try ConfigFile.load(
            explicit: config,
            roots: roots.isEmpty ? [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] : roots
        )
        let file = loaded?.0
        let fileDirectory = loaded?.1.deletingLastPathComponent()

        if roots.isEmpty, let configured = file?.roots, !configured.isEmpty {
            // Relative roots in a config file resolve against the file, so a vault can be
            // moved wholesale without editing it.
            roots = configured.map { path in
                let url = URL(fileURLWithPath: path)
                return path.hasPrefix("/")
                    ? url.standardizedFileURL
                    : (fileDirectory?.appending(path: path).standardizedFileURL ?? url)
            }
        }
        if roots.isEmpty {
            roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL]
        }

        let databasePath = database ?? file?.database
        let databaseURL: URL
        if let databasePath {
            databaseURL = URL(fileURLWithPath: databasePath).standardizedFileURL
        } else {
            // Hidden directory inside the first root: it travels with the vault and the
            // scanner ignores dot-directories, so the store never indexes itself.
            databaseURL = roots[0].appending(path: ".kb/store.sqlite")
        }

        var configuration = KnowledgeStoreConfiguration(corpusRoots: roots)
        configuration.ignorePatterns = file?.ignore ?? []
        configuration.allowsWriting = !readOnly

        if let endpoint = endpoint ?? file?.endpoint {
            guard let url = URL(string: endpoint) else {
                throw ValidationError("Invalid endpoint: \(endpoint)")
            }
            configuration.ollamaEndpoint = url
        }

        configuration.embedding = EmbeddingConfiguration(
            model: embeddingModel ?? file?.embeddingModel ?? EmbeddingConfiguration.default.model,
            dimensions: embeddingDimensions ?? file?.embeddingDimensions
                ?? EmbeddingConfiguration.default.dimensions
        )
        configuration.extraction = ExtractionConfiguration(
            model: extractionModel ?? file?.extractionModel ?? ExtractionConfiguration.default.model
        )
        configuration.graphExtraction = noGraph ? false : (file?.graphExtraction ?? true)
        configuration.chunking = ChunkingConfiguration(
            minimumTokens: file?.minimumTokens ?? ChunkingConfiguration.default.minimumTokens,
            maximumTokens: file?.maximumTokens ?? ChunkingConfiguration.default.maximumTokens
        )
        if let workerCount = file?.workerCount {
            configuration.workerCount = workerCount
        }

        return (configuration, databaseURL)
    }

    /// Opens the store, reporting any migration it is about to perform.
    func makeStore() throws -> KnowledgeStore {
        let (configuration, databaseURL) = try resolve()
        return try KnowledgeStore(
            databaseURL: databaseURL,
            configuration: configuration,
            migrationHandler: { plan in
                FileHandle.standardError.write(
                    Data("Migrating:\n\(plan.summary)\n".utf8)
                )
                return true
            }
        )
    }
}
