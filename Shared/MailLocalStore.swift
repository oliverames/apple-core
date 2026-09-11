// SPDX-License-Identifier: GPL-3.0-or-later
//
// Where Apple Mail keeps its messages, and whether this Mac will let us look.
//
// Mail's store is a directory tree, not a database:
//
//   ~/Library/Mail/V10/<account UUID>/<Mailbox>.mbox/<UUID>/Data/…/Messages/*.emlx
//
// Nested mailboxes nest their `.mbox` directories, the `Data` fan-out exists
// only to keep directory sizes down, and a message whose body has not been
// downloaded is written as `<id>.partial.emlx`. This file turns all of that
// into a flat list of message files with the mailbox path they belong to.
//
// Nothing here opens Mail, writes anything, or takes a lock. Reading is the
// entire contract: the index built from this is Apple Core's own artifact and
// Mail's storage is never touched.
//
// Two failure modes are kept apart on purpose. A Mac with no local mail is
// not a Mac that refused to show it, and reporting "no results" for the
// second is the exact dishonesty this index exists to remove. Without Full
// Disk Access the directory usually still stats but will not enumerate, so
// the distinction is drawn on the enumeration rather than on existence.

import Foundation

/// Whether the on-disk store can be read at all, and why not when it cannot.
enum MailLocalStoreAccess: Sendable, Equatable {
    case available(root: String)
    /// The path is not there. Mail has never run here, or stores nothing
    /// locally for the accounts configured.
    case noLocalMail(String)
    /// The path is there and will not enumerate, which on macOS means Full
    /// Disk Access has not been granted to this app.
    case accessDenied(String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    /// One sentence stating the state in the words a client should relay.
    var explanation: String {
        switch self {
        case let .available(root):
            return "Mail's local store is readable at \(root)."
        case let .noLocalMail(path):
            return
                "NO_LOCAL_MAIL: nothing is stored at \(path), so there is no local mail to "
                + "index. Accounts that keep everything on the server are read through Mail "
                + "itself instead."
        case let .accessDenied(path):
            return
                "NO_DISK_ACCESS: \(path) exists but cannot be read. Grant Apple Core Full Disk "
                + "Access in System Settings > Privacy & Security, then quit and reopen it. "
                + "Every other Mail tool works without this; only the local index needs it."
        }
    }
}

/// One message file on disk, before it has been parsed.
struct MailScannedMessageFile: Sendable, Equatable {
    /// Identity inside the index: account, mailbox and Mail's own file id.
    /// A message that moves gets a new one, which is what makes a move
    /// visible instead of silently doubling the message.
    let stableID: String
    let accountID: String
    /// Slash-joined mailbox path with the `.mbox` suffixes removed, so
    /// `Work.mbox/Clients.mbox` reads as `Work/Clients`.
    let mailbox: String
    let emlxID: String
    let path: String
    let sizeBytes: Int
    let modified: Date
    let isPartial: Bool

    static func stableID(accountID: String, mailbox: String, emlxID: String) -> String {
        "\(accountID)/\(mailbox)/\(emlxID)"
    }
}

/// A file that exists but could not be read or parsed, kept so the count of
/// unavailable messages is reported rather than lost.
struct MailIndexIssue: Sendable, Equatable, Codable {
    let path: String
    let reason: String
}

struct MailLocalStoreScan: Sendable, Equatable {
    let files: [MailScannedMessageFile]
    let issues: [MailIndexIssue]
    let accountIDs: [String]
    let mailboxes: [String]
    /// True when the walk stopped at `fileLimit` rather than at the end of
    /// the tree. A scan that stopped early must never be recorded as a
    /// complete picture of the store.
    let truncated: Bool
}

/// Read-only enumeration of Mail's message files.
struct MailLocalStore: Sendable {
    let root: URL

    /// `~/Library/Mail`, or the directory named by `APPLECORE_MAIL_ROOT`.
    ///
    /// The override exists for tests and for a copy of a store taken for
    /// diagnosis. It is resolved per call, so a test can point it somewhere
    /// disposable without the value being captured at launch.
    static var `default`: MailLocalStore {
        if let override = ProcessInfo.processInfo.environment["APPLECORE_MAIL_ROOT"],
            !override.isEmpty
        {
            return MailLocalStore(
                root: URL(
                    fileURLWithPath: (override as NSString).expandingTildeInPath,
                    isDirectory: true
                )
            )
        }
        return MailLocalStore(
            root: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mail", isDirectory: true)
        )
    }

    /// Can this store be enumerated, and if not, which kind of "no".
    var access: MailLocalStoreAccess {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .noLocalMail(root.path)
        }
        do {
            _ = try manager.contentsOfDirectory(atPath: root.path)
        } catch {
            return .accessDenied(root.path)
        }
        guard versionDirectory != nil else { return .noLocalMail(root.path) }
        return .available(root: root.path)
    }

