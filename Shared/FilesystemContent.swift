// SPDX-License-Identifier: GPL-3.0-or-later
//
// File content helpers that sit below the tool surface.
//
// These are the parts of the Filesystem service worth testing on their own:
// deciding where a byte window may be cut so it still decodes, writing Finder
// tags on a macOS older than the one whose API can, and quoting a search term
// for Spotlight. `FilesystemAccess` is the sibling of this file and answers
// the separate question of whether a path may be touched at all.

import CryptoKit
import Foundation

public enum FilesystemContentError: LocalizedError, Equatable {
    case spotlightUnavailable(Int)
    case tagWriteFailed(path: String, code: Int)
    case invalidLookback

    public var errorDescription: String? {
        switch self {
        case .invalidLookback:
            return "The number of days is too large to represent as a Spotlight lookback."
        case let .spotlightUnavailable(status):
            return
                "Spotlight could not answer that search (mdfind exited \(status)). Indexing may "
                + "be off for this volume; searching by file name still works."
        case let .tagWriteFailed(path, code):
            return "Could not write Finder tags on \(path) (errno \(code))."
        }
    }
}

public enum FilesystemContent {
    /// Paging beyond the end must return an empty page, never overflow.
    public static func pageEnd(offset: Int, limit: Int) -> Int {
        let result = max(0, offset).addingReportingOverflow(max(0, limit))
        return result.overflow ? Int.max : result.partialValue
    }

    /// A byte window trimmed so it decodes as UTF-8 on its own.
    ///
    /// `byteCount` is how many bytes the returned text occupies. `consumed`
    /// also counts leading bytes that were discarded, so it is what a caller
    /// adds to its offset to reach the next window. The two differ, and using
    /// the wrong one repeats or skips bytes on every page.
    public struct TextWindow: Equatable, Sendable {
        public let text: String?
        public let byteCount: Int
        public let consumed: Int
    }

    /// Trims a read so it decodes, whichever end lands mid-character.
    ///
    /// Two separate hazards. A window starting at a caller's offset can open
    /// on continuation bytes belonging to the character before it, and a
    /// window cut at the cap can stop partway through a character. Either one
    /// fails UTF-8 validation, and the caller would then report an ordinary
    /// text file as binary purely because of where the page boundary fell.
    public static func textWindow(
        _ data: Data,
        cap: Int,
        resuming: Bool,
        truncated: Bool
    ) -> TextWindow {
        var slice = Data(data.prefix(cap))

        var skippedLeading = 0
        if resuming {
            while let first = slice.first, first & 0b1100_0000 == 0b1000_0000 {
                slice.removeFirst()
                skippedLeading += 1
            }
        }

        // At most three continuation bytes, then one lead byte, can belong to
        // a character the cap cut through.
        if truncated {
            while let last = slice.last, last & 0b1100_0000 == 0b1000_0000 {
                slice.removeLast()
            }
            if let last = slice.last,
                last & 0b1110_0000 == 0b1100_0000
                    || last & 0b1111_0000 == 0b1110_0000
                    || last & 0b1111_1000 == 0b1111_0000
            {
                slice.removeLast()
            }
        }

        return TextWindow(
            text: String(data: slice, encoding: .utf8),
            byteCount: slice.count,
            consumed: skippedLeading + slice.count
        )
    }

    /// Writes Finder tags through the extended attribute Finder itself uses.
    ///
    /// `URLResourceValues.tagNames` gained a setter only in macOS 26, and this
    /// app deploys further back. The attribute is a binary plist array of
    /// strings and is what that setter writes anyway, so this is one code path
    /// for every supported version rather than a fork. Reading still goes
    /// through the resource key, whose getter has always been available.
    public static func setTags(_ tags: [String], on url: URL) throws {
        let name = "com.apple.metadata:_kMDItemUserTags"
        let encoded = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )
        let status = encoded.withUnsafeBytes { buffer in
            setxattr(url.path, name, buffer.baseAddress, buffer.count, 0, 0)
        }
        guard status == 0 else {
            throw FilesystemContentError.tagWriteFailed(path: url.path, code: Int(errno))
        }
    }
}

