// SPDX-License-Identifier: GPL-3.0-or-later
//
// Validation and staging for attachments on outgoing mail.
//
// The compose schema used to take recipients, an account, a subject and a
// plain-text body, and nothing else, so an agent could describe a file but
// never send one. This adds two ways in, both bounded:
//
//   - `path`, resolved against the folders the user has shared with Apple
//     Core. A path outside them is refused, so "attach a file" can never turn
//     into "read any file on this Mac and mail it somewhere".
//   - `base64`, for bytes the client already holds, under a size cap. A
//     remote client such as Muse has no filesystem on the serving Mac, so
//     without this it has no way to attach anything at all.
//
// Caps exist because an outgoing message is a slow, unbatched Apple Event
// conversation and because oversized mail fails at the far end rather than
// here. They are deliberately conservative.
//
// Everything in this file is a pure function over values plus the filesystem,
// so the send path's validation is testable without Mail.app and without
// sending anything to anyone.

import Foundation
import UniformTypeIdentifiers

/// One attachment as the client described it. Exactly one of `path` and
/// `base64` must be present.
public struct MailComposeAttachmentSpec: Sendable, Equatable {
    public let name: String?
    public let path: String?
    public let base64: String?

    public init(name: String? = nil, path: String? = nil, base64: String? = nil) {
        self.name = name
        self.path = path
        self.base64 = base64
    }
}

/// One attachment after validation, ready to be staged on disk and handed to
/// Mail. Mail will only take an attachment from a file path, so inline bytes
/// still end up in a temporary file; this type carries them until then.
public struct MailPreparedAttachment: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        /// An existing file inside a shared folder. Never copied.
        case file(URL)
        /// Bytes supplied inline, to be written to a scratch file.
        case inline(Data)
    }

    public let name: String
    public let mimeType: String
    public let byteCount: Int
    public let source: Source

    public init(name: String, mimeType: String, byteCount: Int, source: Source) {
        self.name = name
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.source = source
    }
}

public enum MailComposeAttachmentError: LocalizedError, Equatable {
    case tooMany(Int)
    case sourceAmbiguous
    case sourceMissing
    case invalidBase64(String)
    case missingName
    case notAFile(String)
    case unreadable(String)
    case attachmentTooLarge(name: String, bytes: Int, limit: Int)
    case totalTooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .tooMany(limit):
            return "INVALID: at most \(limit) attachments per message"
        case .sourceAmbiguous:
            return "INVALID: each attachment takes either path or base64, not both"
        case .sourceMissing:
            return "INVALID: each attachment needs a path or base64"
        case let .invalidBase64(name):
            return "INVALID: \"\(name)\" is not valid base64"
        case .missingName:
            return "INVALID: an attachment sent as base64 needs a name, so the recipient sees a filename"
        case let .notAFile(path):
            return "NOT_FOUND: \(path) is not a file"
        case let .unreadable(path):
            return "INVALID: \(path) could not be read"
        case let .attachmentTooLarge(name, bytes, limit):
            return
                "TOO_LARGE: \"\(name)\" is \(bytes / 1024)KB, over the \(limit / 1024)KB per-attachment limit"
        case let .totalTooLarge(bytes, limit):
            return
                "TOO_LARGE: attachments total \(bytes / 1024)KB, over the \(limit / 1024)KB per-message limit"
        }
    }
}

public enum MailComposeAttachments {
    public static let maximumCount = 10
    /// Matches what mail servers actually accept before base64 transfer
    /// encoding inflates the message by a third.
    public static let maximumAttachmentBytes = 10 * 1024 * 1024
    public static let maximumTotalBytes = 20 * 1024 * 1024

    /// Strips directory separators and leading dots so a client-supplied name
    /// can only ever name a file, never a location.
    public static func sanitizedFileName(_ name: String) -> String {
        let cleaned =
            name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." { return "attachment" }
        return cleaned.hasPrefix(".") ? "attachment" + cleaned : cleaned
    }

