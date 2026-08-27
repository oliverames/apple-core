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
