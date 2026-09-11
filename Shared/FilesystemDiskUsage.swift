// SPDX-License-Identifier: GPL-3.0-or-later
//
// "What is taking up all the space in this folder?"
//
// `utilities_storage_summary` answers that question for a whole volume, and
// `filesystem_tree` shows shape without totals. Neither rolls a subtree up into
// a number, which is the question anyone actually asks before deleting
// anything. Doing it by hand costs one `filesystem_tree` page per folder and
// still misses everything below the depth limit.
//
// Three things this walk is careful about:
//
//   * Allocated size, not just logical size. A sparse file, a compressed file
//     and an APFS clone all report a `fileSize` that has little to do with the
//     blocks they occupy, and "why is the disk full" is a question about
//     blocks. Both numbers are reported, because the difference is itself
//     informative.
//   * Symbolic links are counted and never followed. Following them would
//     double-count a clone farm, loop forever on a cycle, and — the part that
//     matters — measure files outside the shared folders.
//   * Every entry is re-checked against the allowlist, exactly as
//     `FilesystemTree` does. A link planted inside a shared folder cannot make
//     this walk read the size of anything outside it.

import Foundation

/// One direct child of the measured folder, with its whole subtree rolled up.
public struct FilesystemUsageChild: Equatable, Sendable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    /// Sum of file sizes, the number a listing shows.
    public let logicalBytes: Int64
    /// Sum of blocks actually allocated, the number the disk cares about.
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        fileCount: Int,
        directoryCount: Int
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
    }
}

public struct FilesystemUsageResult: Equatable, Sendable {
    public let root: String
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let fileCount: Int
    public let directoryCount: Int
    /// Direct children, largest first, capped at the requested count.
    public let children: [FilesystemUsageChild]
    /// How many direct children the folder has in total, so a caller can see
    /// that the list was cut.
    public let childCount: Int
    /// Symbolic links found. Counted, never followed, never sized.
    public let symbolicLinkCount: Int
    /// Entries that resolved outside the shared folders. Counted, never named.
    public let deniedCount: Int
    /// Folders that could not be read at all, usually a permission the Mac's
    /// owner has not granted Apple Core.
    public let unreadableCount: Int
    /// True when the walk stopped on its own budget. The totals are then a
    /// floor, not an answer.
    public let exhaustedScanBudget: Bool

    public init(
        root: String,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        fileCount: Int,
        directoryCount: Int,
        children: [FilesystemUsageChild],
        childCount: Int,
        symbolicLinkCount: Int,
        deniedCount: Int,
        unreadableCount: Int,
        exhaustedScanBudget: Bool
    ) {
        self.root = root
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.children = children
        self.childCount = childCount
        self.symbolicLinkCount = symbolicLinkCount
        self.deniedCount = deniedCount
        self.unreadableCount = unreadableCount
        self.exhaustedScanBudget = exhaustedScanBudget
    }
}

public enum FilesystemDiskUsageError: LocalizedError, Equatable {
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .notADirectory(path):
            return
                "\(path) is a file, not a folder, so there is nothing to add up. Use filesystem_stat for one file's size."
        }
    }
}

public enum FilesystemDiskUsage {
    public static let defaultMaxChildren = 20
    public static let maximumMaxChildren = 200
    /// Entries one call may look at. A home folder is millions of files; a
    /// connector call that walks all of them is a hang, not a measurement.
    public static let scanBudget = 200_000

    public static func clampedChildren(_ requested: Int?) -> Int {
        guard let requested, requested > 0 else { return defaultMaxChildren }
        return min(requested, maximumMaxChildren)
    }

