// SPDX-License-Identifier: GPL-3.0-or-later
//
// Scope enforcement for the filesystem surface.
//
// Every other surface in Apple Core is bounded by a macOS privacy grant: the
// Calendar surface can only ever see calendars, whatever a client asks for.
// The filesystem has no such natural bound, so the bound is this file: an
// explicit allowlist of roots, empty until the user adds one, with read and
// write tracked separately per root.
//
// Containment is checked against symlink-resolved canonical paths, because
// "is this path under that directory?" answered on the literal string is
// answered wrongly by `..` segments and by a symlink inside an allowed root
// pointing outside it. A path that does not exist yet (the write case) is
// checked by resolving its parent, since a file cannot be canonicalized
// before it exists.

import Foundation

public struct FilesystemRoot: Codable, Sendable, Equatable, Identifiable {
    public var path: String
    /// Read access is implied by being on the list. Writing is not.
    public var writable: Bool

    public var id: String { path }

    public init(path: String, writable: Bool = false) {
        self.path = path
        self.writable = writable
    }
}

public enum FilesystemAccessError: LocalizedError, Equatable {
    case noRootsConfigured
    case outsideAllowedRoots(String)
    case rootNotWritable(String)
    case notFound(String)
    case danglingSymlink(String)
    case retargetedRoot(String)

    public var errorDescription: String? {
        switch self {
        case .noRootsConfigured:
            return
                "No folders have been shared with Apple Core. Add one in Settings › Services › Filesystem first."
        case let .outsideAllowedRoots(path):
            return "\(path) is outside every folder shared with Apple Core."
        case let .rootNotWritable(path):
            return "\(path) is in a folder shared for reading only."
        case let .notFound(path):
            return "\(path) does not exist."
        case let .danglingSymlink(path):
            return
                "\(path) is a broken symbolic link. Apple Core refuses to create files through one, because it cannot tell where the write would land."
        case let .retargetedRoot(path):
            return
                "The shared folder at \(path) is now a symbolic link. Remove it from Settings and share the intended folder again."
        }
    }
}

