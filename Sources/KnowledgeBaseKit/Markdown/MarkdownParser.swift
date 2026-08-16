import Foundation
import Markdown

/// One heading section of a document, before size bounds are applied.
public struct ParsedSection: Sendable, Hashable {
    public var headingPath: HeadingPath
    /// The section body as it appears in the file, excluding the heading line itself.
    public var text: String
}

public struct ParsedDocument: Sendable {
    public var title: String
    public var metadata: DocumentMetadata
    public var sections: [ParsedSection]
    /// Link destinations found anywhere in the document, in source order. Preserved for
    /// callers and for future wikilink/backlink work; not yet resolved into graph edges.
    public var links: [String]
    public var warnings: [String]
}

/// Turns a Markdown file into heading sections.
///
/// Section boundaries come from swift-markdown's parse tree rather than a line scan, so a
/// `#` inside a fenced code block is correctly not a heading. The section *text* is then
/// sliced out of the original source by line, which preserves the author's exact formatting
/// — re-rendering via `format()` would normalize emphasis markers and list bullets, and the
/// stored Markdown is meant to be what the file says.
public struct MarkdownParser: Sendable {
    public init() {}

    public func parse(source: String, filenameStem: String) -> ParsedDocument {
        let frontMatter = FrontMatterParser.parse(source)
        let body = frontMatter.body
        let document = Markdown.Document(parsing: body, options: [])

        let bodyLines = body.components(separatedBy: "\n")
        let headings = topLevelHeadings(in: document)
        let title = resolveTitle(
            frontMatterTitle: frontMatter.metadata.title,
            headings: headings,
            filenameStem: filenameStem
        )

        let sections = buildSections(headings: headings, bodyLines: bodyLines, title: title)

        return ParsedDocument(
            title: title,
            metadata: frontMatter.metadata,
            sections: sections,
            links: collectLinks(in: document),
            warnings: frontMatter.warnings
        )
    }

    // MARK: - Headings

    private struct HeadingMark {
        var level: Int
        var text: String
        /// 0-based index into `bodyLines` of the heading's first line.
        var startLine: Int
        /// 0-based index of the heading's last line. Setext headings span two lines.
        var endLine: Int
    }

    private func topLevelHeadings(in document: Markdown.Document) -> [HeadingMark] {
        // Only top-level headings define sections. A heading nested inside a blockquote or
        // list item is part of that block's content, not a new section of the document.
        document.children.compactMap { child -> HeadingMark? in
            guard let heading = child as? Heading, let range = heading.range else { return nil }
            return HeadingMark(
                level: heading.level,
                text: heading.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
                startLine: range.lowerBound.line - 1,
                endLine: range.upperBound.line - 1
            )
        }
    }

    private func resolveTitle(
        frontMatterTitle: String?,
        headings: [HeadingMark],
        filenameStem: String
    ) -> String {
        if let title = frontMatterTitle, !title.isEmpty { return title }
        if let firstH1 = headings.first(where: { $0.level == 1 })?.text, !firstH1.isEmpty {
            return firstH1
        }
        return filenameStem
    }

    // MARK: - Sections

    private func buildSections(
        headings: [HeadingMark],
        bodyLines: [String],
        title: String
    ) -> [ParsedSection] {
        var sections: [ParsedSection] = []
        // The heading stack, indexed by level. Walking it is what turns a flat list of
        // headings into a path.
        var stack: [(level: Int, text: String)] = []

        let normalizedTitle = NameNormalizer.normalize(title)

        func currentPath() -> HeadingPath {
            var components = stack.map(\.text)
            // The path is rooted at the document title. When the title *is* the leading H1 —
            // the common `# Title` at the top of a file — that heading would otherwise appear
            // twice, as both root and first component.
            if let first = components.first, NameNormalizer.normalize(first) == normalizedTitle {
                components.removeFirst()
            }
            return HeadingPath([title] + components)
        }

        // Content before the first heading belongs to the document root.
        let firstHeadingLine = headings.first?.startLine ?? bodyLines.count
        if firstHeadingLine > 0 {
            let preamble = slice(bodyLines, from: 0, upTo: firstHeadingLine)
            if !preamble.isEmpty {
                sections.append(ParsedSection(headingPath: HeadingPath([title]), text: preamble))
            }
        }

        for (index, heading) in headings.enumerated() {
            while let last = stack.last, last.level >= heading.level {
                stack.removeLast()
            }
            stack.append((heading.level, heading.text))

            let contentStart = heading.endLine + 1
            let contentEnd = index + 1 < headings.count ? headings[index + 1].startLine : bodyLines.count
            let text = slice(bodyLines, from: contentStart, upTo: contentEnd)

            // A heading with no body of its own is still worth a chunk when it has no
            // children either — otherwise the heading text itself would be unsearchable.
            let hasChildSection = index + 1 < headings.count && headings[index + 1].level > heading.level
            if text.isEmpty && hasChildSection { continue }

            sections.append(ParsedSection(headingPath: currentPath(), text: text))
        }

        return sections
    }

    private func slice(_ lines: [String], from start: Int, upTo end: Int) -> String {
        guard start < end, start < lines.count else { return "" }
        let clampedEnd = min(end, lines.count)
        return lines[start..<clampedEnd]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Links

    private func collectLinks(in document: Markdown.Document) -> [String] {
        var destinations: [String] = []
        var walker = LinkCollector()
        walker.visit(document)
        destinations = walker.destinations
        return destinations
    }

    private struct LinkCollector: MarkupWalker {
        var destinations: [String] = []

        mutating func visitLink(_ link: Link) {
            if let destination = link.destination, !destination.isEmpty {
                destinations.append(destination)
            }
            descendInto(link)
        }

        mutating func visitImage(_ image: Image) {
            if let source = image.source, !source.isEmpty {
                destinations.append(source)
            }
            descendInto(image)
        }
    }
}

/// Rough token estimate, used only to apply the chunker's size bounds.
///
/// The real token count depends on the embedding model's tokenizer, which is not exposed by
/// Ollama. The bounds exist to keep chunks in a sane size band rather than to hit an exact
/// budget, so an estimate is sufficient — and it keeps chunking deterministic and
/// model-independent, which matters because the chunker version is a migration key.
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Whitespace-delimited words, scaled for subword splitting and punctuation.
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(1, Int(Double(words) * 1.3))
    }
}
