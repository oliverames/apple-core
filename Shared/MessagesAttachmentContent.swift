// SPDX-License-Identifier: GPL-3.0-or-later
//
// Turning an attachment row into bytes a remote client can actually use.
//
// chat.db records where an attachment lives on this Mac. That path is useless
// to Muse or any other client that is not running on this machine, so the
// retrieval path here returns bounded content instead: the bytes, their MIME
// type and their size, under a cap, or a specific reason why not.
//
// Two failure modes are common enough that a generic "could not read file"
// would be a bug report every time:
//
//   - the file was pruned by Messages' storage management, so the row survives
//     with nothing behind it, and
//   - the file lives in iCloud and was never downloaded to this Mac, which
//     looks identical to "missing" unless the placeholder is checked.
//
// The path itself is untrusted: it comes out of a database, and a symlink
// sitting in the attachments folder would otherwise read any file the app can
// reach. Every path is symlink-resolved and required to land inside Messages'
// own storage before a single byte is read.

import Foundation

/// Why an attachment can or cannot be handed to a client, decided before
/// anything is read so a listing can say so without opening files.
enum MessagesAttachmentAvailability: String, Sendable {
    /// On this Mac and readable.
    case available
    /// The row survives but the file does not.
    case missing
    /// In iCloud, never downloaded here. Opening it in Messages fetches it.
    case notDownloaded = "not_downloaded"
    /// The recorded path resolves outside Messages' storage, so it is refused.
    case blocked
    /// chat.db recorded no path at all for this row.
    case unknown
}

enum MessagesAttachmentContentError: LocalizedError, Equatable {
    case noStoredPath(String)
    case outsideMessagesStorage(name: String, path: String)
    case missingFile(name: String, path: String)
    case notDownloaded(name: String, path: String)
    case tooLarge(name: String, bytes: Int, cap: Int)
    case unreadable(name: String, detail: String)

    var errorDescription: String? {
        switch self {
        case let .noStoredPath(name):
            return
                "NO_FILE: Messages recorded no file on disk for \"\(name)\", so there is nothing to return."
        case let .outsideMessagesStorage(name, path):
            return
                "OUTSIDE_ROOT: \"\(name)\" resolves to \(path), outside Messages' own attachment storage. "
                + "Apple Core refuses to read through a link that leaves it."
        case let .missingFile(name, path):
            return
                "MISSING_FILE: \"\(name)\" is listed in Messages but its file is gone from this Mac (\(path)). "
                + "Messages storage management removes attachment files while keeping the conversation row."
        case let .notDownloaded(name, path):
            return
                "NOT_DOWNLOADED: \"\(name)\" is stored in iCloud and has not been downloaded to this Mac "
                + "(\(path)). Open it once in Messages on this Mac, then try again."
        case let .tooLarge(name, bytes, cap):
            return
                "TOO_LARGE: \"\(name)\" is \(bytes / 1024)KB, over the \(cap / 1024)KB limit for inline "
                + "content. Raise max_bytes up to the ceiling, or open the attachment in Messages."
        case let .unreadable(name, detail):
            return "UNREADABLE: \"\(name)\" could not be read (\(detail))."
        }
    }
}

/// Bytes plus the metadata a client needs to interpret them.
struct MessagesAttachmentPayload: Sendable {
    let data: Data
    let byteCount: Int
    let mimeType: String?
    let availability: MessagesAttachmentAvailability
}

