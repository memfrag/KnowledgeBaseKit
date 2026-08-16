import Foundation

/// Applies size bounds to parsed sections and mints stable chunk IDs.
///
/// Heading-based chunking with two corrections:
/// - sections over ``ChunkingConfiguration/maximumTokens`` are subdivided at paragraph
///   boundaries into siblings that share the same heading path;
/// - adjacent sections under ``ChunkingConfiguration/minimumTokens`` are merged, taking the
///   heading path of the first.
///
/// Oversized sections are split rather than truncated. A truncated chunk would still be
/// fully indexed in FTS5 while its embedding covered only the head of the text, so keyword
/// and vector recall would silently disagree about what the corpus contains.
public struct Chunker: Sendable {
    public let configuration: ChunkingConfiguration

    /// Bumped when the chunking algorithm changes in a way that would produce different
    /// output for the same input. Participates in the chunker version key, so a change
    /// re-chunks the corpus and cascades to re-embed and re-extract.
    public static let algorithmVersion = 1

    public init(configuration: ChunkingConfiguration = .default) {
        self.configuration = configuration
    }

    /// The chunker version key: algorithm plus the bounds that shape its output.
    public var versionKey: String {
        "\(Self.algorithmVersion):\(configuration.minimumTokens):\(configuration.maximumTokens)"
    }

    public func chunk(_ document: ParsedDocument, documentID: DocumentID) -> [Chunk] {
        let merged = mergeUndersized(document.sections)
        let bounded = merged.flatMap(splitOversized)

        // Occurrence disambiguates chunks sharing a heading path — both the siblings a split
        // produces and genuinely duplicated headings in the source.
        var occurrences: [String: Int] = [:]
        var chunks: [Chunk] = []
        chunks.reserveCapacity(bounded.count)

        for (ordinal, section) in bounded.enumerated() {
            let key = section.headingPath.canonicalForm
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1

            chunks.append(
                Chunk(
                    id: ChunkID(
                        document: documentID,
                        headingPath: section.headingPath,
                        occurrence: occurrence
                    ),
                    documentID: documentID,
                    ordinal: ordinal,
                    headingPath: section.headingPath,
                    content: section.text,
                    contentHash: ContentHash.of(section.text),
                    occurrence: occurrence
                )
            )
        }

        return chunks
    }

    // MARK: - Merging

    private func mergeUndersized(_ sections: [ParsedSection]) -> [ParsedSection] {
        var result: [ParsedSection] = []

        for section in sections {
            guard !section.text.isEmpty || !section.headingPath.isEmpty else { continue }

            if var previous = result.last,
                TokenEstimator.estimate(previous.text) < configuration.minimumTokens
            {
                let combinedText = previous.text.isEmpty
                    ? headingLine(for: section) + section.text
                    : previous.text + "\n\n" + headingLine(for: section) + section.text

                // Only merge when the result still fits; otherwise a run of small sections
                // would snowball into one oversized chunk that the split pass has to undo.
                if TokenEstimator.estimate(combinedText) <= configuration.maximumTokens {
                    previous.text = combinedText
                    result[result.count - 1] = previous
                    continue
                }
            }

            result.append(section)
        }

        return result
    }

    /// When a subsection is folded into its parent, its heading is kept inline so the text
    /// does not lose the structure that gave it meaning.
    private func headingLine(for section: ParsedSection) -> String {
        guard let leaf = section.headingPath.leaf else { return "" }
        return "## \(leaf)\n\n"
    }

    // MARK: - Splitting

    private func splitOversized(_ section: ParsedSection) -> [ParsedSection] {
        guard TokenEstimator.estimate(section.text) > configuration.maximumTokens else {
            return [section]
        }

        let units = paragraphs(in: section.text)
        var groups: [String] = []
        var current: [String] = []
        var currentTokens = 0

        func flushCurrent() {
            guard !current.isEmpty else { return }
            groups.append(current.joined(separator: "\n\n"))
            current = []
            currentTokens = 0
        }

        for unit in units {
            let unitTokens = TokenEstimator.estimate(unit.text)

            // A single unit over budget cannot be packed. Prose gets broken down further;
            // an atomic unit is emitted whole, because a code block cut in half is worse
            // than an oversized chunk — both to read and to embed.
            if unitTokens > configuration.maximumTokens {
                flushCurrent()
                if unit.isAtomic {
                    groups.append(unit.text)
                } else {
                    groups.append(contentsOf: splitLongParagraph(unit.text))
                }
                continue
            }

            if currentTokens + unitTokens > configuration.maximumTokens {
                flushCurrent()
            }

            current.append(unit.text)
            currentTokens += unitTokens
        }

        flushCurrent()

        return groups.map { ParsedSection(headingPath: section.headingPath, text: $0) }
    }

    /// A splittable unit of a section.
    private struct TextUnit {
        var text: String
        /// Atomic units are never subdivided, however long they are.
        var isAtomic: Bool
    }

    /// Splits on blank lines, keeping fenced code blocks intact as atomic units.
    private func paragraphs(in text: String) -> [TextUnit] {
        var units: [TextUnit] = []
        var current: [String] = []
        var fence: String?
        var currentIsAtomic = false

        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { units.append(TextUnit(text: joined, isAtomic: currentIsAtomic)) }
            current = []
            currentIsAtomic = false
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let openFence = fence {
                current.append(line)
                if trimmed.hasPrefix(openFence) {
                    fence = nil
                    // The closing fence ends the unit, so a fence and the prose that follows
                    // it never merge into one unit that would then be treated as atomic.
                    flush()
                }
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // A fence opening mid-paragraph closes the prose unit first.
                flush()
                fence = String(trimmed.prefix(3))
                currentIsAtomic = true
                current.append(line)
                continue
            }

            if trimmed.isEmpty {
                flush()
            } else {
                current.append(line)
            }
        }

        // An unterminated fence still reaches here; it stays atomic rather than being
        // re-parsed as prose.
        flush()
        return units
    }

    /// Last resort for a paragraph that exceeds the budget on its own: split at sentence
    /// boundaries, and if a single sentence is still too long, at word boundaries.
    private func splitLongParagraph(_ paragraph: String) -> [String] {
        let sentences = sentenceUnits(in: paragraph)
        var groups: [String] = []
        var current: [String] = []
        var currentTokens = 0

        for sentence in sentences {
            let tokens = TokenEstimator.estimate(sentence)

            if tokens > configuration.maximumTokens {
                if !current.isEmpty {
                    groups.append(current.joined(separator: " "))
                    current = []
                    currentTokens = 0
                }
                groups.append(contentsOf: splitByWords(sentence))
                continue
            }

            if currentTokens + tokens > configuration.maximumTokens, !current.isEmpty {
                groups.append(current.joined(separator: " "))
                current = []
                currentTokens = 0
            }

            current.append(sentence)
            currentTokens += tokens
        }

        if !current.isEmpty { groups.append(current.joined(separator: " ")) }
        return groups
    }

    private func sentenceUnits(in text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) {
            substring, _, _, _ in
            if let substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(substring.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    private func splitByWords(_ text: String) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Invert the token estimate to get a word budget for one group.
        let wordsPerGroup = max(1, Int(Double(configuration.maximumTokens) / 1.3))
        return stride(from: 0, to: words.count, by: wordsPerGroup).map { start in
            words[start..<min(start + wordsPerGroup, words.count)].joined(separator: " ")
        }
    }
}
