// SPDX-License-Identifier: GPL-3.0-or-later
//
// Typed clipboard access, and the rule that stops a restore clobbering a copy.
//
// The clipboard surface used to be two calls that only knew about plain text.
// That is wrong in both directions: copying a table out of Numbers and asking
// for it back produced the tab-separated fallback with no way to learn that
// richer text was sitting there, and writing text destroyed whatever was on
// the clipboard with no way to put it back.
//
// Two ideas fix that, and both are here rather than in the tool closures
// because both are rules rather than plumbing:
//
//   * Formats are advertised before bytes are fetched. A client asks what is
//     on the clipboard, sees "rtf, html, text, png, 4.2MB", and then asks for
//     the one it wants. Nothing large crosses the connector by accident.
//   * A snapshot may only be restored when nothing else has touched the
//     clipboard since. The clipboard is shared with the person sitting at the
//     Mac, and a restore that overwrites the paragraph they just copied is
//     indistinguishable, from their side, from the app losing their work.

import Foundation

/// The formats worth naming. Deliberately a short list of things a client can
/// actually use, rather than every UTI a pasteboard can carry.
public enum ClipboardFormat: String, CaseIterable, Sendable, Equatable {
    case text
    case rtf
    case html
    case url
    case fileURL
    case png
    case tiff
    case pdf

    /// The pasteboard type each one reads and writes.
    public var pasteboardType: String {
        switch self {
        case .text: return "public.utf8-plain-text"
        case .rtf: return "public.rtf"
        case .html: return "public.html"
        case .url: return "public.url"
        case .fileURL: return "public.file-url"
        case .png: return "public.png"
        case .tiff: return "public.tiff"
        case .pdf: return "com.adobe.pdf"
        }
    }

    /// True when the payload is text a client can read directly. The rest come
    /// back base64 encoded, or are written to a file inside a shared folder.
    public var isTextual: Bool {
        switch self {
        case .text, .rtf, .html, .url, .fileURL: return true
        case .png, .tiff, .pdf: return false
        }
    }

    /// Only these can be put on the clipboard. Writing an image or a PDF would
    /// mean accepting megabytes of base64 through a tool argument, and the
    /// file-URL type would let a client fabricate a Finder copy of a path the
    /// allowlist never approved.
    public var isWritable: Bool {
        switch self {
        case .text, .rtf, .html, .url: return true
        case .fileURL, .png, .tiff, .pdf: return false
        }
    }

    public static func named(_ raw: String?) -> ClipboardFormat? {
        guard let raw else { return nil }
        return ClipboardFormat(rawValue: raw)
    }

    /// The format a pasteboard type corresponds to, or nil for the many types
    /// that are private to one application.
    public static func matching(pasteboardType: String) -> ClipboardFormat? {
        allCases.first { $0.pasteboardType == pasteboardType }
    }
}

public enum ClipboardError: LocalizedError, Equatable {
    case formatUnavailable(requested: String, available: [String])
    case formatNotWritable(String)
    case unknownFormat(String)
    case tooLargeToInline(format: String, sizeBytes: Int, limitBytes: Int)
    case empty

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "The clipboard is empty."
        case let .unknownFormat(name):
            return
                "\(name) is not a clipboard format this tool knows. Call utilities_clipboard_formats to see what is on the clipboard."
        case let .formatUnavailable(requested, available):
            return available.isEmpty
                ? "The clipboard holds nothing in \(requested) format."
                : "The clipboard holds nothing in \(requested) format. It has: \(available.joined(separator: ", "))."
        case let .formatNotWritable(name):
            return
                "\(name) cannot be put on the clipboard by Apple Core. Writable formats are text, rtf, html and url."
        case let .tooLargeToInline(format, sizeBytes, limitBytes):
            return
                "The \(format) on the clipboard is \(sizeBytes / 1024)KB, over the \(limitBytes / 1024)KB a tool result may carry. "
                + "Pass savePath to write it to a file inside a shared folder instead."
        }
    }
}

public enum ClipboardPayload {
    /// The same ceiling `filesystem_read_binary` uses. Base64 inflates by a
    /// third, and the limit that matters is the client's context window, which
    /// does not care which surface spent it.
    public static let maximumInlineBytes = 256 * 1024

    public static func resolveFormat(_ raw: String?) throws -> ClipboardFormat {
        guard let raw else { return .text }
        guard let format = ClipboardFormat(rawValue: raw) else {
            throw ClipboardError.unknownFormat(raw)
        }
        return format
    }

    /// Decides whether a payload may be returned inline.
    ///
    /// `savePath` is the escape hatch, and it is not a bypass: the caller of
    /// this function still has to resolve that path through `FilesystemAccess`,
    /// so a large clipboard image can only ever land inside a folder the user
    /// shared for writing.
    public static func requiresFile(sizeBytes: Int, savePath: String?, limit: Int = maximumInlineBytes)
        -> Bool
    {
        savePath != nil || sizeBytes > limit
    }

