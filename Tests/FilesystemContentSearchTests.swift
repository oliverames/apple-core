import Foundation
import Testing

@Suite("Content search snippets and absence")
struct FilesystemContentSearchTests {
    @Test("Matching lines come back with 1-based line numbers")
    func snippetLineNumbers() {
        let text = "alpha\nbeta needle here\ngamma\nanother needle\n"
        let snippets = FilesystemContentSearch.snippets(in: text, query: "needle")
        #expect(snippets.map(\.line) == [2, 4])
        #expect(snippets.first?.text == "beta needle here")
    }

    @Test("Matching is case and diacritic insensitive")
    func caseInsensitive() {
        let snippets = FilesystemContentSearch.snippets(in: "Café NEEDLE", query: "needle")
        #expect(snippets.count == 1)
        #expect(FilesystemContentSearch.snippets(in: "cafe", query: "café").count == 1)
    }

    @Test("The number of snippets per file is bounded")
    func boundedCount() {
        let text = Array(repeating: "needle", count: 20).joined(separator: "\n")
        #expect(FilesystemContentSearch.snippets(in: text, query: "needle", maximum: 3).count == 3)
        #expect(FilesystemContentSearch.snippets(in: text, query: "needle", maximum: 0).isEmpty)
    }

    @Test("A long line is trimmed around the match and marked as trimmed")
    func windowing() {
        let padding = String(repeating: "x", count: 500)
        let text = padding + "needle" + padding
        let snippet = FilesystemContentSearch.snippets(in: text, query: "needle", radius: 10).first
        #expect(snippet?.truncated == true)
        #expect(snippet?.text == "…xxxxxxxxxxneedlexxxxxxxxxx…")
    }

    @Test("A short line is returned whole and unmarked")
    func shortLineUntouched() {
        let snippet = FilesystemContentSearch.snippets(in: "a needle b", query: "needle").first
        #expect(snippet?.text == "a needle b")
        #expect(snippet?.truncated == false)
    }

    @Test("An empty query matches nothing rather than everything")
    func emptyQuery() {
        #expect(FilesystemContentSearch.snippets(in: "anything", query: "").isEmpty)
    }

    @Test("mdutil output is read as an indexing state")
    func indexStateParsing() {
        #expect(
            SpotlightIndexState.parse(mdutilOutput: "/:\n\tIndexing enabled.") == .enabled
        )
        #expect(
            SpotlightIndexState.parse(mdutilOutput: "/Volumes/Big:\n\tIndexing and searching disabled.")
                == .disabled
        )
        #expect(SpotlightIndexState.parse(mdutilOutput: "/Volumes/Big:\n\tNo index.") == .unsupported)
        #expect(SpotlightIndexState.parse(mdutilOutput: "") == .unknown)
    }

    @Test("A disabled or unsupported index explains itself; an enabled one has nothing to say")
    func indexStateExplanations() {
        #expect(SpotlightIndexState.enabled.explanation == nil)
        #expect(SpotlightIndexState.unknown.explanation == nil)
        #expect(SpotlightIndexState.disabled.explanation?.contains("turned off") == true)
        #expect(SpotlightIndexState.unsupported.explanation?.contains("does not support") == true)
    }

    @Test("iCloud download status maps to availability, and only local content reads")
    func cloudAvailability() {
        #expect(
            FilesystemCloudAvailability.from(downloadingStatus: "NSURLUbiquitousItemDownloadingStatusCurrent") == .local
        )
        #expect(
            FilesystemCloudAvailability.from(
                downloadingStatus: "NSURLUbiquitousItemDownloadingStatusNotDownloaded"
            ) == .notDownloaded
        )
        #expect(FilesystemCloudAvailability.from(downloadingStatus: nil) == .unknown)
        #expect(FilesystemCloudAvailability.notDownloaded.isReadable == false)
        #expect(FilesystemCloudAvailability.unknown.isReadable)
    }

    @Test("An iCloud placeholder name is recognised and unwrapped")
    func placeholderNames() {
        #expect(FilesystemCloudAvailability.isPlaceholderName(".Report.pdf.icloud"))
        #expect(
            FilesystemCloudAvailability.realName(forPlaceholder: ".Report.pdf.icloud") == "Report.pdf"
        )
        #expect(!FilesystemCloudAvailability.isPlaceholderName("Report.pdf"))
        #expect(!FilesystemCloudAvailability.isPlaceholderName(".icloud"))
    }

    @Test("Every reason a snippet is missing explains itself")
    func absenceExplanations() {
        for absence in [
            FilesystemSnippetAbsence.notPlainText,
            .contentNotDownloaded,
            .tooLarge,
            .unreadable,
            .noLiteralMatch,
        ] {
            #expect(!absence.explanation.isEmpty)
        }
    }
}
