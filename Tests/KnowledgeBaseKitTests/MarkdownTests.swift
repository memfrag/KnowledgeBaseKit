import Testing

@testable import KnowledgeBaseKit

@Suite("Front matter")
struct FrontMatterTests {
    @Test("Semantic fields are lifted, everything else is preserved")
    func semanticFields() {
        let source = """
            ---
            title: Authentication
            tags: [security, backend]
            aliases:
              - Auth
              - AuthN
            status: draft
            reviewed: 2026-01-15
            ---

            Body text.
            """

        let result = FrontMatterParser.parse(source)
        #expect(result.metadata.title == "Authentication")
        #expect(result.metadata.tags == ["security", "backend"])
        #expect(result.metadata.aliases == ["Auth", "AuthN"])
        #expect(result.metadata.additional["status"]?.stringValue == "draft")
        #expect(result.metadata.additional["reviewed"] != nil)
        #expect(result.body.trimmingCharacters(in: .whitespacesAndNewlines) == "Body text.")
        #expect(result.warnings.isEmpty)
    }

    @Test("A scalar tag is accepted as well as a list")
    func scalarTag() {
        let result = FrontMatterParser.parse("---\ntags: security\n---\n\nBody.")
        #expect(result.metadata.tags == ["security"])
    }

    @Test("Malformed YAML warns but never fails ingestion")
    func malformedYAML() {
        let source = """
            ---
            title: [unclosed
            ---

            Body text.
            """

        let result = FrontMatterParser.parse(source)
        #expect(result.metadata.title == nil)
        #expect(result.warnings.count == 1)
        #expect(result.body.contains("Body text."))
    }

    @Test("A thematic break at the top of a document is not front matter")
    func thematicBreak() {
        let source = "---\n\nJust a rule, then prose.\n"
        let result = FrontMatterParser.parse(source)
        #expect(result.consumedLines == 0)
        #expect(result.body == source)
    }

    @Test("No front matter leaves the document untouched")
    func absent() {
        let source = "# Title\n\nBody.\n"
        let result = FrontMatterParser.parse(source)
        #expect(result.body == source)
        #expect(result.metadata == .empty)
    }
}

@Suite("Markdown parsing")
struct MarkdownParserTests {
    let parser = MarkdownParser()

    @Test("Heading paths nest and are rooted at the document title")
    func headingPaths() {
        let source = """
            # Auth Service

            Intro paragraph.

            ## Tokens

            Token text.

            ### Refresh

            Refresh text.

            ## Sessions

            Session text.
            """

        let parsed = parser.parse(source: source, filenameStem: "auth")
        #expect(parsed.title == "Auth Service")

        let paths = parsed.sections.map(\.headingPath.components)
        #expect(
            paths == [
                ["Auth Service"],
                ["Auth Service", "Tokens"],
                ["Auth Service", "Tokens", "Refresh"],
                ["Auth Service", "Sessions"],
            ]
        )
    }

    @Test("A hash inside a fenced code block is not a heading")
    func hashInCodeFence() {
        let source = """
            # Real Heading

            ```sh
            # This is a shell comment, not a heading
            echo hi
            ```

            Trailing text.
            """

        let parsed = parser.parse(source: source, filenameStem: "sample")
        #expect(parsed.sections.count == 1)
        #expect(parsed.sections[0].text.contains("shell comment"))
    }

    @Test("Title falls back to first H1, then filename")
    func titleFallback() {
        let withH1 = parser.parse(source: "# From Heading\n\nText.", filenameStem: "ignored")
        #expect(withH1.title == "From Heading")

        let withoutH1 = parser.parse(source: "Just prose, no heading.", filenameStem: "my-note")
        #expect(withoutH1.title == "my-note")

        let withFrontMatter = parser.parse(
            source: "---\ntitle: Explicit\n---\n\n# From Heading\n\nText.",
            filenameStem: "ignored"
        )
        #expect(withFrontMatter.title == "Explicit")
    }

    @Test("Link and image destinations are collected")
    func links() {
        let source = """
            # Doc

            See [the guide](./guide.md) and ![diagram](./diagram.png).
            """

        let parsed = parser.parse(source: source, filenameStem: "doc")
        #expect(parsed.links.contains("./guide.md"))
        #expect(parsed.links.contains("./diagram.png"))
    }
}