    public static func checkInlineSize(
        format: ClipboardFormat,
        sizeBytes: Int,
        limit: Int = maximumInlineBytes
    ) throws {
        guard sizeBytes <= limit else {
            throw ClipboardError.tooLargeToInline(
                format: format.rawValue,
                sizeBytes: sizeBytes,
                limitBytes: limit
            )
        }
    }
}

// MARK: - Snapshot and conditional restore

public enum ClipboardRestoreDecision: Equatable, Sendable {
    case restore
    /// Something copied over the clipboard after the snapshot was taken.
    case refusedNewerCopy(currentChangeCount: Int, expectedChangeCount: Int)
    case expired
    case unknownToken

    public var message: String? {
        switch self {
        case .restore:
            return nil
        case .refusedNewerCopy:
            return
                "The clipboard has changed since that snapshot was taken, so restoring it would discard whatever was copied since. Nothing was restored. Take a new snapshot if you still need to swap the clipboard out."
        case .expired:
            return
                "That clipboard snapshot has expired and was discarded. Snapshots are kept for a few minutes so a copied password does not sit in memory afterwards."
        case .unknownToken:
            return "No clipboard snapshot with that token. It may have expired, or the app may have restarted."
        }
    }
}

/// One saved clipboard, held in memory only.
public struct ClipboardSnapshot: Equatable, Sendable {
    public let token: String
    public let createdAt: Date
    /// The pasteboard change count this snapshot may be restored over. It
    /// moves forward when Apple Core itself writes, and never when anything
    /// else does, which is the whole rule in one field.
    public var expectedChangeCount: Int
    public let items: [ClipboardFormat: Data]

    public init(token: String, createdAt: Date, expectedChangeCount: Int, items: [ClipboardFormat: Data]) {
        self.token = token
        self.createdAt = createdAt
        self.expectedChangeCount = expectedChangeCount
        self.items = items
    }
}

/// Holds snapshots for a bounded time and answers whether one may be restored.
///
/// Bounded on purpose: a snapshot can contain a password a user copied out of
/// their password manager, so it is held for minutes rather than for the life
/// of the process, and never written to disk.
public final class ClipboardSnapshotStore: @unchecked Sendable {
    public static let shared = ClipboardSnapshotStore()

    /// Long enough for a copy-do-something-restore sequence, short enough that
    /// a forgotten snapshot is not still in memory an hour later.
    public static let defaultLifetime: TimeInterval = 10 * 60
    public static let maximumSnapshots = 8

    private let lifetime: TimeInterval
    private let lock = NSLock()
    private var snapshots: [String: ClipboardSnapshot] = [:]

    public init(lifetime: TimeInterval = ClipboardSnapshotStore.defaultLifetime) {
        self.lifetime = lifetime
    }

    @discardableResult
    public func store(
        items: [ClipboardFormat: Data],
        changeCount: Int,
        now: Date = Date(),
        token: String = UUID().uuidString
    ) -> ClipboardSnapshot {
        lock.withLock {
            purge(now: now)
            if snapshots.count >= Self.maximumSnapshots,
                let oldest = snapshots.values.min(by: { $0.createdAt < $1.createdAt })
            {
                snapshots.removeValue(forKey: oldest.token)
            }
            let snapshot = ClipboardSnapshot(
                token: token,
                createdAt: now,
                expectedChangeCount: changeCount,
                items: items
            )
            snapshots[token] = snapshot
            return snapshot
        }
    }

    /// Records a write Apple Core made itself, so a snapshot taken before it
    /// stays restorable. Without this, the tool that takes a snapshot and then
    /// writes the clipboard would immediately invalidate its own snapshot.
    public func recordOwnWrite(changeCount: Int) {
        lock.withLock {
            for key in snapshots.keys {
                snapshots[key]?.expectedChangeCount = changeCount
            }
        }
    }

    public func decide(token: String, currentChangeCount: Int, now: Date = Date())
        -> ClipboardRestoreDecision
    {
        lock.withLock {
            guard let snapshot = snapshots[token] else { return .unknownToken }
            guard now.timeIntervalSince(snapshot.createdAt) <= lifetime else {
                snapshots.removeValue(forKey: token)
                return .expired
            }
            guard snapshot.expectedChangeCount == currentChangeCount else {
                return .refusedNewerCopy(
                    currentChangeCount: currentChangeCount,
                    expectedChangeCount: snapshot.expectedChangeCount
                )
            }
            return .restore
        }
    }

    public func snapshot(token: String, now: Date = Date()) -> ClipboardSnapshot? {
        lock.withLock {
            purge(now: now)
            return snapshots[token]
        }
    }

    /// Restoring consumes the snapshot: a token that has been used is not a
    /// standing licence to overwrite the clipboard again later.
    public func consume(token: String) {
        lock.withLock { _ = snapshots.removeValue(forKey: token) }
    }

    public var count: Int { lock.withLock { snapshots.count } }

    private func purge(now: Date) {
        for (token, snapshot) in snapshots
        where now.timeIntervalSince(snapshot.createdAt) > lifetime {
            snapshots.removeValue(forKey: token)
        }
    }
}