public enum FilesystemAccess {
    /// Absolute, tilde-expanded, symlink-resolved. Two paths naming the same
    /// file always produce the same string here, which is what makes the
    /// prefix comparison below sound.
    public static func canonicalize(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    /// True when `candidate` is the root itself or sits beneath it. Compares
    /// whole path components, so "/Users/foo/Documents-private" is correctly
    /// rejected against the root "/Users/foo/Documents" — a plain `hasPrefix`
    /// on the raw string would accept it.
    public static func isContained(_ candidate: String, in root: String) -> Bool {
        if candidate == root { return true }
        return candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Resolves a client-supplied path against the allowlist, or throws.
    ///
    /// `requiringWrite` picks which roots count: reading is allowed anywhere
    /// on the list, writing only under a root marked writable.
    public static func resolve(
        requested path: String,
        roots: [FilesystemRoot],
        requiringWrite: Bool,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !roots.isEmpty else { throw FilesystemAccessError.noRootsConfigured }

        let expanded = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL

        // Settings stores a symlink-resolved root. If that literal path later
        // resolves somewhere else, the folder was replaced or an ancestor was
        // retargeted after approval. Never silently move the allowlist with it.
        let stableRoots = roots.filter { root in
            let approvedPath = URL(fileURLWithPath: NSString(string: root.path).expandingTildeInPath)
                .standardizedFileURL.path
            let isStable = canonicalize(approvedPath) == approvedPath
            if !isStable, isContained(expanded.path, in: approvedPath) {
                return false
            }
            return isStable
        }
        if let retargeted = roots.first(where: { root in
            let approvedPath = URL(fileURLWithPath: NSString(string: root.path).expandingTildeInPath)
                .standardizedFileURL.path
            return canonicalize(approvedPath) != approvedPath
                && isContained(expanded.path, in: approvedPath)
        }) {
            throw FilesystemAccessError.retargetedRoot(retargeted.path)
        }
        let usableRoots = requiringWrite ? stableRoots.filter(\.writable) : stableRoots

        // A file being created does not exist yet, so canonicalize its parent
        // and re-attach the final component. Without this, every write would
        // be rejected as "outside allowed roots".
        let canonical: String
        if fileManager.fileExists(atPath: expanded.path) {
            canonical = canonicalize(expanded.path)
        } else {
            // fileExists follows symlinks, so a dangling symlink at the final
            // component reads as "nonexistent" here. Parent-only resolution
            // would then bless the raw name, and whatever runs afterward —
            // Mail.app saving an attachment, shortcuts writing an output
            // file — follows the link outside the roots. lstat it and refuse.
            if (try? fileManager.destinationOfSymbolicLink(atPath: expanded.path)) != nil {
                throw FilesystemAccessError.danglingSymlink(expanded.path)
            }
            let parent = expanded.deletingLastPathComponent().path
            guard fileManager.fileExists(atPath: parent) else {
                throw FilesystemAccessError.notFound(expanded.path)
            }
            canonical = canonicalize(parent) + "/" + expanded.lastPathComponent
        }

        for root in usableRoots where isContained(canonical, in: canonicalize(root.path)) {
            return URL(fileURLWithPath: canonical)
        }

        // Distinguish "not shared at all" from "shared read-only", because the
        // two have different fixes and the second is easy to mistake for a bug.
        if requiringWrite,
            stableRoots.contains(where: { isContained(canonical, in: canonicalize($0.path)) })
        {
            throw FilesystemAccessError.rootNotWritable(canonical)
        }
        throw FilesystemAccessError.outsideAllowedRoots(canonical)
    }
}

/// How wide a shared folder actually is, in terms a person can act on.
///
/// The Settings list showed a name, a path and a writing switch, and nothing
/// about consequence. Someone could share their whole Home folder read-write
/// and see the same row as someone sharing one project directory, then add
/// four more folders already inside it without being told they were
/// redundant. This is the missing signal, kept out of the view so it can be
/// tested and so the wording lives in one place.
public enum FilesystemRootScope: Sendable, Equatable {
    /// An ordinary folder. Nothing to say about it.
    case ordinary
    /// Already inside another shared folder, so it grants nothing extra.
    case alreadyCovered(by: String)
    /// The user's entire home folder.
    case entireHomeFolder
    /// A volume root, or anything above the home folder.
    case entireDisk
}

public struct FilesystemRootAdvice: Sendable, Equatable {
    public let scope: FilesystemRootScope
    public let writable: Bool

    public init(scope: FilesystemRootScope, writable: Bool) {
        self.scope = scope
        self.writable = writable
    }

    /// True when this is worth interrupting someone over, rather than a note.
    public var isSerious: Bool {
        switch scope {
        case .entireDisk:
            return true
        case .entireHomeFolder:
            return true
        case .alreadyCovered, .ordinary:
            return false
        }
    }

    /// One sentence, in plain language, or nil when there is nothing to say.
    ///
    /// Deliberately says what a connected app could do, not what the setting
    /// is called. "Read-write access to $HOME" means nothing to most people;
    /// "could read and change anything in it" does.
    public var message: String? {
        switch scope {
        case .ordinary:
            return nil
        case let .alreadyCovered(parent):
            return
                "Already inside \(parent), which is shared, so this adds nothing. You can remove it."
        case .entireHomeFolder:
            return writable
                ? "This is your whole Home folder. Connected apps could read and change anything in it, including your app data and saved passwords. Sharing just Documents is usually enough."
                : "This is your whole Home folder, so connected apps can read anything in it, including your app data. Sharing just Documents is usually enough."
        case .entireDisk:
            return writable
                ? "This covers your whole disk. Connected apps could read and change any file on this Mac. Share a specific folder instead."
                : "This covers your whole disk, so connected apps can read any file on this Mac. Share a specific folder instead."
        }
    }
}

extension FilesystemAccess {
    /// Describes one root in the context of the others.
    ///
    /// `others` is the rest of the list; a folder is only reported as covered
    /// when something else on the list actually contains it.
    public static func advice(
        for root: FilesystemRoot,
        among others: [FilesystemRoot],
        homeDirectory: String = NSHomeDirectory()
    ) -> FilesystemRootAdvice {
        let path = canonicalize(root.path)
        let home = canonicalize(homeDirectory)

        if path == "/" || isContained(home, in: path) && path != home {
            return FilesystemRootAdvice(scope: .entireDisk, writable: root.writable)
        }
        if path == home {
            return FilesystemRootAdvice(scope: .entireHomeFolder, writable: root.writable)
        }
        // Compare against the others by canonical path so two spellings of the
        // same folder do not read as one containing the other.
        for other in others {
            let otherPath = canonicalize(other.path)
            if otherPath != path, isContained(path, in: otherPath) {
                return FilesystemRootAdvice(
                    scope: .alreadyCovered(by: displayName(for: otherPath, homeDirectory: home)),
                    writable: root.writable
                )
            }
        }
        return FilesystemRootAdvice(scope: .ordinary, writable: root.writable)
    }

    /// A short name for a folder, for use inside a sentence.
    public static func displayName(for path: String, homeDirectory: String = NSHomeDirectory())
        -> String
    {
        if canonicalize(path) == canonicalize(homeDirectory) { return "your Home folder" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