@Suite("Chunk identity")
struct ChunkIdentityTests {
    let parser = MarkdownParser()
    /// Merging is exercised in ``ChunkerBoundsTests``. Here the minimum is lowered out of the
    /// way so these tests observe identity alone, not the merge pass folding tiny fixtures
    /// into a single chunk.
    let chunker = Chunker(configuration: ChunkingConfiguration(minimumTokens: 1, maximumTokens: 512))
    let documentID = DocumentID(relativePath: "notes/auth.md")

    private func chunks(_ source: String) -> [Chunk] {
        chunker.chunk(parser.parse(source: source, filenameStem: "auth"), documentID: documentID)
    }

    @Test("Editing a section's prose keeps its chunk ID and changes its content hash")
    func proseEditKeepsID() {
        let before = chunks("# Auth\n\n## Tokens\n\nOriginal text about tokens.")
        let after = chunks("# Auth\n\n## Tokens\n\nRewritten text about tokens entirely.")

        let beforeTokens = before.first { $0.headingPath.leaf == "Tokens" }
        let afterTokens = after.first { $0.headingPath.leaf == "Tokens" }

        #expect(beforeTokens?.id == afterTokens?.id)
        #expect(beforeTokens?.contentHash != afterTokens?.contentHash)
    }

    @Test("Renaming a heading mints a new chunk ID")
    func headingRenameChangesID() {
        let before = chunks("# Auth\n\n## Tokens\n\nSame body text here.")
        let after = chunks("# Auth\n\n## Credentials\n\nSame body text here.")

        #expect(before.map(\.id) != after.map(\.id))
    }

    @Test("Changing only a heading's capitalization does not retire the chunk")
    func headingCaseIsNormalized() {
        let before = chunks("# Auth\n\n## Access tokens\n\nBody.")
        let after = chunks("# Auth\n\n## Access Tokens\n\nBody.")

        #expect(before.map(\.id) == after.map(\.id))
    }

    @Test("Editing one section leaves its siblings' IDs untouched")
    func siblingsUnaffected() {
        let before = chunks(
            "# Auth\n\n## Tokens\n\nToken body.\n\n## Sessions\n\nSession body."
        )
        let after = chunks(
            "# Auth\n\n## Tokens\n\nCompletely different token body.\n\n## Sessions\n\nSession body."
        )

        let beforeSessions = before.first { $0.headingPath.leaf == "Sessions" }
        let afterSessions = after.first { $0.headingPath.leaf == "Sessions" }

        #expect(beforeSessions?.id == afterSessions?.id)
        #expect(beforeSessions?.contentHash == afterSessions?.contentHash)
    }

    @Test("Duplicate heading paths are disambiguated by occurrence")
    func duplicateHeadings() throws {
        let result = chunks(
            """
            # Auth

            ## Notes

            First notes section.

            ## Other

            Filler.

            ## Notes

            Second notes section.
            """
        )

        let notes = result.filter { $0.headingPath.leaf == "Notes" }
        try #require(notes.count == 2)
        #expect(notes[0].occurrence == 0)
        #expect(notes[1].occurrence == 1)
        #expect(notes[0].id != notes[1].id)
    }

    @Test("Chunk IDs are reproducible across runs")
    func deterministic() {
        let source = "# Auth\n\n## Tokens\n\nBody text.\n\n## Sessions\n\nMore text."
        #expect(chunks(source).map(\.id) == chunks(source).map(\.id))
    }