    /// Measures `root` and rolls each direct child's subtree up.
    ///
    /// `root` is expected to have been resolved through `FilesystemAccess`
    /// already; every entry below it is resolved again here.
    public static func measure(
        root: URL,
        roots: [FilesystemRoot],
        maxChildren: Int = defaultMaxChildren,
        fileManager: FileManager = .default
    ) throws -> FilesystemUsageResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
            throw FilesystemAccessError.notFound(root.path)
        }
        guard isDirectory.boolValue else {
            throw FilesystemDiskUsageError.notADirectory(root.path)
        }

        var state = MeasureState(roots: roots, fileManager: fileManager)
        var children: [FilesystemUsageChild] = []

        let topLevel = state.readChildren(of: root)
        for child in topLevel {
            guard !state.exhaustedScanBudget else { break }
            guard let classified = state.classify(child) else { continue }
            switch classified {
            case .symbolicLink:
                continue
            case let .file(logical, allocated):
                children.append(
                    FilesystemUsageChild(
                        name: child.lastPathComponent,
                        path: child.path,
                        isDirectory: false,
                        logicalBytes: logical,
                        allocatedBytes: allocated,
                        fileCount: 1,
                        directoryCount: 0
                    )
                )
            case .directory:
                var subtree = Totals()
                state.accumulate(directory: child, into: &subtree)
                children.append(
                    FilesystemUsageChild(
                        name: child.lastPathComponent,
                        path: child.path,
                        isDirectory: true,
                        logicalBytes: subtree.logicalBytes,
                        allocatedBytes: subtree.allocatedBytes,
                        fileCount: subtree.fileCount,
                        directoryCount: subtree.directoryCount + 1
                    )
                )
            }
        }

        let totals = children.reduce(into: Totals()) { totals, child in
            totals.logicalBytes += child.logicalBytes
            totals.allocatedBytes += child.allocatedBytes
            totals.fileCount += child.fileCount
            totals.directoryCount += child.directoryCount
        }

        // Largest first. Allocated size decides, because that is the number
        // the disk cares about — but small files all occupy exactly one block,
        // so a folder of them would otherwise come back in name order with the
        // biggest file buried. Logical size breaks that tie, and the name
        // breaks the remaining one, so two calls on an unchanged folder always
        // return the same order.
        let ranked = children.sorted { left, right in
            if left.allocatedBytes != right.allocatedBytes {
                return left.allocatedBytes > right.allocatedBytes
            }
            if left.logicalBytes != right.logicalBytes {
                return left.logicalBytes > right.logicalBytes
            }
            return left.name < right.name
        }

        return FilesystemUsageResult(
            root: root.path,
            logicalBytes: totals.logicalBytes,
            allocatedBytes: totals.allocatedBytes,
            fileCount: totals.fileCount,
            directoryCount: totals.directoryCount,
            children: Array(ranked.prefix(max(1, maxChildren))),
            childCount: children.count,
            symbolicLinkCount: state.symbolicLinkCount,
            deniedCount: state.deniedCount,
            unreadableCount: state.unreadableCount,
            exhaustedScanBudget: state.exhaustedScanBudget
        )
    }

    private struct Totals {
        var logicalBytes: Int64 = 0
        var allocatedBytes: Int64 = 0
        var fileCount = 0
        var directoryCount = 0
    }

    private enum Entry {
        case directory
        case file(logical: Int64, allocated: Int64)
        case symbolicLink
    }

    private struct MeasureState {
        let roots: [FilesystemRoot]
        let fileManager: FileManager
        var scanned = 0
        var symbolicLinkCount = 0
        var deniedCount = 0
        var unreadableCount = 0
        var exhaustedScanBudget = false

        mutating func readChildren(of directory: URL) -> [URL] {
            guard
                let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    ],
                    options: []
                )
            else {
                unreadableCount += 1
                return []
            }
            return children
        }

        /// Judges one entry, or returns nil when it must not be counted.
        ///
        /// The allowlist question comes first and the symlink question second,
        /// deliberately: a link pointing out of the shared folder has to be
        /// counted as denied, not quietly filed as a link.
        mutating func classify(_ url: URL) -> Entry? {
            scanned += 1
            if scanned > FilesystemDiskUsage.scanBudget {
                exhaustedScanBudget = true
                return nil
            }
            guard
                (try? FilesystemAccess.resolve(
                    requested: url.path,
                    roots: roots,
                    requiringWrite: false,
                    fileManager: fileManager
                )) != nil
            else {
                deniedCount += 1
                return nil
            }
            // Asked of the path itself rather than through resourceValues,
            // which resolves the link and would report the target's kind.
            if (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil {
                symbolicLinkCount += 1
                return .symbolicLink
            }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
            ])
            if values?.isDirectory == true { return .directory }
            let logical = Int64(values?.fileSize ?? 0)
            // totalFileAllocatedSize includes the resource fork and any
            // metadata the file carries; fileAllocatedSize is the fallback on
            // a filesystem that does not report the total.
            let allocated = Int64(
                values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? values?.fileSize ?? 0
            )
            return .file(logical: logical, allocated: allocated)
        }

        mutating func accumulate(directory: URL, into totals: inout Totals) {
            guard !exhaustedScanBudget else { return }
            guard
                let children = try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
                    ],
                    options: []
                )
            else {
                unreadableCount += 1
                return
            }
            for child in children {
                guard !exhaustedScanBudget else { return }
                guard let classified = classify(child) else { continue }
                switch classified {
                case .symbolicLink:
                    continue
                case let .file(logical, allocated):
                    totals.logicalBytes += logical
                    totals.allocatedBytes += allocated
                    totals.fileCount += 1
                case .directory:
                    totals.directoryCount += 1
                    accumulate(directory: child, into: &totals)
                }
            }
        }
    }
}
