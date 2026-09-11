// SPDX-License-Identifier: GPL-3.0-or-later
//
// Snippets, paging and honest absence for `filesystem_search_content`.
//
// The tool used to hand back a list of file names and a bare `truncated: true`.
// Three separate things were missing from that, and all three made a caller
// guess:
//
//   * No snippet, so "does this file really discuss the thing I asked about"
//     cost one more read per hit.
//   * No continuation, so a truncated search could only be narrowed, never
//     continued.
//   * No way to tell an empty result caused by "nothing matches" from one
//     caused by "Spotlight does not index this volume" or "this iCloud file
//     is not on this Mac". Those have completely different fixes, and the
//     tool reported all three as zero matches.
//
// Everything here is deliberately pure so it can be tested without a live
// Spotlight index, which is exactly the thing that cannot be relied on.

import Foundation

/// One matching line, with enough context to read and no more.
public struct FilesystemSnippet: Equatable, Sendable {
    /// 1-based line number in the file.
    public let line: Int
    public let text: String
    /// True when the line was cut to fit the radius.
    public let truncated: Bool

    public init(line: Int, text: String, truncated: Bool) {
        self.line = line
        self.text = text
        self.truncated = truncated
    }
}

/// Why a hit has no snippet. Spotlight indexes content this process cannot
/// cheaply re-read — PDF text layers, Pages documents, mail — so "no snippet"
/// is a normal outcome and says nothing about whether the match is real.
public enum FilesystemSnippetAbsence: String, Equatable, Sendable {
    case notPlainText = "not_plain_text"
    case contentNotDownloaded = "content_not_downloaded"
    case tooLarge = "too_large"
    case unreadable = "unreadable"
    case noLiteralMatch = "no_literal_match"

    public var explanation: String {
        switch self {
        case .notPlainText:
            return
                "Spotlight matched this file's indexed contents, but the file is not plain text, so no snippet could be quoted from it."
        case .contentNotDownloaded:
            return
                "This file lives in iCloud and its contents are not on this Mac, so only the name and metadata are available. Open it on the Mac to download it."
        case .tooLarge:
            return "The file is larger than the snippet reader will open. Use filesystem_read with an offset."
        case .unreadable:
            return "The file could not be opened to quote from it."
        case .noLiteralMatch:
            return
                "Spotlight matched this file's index, but the exact phrase does not appear literally in its text. The index also matches word stems and document metadata."
        }
    }
}

public enum FilesystemContentSearch {
    /// Far below `filesystem_read`'s cap: a snippet reader opens every hit on
    /// the page, so its ceiling is spent many times over in one call.
    public static let maximumSnippetFileBytes = 2 * 1024 * 1024
    public static let defaultSnippetsPerFile = 3
    public static let maximumSnippetsPerFile = 10
    /// Characters kept either side of the match on its line.
    public static let snippetRadius = 120

    /// Every line containing `query`, case-insensitively, bounded in count and
    /// in width.
    ///
    /// Matching is literal and case-insensitive, which is narrower than what
    /// Spotlight itself matched. A hit with no snippet is therefore reported
    /// as `noLiteralMatch` rather than dropped: Spotlight matches stems and
    /// metadata, and silently discarding those would turn its answer into a
    /// different, smaller one without saying so.
    public static func snippets(
        in text: String,
        query: String,
        maximum: Int = defaultSnippetsPerFile,
        radius: Int = snippetRadius
    ) -> [FilesystemSnippet] {
        guard !query.isEmpty, maximum > 0 else { return [] }
        var found: [FilesystemSnippet] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            guard found.count < maximum else { break }
            let whole = String(line)
            guard let range = whole.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
            else { continue }
            let (window, truncated) = window(of: whole, around: range, radius: radius)
            found.append(FilesystemSnippet(line: index + 1, text: window, truncated: truncated))
        }
        return found
    }

    /// A window of at most `radius` characters either side of the match, cut on
    /// character boundaries and marked when it was cut.
    static func window(
        of line: String,
        around range: Range<String.Index>,
        radius: Int
    ) -> (String, Bool) {
        let before = line.distance(from: line.startIndex, to: range.lowerBound)
        let after = line.distance(from: range.upperBound, to: line.endIndex)
        let lowerTrim = max(0, before - radius)
        let upperTrim = max(0, after - radius)
        guard lowerTrim > 0 || upperTrim > 0 else { return (line, false) }
        let start = line.index(line.startIndex, offsetBy: lowerTrim)
        let end = line.index(line.endIndex, offsetBy: -upperTrim)
        var window = String(line[start ..< end])
        if lowerTrim > 0 { window = "…" + window }
        if upperTrim > 0 { window += "…" }
        return (window, true)
    }
}