    @Test("Embedding input carries the heading path as context")
    func embeddingInputHasContext() {
        let result = chunks("# Auth Service\n\n## Overview\n\nIt authenticates.")
        let overview = result.first { $0.headingPath.leaf == "Overview" }
        #expect(overview?.embeddingInput.hasPrefix("Auth Service > Overview\n\n") == true)
    }
}

@Suite("Chunk size bounds")
struct ChunkerBoundsTests {
    let parser = MarkdownParser()

    @Test("An oversized section splits into siblings sharing the heading path")
    func oversizedSplits() {
        let paragraph = Array(repeating: "word", count: 60).joined(separator: " ")
        let body = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        let source = "# Doc\n\n## Long\n\n\(body)"

        let chunker = Chunker(configuration: ChunkingConfiguration(minimumTokens: 10, maximumTokens: 120))
        let result = chunker.chunk(
            parser.parse(source: source, filenameStem: "doc"),
            documentID: DocumentID(relativePath: "doc.md")
        )

        #expect(result.count > 1)
        #expect(result.allSatisfy { $0.headingPath.components == ["Doc", "Long"] })
        #expect(Set(result.map(\.occurrence)).count == result.count)
        #expect(Set(result.map(\.id)).count == result.count)
        // Nothing is dropped: every source paragraph survives somewhere.
        let recombined = result.map(\.content).joined(separator: "\n\n")
        #expect(recombined.components(separatedBy: paragraph).count - 1 == 10)
    }

    @Test("Undersized adjacent sections merge under the first heading path")
    func undersizedMerge() {
        let source = """
            # Doc

            ## A

            Tiny.

            ## B

            Also tiny.

            ## C

            Still tiny.
            """

        let chunker = Chunker(configuration: ChunkingConfiguration(minimumTokens: 50, maximumTokens: 512))
        let result = chunker.chunk(
            parser.parse(source: source, filenameStem: "doc"),
            documentID: DocumentID(relativePath: "doc.md")
        )

        #expect(result.count == 1)
        #expect(result[0].content.contains("Tiny."))
        #expect(result[0].content.contains("Also tiny."))
        #expect(result[0].content.contains("Still tiny."))
    }

    @Test("A fenced code block is never split across chunks")
    func codeFenceKeptIntact() throws {
        let code = (1...40).map { "let line\($0) = \($0)" }.joined(separator: "\n")
        let source = """
            # Doc

            ## Code

            Intro paragraph before the code.

            ```swift
            \(code)
            ```

            Trailing paragraph after the code.
            """

        let chunker = Chunker(configuration: ChunkingConfiguration(minimumTokens: 5, maximumTokens: 60))
        let result = chunker.chunk(
            parser.parse(source: source, filenameStem: "doc"),
            documentID: DocumentID(relativePath: "doc.md")
        )

        let fenceHolders = result.filter { $0.content.contains("```swift") }
        #expect(fenceHolders.count == 1)
        // The opening and closing fence land in the same chunk.
        let holder = try #require(fenceHolders.first)
        #expect(holder.content.components(separatedBy: "```").count == 3)
        #expect(holder.content.contains("let line40 = 40"))
    }
}

@Suite("Name normalization")
struct NameNormalizerTests {
    @Test("Case, diacritics, and separator punctuation fold together")
    func folding() {
        #expect(NameNormalizer.normalize("Auth-Service") == NameNormalizer.normalize("auth service"))
        #expect(NameNormalizer.normalize("Café") == NameNormalizer.normalize("cafe"))
        #expect(NameNormalizer.normalize("  spaced   out  ") == "spaced out")
    }

    @Test("Matching normalization also folds simple plurals")
    func plurals() {
        #expect(NameNormalizer.normalizeForMatching("tokens") == NameNormalizer.normalizeForMatching("Token"))
        #expect(NameNormalizer.normalizeForMatching("policies") == NameNormalizer.normalizeForMatching("policy"))
        // Plural folding is deliberately absent from ID derivation.
        #expect(NameNormalizer.normalize("tokens") != NameNormalizer.normalize("token"))
    }
}