enum MessagesAttachmentContent {
    /// The folders an attachment is allowed to resolve into. Messages keeps
    /// attachments under `~/Library/Messages/Attachments`; the sandboxed
    /// container path is included because a container-relative home resolves
    /// differently depending on how the app is launched.
    static func defaultRoots(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [String]
    {
        [
            homeDirectory.appendingPathComponent("Library/Messages").path,
            homeDirectory.appendingPathComponent(
                "Library/Containers/com.apple.iChat/Data/Library/Messages"
            ).path,
        ].map(FilesystemAccess.canonicalize)
    }

    /// chat.db stores `~/Library/...` literally, tilde and all.
    static func expandedPath(
        _ storedPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let trimmed = storedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(trimmed.dropFirst(2))).path
        }
        if trimmed == "~" { return homeDirectory.path }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            .standardizedFileURL.path
    }

    /// Resolves the stored path to a real, contained location, or says why not.
    ///
    /// Containment is checked on the symlink-resolved path, so a link planted
    /// inside the attachments folder cannot be used to read elsewhere. A link
    /// that stays inside Messages' storage is followed normally.
    static func resolve(
        storedPath: String?,
        name: String,
        roots: [String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> String {
        guard let storedPath, !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw MessagesAttachmentContentError.noStoredPath(name)
        }
        let expanded = expandedPath(storedPath, homeDirectory: homeDirectory)
        let allowed = roots ?? defaultRoots(homeDirectory: homeDirectory)
        func contained(_ candidate: String) -> Bool {
            allowed.contains { FilesystemAccess.isContained(candidate, in: $0) }
        }

        // The fully resolved path is the one that would be read, so it is the
        // one that has to be inside Messages' storage. A link that leaves is
        // refused even though the link itself sits in an allowed folder.
        let canonical = FilesystemAccess.canonicalize(expanded)
        if contained(canonical) { return canonical }

        // Nothing at that path at all: a file cannot be canonicalized before
        // it exists, so fall back to its parent. That still defeats `..` and a
        // retargeted parent, and it lets a pruned attachment be reported as
        // missing rather than as blocked.
        let exists =
            fileManager.fileExists(atPath: expanded)
            || (try? fileManager.attributesOfItem(atPath: expanded)) != nil
        if !exists {
            let canonicalParent = FilesystemAccess.canonicalize(
                URL(fileURLWithPath: expanded).deletingLastPathComponent().path
            )
            let rejoined = URL(fileURLWithPath: canonicalParent)
                .appendingPathComponent(URL(fileURLWithPath: expanded).lastPathComponent).path
            if contained(rejoined) { return rejoined }
        }

        throw MessagesAttachmentContentError.outsideMessagesStorage(
            name: name,
            path: canonical
        )
    }

    /// What a listing should report for a row, without reading its bytes.
    static func availability(
        storedPath: String?,
        name: String,
        declaredSize: Int,
        roots: [String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> MessagesAttachmentAvailability {
        guard let storedPath, !storedPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .unknown
        }
        let resolved: String
        do {
            resolved = try resolve(
                storedPath: storedPath,
                name: name,
                roots: roots,
                homeDirectory: homeDirectory,
                fileManager: fileManager
            )
        } catch {
            return .blocked
        }

        if fileManager.fileExists(atPath: resolved) {
            let size =
                (try? fileManager.attributesOfItem(atPath: resolved)[.size] as? Int) ?? nil
            // A zero-byte stand-in for a file chat.db says has content is the
            // shape an undownloaded iCloud attachment takes on disk.
            if let size, size == 0, declaredSize > 0 { return .notDownloaded }
            return .available
        }
        if hasCloudPlaceholder(for: resolved, fileManager: fileManager) { return .notDownloaded }
        return .missing
    }

    /// iCloud leaves `.name.ext.icloud` beside an evicted file.
    static func hasCloudPlaceholder(for path: String, fileManager: FileManager = .default) -> Bool {
        let url = URL(fileURLWithPath: path)
        let placeholder =
            url
            .deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fileManager.fileExists(atPath: placeholder.path)
    }

    /// Reads an attachment's bytes, or throws the specific reason it could not.
    ///
    /// The declared size from chat.db is checked before the file is opened, so
    /// an oversized attachment is refused without reading it into memory.
    static func load(
        storedPath: String?,
        name: String,
        declaredSize: Int,
        maximumBytes: Int,
        roots: [String]? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        mimeType: String? = nil
    ) throws -> MessagesAttachmentPayload {
        let resolved = try resolve(
            storedPath: storedPath,
            name: name,
            roots: roots,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )

        switch availability(
            storedPath: storedPath,
            name: name,
            declaredSize: declaredSize,
            roots: roots,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
        case .missing:
            throw MessagesAttachmentContentError.missingFile(name: name, path: resolved)
        case .notDownloaded:
            throw MessagesAttachmentContentError.notDownloaded(name: name, path: resolved)
        case .blocked:
            throw MessagesAttachmentContentError.outsideMessagesStorage(name: name, path: resolved)
        case .unknown:
            throw MessagesAttachmentContentError.noStoredPath(name)
        case .available:
            break
        }

        if declaredSize > maximumBytes {
            throw MessagesAttachmentContentError.tooLarge(
                name: name,
                bytes: declaredSize,
                cap: maximumBytes
            )
        }
        let onDiskSize = (try? fileManager.attributesOfItem(atPath: resolved)[.size] as? Int) ?? nil
        if let onDiskSize, onDiskSize > maximumBytes {
            throw MessagesAttachmentContentError.tooLarge(
                name: name,
                bytes: onDiskSize,
                cap: maximumBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: resolved))
        } catch {
            throw MessagesAttachmentContentError.unreadable(
                name: name,
                detail: error.localizedDescription
            )
        }
        // The recorded size can lag the file; the bytes in hand are the ones
        // that would cross the wire, so they get the final say.
        guard data.count <= maximumBytes else {
            throw MessagesAttachmentContentError.tooLarge(
                name: name,
                bytes: data.count,
                cap: maximumBytes
            )
        }
        return MessagesAttachmentPayload(
            data: data,
            byteCount: data.count,
            mimeType: mimeType,
            availability: .available
        )
    }
}