/// Whether Spotlight is indexing the volume a path lives on.
///
/// An unindexed volume answers every content search with silence, and the old
/// tool passed that silence on as "no matches". `mdutil -s` is the only thing
/// that distinguishes the two, and its output is a human sentence, so the
/// parsing is here where it can be tested against the strings macOS actually
/// prints.
public enum SpotlightIndexState: String, Equatable, Sendable {
    case enabled
    case disabled
    case unsupported
    case unknown

    public var explanation: String? {
        switch self {
        case .enabled, .unknown:
            return nil
        case .disabled:
            return
                "Spotlight indexing is turned off for this volume, so a content search cannot find anything on it however many files match. Search by file name with filesystem_search instead."
        case .unsupported:
            return
                "This volume does not support Spotlight indexing, so content search cannot reach it. Search by file name with filesystem_search instead."
        }
    }

    /// Parses `mdutil -s <path>`. The wording has changed across macOS
    /// releases, so this matches on the substrings that have stayed put rather
    /// than on a whole line.
    public static func parse(mdutilOutput: String) -> SpotlightIndexState {
        let text = mdutilOutput.lowercased()
        if text.contains("indexing enabled") || text.contains("indexing and searching enabled") {
            return .enabled
        }
        if text.contains("disabled") { return .disabled }
        if text.contains("no index") || text.contains("not support")
            || text.contains("unsupported")
        {
            return .unsupported
        }
        return .unknown
    }
}

/// Whether an iCloud Drive file's contents are actually on this Mac.
///
/// A file that has been evicted still has a name, a size and a Spotlight entry,
/// so it looks like an ordinary hit right up until something tries to read it.
public enum FilesystemCloudAvailability: String, Equatable, Sendable {
    case local
    case notDownloaded = "not_downloaded"
    case downloading
    case unknown

    public var isReadable: Bool { self == .local || self == .unknown }

    /// Maps `URLUbiquitousItemDownloadingStatus` raw values without importing
    /// the constants, so the mapping can be tested on its own.
    public static func from(downloadingStatus raw: String?) -> FilesystemCloudAvailability {
        guard let raw else { return .unknown }
        // "NotDownloaded" contains "Downloaded", so the negative case is
        // tested first. Read the other way round, an evicted file reports as
        // local and every read of it fails later for no stated reason.
        if raw.contains("NotDownloaded") { return .notDownloaded }
        if raw.contains("Current") || raw.contains("Downloaded") { return .local }
        return .unknown
    }

    /// The dataless placeholder iCloud leaves in a directory listing. Its name
    /// is the real name with a leading dot and a `.icloud` extension, and a
    /// caller handed that name back would be told a file exists that does not.
    public static func isPlaceholderName(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > ".".count + ".icloud".count
    }

    /// The name a placeholder stands in for, or nil when it is not one.
    public static func realName(forPlaceholder name: String) -> String? {
        guard isPlaceholderName(name) else { return nil }
        return String(name.dropFirst().dropLast(".icloud".count))
    }
}

extension SpotlightIndexState {
    /// Asks `mdutil` about the volume a path lives on.
    ///
    /// Run only when a content search found nothing, because it is a process
    /// spawn and the answer only changes what an empty result means. `mdutil`
    /// needs no privileges to report state, and its failure is reported as
    /// `unknown` rather than as a search error: not being able to explain an
    /// empty result is not the same as the search failing.
    public static func query(path: String, executable: String = "/usr/bin/mdutil")
        -> SpotlightIndexState
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .unknown
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return .unknown }
        return parse(mdutilOutput: String(decoding: data, as: UTF8.self))
    }
}

extension FilesystemCloudAvailability {
    /// Reads iCloud's download state for one file. A file that is only a
    /// placeholder still has a name and a size, so this is the only thing that
    /// separates "here" from "listed".
    public static func of(_ url: URL) -> FilesystemCloudAvailability {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ]), values.isUbiquitousItem == true
        else { return .local }
        return from(downloadingStatus: values.ubiquitousItemDownloadingStatus?.rawValue)
    }
}
