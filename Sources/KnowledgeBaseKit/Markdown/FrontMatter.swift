import Foundation
import Yams

/// Splits YAML front matter off the head of a Markdown file.
///
/// cmark-gfm has no notion of front matter, so this runs before swift-markdown sees the
/// document. Malformed front matter never fails ingestion: the document is indexed with
/// empty metadata and a warning is recorded.
public enum FrontMatterParser {
    public struct Result: Sendable {
        public var metadata: DocumentMetadata
        /// The document with front matter removed.
        public var body: String
        /// Number of lines consumed, so callers can map body lines back to file lines.
        public var consumedLines: Int
        public var warnings: [String]
    }

    private static let fence = "---"

    public static func parse(_ source: String) -> Result {
        let lines = source.components(separatedBy: "\n")

        // Front matter must open on the very first line. A `---` anywhere else is a
        // thematic break and belongs to the document body.
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == fence else {
            return Result(metadata: .empty, body: source, consumedLines: 0, warnings: [])
        }

        guard
            let closingIndex = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == fence
            })
        else {
            // An unterminated opening fence is far more likely to be a thematic break at the
            // top of a document than truncated front matter, so the document is left intact.
            return Result(metadata: .empty, body: source, consumedLines: 0, warnings: [])
        }

        let yamlLines = lines[1..<closingIndex]
        let bodyLines = lines[(closingIndex + 1)...]
        let body = bodyLines.joined(separator: "\n")
        let consumed = closingIndex + 1

        guard !yamlLines.isEmpty else {
            return Result(metadata: .empty, body: body, consumedLines: consumed, warnings: [])
        }

        do {
            let loaded = try Yams.load(yaml: yamlLines.joined(separator: "\n"))
            guard let mapping = loaded as? [String: Any] else {
                return Result(
                    metadata: .empty,
                    body: body,
                    consumedLines: consumed,
                    warnings: ["Front matter is not a mapping; ignored."]
                )
            }
            return Result(
                metadata: metadata(from: mapping),
                body: body,
                consumedLines: consumed,
                warnings: []
            )
        } catch {
            return Result(
                metadata: .empty,
                body: body,
                consumedLines: consumed,
                warnings: ["Front matter could not be parsed as YAML: \(error.localizedDescription)"]
            )
        }
    }

    /// Three fields are semantic; everything else is preserved verbatim but carries no
    /// built-in behavior.
    private static func metadata(from mapping: [String: Any]) -> DocumentMetadata {
        var additional: [String: JSONValue] = [:]
        var title: String?
        var tags: [String] = []
        var aliases: [String] = []

        for (key, value) in mapping {
            let json = JSONValue(any: value)
            switch key.lowercased() {
            case "title":
                title = json.stringValue
            case "tags", "tag":
                tags.append(contentsOf: json.stringListValue ?? [])
            case "aliases", "alias":
                aliases.append(contentsOf: json.stringListValue ?? [])
            default:
                additional[key] = json
            }
        }

        return DocumentMetadata(
            title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
            tags: normalize(tags),
            aliases: normalize(aliases),
            additional: additional
        )
    }

    private static func normalize(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }
}
