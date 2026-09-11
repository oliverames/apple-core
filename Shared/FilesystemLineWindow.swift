// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reading the first or the last few lines of a file.
//
// `filesystem_read` pages by byte offset, which is the right primitive and the
// wrong interface for the two things people actually ask for. "The first
// twenty lines" costs a read of half a megabyte and a client-side split. "The
// last fifty lines of the log" — the single most common reason to open a log
// at all — costs a walk through the entire file, one page at a time, because a
// byte offset cannot be counted from the end. The reference MCP filesystem
// server exposes both as `head` and `tail`, and this is the part of doing the
// same that can be tested without a disk.
//
// Two details worth stating, because both are ways to return text that looks
// right and is not:
//
//   * A tail read starts at an arbitrary byte, which is almost never a line
//     boundary, so the first line it sees is a fragment of a line. It is
//     dropped rather than reported as a line of the file.
//   * That same arbitrary byte lands in the middle of a multi-byte character
//     often enough to matter. Decoding then fails for the whole window, so the
//     decode retries from the first plausible boundary instead of reporting an
//     empty file.

import Foundation

public struct FilesystemLineWindowResult: Equatable, Sendable {
    public let lines: [String]
    /// True when the file has more lines than were returned.
    public let truncated: Bool
    /// True when the read started part-way into the file, so anything before
    /// the first returned line was not looked at.
    public let startedMidFile: Bool

    public init(lines: [String], truncated: Bool, startedMidFile: Bool) {
        self.lines = lines
        self.truncated = truncated
        self.startedMidFile = startedMidFile
    }
}

public enum FilesystemLineWindow {
    public static let maximumLines = 10_000
    /// How far back from the end of a file a tail read may look. A file with
    /// one enormous line still has to terminate.
    public static let maximumTailBytes = 8 * 1024 * 1024

    public static func clampedLines(_ requested: Int) -> Int {
        min(max(1, requested), maximumLines)
    }

    /// Decodes a window of bytes as UTF-8, retrying from the first byte that
    /// can begin a character when the window starts mid-character.
    ///
    /// Returns nil for data that is not text at all, which is a different
    /// answer from text that happened to start in the middle.
    public static func decode(_ data: Data, startsMidFile: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard startsMidFile else { return nil }
        // A UTF-8 continuation byte is 0b10xxxxxx. Skipping them finds the
        // first byte that can start a character.
        var index = data.startIndex
        let limit = data.index(index, offsetBy: min(4, data.count))
        while index < limit, data[index] & 0xC0 == 0x80 {
            index = data.index(after: index)
        }
        guard index > data.startIndex else { return nil }
        return String(data: data[index...], encoding: .utf8)
    }

    /// The first `count` lines of a chunk read from the start of a file.
    ///
    /// `isWholeFile` says whether the chunk is all there is; without it a file
    /// whose first `count` lines happen to be the whole file would be reported
    /// as truncated.
    public static func head(_ text: String, count: Int, isWholeFile: Bool)
        -> FilesystemLineWindowResult
    {
        let wanted = clampedLines(count)
        let lines = split(text)
        return FilesystemLineWindowResult(
            lines: Array(lines.prefix(wanted)),
            truncated: lines.count > wanted || !isWholeFile,
            startedMidFile: false
        )
    }

    /// The last `count` lines of a chunk read from the end of a file.
    ///
    /// A chunk that does not reach the start of the file has its first line
    /// dropped: that line is a fragment, and returning it would hand back a
    /// sentence starting in the middle of a word as though it were a line.
    public static func tail(_ text: String, count: Int, startsMidFile: Bool)
        -> FilesystemLineWindowResult
    {
        let wanted = clampedLines(count)
        var lines = split(text)
        var truncatedByScan = false
        if startsMidFile, !lines.isEmpty {
            lines.removeFirst()
            truncatedByScan = true
        }
        return FilesystemLineWindowResult(
            lines: Array(lines.suffix(wanted)),
            truncated: lines.count > wanted || truncatedByScan,
            startedMidFile: startsMidFile
        )
    }

    /// Splits on newlines, treating a trailing newline as ending the last line
    /// rather than starting an empty one. A file ending in "\n" has as many
    /// lines as a file that does not, which is what `wc -l` and every reader
    /// of a log agrees on.
    static func split(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}