/// Spotlight does the content searching. Walking the tree and reading every
/// file would be far slower and would still miss what Spotlight already knows
/// about PDFs, Pages documents and mail.
extension FilesystemContent {
    /// Prefers the filesystem's own hidden flag, which catches files hidden
    /// without a leading dot, and falls back to the dot convention when the
    /// attribute cannot be read.
    public static func isHidden(_ url: URL) -> Bool {
        if let hidden = (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden {
            return hidden
        }
        return url.lastPathComponent.hasPrefix(".")
    }

    /// Whether a write must be refused rather than replacing what is there.
    ///
    /// Move and copy have always refused; write did not, and a replaced file
    /// never reaches the Trash. Stated here so the rule is one testable thing
    /// rather than a condition buried in a tool closure.
    public static func refusesOverwrite(exists: Bool, overwriteRequested: Bool) -> Bool {
        exists && !overwriteRequested
    }

    /// Whether a page of results left something behind.
    ///
    /// Counted against what the caller is permitted to see, never against raw
    /// search hits: entries dropped for sitting outside the shared roots are
    /// not truncation, and reporting them as such told callers to narrow a
    /// search that had already returned everything they could be shown.
    public static func isTruncated(permittedCount: Int, limit: Int) -> Bool {
        permittedCount > max(0, limit)
    }
}

public enum Spotlight {
    public static func lookbackSeconds(days: Int) throws -> Int {
        let result = max(1, days).multipliedReportingOverflow(by: 86_400)
        guard !result.overflow else { throw FilesystemContentError.invalidLookback }
        return result.partialValue
    }