    public static func mimeType(forFileName name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty,
            let type = UTType(filenameExtension: ext),
            let mime = type.preferredMIMEType
        else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Validates every spec and resolves its bytes or its file.
    ///
    /// `resolvePath` is the containment check, injected so the shared-root
    /// policy stays in the filesystem surface and this file stays testable.
    /// It throws for a path the user has not shared.
    public static func prepare(
        _ specs: [MailComposeAttachmentSpec],
        resolvePath: (String) throws -> URL,
        fileManager: FileManager = .default
    ) throws -> [MailPreparedAttachment] {
        guard specs.count <= maximumCount else {
            throw MailComposeAttachmentError.tooMany(maximumCount)
        }

        var prepared: [MailPreparedAttachment] = []
        var total = 0

        for spec in specs {
            let hasPath = !(spec.path ?? "").isEmpty
            let hasBase64 = !(spec.base64 ?? "").isEmpty
            guard hasPath != hasBase64 else {
                throw hasPath
                    ? MailComposeAttachmentError.sourceAmbiguous
                    : MailComposeAttachmentError.sourceMissing
            }

            let item: MailPreparedAttachment
            if hasPath, let path = spec.path {
                let url = try resolvePath(path)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                    !isDirectory.boolValue
                else {
                    throw MailComposeAttachmentError.notAFile(url.path)
                }
                guard
                    let size = try? fileManager.attributesOfItem(atPath: url.path)[.size]
                        as? NSNumber
                else {
                    throw MailComposeAttachmentError.unreadable(url.path)
                }
                let name = sanitizedFileName(spec.name ?? url.lastPathComponent)
                item = MailPreparedAttachment(
                    name: name,
                    mimeType: mimeType(forFileName: name),
                    byteCount: size.intValue,
                    source: .file(url)
                )
            } else {
                guard let rawName = spec.name, !rawName.isEmpty else {
                    throw MailComposeAttachmentError.missingName
                }
                let name = sanitizedFileName(rawName)
                guard
                    let data = Data(
                        base64Encoded: spec.base64 ?? "",
                        options: .ignoreUnknownCharacters
                    )
                else {
                    throw MailComposeAttachmentError.invalidBase64(name)
                }
                item = MailPreparedAttachment(
                    name: name,
                    mimeType: mimeType(forFileName: name),
                    byteCount: data.count,
                    source: .inline(data)
                )
            }

            guard item.byteCount <= maximumAttachmentBytes else {
                throw MailComposeAttachmentError.attachmentTooLarge(
                    name: item.name,
                    bytes: item.byteCount,
                    limit: maximumAttachmentBytes
                )
            }
            total += item.byteCount
            guard total <= maximumTotalBytes else {
                throw MailComposeAttachmentError.totalTooLarge(
                    bytes: total,
                    limit: maximumTotalBytes
                )
            }
            prepared.append(item)
        }
        return prepared
    }

    /// Writes inline attachments into `directory` and returns the file path
    /// for every attachment, in order. The caller owns the directory and is
    /// responsible for removing it once Mail has taken the bytes.
    public static func stage(
        _ attachments: [MailPreparedAttachment],
        in directory: URL,
        fileManager: FileManager = .default
    ) throws -> [String] {
        var paths: [String] = []
        for (offset, attachment) in attachments.enumerated() {
            switch attachment.source {
            case let .file(url):
                paths.append(url.path)
            case let .inline(data):
                // Numbered subdirectories, so two inline attachments sharing a
                // name keep both names rather than overwriting each other.
                let slot = directory.appendingPathComponent("\(offset)", isDirectory: true)
                try fileManager.createDirectory(at: slot, withIntermediateDirectories: true)
                let file = slot.appendingPathComponent(attachment.name)
                try data.write(to: file, options: .atomic)
                paths.append(file.path)
            }
        }
        return paths
    }
}