    /// The highest-numbered `V<n>` directory, which is the one Mail uses.
    /// A store copied without its version directory is read from the root.
    var versionDirectory: URL? {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: root.path) else { return nil }
        let versions = entries.filter { entry in
            entry.hasPrefix("V") && entry.dropFirst().allSatisfy(\.isNumber)
                && !entry.dropFirst().isEmpty
        }
        guard
            let latest = versions.max(by: {
                (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0)
            })
        else {
            // A directory holding `.mbox` bundles directly is still a store.
            return entries.contains { $0.hasSuffix(".mbox") } ? root : nil
        }
        return root.appendingPathComponent(latest, isDirectory: true)
    }

    /// Walks every account for message files.
    ///
    /// `fileLimit` bounds one pass so a first run against a very large store
    /// cannot hang a tool call. Hitting it sets `truncated`, and the caller
    /// is expected to report the index as incomplete until a pass finishes
    /// without it.
    func scan(fileLimit: Int = 200_000) throws -> MailLocalStoreScan {
        guard case .available = access, let version = versionDirectory else {
            return MailLocalStoreScan(
                files: [],
                issues: [],
                accountIDs: [],
                mailboxes: [],
                truncated: false
            )
        }
        let manager = FileManager.default
        var files: [MailScannedMessageFile] = []
        var issues: [MailIndexIssue] = []
        var accountIDs: [String] = []
        var mailboxes: Set<String> = []
        var truncated = false

        let accountDirectories =
            (try? manager.contentsOfDirectory(atPath: version.path))?
            .sorted()
            .map { version.appendingPathComponent($0, isDirectory: true) }
            .filter { isDirectory($0) }
            ?? []

        for accountDirectory in accountDirectories {
            let accountID = accountDirectory.lastPathComponent
            // MailData holds Mail's own settings, not messages.
            guard accountID != "MailData" else { continue }
            guard
                let enumerator = manager.enumerator(
                    at: accountDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { url, error in
                        issues.append(
                            MailIndexIssue(path: url.path, reason: error.localizedDescription)
                        )
                        return true
                    }
                )
            else {
                issues.append(
                    MailIndexIssue(
                        path: accountDirectory.path,
                        reason: "the account directory could not be enumerated"
                    )
                )
                continue
            }
            var sawMessage = false
            for case let url as URL in enumerator {
                guard url.pathExtension == "emlx" else { continue }
                let name = url.lastPathComponent
                let isPartial = name.hasSuffix(".partial.emlx")
                let emlxID =
                    isPartial
                    ? String(name.dropLast(".partial.emlx".count))
                    : String(name.dropLast(".emlx".count))
                guard !emlxID.isEmpty else { continue }
                let mailbox = Self.mailboxPath(for: url, under: accountDirectory)
                guard !mailbox.isEmpty else { continue }
                let values = try? url.resourceValues(forKeys: [
                    .fileSizeKey, .contentModificationDateKey,
                ])
                files.append(
                    MailScannedMessageFile(
                        stableID: MailScannedMessageFile.stableID(
                            accountID: accountID,
                            mailbox: mailbox,
                            emlxID: emlxID
                        ),
                        accountID: accountID,
                        mailbox: mailbox,
                        emlxID: emlxID,
                        path: url.path,
                        sizeBytes: values?.fileSize ?? 0,
                        modified: values?.contentModificationDate ?? .distantPast,
                        isPartial: isPartial
                    )
                )
                mailboxes.insert("\(accountID)/\(mailbox)")
                sawMessage = true
                if files.count >= fileLimit {
                    truncated = true
                    break
                }
            }
            if sawMessage { accountIDs.append(accountID) }
            if truncated { break }
        }

        return MailLocalStoreScan(
            files: files,
            issues: issues,
            accountIDs: accountIDs,
            mailboxes: mailboxes.sorted(),
            truncated: truncated
        )
    }

    /// The mailbox a message file belongs to, read off the `.mbox`
    /// directories in its path. Nesting is preserved; the `Data` fan-out and
    /// the per-mailbox UUID directory are not part of the name.
    static func mailboxPath(for file: URL, under accountDirectory: URL) -> String {
        let accountComponents = accountDirectory.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        guard fileComponents.count > accountComponents.count else { return "" }
        let relative = fileComponents[accountComponents.count...]
        let names = relative.filter { $0.hasSuffix(".mbox") }
            .map { String($0.dropLast(".mbox".count)) }
        return names.joined(separator: "/")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag)
            && flag.boolValue
    }
}