    /// Quotes a user string for the metadata query language. Arguments reach
    /// mdfind through argv rather than a shell, so this is about the query
    /// parser and not about shell injection.
    public static func quoted(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    /// Runs mdfind and returns the paths it printed.
    public static func run(arguments: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FilesystemContentError.spotlightUnavailable(Int(process.terminationStatus))
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

extension FilesystemContent {
    /// Resolves a path and insists it is actually there.
    ///
    /// `FilesystemAccess.resolve` answers whether a path may be touched, and
    /// deliberately succeeds for a path that does not exist yet, because that
    /// is the write case. Read-only callers that skipped this check described
    /// a trashed file back as an ordinary non-directory with no size, so the
    /// caller had to infer absence from missing fields.
    public static func resolveExisting(
        requested path: String,
        roots: [FilesystemRoot],
        requiringWrite: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = try FilesystemAccess.resolve(
            requested: path,
            roots: roots,
            requiringWrite: requiringWrite,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: url.path) else {
            throw FilesystemAccessError.notFound(url.path)
        }
        return url
    }
}

// MARK: - Selective text edits

public enum FilesystemEditError: LocalizedError, Equatable {
    case noEdits
    case tooManyEdits(requested: Int, limit: Int)
    case emptyMatchText(editIndex: Int)
    case textNotFound(editIndex: Int)
    case ambiguousMatch(editIndex: Int, count: Int)
    case notText(String)
    case conflict(String)

    public var errorDescription: String? {
        switch self {
        case .noEdits:
            return "Pass at least one edit, each with the exact text to find and the text to put in its place."
        case let .tooManyEdits(requested, limit):
            return "\(requested) edits is over the \(limit) this call accepts. Split them across calls."
        case let .emptyMatchText(index):
            return
                "Edit \(index + 1) has empty oldText. Use filesystem_write or filesystem_append to add text that is not replacing anything."
        case let .textNotFound(index):
            return
                "Edit \(index + 1): its oldText does not appear in the file. Read the file again and copy the text to replace exactly, including indentation and line endings."
        case let .ambiguousMatch(index, count):
            return
                "Edit \(index + 1): its oldText appears \(count) times, so there is no one place to change. Include enough surrounding text to make it unique, or pass replaceAll: true to change every occurrence."
        case let .notText(path):
            return "\(path) is not UTF-8 text, so it cannot be edited by matching text."
        case let .conflict(path):
            return
                "filesystem_edit_conflict: \(path) changed since the hash you passed. Read it again with filesystem_read and hash it with filesystem_hash before editing."
        }
    }
}

/// One exact-match replacement. `oldText` is matched literally, byte for byte,
/// rather than by Unicode canonical equivalence: a caller that copied its
/// match text out of a read must get back the bytes it saw, and two spellings
/// of the same accented character compare equal under the default `String`
/// semantics while occupying different bytes on disk.
public struct FilesystemTextEdit: Equatable, Sendable {
    public let oldText: String
    public let newText: String
    /// Repeated text is a conflict by default. This turns it into an instruction.
    public let replaceAll: Bool

    public init(oldText: String, newText: String, replaceAll: Bool = false) {
        self.oldText = oldText
        self.newText = newText
        self.replaceAll = replaceAll
    }
}

/// One replaced span, shown as the whole lines it touched.
///
/// A character-level diff would be smaller and much harder to check by eye,
/// and the point of preview is that a person or a model can see what the edit
/// would do before it happens.
public struct FilesystemEditHunk: Equatable, Sendable {
    public let editIndex: Int
    /// 1-based line the match starts on, counted in the file as it stood
    /// before this particular edit.
    public let line: Int
    public let before: String
    public let after: String

    public init(editIndex: Int, line: Int, before: String, after: String) {
        self.editIndex = editIndex
        self.line = line
        self.before = before
        self.after = after
    }
}

public struct FilesystemEditResult: Equatable, Sendable {
    public let content: String
    /// How many occurrences each edit replaced, in the order the edits were given.
    public let replacements: [Int]
    public let hunks: [FilesystemEditHunk]
}

public enum FilesystemEdit {
    public static let maximumEdits = 64
    /// Enough to show a whole-file rename without describing every line of a
    /// large file back to the caller.
    public static let maximumHunks = 50

    /// SHA-256 hex, the same value `filesystem_hash` returns for the file and
    /// the same contract `notes_update` uses for `expectedHash`. Sharing the
    /// representation is the point: a caller hashes once and the two surfaces
    /// agree on what a stale snapshot looks like.
    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(of text: String) -> String {
        hash(of: Data(text.utf8))
    }

    /// Every literal, non-overlapping occurrence of `needle`.
    private static func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
            let range = haystack.range(
                of: needle,
                options: .literal,
                range: searchStart ..< haystack.endIndex
            )
        {
            found.append(range)
            searchStart = range.upperBound
        }
        return found
    }

    /// The whole lines a range sits on, before and after the replacement.
    private static func hunk(
        editIndex: Int,
        replacing range: Range<String.Index>,
        with newText: String,
        in content: String
    ) -> FilesystemEditHunk {
        let lineStart =
            content[content.startIndex ..< range.lowerBound].lastIndex(of: "\n")
            .map { content.index(after: $0) } ?? content.startIndex
        let lineEnd = content[range.upperBound...].firstIndex(of: "\n") ?? content.endIndex
        let before = String(content[lineStart ..< lineEnd])
        let after =
            String(content[lineStart ..< range.lowerBound]) + newText
            + String(content[range.upperBound ..< lineEnd])
        let line = content[content.startIndex ..< lineStart].filter { $0 == "\n" }.count + 1
        return FilesystemEditHunk(editIndex: editIndex, line: line, before: before, after: after)
    }

    /// Applies the edits in order, refusing the whole set if any one of them
    /// cannot be placed. Nothing partial ever reaches a caller, which is what
    /// lets the commit below be all-or-nothing.
    public static func apply(_ edits: [FilesystemTextEdit], to content: String) throws
        -> FilesystemEditResult
    {
        guard !edits.isEmpty else { throw FilesystemEditError.noEdits }
        guard edits.count <= maximumEdits else {
            throw FilesystemEditError.tooManyEdits(requested: edits.count, limit: maximumEdits)
        }

        var working = content
        var replacements: [Int] = []
        var hunks: [FilesystemEditHunk] = []

        for (index, edit) in edits.enumerated() {
            guard !edit.oldText.isEmpty else {
                throw FilesystemEditError.emptyMatchText(editIndex: index)
            }
            let matches = occurrences(of: edit.oldText, in: working)
            guard !matches.isEmpty else {
                throw FilesystemEditError.textNotFound(editIndex: index)
            }
            guard edit.replaceAll || matches.count == 1 else {
                throw FilesystemEditError.ambiguousMatch(editIndex: index, count: matches.count)
            }

            for match in matches where hunks.count < maximumHunks {
                hunks.append(
                    hunk(editIndex: index, replacing: match, with: edit.newText, in: working)
                )
            }
            // Replace back to front so the earlier ranges stay valid.
            for match in matches.reversed() {
                working.replaceSubrange(match, with: edit.newText)
            }
            replacements.append(matches.count)
        }

        return FilesystemEditResult(content: working, replacements: replacements, hunks: hunks)
    }

    /// Replaces the file's contents in one step, or leaves it exactly as it was.
    ///
    /// Writes a sibling temporary file and swaps it in, rather than truncating
    /// and rewriting in place: a failure halfway through the second would
    /// leave a half-edited file with no way back. `replaceItemAt` also carries
    /// the original's metadata across, so an edit does not silently drop a
    /// file's Finder tags.
    public static func commit(_ content: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".apple-core-edit-\(UUID().uuidString)"
        )
        do {
            try Data(content.utf8).write(to: temporary, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    public struct Applied: Sendable {
        public let url: URL
        public let result: FilesystemEditResult
        public let previousHash: String
        public let newHash: String
        public let committed: Bool
    }

    /// Resolves, checks for a conflict, applies, and commits unless previewing.
    ///
    /// A preview still requires a writable root. Previewing an edit that could
    /// never be committed reads as approval for something the allowlist will
    /// refuse, and the caller learns the real answer one call later than it
    /// should.
    public static func perform(
        path: String,
        edits: [FilesystemTextEdit],
        expectedHash: String?,
        preview: Bool,
        roots: [FilesystemRoot],
        fileManager: FileManager = .default
    ) throws -> Applied {
        let url = try FilesystemContent.resolveExisting(
            requested: path,
            roots: roots,
            requiringWrite: true,
            fileManager: fileManager
        )
        let data = try Data(contentsOf: url)
        let previousHash = hash(of: data)
        if let expectedHash, expectedHash != previousHash {
            throw FilesystemEditError.conflict(url.path)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw FilesystemEditError.notText(url.path)
        }

        let result = try apply(edits, to: content)
        if !preview {
            try commit(result.content, to: url)
        }
        return Applied(
            url: url,
            result: result,
            previousHash: previousHash,
            newHash: hash(of: result.content),
            committed: !preview
        )
    }
}

// MARK: - Batch reads

public enum FilesystemBatchReadError: LocalizedError, Equatable {
    case noPaths
    case tooManyPaths(requested: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .noPaths:
            return "Pass at least one path to read."
        case let .tooManyPaths(requested, limit):
            return
                "\(requested) paths is over the \(limit) this call accepts. Read them in batches of \(limit)."
        }
    }
}

/// One file's outcome. Ordered against the request, and carrying its own
/// success or failure: a batch where one path is denied still returns the
/// other files, and the denial says nothing about folders the caller was
/// never shown.
public struct FilesystemBatchReadEntry: Equatable, Sendable {
    public let requestedPath: String
    public let resolvedPath: String?
    public let content: String?
    public let sizeBytes: Int?
    public let isText: Bool
    public let truncated: Bool
    public let error: String?

    public var ok: Bool { error == nil }
}

public struct FilesystemBatchReadResult: Equatable, Sendable {
    public let entries: [FilesystemBatchReadEntry]
    public let bytesReturned: Int
    /// True when the budget, not the files, ended the read.
    public let budgetExhausted: Bool
}

public enum FilesystemBatchRead {
    public static let maximumPaths = 32
    /// The same ceiling one `filesystem_read` may return, spent across the
    /// whole batch. Without an aggregate bound, a batch of thirty-two files is
    /// thirty-two times the cap a single read is held to, which is the client
    /// context window this surface is capped to protect in the first place.
    public static let byteBudget = 512 * 1024

    public static func read(
        paths: [String],
        roots: [FilesystemRoot],
        budget: Int = byteBudget,
        fileManager: FileManager = .default
    ) throws -> FilesystemBatchReadResult {
        guard !paths.isEmpty else { throw FilesystemBatchReadError.noPaths }
        guard paths.count <= maximumPaths else {
            throw FilesystemBatchReadError.tooManyPaths(
                requested: paths.count,
                limit: maximumPaths
            )
        }

        var remaining = max(0, budget)
        var entries: [FilesystemBatchReadEntry] = []
        var budgetExhausted = false

        for path in paths {
            let url: URL
            do {
                url = try FilesystemAccess.resolve(
                    requested: path,
                    roots: roots,
                    requiringWrite: false,
                    fileManager: fileManager
                )
            } catch {
                entries.append(failure(path, nil, error.localizedDescription))
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                entries.append(
                    failure(
                        path,
                        url.path,
                        FilesystemAccessError.notFound(url.path).localizedDescription
                    )
                )
                continue
            }
            if isDirectory.boolValue {
                entries.append(
                    failure(
                        path,
                        url.path,
                        "\(url.path) is a folder. Use filesystem_list to see what is in it."
                    )
                )
                continue
            }
            guard remaining > 0 else {
                budgetExhausted = true
                entries.append(
                    failure(
                        path,
                        url.path,
                        "The \(byteBudget / 1024)KB this call may return was already used by the files before it. Read this one with filesystem_read."
                    )
                )
                continue
            }

            do {
                let entry = try readOne(path: path, url: url, cap: remaining)
                remaining -= entry.content.map { $0.utf8.count } ?? 0
                if entry.truncated { budgetExhausted = true }
                entries.append(entry)
            } catch {
                entries.append(failure(path, url.path, error.localizedDescription))
            }
        }

        return FilesystemBatchReadResult(
            entries: entries,
            bytesReturned: max(0, budget) - remaining,
            budgetExhausted: budgetExhausted
        )
    }

    private static func failure(_ requested: String, _ resolved: String?, _ message: String)
        -> FilesystemBatchReadEntry
    {
        FilesystemBatchReadEntry(
            requestedPath: requested,
            resolvedPath: resolved,
            content: nil,
            sizeBytes: nil,
            isText: false,
            truncated: false,
            error: message
        )
    }

    private static func readOne(path: String, url: URL, cap: Int) throws
        -> FilesystemBatchReadEntry
    {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Three bytes past the cap so a window cut mid-character is visible as
        // truncation rather than as a file that is not text.
        let data = try handle.read(upToCount: cap + 3) ?? Data()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? data.count
        let truncated = data.count > cap
        let window = FilesystemContent.textWindow(
            data,
            cap: cap,
            resuming: false,
            truncated: truncated
        )
        guard let text = window.text else {
            return FilesystemBatchReadEntry(
                requestedPath: path,
                resolvedPath: url.path,
                content: nil,
                sizeBytes: size,
                isText: false,
                truncated: false,
                error: nil
            )
        }
        return FilesystemBatchReadEntry(
            requestedPath: path,
            resolvedPath: url.path,
            content: text,
            sizeBytes: size,
            isText: true,
            truncated: truncated,
            error: nil
        )
    }
}

public enum FilesystemBinaryWriteError: LocalizedError, Equatable {
    case invalidBase64
    case tooLarge(sizeBytes: Int, limitBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return
                "The base64 argument is not valid base64. Nothing was written, because decoding "
                + "it loosely would save a corrupt file that only fails when something opens it."
        case let .tooLarge(sizeBytes, limitBytes):
            return
                "\(sizeBytes) bytes exceeds the \(limitBytes / (1024 * 1024))MB limit for an "
                + "inline write. Nothing was written."
        }
    }
}

/// Decoding for `filesystem_write_binary`. Kept beside the batch-read budget
/// logic because it answers the same question from the other direction: how
/// many bytes may cross the connector in one call.
public enum FilesystemBinaryWrite {
    /// Base64 encodes three bytes as four characters, so the decoded size is
    /// known from the string's length before any buffer is allocated. Checking
    /// the limit first means an oversized payload is refused without
    /// materialising it.
    public static func decodedByteCount(base64 encoded: String) -> Int {
        let characters = encoded.reduce(into: 0) { count, character in
            if !character.isWhitespace { count += 1 }
        }
        guard characters > 0 else { return 0 }
        let padding = encoded.reversed().prefix(2).filter { $0 == "=" }.count
        return max(0, characters / 4 * 3 - padding)
    }

    public static func decode(base64 encoded: String, limitBytes: Int) throws -> Data {
        let projected = decodedByteCount(base64: encoded)
        guard projected <= limitBytes else {
            throw FilesystemBinaryWriteError.tooLarge(
                sizeBytes: projected,
                limitBytes: limitBytes
            )
        }
        // Line breaks are ordinary in base64 that has travelled through other
        // tools, so they are tolerated. Anything else is refused rather than
        // silently dropped.
        guard
            let data = Data(
                base64Encoded: encoded,
                options: [.ignoreUnknownCharacters]
            ),
            encoded.allSatisfy({ $0.isWhitespace || $0.isLetter || $0.isNumber || "+/=".contains($0) })
        else {
            throw FilesystemBinaryWriteError.invalidBase64
        }
        guard data.count <= limitBytes else {
            throw FilesystemBinaryWriteError.tooLarge(
                sizeBytes: data.count,
                limitBytes: limitBytes
            )
        }
        return data
    }
}
