// SPDX-License-Identifier: GPL-3.0-or-later
//
// The metadata macOS keeps about a file that a `stat` call never sees.
//
// `filesystem_stat` answers size, kind and modification time, which is what a
// POSIX filesystem knows. A Mac knows considerably more, and none of it is
// exposed by any filesystem MCP server surveyed: the uniform type of the file
// rather than a guess from its extension, where a downloaded file came from,
// which application downloaded it and when Gatekeeper quarantined it, whether
// an iCloud file's bytes are actually here, and the Spotlight attributes that
// describe the content itself — page count, pixel dimensions, duration.
//
// Two things this file is careful about:
//
//   * Type is asked of the system, not inferred from the extension. A `.dat`
//     that is really a JPEG answers JPEG here, and a `.txt` that is really a
//     binary answers binary, which is the difference between a caller reading
//     a file successfully and a caller reading mojibake.
//   * Everything optional is reported as absent rather than as a default. A
//     file with no quarantine record and a file whose quarantine record could
//     not be read are different facts, and flattening them into "not
//     quarantined" would be a claim this code cannot make.

import Foundation
import UniformTypeIdentifiers

/// Where a downloaded file came from, as Gatekeeper recorded it.
public struct FilesystemQuarantineRecord: Equatable, Sendable {
    /// The application that wrote the file, as it identified itself.
    public let agentName: String?
    /// When the download happened, from the record's own timestamp.
    public let timestamp: Date?

    public init(agentName: String?, timestamp: Date?) {
        self.agentName = agentName
        self.timestamp = timestamp
    }
}

/// A coarse grouping of uniform types, so a caller can decide which tool to
/// reach for without knowing the type hierarchy.
public enum FilesystemContentCategory: String, Equatable, Sendable {
    case folder
    case text
    case image
    case audio
    case video
    case pdf
    case archive
    case application
    case other
}

public enum FilesystemMetadata {
    /// Parses the `com.apple.quarantine` extended attribute.
    ///
    /// The value is four semicolon-separated fields: flags, a hexadecimal
    /// timestamp in seconds since 1970, the agent name, and an event UUID.
    /// Fields go missing in practice — an agent that wrote the attribute by
    /// hand may supply two — so every field is optional and a short record is
    /// still a record rather than a parse failure.
    public static func quarantineRecord(fromAttribute raw: String) -> FilesystemQuarantineRecord? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0 \t\n"))
        guard !trimmed.isEmpty else { return nil }
        let fields = trimmed.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }

        var timestamp: Date?
        if let seconds = UInt64(fields[1], radix: 16), seconds > 0 {
            timestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        let agent = fields.count >= 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
        return FilesystemQuarantineRecord(
            agentName: agent.isEmpty ? nil : agent,
            timestamp: timestamp
        )
    }

    /// Decodes `com.apple.metadata:kMDItemWhereFroms`, a binary property list
    /// holding the URL a file was downloaded from and, usually, the page that
    /// linked to it.
    ///
    /// Empty strings are dropped: Safari writes one when there was no
    /// referring page, and handing a caller `""` as a source is worse than
    /// handing it nothing.
    public static func whereFroms(fromAttribute data: Data) -> [String] {
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
        else { return [] }
        if let strings = plist as? [String] {
            return strings.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let single = plist as? String, !single.isEmpty { return [single] }
        return []
    }

    /// Groups a uniform type. Conformance, not the identifier, decides: a
    /// HEIC, a RAW file and a PNG are all images, and asking each identifier
    /// by name would miss every type nobody thought of.
    public static func category(for type: UTType?) -> FilesystemContentCategory {
        guard let type else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audiovisualContent) {
            return type.conforms(to: .audio) ? .audio : .video
        }
        if type.conforms(to: .archive) || type.conforms(to: .zip) { return .archive }
        // Before the folder check, not after: an application bundle is a
        // directory on disk, and calling an app a folder is technically true
        // and useless.
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) {
            return .application
        }
        if type.conforms(to: .folder) || type.conforms(to: .directory) { return .folder }
        // Checked after the specific types on purpose: an SVG and a Swift
        // source file both conform to text, and calling the SVG text would
        // send a caller to the wrong reader.
        if type.conforms(to: .text) { return .text }
        return .other
    }

    /// Reads one extended attribute, or nil when the file does not carry it.
    public static func extendedAttribute(_ name: String, of path: String) -> Data? {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }

    /// The Spotlight attributes worth reporting, in the order they are asked
    /// for. Kept deliberately short: this is a description of the file, not a
    /// dump of everything Spotlight scraped out of its contents.
    public static let spotlightAttributes: [String] = [
        "kMDItemContentCreationDate",
        "kMDItemContentModificationDate",
        "kMDItemTitle",
        "kMDItemAuthors",
        "kMDItemNumberOfPages",
        "kMDItemPixelWidth",
        "kMDItemPixelHeight",
        "kMDItemDurationSeconds",
        "kMDItemCodecs",
        "kMDItemFinderComment",
    ]

    /// Strips the `kMDItem` prefix and lowercases the first letter, so
    /// `kMDItemPixelWidth` is reported as `pixelWidth` alongside every other
    /// camel-cased key in the response rather than shouting its C origin.
    public static func responseKey(forSpotlightAttribute attribute: String) -> String {
        var name = attribute
        if name.hasPrefix("kMDItem") { name.removeFirst("kMDItem".count) }
        guard let first = name.first else { return attribute }
        return first.lowercased() + name.dropFirst()
    }
}
