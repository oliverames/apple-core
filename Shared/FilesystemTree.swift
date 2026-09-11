// SPDX-License-Identifier: GPL-3.0-or-later
//
// Bounded recursive listing for the filesystem surface.
//
// `filesystem_list` shows one directory and `filesystem_search` walks a whole
// tree looking for a name. Neither answers "what is the shape of this folder",
// which is the question a client asks before it does anything else, and the
// naive answer — walk everything — is unbounded in three separate directions:
// depth, entry count, and the time spent inside build folders nobody asked
// about.
//
// So the walk is bounded on all three, and every bound is reported rather than
// silently applied. Continuation is explicit: a cursor names the last entry
// handed back, and the next call resumes after it in the same deterministic
// order. Ordering is plain Unicode ordering of the path, not a localized
// collation, because a cursor has to mean the same thing on the next call
// whatever the user's locale is.
//
// The one thing this file does not do is take the allowlist's word for the
// root. Every child is resolved through `FilesystemAccess` in its own right,
// so a symlink planted inside a shared folder cannot widen the walk, and a
// root that was unshared between two pages stops the second one.

import Foundation

public struct FilesystemTreeEntry: Equatable, Sendable {
    /// Path relative to the walk's root, with no leading slash. This is also
    /// the cursor value, so it has to identify an entry uniquely.
    public let relativePath: String
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let isSymbolicLink: Bool
    /// 1 for an entry directly inside the root.
    public let depth: Int
    public let sizeBytes: Int?
    public let modified: Date?

    public init(
        relativePath: String,
        path: String,
        name: String,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        depth: Int,
        sizeBytes: Int?,
        modified: Date?
    ) {
        self.relativePath = relativePath
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.depth = depth
        self.sizeBytes = sizeBytes
        self.modified = modified
    }
}

/// What stopped the walk, in the caller's terms. More than one can be true:
/// a page can hit the entry budget inside a tree that was also deeper than
/// the depth limit.
public struct FilesystemTreeResult: Equatable, Sendable {
    public let root: String
    public let entries: [FilesystemTreeEntry]
    /// Pass back as `cursor` to continue. Nil means the walk finished.
    public let nextCursor: String?
    /// True when the entry budget, not the tree, ended this page.
    public let reachedEntryLimit: Bool
    /// True when something was not descended into because of `maxDepth`.
    public let reachedDepthLimit: Bool
    /// How many entries the exclusion patterns removed.
    public let excludedCount: Int
    /// How many entries were dropped because they resolved outside the shared
    /// folders. Counted, never named: naming them would describe files the
    /// caller was not allowed to see.
    public let deniedCount: Int
    /// True when the traversal budget ran out before the tree did. The page is
    /// still correct; the cursor still continues it.
    public let exhaustedScanBudget: Bool

    public init(
        root: String,
        entries: [FilesystemTreeEntry],
        nextCursor: String?,
        reachedEntryLimit: Bool,
        reachedDepthLimit: Bool,
        excludedCount: Int,
        deniedCount: Int,
        exhaustedScanBudget: Bool
    ) {
        self.root = root
        self.entries = entries
        self.nextCursor = nextCursor
        self.reachedEntryLimit = reachedEntryLimit
        self.reachedDepthLimit = reachedDepthLimit
        self.excludedCount = excludedCount
        self.deniedCount = deniedCount
        self.exhaustedScanBudget = exhaustedScanBudget
    }
}

public enum FilesystemTreeError: LocalizedError, Equatable {
    case notADirectory(String)
    case tooManyExclusions(requested: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case let .notADirectory(path):
            return "\(path) is not a folder, so there is no tree to walk. Use filesystem_stat for one file."
        case let .tooManyExclusions(requested, limit):
            return "\(requested) exclusion patterns is over the \(limit) this call accepts."
        }
    }
}

/// Shell-style pattern matching, delegated to `fnmatch` so the syntax is the
/// one people already know from `.gitignore` and the shell rather than a
/// private dialect invented here.
public enum FilesystemGlob {
    /// A pattern containing a slash is matched against the whole relative
    /// path, and one without it against the entry's name alone. That is the
    /// rule `.gitignore` uses, and the one a caller writing `*.log` means.
    public static func matches(pattern: String, name: String, relativePath: String) -> Bool {
        let subject = pattern.contains("/") ? relativePath : name
        return pattern.withCString { patternBytes in
            subject.withCString { subjectBytes in
                fnmatch(patternBytes, subjectBytes, 0) == 0
            }
        }
    }

    public static func matchesAny(
        patterns: [String],
        name: String,
        relativePath: String
    ) -> Bool {
        patterns.contains { matches(pattern: $0, name: name, relativePath: relativePath) }
    }
}

public enum FilesystemTree {
    public static let defaultMaxDepth = 3
    public static let maximumMaxDepth = 10
    public static let defaultMaxEntries = 200
    public static let maximumMaxEntries = 1000
    public static let maximumExclusions = 32
    /// How many directory entries one call may look at, including the ones it
    /// skips to reach the cursor. Without this a deep tree of excluded folders
    /// could spend minutes producing an empty page.
    public static let scanBudget = 20_000

    /// Folders that are always noise in a tree listing. Overridable: passing
    /// `useDefaultExclusions: false` walks them.
    public static let defaultExclusions = [
        ".git", ".build", ".DS_Store", "node_modules", "__pycache__", ".venv",
    ]

