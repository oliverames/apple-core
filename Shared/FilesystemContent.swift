// SPDX-License-Identifier: GPL-3.0-or-later
//
// File content helpers that sit below the tool surface.
//
// These are the parts of the Filesystem service worth testing on their own:
// deciding where a byte window may be cut so it still decodes, writing Finder
// tags on a macOS older than the one whose API can, and quoting a search term
// for Spotlight. `FilesystemAccess` is the sibling of this file and answers
// the separate question of whether a path may be touched at all.

import Foundation

public enum FilesystemContentError: LocalizedError, Equatable {
    case spotlightUnavailable(Int)
    case tagWriteFailed(path: String, code: Int)

    public var errorDescription: String? {
        switch self {
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
public enum Spotlight {
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