    public static func clampedDepth(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxDepth }
        return min(requested, maximumMaxDepth)
    }

    public static func clampedEntries(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxEntries }
        return min(requested, maximumMaxEntries)
    }

    /// Walks `root` in deterministic pre-order and returns one bounded page.
    ///
    /// Symbolic links are reported but never descended into. That bounds the
    /// walk against cycles, and it is also the containment rule: a link's
    /// target is a separate path, and anything under it has to be asked for
    /// by name so `FilesystemAccess` gets to judge it as a root question.
    public static func walk(
        root: URL,
        roots: [FilesystemRoot],
        maxDepth: Int,
        maxEntries: Int,
        exclusions: [String],
        includeHidden: Bool,
        cursor: String?,
        fileManager: FileManager = .default
    ) throws -> FilesystemTreeResult {
        guard exclusions.count <= maximumExclusions else {
            throw FilesystemTreeError.tooManyExclusions(
                requested: exclusions.count,
                limit: maximumExclusions
            )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw FilesystemAccessError.notFound(root.path)
        }
        guard isDirectory.boolValue else {
            throw FilesystemTreeError.notADirectory(root.path)
        }

        var state = WalkState(
            roots: roots,
            maxDepth: max(1, maxDepth),
            maxEntries: max(1, maxEntries),
            exclusions: exclusions,
            includeHidden: includeHidden,
            cursor: cursor,
            fileManager: fileManager
        )
        state.skipping = cursor != nil
        descend(root, relativePrefix: "", depth: 1, state: &state)

        return FilesystemTreeResult(
            root: root.path,
            entries: state.entries,
            // A budget-exhausted page that emitted nothing still has to
            // continue from somewhere, so it hands the same cursor back rather
            // than reading as a finished walk.
            nextCursor: state.reachedEntryLimit || state.exhaustedScanBudget
                ? (state.entries.last?.relativePath ?? cursor) : nil,
            reachedEntryLimit: state.reachedEntryLimit,
            reachedDepthLimit: state.reachedDepthLimit,
            excludedCount: state.excludedCount,
            deniedCount: state.deniedCount,
            exhaustedScanBudget: state.exhaustedScanBudget
        )
    }

    private struct WalkState {
        let roots: [FilesystemRoot]
        let maxDepth: Int
        let maxEntries: Int
        let exclusions: [String]
        let includeHidden: Bool
        let cursor: String?
        let fileManager: FileManager

        var entries: [FilesystemTreeEntry] = []
        var scanned = 0
        var excludedCount = 0
        var deniedCount = 0
        var reachedEntryLimit = false
        var reachedDepthLimit = false
        var exhaustedScanBudget = false
        /// True until the cursor entry has been passed. Resuming rescans the
        /// same order rather than trusting a path comparison to reproduce it.
        var skipping = false

        var isFinished: Bool { reachedEntryLimit || exhaustedScanBudget }
    }

    private static func descend(
        _ directory: URL,
        relativePrefix: String,
        depth: Int,
        state: inout WalkState
    ) {
        guard !state.isFinished else { return }
        guard
            let children = try? state.fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
                    .isHiddenKey,
                ],
                options: []
            )
        else { return }

        // Unicode ordering of the file name, not a localized collation: the
        // cursor has to name the same position on the next call, and
        // localizedStandardCompare depends on the process's locale.
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard !state.isFinished else { return }
            state.scanned += 1
            if state.scanned > scanBudget {
                state.exhaustedScanBudget = true
                return
            }

            let name = child.lastPathComponent
            let relativePath = relativePrefix.isEmpty ? name : relativePrefix + "/" + name

            if !state.includeHidden, FilesystemContent.isHidden(child) { continue }
            if FilesystemGlob.matchesAny(
                patterns: state.exclusions,
                name: name,
                relativePath: relativePath
            ) {
                state.excludedCount += 1
                continue
            }

            // The allowlist is re-asked for every child, never inherited from
            // the root. A shared folder that contains a symlink out of itself
            // must not widen the walk, and a root unshared between two pages
            // has to stop the second one.
            guard
                (try? FilesystemAccess.resolve(
                    requested: child.path,
                    roots: state.roots,
                    requiringWrite: false,
                    fileManager: state.fileManager
                )) != nil
            else {
                state.deniedCount += 1
                continue
            }

            let values = try? child.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            ])
            let isSymbolicLink =
                (try? state.fileManager.destinationOfSymbolicLink(atPath: child.path)) != nil
            let isDirectory = (values?.isDirectory ?? false) && !isSymbolicLink

            if state.skipping {
                if relativePath == state.cursor { state.skipping = false }
            } else {
                state.entries.append(
                    FilesystemTreeEntry(
                        relativePath: relativePath,
                        path: child.path,
                        name: name,
                        isDirectory: isDirectory,
                        isSymbolicLink: isSymbolicLink,
                        depth: depth,
                        sizeBytes: values?.fileSize,
                        modified: values?.contentModificationDate
                    )
                )
                if state.entries.count >= state.maxEntries {
                    state.reachedEntryLimit = true
                    return
                }
            }

            guard isDirectory else { continue }
            if depth >= state.maxDepth {
                state.reachedDepthLimit = true
                continue
            }
            descend(child, relativePrefix: relativePath, depth: depth + 1, state: &state)
        }
    }
}
