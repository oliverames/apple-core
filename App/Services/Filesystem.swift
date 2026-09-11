// SPDX-License-Identifier: GPL-3.0-or-later
//
// Filesystem surface.
//
// Every tool here resolves its path through `FilesystemAccess`, which is the
// only thing standing between a client and the whole disk: unlike Calendar or
// Contacts, nothing in macOS bounds this surface for us. The allowlist starts
// empty, so a fresh install exposes nothing until the user shares a folder.
//
// Reads are capped and text-only by design. Returning arbitrary binary as
// base64 through an MCP tool result is a good way to blow a client's context
// window on a file nobody can read anyway, so binary is reported as metadata
// and left on disk.

import CoreServices
import CryptoKit
import Foundation
import JSONSchema
import OSLog
import UniformTypeIdentifiers

private let log = Logger.service("filesystem")

/// Reads beyond this are truncated, with the truncation reported.
private let maximumReadBytes = 512 * 1024

/// Listings page rather than return everything. A directory of a few thousand
/// files describes out to megabytes, which costs a client its context window
/// for no benefit, and the old flat 200-match search cap gave no sign it had
/// stopped early — a caller could not tell "these are all the matches" from
/// "these are the first 200".
private let defaultPageSize = 100
private let maximumPageSize = 500

private func clampedPageSize(_ requested: Int?) -> Int {
    guard let requested, requested > 0 else { return defaultPageSize }
    return min(requested, maximumPageSize)
}

/// Directory order from the filesystem is arbitrary, so paging over it would
/// be free to repeat or skip entries between calls. Sort by name to give the
/// offsets something stable to point at.
private func sortedByName(_ urls: [URL]) -> [URL] {
    urls.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
}

/// Binary reads are capped for the same reason note attachments are: base64
/// inflates by a third, and a client's context window is the real limit here,
/// not the disk.
private let maximumInlineBinaryBytes = 256 * 1024
// Matches the per-attachment ceiling mail_send already enforces, rather
// than introducing a third number for the same question.
private let maximumBinaryWriteBytes = 10 * 1024 * 1024

final class FilesystemService: Service {
    static let shared = FilesystemService()

    /// Read fresh each call rather than cached: the user can share or unshare a
    /// folder while a client is connected, and the next call must respect it.
    ///
    /// Not private: `capture_read_image_text` reads a file from disk, so it
    /// has to ask the same allowlist this surface does. One definition, asked
    /// twice, rather than two definitions that can drift apart.
    var roots: [FilesystemRoot] {
        ServingConfigManager.load().filesystemRoots ?? []
    }

    var isActivated: Bool {
        get async { !roots.isEmpty }
    }

    var tools: [Tool] {
        Tool(
            name: "filesystem_roots",
            description:
                "List the folders the user has shared with Apple Core, and whether each one allows writing. "
                + "Call this first: every other filesystem tool only works inside these folders.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "List Shared Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let roots = FilesystemService.shared.roots
            guard !roots.isEmpty else {
                let empty: [String: Value] = [
                    "roots": .array([]),
                    "note": .string(
                        "No folders are shared yet. The user can add one in Settings › Services › Filesystem."
                    ),
                ]
                return Value.object(empty)
            }
            let described: [Value] = roots.map { root in
                .object([
                    "path": .string(root.path),
                    "writable": .bool(root.writable),
                ])
            }
            return Value.object(["roots": .array(described)])
        }

        Tool(
            name: "filesystem_list",
            description: "List the contents of a directory inside a shared folder",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Directory to list"),
                    "limit": .integer(
                        description: "Maximum entries to return",
                        default: .int(defaultPageSize)
                    ),
                    "offset": .integer(
                        description: "Entries to skip; pass a previous call's nextOffset",
                        default: .int(0)
                    ),
                    "includeHidden": .boolean(
                        description: "Include hidden files and folders, such as dotfiles",
                        default: .bool(true)
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Directory",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
            )
            let includeHidden = arguments["includeHidden"]?.boolValue ?? true
            let entries = sortedByName(
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey,
                    ]
                )
                .filter { includeHidden || !FilesystemContent.isHidden($0) }
            )
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            let limit = clampedPageSize(arguments["limit"]?.intValue)
            let page = Array(entries.dropFirst(offset).prefix(limit))

            var result: [String: Value] = [
                "path": .string(url.path),
                "entries": .array(page.map { FilesystemService.describe($0) }),
                "totalEntries": .int(entries.count),
            ]
            if offset + page.count < entries.count {
                result["nextOffset"] = .int(offset + page.count)
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_tree",
            description:
                "Walk a shared folder and everything beneath it, to a bounded depth. "
                + "Use this to see the shape of a project before reading anything. "
                + "Depth, entry count and exclusions are all bounded and every bound is reported; "
                + "when nextCursor comes back, pass it to continue exactly where this page stopped. "
                + "Symbolic links are listed but never followed.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Folder to walk"),
                    "maxDepth": .integer(
                        description:
                            "How many levels below the folder to descend, up to \(FilesystemTree.maximumMaxDepth)",
                        default: .int(FilesystemTree.defaultMaxDepth)
                    ),
                    "maxEntries": .integer(
                        description:
                            "Maximum entries in this page, up to \(FilesystemTree.maximumMaxEntries)",
                        default: .int(FilesystemTree.defaultMaxEntries)
                    ),
                    "exclude": .array(
                        description:
                            "Shell-style patterns to skip, such as *.log or build/*. A pattern with a slash matches the path relative to the folder; one without matches the entry name.",
                        items: .string()
                    ),
                    "useDefaultExclusions": .boolean(
                        description:
                            "Also skip the usual noise: \(FilesystemTree.defaultExclusions.joined(separator: ", "))",
                        default: .bool(true)
                    ),
                    "includeHidden": .boolean(
                        description: "Include hidden files and folders, such as dotfiles",
                        default: .bool(true)
                    ),
                    "cursor": .string(
                        description: "Continue a previous walk; pass its nextCursor unchanged"
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Walk Folder Tree",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let roots = FilesystemService.shared.roots
            let url = try FilesystemContent.resolveExisting(requested: path, roots: roots)

            var exclusions = arguments["exclude"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if arguments["useDefaultExclusions"]?.boolValue ?? true {
                exclusions.append(contentsOf: FilesystemTree.defaultExclusions)
            }

            let result = try FilesystemTree.walk(
                root: url,
                roots: roots,
                maxDepth: FilesystemTree.clampedDepth(arguments["maxDepth"]?.intValue),
                maxEntries: FilesystemTree.clampedEntries(arguments["maxEntries"]?.intValue),
                exclusions: exclusions,
                includeHidden: arguments["includeHidden"]?.boolValue ?? true,
                cursor: arguments["cursor"]?.stringValue
            )

            let formatter = ISO8601DateFormatter()
            let entries: [Value] = result.entries.map { entry in
                var described: [String: Value] = [
                    "relativePath": .string(entry.relativePath),
                    "path": .string(entry.path),
                    "name": .string(entry.name),
                    "isDirectory": .bool(entry.isDirectory),
                    "depth": .int(entry.depth),
                ]
                if entry.isSymbolicLink { described["isSymbolicLink"] = .bool(true) }
                if let size = entry.sizeBytes { described["sizeBytes"] = .int(size) }
                if let modified = entry.modified {
                    described["modified"] = .string(formatter.string(from: modified))
                }
                return .object(described)
            }

            var response: [String: Value] = [
                "path": .string(result.root),
                "entries": .array(entries),
                "entryCount": .int(entries.count),
                "reachedDepthLimit": .bool(result.reachedDepthLimit),
                "reachedEntryLimit": .bool(result.reachedEntryLimit),
                "excludedCount": .int(result.excludedCount),
            ]
            // Named only as a count. A denied child is a path the caller was
            // never shown, and listing them would turn a tree walk into a way
            // to map the folders around a shared one.
            if result.deniedCount > 0 {
                response["deniedCount"] = .int(result.deniedCount)
            }
            if let cursor = result.nextCursor {
                response["nextCursor"] = .string(cursor)
            }
            var notes: [String] = []
            if result.reachedEntryLimit {
                notes.append("Stopped at the entry limit. Pass nextCursor to continue.")
            }
            if result.reachedDepthLimit {
                notes.append(
                    "Some folders were not opened because they sit below maxDepth. Walk one of them directly, or raise maxDepth."
                )
            }
            if result.exhaustedScanBudget {
                notes.append(
                    "The walk hit its traversal budget before the entry limit, usually because most of the tree is excluded. Pass nextCursor to continue."
                )
            }
            if !notes.isEmpty { response["note"] = .string(notes.joined(separator: " ")) }
            return Value.object(response)
        }

        Tool(
            name: "filesystem_read",
            description:
                "Read a text file inside a shared folder. Binary files are not returned; their metadata is. "
                + "Large files come back capped, with nextOffset for reading on from there. Pass head or tail "
                + "to read the first or last lines instead: tail reads from the end of the file, so the end of "
                + "a long log costs one call rather than a walk through the whole thing.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to read"),
                    "offset": .integer(
                        description:
                            "Byte to start reading from; pass a previous call's nextOffset",
                        default: .int(0)
                    ),
                    "head": .integer(
                        description: FilesystemService.headArgumentDescription,
                        minimum: 1,
                        maximum: FilesystemLineWindow.maximumLines
                    ),
                    "tail": .integer(
                        description: FilesystemService.tailArgumentDescription,
                        minimum: 1,
                        maximum: FilesystemLineWindow.maximumLines
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
            )
            let metadataSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            let head = arguments["head"]?.intValue
            let tail = arguments["tail"]?.intValue
            if head != nil || tail != nil {
                return try FilesystemService.readLines(
                    at: url,
                    head: head,
                    tail: tail,
                    offsetRequested: arguments["offset"]?.intValue,
                    sizeBytes: metadataSize
                )
            }
            let byteOffset = max(0, arguments["offset"]?.intValue ?? 0)
            // Read only the cap, not the file: Data(contentsOf:) loaded a
            // multi-gigabyte file whole before the old slice applied.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if byteOffset > 0 {
                try handle.seek(toOffset: UInt64(byteOffset))
            }
            guard let data = try handle.read(upToCount: maximumReadBytes + 3) else {
                return Value.object([
                    "path": .string(url.path),
                    "isText": .bool(true),
                    "sizeBytes": .int(metadataSize ?? 0),
                    "content": .string(""),
                ])
            }
            let truncated = data.count > maximumReadBytes
            let window = FilesystemContent.textWindow(
                data,
                cap: maximumReadBytes,
                resuming: byteOffset > 0,
                truncated: truncated
            )

            guard let text = window.text else {
                return Value.object([
                    "path": .string(url.path),
                    "isText": .bool(false),
                    "sizeBytes": .int(metadataSize ?? data.count),
                    "note": .string(
                        "This file is not UTF-8 text, so its contents were not read. "
                            + "Use filesystem_read_binary for small binary files."
                    ),
                ])
            }
            let sizeBytes = metadataSize ?? data.count
            var result: [String: Value] = [
                "path": .string(url.path),
                "isText": .bool(true),
                "sizeBytes": .int(sizeBytes),
                "content": .string(text),
            ]
            if byteOffset > 0 {
                result["offset"] = .int(byteOffset)
            }
            if truncated {
                result["truncated"] = .bool(true)
                // Count the bytes actually consumed, not the cap: the trims
                // mean those differ, and a nextOffset built from the cap would
                // skip or repeat a few bytes on every page.
                result["nextOffset"] = .int(byteOffset + window.consumed)
                result["note"] = .string(
                    "Showing \(window.byteCount) bytes from offset \(byteOffset). "
                        + "Read on from nextOffset."
                )
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_write",
            description:
                "Create a text file inside a shared folder that allows writing. "
                + "Refuses to replace a file that already exists unless overwrite is true, "
                + "because a replaced file does not go to the Trash and cannot be recovered.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to write"),
                    "content": .string(description: "Text to write"),
                    "overwrite": .boolean(
                        description:
                            "Replace the file if it already exists. Its previous contents are lost.",
                        default: .bool(false)
                    ),
                ],
                required: ["path", "content"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write File",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let content = arguments["content"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("content")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: true
            )
            let existed = FileManager.default.fileExists(atPath: url.path)
            // Move and copy have always refused to overwrite, for the reason
            // spelled out on `destinationExists`: a replaced file never
            // reaches the Trash, so this is the one destructive act on this
            // surface with no undo. Write was the exception, and it is the
            // one a caller reaches for when it believes a file is new.
            guard
                !FilesystemContent.refusesOverwrite(
                    exists: existed,
                    overwriteRequested: arguments["overwrite"]?.boolValue ?? false
                )
            else {
                throw FilesystemServiceError.refusingToOverwrite(url.path)
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            log.info("Wrote \(url.lastPathComponent, privacy: .public)")
            return Value.object([
                "path": .string(url.path),
                "replaced": .bool(existed),
                "sizeBytes": .int(content.utf8.count),
            ])
        }

        Tool(
            name: "filesystem_search",
            description: "Find files by name beneath a shared folder",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Directory to search beneath"),
                    "query": .string(description: "Text the file name must contain"),
                    "limit": .integer(
                        description: "Maximum matches to return",
                        default: .int(defaultPageSize)
                    ),
                    "offset": .integer(
                        description: "Matches to skip; pass a previous call's nextOffset",
                        default: .int(0)
                    ),
                    "includeHidden": .boolean(
                        description: "Include hidden files and folders, such as dotfiles",
                        default: .bool(true)
                    ),
                ],
                required: ["path", "query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                throw FilesystemServiceError.missingArgument("query")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
            )
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            let limit = clampedPageSize(arguments["limit"]?.intValue)

            // Walk one past the page so the caller can be told whether more
            // exist. A whole-tree walk cannot report a true total without
            // paying for the entire traversal every call, so report the
            // continuation rather than a count that would be a lie.
            var found: [URL] = []
            let ceiling = FilesystemContent.pageEnd(offset: offset, limit: limit)
            // Was unconditionally `.skipsHiddenFiles`, while filesystem_list
            // had no such option. A dotfile was therefore listable but could
            // never be found by name. The two now agree, and both default to
            // showing what is there.
            let includeHidden = arguments["includeHidden"]?.boolValue ?? true
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                ],
                options: includeHidden ? [] : [.skipsHiddenFiles]
            )
            while let entry = enumerator?.nextObject() as? URL, found.count <= ceiling {
                if entry.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    found.append(entry)
                }
            }
            let hasMore = found.count > ceiling
            let page = Array(found.dropFirst(offset).prefix(limit))

            var result: [String: Value] = [
                "path": .string(url.path),
                "query": .string(query),
                "matches": .array(page.map { FilesystemService.describe($0) }),
            ]
            if hasMore {
                result["nextOffset"] = .int(offset + page.count)
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_stat",
            description:
                "Get one file or folder's metadata without reading it: size, kind, and modification time.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File or folder to describe")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Describe File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            // A path whose parent still exists resolves fine, so a file that
            // has been trashed since the caller last saw it used to come back
            // described as an ordinary non-directory with no size. Absence is
            // an error here, the same one every other surface returns.
            let url = try FilesystemContent.resolveExisting(
                requested: path,
                roots: FilesystemService.shared.roots
            )
            guard case .object(var entry) = FilesystemService.describe(url) else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
            if let created = values?.creationDate {
                entry["created"] = .string(ISO8601DateFormatter().string(from: created))
            }
            entry["isSymbolicLink"] = .bool(values?.isSymbolicLink ?? false)
            return Value.object(entry)
        }

        Tool(
            name: "filesystem_create_folder",
            description:
                "Create a folder inside a shared folder that allows writing. The parent folder must already exist.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Folder to create")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Folder",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: true
            )
            let existed = FileManager.default.fileExists(atPath: url.path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            log.info("Created folder \(url.lastPathComponent, privacy: .public)")
            return Value.object([
                "path": .string(url.path),
                "created": .bool(!existed),
            ])
        }

        Tool(
            name: "filesystem_move",
            description:
                "Move or rename a file or folder. Both the source and the destination must sit inside shared folders that allow writing.",
            inputSchema: .object(
                properties: [
                    "from": .string(description: "File or folder to move"),
                    "to": .string(description: "New path, including the new name"),
                ],
                required: ["from", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move File",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let from = arguments["from"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("from")
            }
            guard let to = arguments["to"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("to")
            }
            let roots = FilesystemService.shared.roots
            // The source needs write access too: a move takes the file out of
            // where it currently lives, which a read-only root does not allow.
            let source = try FilesystemAccess.resolve(
                requested: from,
                roots: roots,
                requiringWrite: true
            )
            let destination = try FilesystemAccess.resolve(
                requested: to,
                roots: roots,
                requiringWrite: true
            )
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FilesystemServiceError.destinationExists(destination.path)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            log.info("Moved \(source.lastPathComponent, privacy: .public)")
            return Value.object([
                "from": .string(source.path),
                "to": .string(destination.path),
                "moved": .bool(true),
            ])
        }

        Tool(
            name: "filesystem_copy",
            description:
                "Copy a file or folder. The source only needs to be readable; the destination must sit inside a shared folder that allows writing.",
            inputSchema: .object(
                properties: [
                    "from": .string(description: "File or folder to copy"),
                    "to": .string(description: "Path to copy it to, including the new name"),
                ],
                required: ["from", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Copy File",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let from = arguments["from"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("from")
            }
            guard let to = arguments["to"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("to")
            }
            let roots = FilesystemService.shared.roots
            let source = try FilesystemAccess.resolve(
                requested: from,
                roots: roots,
                requiringWrite: false
            )
            let destination = try FilesystemAccess.resolve(
                requested: to,
                roots: roots,
                requiringWrite: true
            )
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                throw FilesystemServiceError.destinationExists(destination.path)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            log.info("Copied \(source.lastPathComponent, privacy: .public)")
            return Value.object([
                "from": .string(source.path),
                "to": .string(destination.path),
                "copied": .bool(true),
            ])
        }

        Tool(
            name: "filesystem_trash",
            description:
                "Move a file or folder to the Trash, where the user can still recover it. Nothing here deletes anything outright.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File or folder to move to the Trash")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Trash File",
                readOnlyHint: false,
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: true
            )
            // trashItem rather than removeItem: a client acting on a model's
            // judgement should not be able to destroy a file outright, and the
            // Trash is what every cloud drive does with a delete anyway.
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            log.info("Trashed \(url.lastPathComponent, privacy: .public)")
            var result: [String: Value] = [
                "path": .string(url.path),
                "trashed": .bool(true),
            ]
            if let location = trashed as? URL {
                result["trashPath"] = .string(location.path)
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_append",
            description:
                "Add text to the end of a file inside a shared folder that allows writing, creating it if it is not there. Use this for logs and notes rather than reading a file back and rewriting it whole.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to append to"),
                    "content": .string(description: "Text to add at the end"),
                ],
                required: ["path", "content"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Append to File",
                readOnlyHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let content = arguments["content"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("content")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: true
            )
            let addition = Data(content.utf8)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: addition)
            } else {
                try addition.write(to: url, options: .atomic)
            }
            let sizeBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            log.info("Appended to \(url.lastPathComponent, privacy: .public)")
            return Value.object([
                "path": .string(url.path),
                "appendedBytes": .int(addition.count),
                "sizeBytes": .int(sizeBytes ?? addition.count),
            ])
        }

        Tool(
            name: "filesystem_read_binary",
            description:
                "Read a non-text file as base64, for files up to \(maximumInlineBinaryBytes / 1024)KB. Use filesystem_read for text, and filesystem_stat for anything larger, which stays on disk.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to read")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Binary File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
            )
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= maximumInlineBinaryBytes else {
                throw FilesystemServiceError.tooLargeToInline(
                    path: url.path,
                    sizeBytes: size,
                    limitBytes: maximumInlineBinaryBytes
                )
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumInlineBinaryBytes + 1) ?? Data()
            guard data.count <= maximumInlineBinaryBytes else {
                throw FilesystemServiceError.tooLargeToInline(
                    path: url.path,
                    sizeBytes: data.count,
                    limitBytes: maximumInlineBinaryBytes
                )
            }
            return Value.object([
                "path": .string(url.path),
                "sizeBytes": .int(data.count),
                "base64": .string(data.base64EncodedString()),
            ])
        }

        Tool(
            name: "filesystem_write_binary",
            description:
                "Write a non-text file from base64 into a shared folder that allows writing, for "
                + "payloads up to \(maximumBinaryWriteBytes / (1024 * 1024))MB. Use this for "
                + "documents, images and archives; filesystem_write is for text and would corrupt "
                + "them. Refuses to replace a file that already exists unless overwrite is true, "
                + "because a replaced file does not go to the Trash and cannot be recovered.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to write"),
                    "base64": .string(description: "File contents, base64 encoded"),
                    "overwrite": .boolean(
                        description:
                            "Replace the file if it already exists. Its previous contents are lost.",
                        default: .bool(false)
                    ),
                ],
                required: ["path", "base64"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Write Binary File",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let encoded = arguments["base64"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("base64")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: true
            )
            let existed = FileManager.default.fileExists(atPath: url.path)
            guard
                !FilesystemContent.refusesOverwrite(
                    exists: existed,
                    overwriteRequested: arguments["overwrite"]?.boolValue ?? false
                )
            else {
                throw FilesystemServiceError.refusingToOverwrite(url.path)
            }
            // Decoded before anything touches the disk, so a malformed or
            // oversized payload leaves an existing file untouched.
            let data = try FilesystemBinaryWrite.decode(
                base64: encoded,
                limitBytes: maximumBinaryWriteBytes
            )
            try data.write(to: url, options: .atomic)
            log.info("Wrote \(url.lastPathComponent, privacy: .public)")
            return Value.object([
                "path": .string(url.path),
                "replaced": .bool(existed),
                "sizeBytes": .int(data.count),
            ])
        }

        Tool(
            name: "filesystem_search_content",
            description:
                "Find files by what is inside them, not just their name, using Spotlight. Reaches inside PDFs, Pages and Word documents and anything else Spotlight indexes. "
                + "Returns a quoted snippet from each plain-text match, and says why when it cannot quote one. "
                + "Results page: pass a previous call's nextOffset to continue. Use filesystem_search when you know part of the file name instead.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Directory to search beneath"),
                    "query": .string(description: "Text the file's contents must contain"),
                    "limit": .integer(
                        description: "Maximum matches to return",
                        default: .int(defaultPageSize)
                    ),
                    "offset": .integer(
                        description: "Matches to skip; pass a previous call's nextOffset",
                        default: .int(0)
                    ),
                    "snippets": .boolean(
                        description:
                            "Quote the matching lines from each plain-text file. Turn off for a faster, name-only answer.",
                        default: .bool(true)
                    ),
                    "snippetsPerFile": .integer(
                        description:
                            "Matching lines to quote from each file, up to \(FilesystemContentSearch.maximumSnippetsPerFile)",
                        default: .int(FilesystemContentSearch.defaultSnippetsPerFile)
                    ),
                ],
                required: ["path", "query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search File Contents",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                throw FilesystemServiceError.missingArgument("query")
            }
            let roots = FilesystemService.shared.roots
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: roots,
                requiringWrite: false
            )
            let limit = clampedPageSize(arguments["limit"]?.intValue)
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            let wantsSnippets = arguments["snippets"]?.boolValue ?? true
            let snippetsPerFile = min(
                max(1, arguments["snippetsPerFile"]?.intValue ?? FilesystemContentSearch.defaultSnippetsPerFile),
                FilesystemContentSearch.maximumSnippetsPerFile
            )
            let expression = "kMDItemTextContent == '*\(Spotlight.quoted(query))*'c"
            let hits = try Spotlight.run(arguments: ["-onlyin", url.path, expression])

            // mdfind is told where to look, but it is a separate process with
            // its own view of the disk. Re-check every hit against the
            // allowlist rather than trusting -onlyin to be the access control.
            var permitted: [URL] = []
            for hit in hits {
                guard
                    let resolved = try? FilesystemAccess.resolve(
                        requested: hit,
                        roots: roots,
                        requiringWrite: false
                    )
                else { continue }
                permitted.append(resolved)
            }
            // Spotlight's order is not stable between calls, so paging over it
            // raw would repeat and skip files. Sorting gives the offsets
            // something that means the same thing on the next call.
            permitted.sort { $0.path < $1.path }
            let page = Array(permitted.dropFirst(offset).prefix(limit))

            let matches: [Value] = page.map { hit in
                guard case .object(var described) = FilesystemService.describe(hit) else {
                    return .object(["path": .string(hit.path)])
                }
                let availability = FilesystemCloudAvailability.of(hit)
                if availability != .local {
                    described["cloudAvailability"] = .string(availability.rawValue)
                }
                guard wantsSnippets else { return .object(described) }
                let outcome = FilesystemService.snippets(
                    for: hit,
                    query: query,
                    maximum: snippetsPerFile,
                    availability: availability
                )
                if let snippets = outcome.snippets, !snippets.isEmpty {
                    described["snippets"] = .array(
                        snippets.map { snippet in
                            .object([
                                "line": .int(snippet.line),
                                "text": .string(snippet.text),
                            ])
                        }
                    )
                } else if let absence = outcome.absence {
                    described["snippetUnavailable"] = .string(absence.rawValue)
                    described["snippetNote"] = .string(absence.explanation)
                }
                return .object(described)
            }

            var result: [String: Value] = [
                "path": .string(url.path),
                "query": .string(query),
                "matches": .array(matches),
                "totalMatched": .int(permitted.count),
                // Kept for callers that already branch on it, and now it means
                // what it says: there is another page, and nextOffset reaches
                // it. It used to mean "some results were dropped, good luck".
                "truncated": .bool(offset + page.count < permitted.count),
            ]
            if offset + page.count < permitted.count {
                result["nextOffset"] = .int(offset + page.count)
            }
            // An empty result has three possible causes and they have
            // different fixes, so it is worth one process spawn to say which.
            if permitted.isEmpty {
                let state = SpotlightIndexState.query(path: url.path)
                result["spotlightIndexing"] = .string(state.rawValue)
                if let explanation = state.explanation {
                    result["note"] = .string(explanation)
                } else {
                    result["note"] = .string(
                        "Spotlight is indexing this volume and found nothing containing that text. Files stored in iCloud whose contents are not on this Mac are not searchable by content."
                    )
                }
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_recent",
            description:
                "List files changed most recently beneath a shared folder, newest first. Use when someone refers to what they were just working on.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Directory to look beneath"),
                    "days": .integer(
                        description: "How far back to look, in days",
                        default: .int(7)
                    ),
                    "limit": .integer(
                        description: "Maximum files to return",
                        default: .int(defaultPageSize)
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Recent Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let roots = FilesystemService.shared.roots
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: roots,
                requiringWrite: false
            )
            let days = max(1, arguments["days"]?.intValue ?? 7)
            let limit = clampedPageSize(arguments["limit"]?.intValue)
            let seconds = try Spotlight.lookbackSeconds(days: days)
            let expression = "kMDItemContentModificationDate >= $time.now(-\(seconds))"
            let hits = try Spotlight.run(arguments: ["-onlyin", url.path, expression])

            var found: [URL] = []
            for hit in hits {
                guard
                    let resolved = try? FilesystemAccess.resolve(
                        requested: hit,
                        roots: roots,
                        requiringWrite: false
                    )
                else { continue }
                found.append(resolved)
            }
            // Spotlight returns matches unordered, so sort here rather than
            // handing back an arbitrary slice of a "most recent" list.
            let sorted = found.sorted { left, right in
                let leftDate =
                    (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let rightDate =
                    (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
            return Value.object([
                "path": .string(url.path),
                "days": .int(days),
                "entries": .array(sorted.prefix(limit).map { FilesystemService.describe($0) }),
                "totalMatched": .int(sorted.count),
            ])
        }

        Tool(
            name: "filesystem_hash",
            description:
                "Get a file's SHA-256 checksum, for confirming two files are identical or that a copy came through intact.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to hash")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Hash File",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
            )
            // Hash in chunks. A checksum tool that has to hold the file in
            // memory is useless on the large files most worth checksumming.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            var byteCount = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                digest.update(data: chunk)
                byteCount += chunk.count
            }
            let hex = digest.finalize().map { String(format: "%02x", $0) }.joined()
            return Value.object([
                "path": .string(url.path),
                "algorithm": .string("sha256"),
                "hash": .string(hex),
                "sizeBytes": .int(byteCount),
            ])
        }

        Tool(
            name: "filesystem_tags",
            description:
                "Read or replace a file's Finder tags. Pass tags to set them, or leave it out to read what is there. Setting replaces the whole list, so read first when adding one.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File or folder to read or tag"),
                    "tags": .array(
                        description:
                            "Complete replacement tag list; omit to read the current tags instead",
                        items: .string()
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "File Tags",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let requested = arguments["tags"]?.arrayValue?.compactMap(\.stringValue)
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: requested != nil
            )
            if let requested {
                try FilesystemContent.setTags(requested, on: url)
                log.info("Tagged \(url.lastPathComponent, privacy: .public)")
            }
            let current =
                (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
            return Value.object([
                "path": .string(url.path),
                "tags": .array(current.map { .string($0) }),
                "changed": .bool(requested != nil),
            ])
        }

        Tool(
            name: "filesystem_edit",
            description:
                "Change part of a text file by replacing exact text, leaving the rest of the file alone. "
                + "Pass preview: true to see what would change without touching the file. "
                + "Pass expectedHash, from filesystem_hash, to have the edit refused if the file changed since you read it.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to edit"),
                    "edits": .array(
                        description:
                            "Replacements to make, in order. Each oldText must appear exactly once unless replaceAll is true.",
                        items: .object(
                            properties: [
                                "oldText": .string(
                                    description:
                                        "Exact text to find, copied from the file including indentation"
                                ),
                                "newText": .string(description: "Text to put in its place"),
                                "replaceAll": .boolean(
                                    description: "Replace every occurrence rather than refusing repeated text",
                                    default: .bool(false)
                                ),
                            ],
                            required: ["oldText", "newText"],
                            additionalProperties: false
                        )
                    ),
                    "preview": .boolean(
                        description: "Show what would change and write nothing",
                        default: .bool(false)
                    ),
                    "expectedHash": .string(
                        description:
                            "The file's SHA-256 from filesystem_hash when you read it. The edit is refused if the file has changed since."
                    ),
                ],
                required: ["path", "edits"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Edit File",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            guard let rawEdits = arguments["edits"]?.arrayValue, !rawEdits.isEmpty else {
                throw FilesystemEditError.noEdits
            }
            let edits: [FilesystemTextEdit] = try rawEdits.map { raw in
                guard let object = raw.objectValue,
                    let oldText = object["oldText"]?.stringValue,
                    let newText = object["newText"]?.stringValue
                else {
                    throw FilesystemServiceError.missingArgument("edits[].oldText and edits[].newText")
                }
                return FilesystemTextEdit(
                    oldText: oldText,
                    newText: newText,
                    replaceAll: object["replaceAll"]?.boolValue ?? false
                )
            }
            let preview = arguments["preview"]?.boolValue ?? false
            let applied = try FilesystemEdit.perform(
                path: path,
                edits: edits,
                expectedHash: arguments["expectedHash"]?.stringValue,
                preview: preview,
                roots: FilesystemService.shared.roots
            )
            if applied.committed {
                log.info("Edited \(applied.url.lastPathComponent, privacy: .public)")
            }
            let changes: [Value] = applied.result.hunks.map { hunk in
                .object([
                    "editIndex": .int(hunk.editIndex),
                    "line": .int(hunk.line),
                    "before": .string(hunk.before),
                    "after": .string(hunk.after),
                ])
            }
            return Value.object([
                "path": .string(applied.url.path),
                "preview": .bool(preview),
                "applied": .bool(applied.committed),
                "replacements": .array(applied.result.replacements.map { .int($0) }),
                "changes": .array(changes),
                "previousHash": .string(applied.previousHash),
                "hash": .string(applied.newHash),
                "sizeBytes": .int(applied.result.content.utf8.count),
            ])
        }

        Tool(
            name: "filesystem_read_multiple",
            description:
                "Read up to \(FilesystemBatchRead.maximumPaths) text files in one call. Each file reports its own success or error, so one unreadable path does not lose the rest. "
                + "The whole call returns at most \(FilesystemBatchRead.byteBudget / 1024)KB; read anything larger with filesystem_read.",
            inputSchema: .object(
                properties: [
                    "paths": .array(
                        description: "Files to read, in the order you want them back",
                        items: .string()
                    )
                ],
                required: ["paths"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Several Files",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let raw = arguments["paths"]?.arrayValue else {
                throw FilesystemServiceError.missingArgument("paths")
            }
            let paths = raw.compactMap(\.stringValue)
            guard paths.count == raw.count else {
                throw FilesystemServiceError.missingArgument("paths")
            }
            let batch = try FilesystemBatchRead.read(
                paths: paths,
                roots: FilesystemService.shared.roots
            )
            let files: [Value] = batch.entries.map { entry in
                var described: [String: Value] = [
                    "path": .string(entry.resolvedPath ?? entry.requestedPath),
                    "requestedPath": .string(entry.requestedPath),
                    "ok": .bool(entry.ok),
                ]
                if let error = entry.error {
                    described["error"] = .string(error)
                    return .object(described)
                }
                described["isText"] = .bool(entry.isText)
                if let size = entry.sizeBytes { described["sizeBytes"] = .int(size) }
                if let content = entry.content {
                    described["content"] = .string(content)
                } else {
                    described["note"] = .string(
                        "This file is not UTF-8 text, so its contents were not read. "
                            + "Use filesystem_read_binary for small binary files."
                    )
                }
                if entry.truncated { described["truncated"] = .bool(true) }
                return .object(described)
            }
            return Value.object([
                "files": .array(files),
                "bytesReturned": .int(batch.bytesReturned),
                "budgetBytes": .int(FilesystemBatchRead.byteBudget),
                "budgetExhausted": .bool(batch.budgetExhausted),
            ])
        }

        Tool(
            name: "filesystem_disk_usage",
            description:
                "Add up how much space a shared folder and each thing in it actually occupies. Answers "
                + "\"what is filling this folder\" in one call, where filesystem_tree would take one call per "
                + "folder and still miss anything below its depth limit. Reports both the size a listing shows "
                + "and the blocks the disk gives up, which differ for compressed, sparse and cloned files. "
                + "Symbolic links are counted, never followed.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Folder to measure"),
                    "maxChildren": .integer(
                        description:
                            "How many of the folder's own items to list, largest first, up to \(FilesystemDiskUsage.maximumMaxChildren). The totals always cover everything.",
                        default: .int(FilesystemDiskUsage.defaultMaxChildren),
                        minimum: 1,
                        maximum: FilesystemDiskUsage.maximumMaxChildren
                    ),
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Measure Folder Size",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemContent.resolveExisting(
                requested: path,
                roots: FilesystemService.shared.roots
            )
            let usage = try FilesystemDiskUsage.measure(
                root: url,
                roots: FilesystemService.shared.roots,
                maxChildren: FilesystemDiskUsage.clampedChildren(arguments["maxChildren"]?.intValue)
            )

            let children: [Value] = usage.children.map { child in
                var entry: [String: Value] = [
                    "name": .string(child.name),
                    "path": .string(child.path),
                    "isDirectory": .bool(child.isDirectory),
                    "sizeBytes": .int(Int(child.logicalBytes)),
                    "size": .string(SystemResourceFormatting.describeBytes(max(0, child.logicalBytes))),
                    "allocatedBytes": .int(Int(child.allocatedBytes)),
                    "allocated": .string(
                        SystemResourceFormatting.describeBytes(max(0, child.allocatedBytes))
                    ),
                    "fileCount": .int(child.fileCount),
                ]
                if child.isDirectory { entry["folderCount"] = .int(child.directoryCount) }
                return .object(entry)
            }

            var response: [String: Value] = [
                "path": .string(usage.root),
                "sizeBytes": .int(Int(usage.logicalBytes)),
                "size": .string(SystemResourceFormatting.describeBytes(max(0, usage.logicalBytes))),
                "allocatedBytes": .int(Int(usage.allocatedBytes)),
                "allocated": .string(
                    SystemResourceFormatting.describeBytes(max(0, usage.allocatedBytes))
                ),
                "fileCount": .int(usage.fileCount),
                "folderCount": .int(usage.directoryCount),
                "children": .array(children),
                "childCount": .int(usage.childCount),
            ]
            if usage.symbolicLinkCount > 0 {
                response["symbolicLinkCount"] = .int(usage.symbolicLinkCount)
            }
            if usage.deniedCount > 0 {
                response["outsideSharedFoldersCount"] = .int(usage.deniedCount)
                response["outsideSharedFoldersNote"] = .string(
                    "\(usage.deniedCount) item\(usage.deniedCount == 1 ? "" : "s") resolved outside the folders shared with Apple Core and were not measured."
                )
            }
            if usage.unreadableCount > 0 {
                response["unreadableFolderCount"] = .int(usage.unreadableCount)
                response["unreadableNote"] = .string(
                    "\(usage.unreadableCount) folder\(usage.unreadableCount == 1 ? " was" : "s were") not readable, so the totals are short by whatever is inside them."
                )
            }
            if usage.exhaustedScanBudget {
                response["complete"] = .bool(false)
                response["note"] = .string(
                    "The walk stopped after \(FilesystemDiskUsage.scanBudget) items, so these totals are a floor rather than the answer. Measure a subfolder for a complete number."
                )
            } else {
                response["complete"] = .bool(true)
            }
            return Value.object(response)
        }

        Tool(
            name: "filesystem_metadata",
            description:
                "Read what macOS knows about one file beyond its size and dates: what type it really is rather "
                + "than what its extension claims, whether an iCloud file's contents are actually on this Mac, "
                + "which application downloaded it and from where, and the Spotlight attributes that describe "
                + "the content itself, such as page count, pixel dimensions and duration. Reads metadata only, "
                + "never the file's contents.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File or folder to describe")
                ],
                required: ["path"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "File Metadata",
                readOnlyHint: true,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw FilesystemServiceError.missingArgument("path")
            }
            let url = try FilesystemContent.resolveExisting(
                requested: path,
                roots: FilesystemService.shared.roots
            )
            return FilesystemService.metadata(for: url)
        }
    }
    /// Reads one hit far enough to quote from it.
    ///
    /// Spotlight matched an index, which knows about content this process
    /// cannot cheaply re-read: PDF text layers, Pages documents, mail. Rather
    /// than drop those hits or pretend to quote them, every file that cannot
    /// be quoted comes back with the reason, so a caller can tell "no snippet"
    /// from "no match".
    static func snippets(
        for url: URL,
        query: String,
        maximum: Int,
        availability: FilesystemCloudAvailability
    ) -> (snippets: [FilesystemSnippet]?, absence: FilesystemSnippetAbsence?) {
        guard availability.isReadable else { return (nil, .contentNotDownloaded) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FilesystemContentSearch.maximumSnippetFileBytes else {
            return (nil, .tooLarge)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (nil, .unreadable) }
        defer { try? handle.close() }
        guard
            let data = try? handle.read(
                upToCount: FilesystemContentSearch.maximumSnippetFileBytes
            ),
            let text = String(data: data, encoding: .utf8)
        else { return (nil, .notPlainText) }
        let found = FilesystemContentSearch.snippets(in: text, query: query, maximum: maximum)
        return found.isEmpty ? (nil, .noLiteralMatch) : (found, nil)
    }

    static let headArgumentDescription =
        "Return only the first this many lines, instead of bytes from the start. Cannot be combined with tail or offset."
    static let tailArgumentDescription =
        "Return only the last this many lines, read from the end of the file. Cannot be combined with head or offset."

    /// Reads the first or last lines of a file.
    ///
    /// A tail read seeks to near the end rather than reading the file: the
    /// point of asking for the last fifty lines of a log is not having to read
    /// the two gigabytes in front of them.
    static func readLines(
        at url: URL,
        head: Int?,
        tail: Int?,
        offsetRequested: Int?,
        sizeBytes: Int?
    ) throws -> Value {
        if head != nil, tail != nil {
            throw FilesystemServiceError.conflictingArguments(
                "head and tail ask for opposite ends of the file. Pass one or the other."
            )
        }
        if let offsetRequested, offsetRequested > 0 {
            throw FilesystemServiceError.conflictingArguments(
                "offset counts bytes and head and tail count lines, so they cannot be combined. Drop offset, or page with offset alone."
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = sizeBytes ?? 0

        let data: Data
        let startsMidFile: Bool
        if tail != nil {
            let start = max(0, size - FilesystemLineWindow.maximumTailBytes)
            if start > 0 { try handle.seek(toOffset: UInt64(start)) }
            startsMidFile = start > 0
            data = (try handle.readToEnd()) ?? Data()
        } else {
            startsMidFile = false
            data = (try handle.read(upToCount: maximumReadBytes)) ?? Data()
        }

        guard let text = FilesystemLineWindow.decode(data, startsMidFile: startsMidFile) else {
            return Value.object([
                "path": .string(url.path),
                "isText": .bool(false),
                "sizeBytes": .int(size),
                "note": .string(
                    "This file is not UTF-8 text, so its contents were not read. "
                        + "Use filesystem_read_binary for small binary files."
                ),
            ])
        }

        let window: FilesystemLineWindowResult
        let mode: String
        if let tail {
            window = FilesystemLineWindow.tail(text, count: tail, startsMidFile: startsMidFile)
            mode = "tail"
        } else {
            window = FilesystemLineWindow.head(
                text,
                count: head ?? 1,
                isWholeFile: data.count >= size
            )
            mode = "head"
        }

        var result: [String: Value] = [
            "path": .string(url.path),
            "isText": .bool(true),
            "sizeBytes": .int(size),
            "mode": .string(mode),
            "lineCount": .int(window.lines.count),
            "content": .string(window.lines.joined(separator: "\n")),
        ]
        if window.truncated {
            result["truncated"] = .bool(true)
            result["note"] = .string(
                mode == "tail"
                    ? "These are the last \(window.lines.count) lines. Earlier lines were not read."
                    : "These are the first \(window.lines.count) lines. Later lines were not read."
            )
        }
        return Value.object(result)
    }

    /// Everything macOS knows about one file that a `stat` call does not.
    ///
    /// Each block is omitted when the file has nothing to say, rather than
    /// reported as empty: a file with no download record and a file whose
    /// download record could not be read are different facts.
    static func metadata(for url: URL) -> Value {
        let values = try? url.resourceValues(forKeys: [
            .contentTypeKey, .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey,
            .contentModificationDateKey, .addedToDirectoryDateKey, .isDirectoryKey,
            .isSymbolicLinkKey, .isAliasFileKey, .isHiddenKey, .isPackageKey, .isWritableKey,
        ])
        let formatter = ISO8601DateFormatter()

        var response: [String: Value] = [
            "path": .string(url.path),
            "name": .string(url.lastPathComponent),
            "isDirectory": .bool(values?.isDirectory ?? false),
        ]
        if let type = values?.contentType {
            var described: [String: Value] = [
                "identifier": .string(type.identifier),
                "category": .string(FilesystemMetadata.category(for: type).rawValue),
            ]
            if let description = type.localizedDescription {
                described["description"] = .string(description)
            }
            if let mime = type.preferredMIMEType { described["mimeType"] = .string(mime) }
            response["contentType"] = .object(described)
        }
        if let size = values?.fileSize { response["sizeBytes"] = .int(size) }
        if let allocated = values?.totalFileAllocatedSize {
            response["allocatedBytes"] = .int(allocated)
        }
        if let created = values?.creationDate {
            response["created"] = .string(formatter.string(from: created))
        }
        if let modified = values?.contentModificationDate {
            response["modified"] = .string(formatter.string(from: modified))
        }
        if let added = values?.addedToDirectoryDate {
            response["addedToFolder"] = .string(formatter.string(from: added))
        }
        if values?.isSymbolicLink == true { response["isSymbolicLink"] = .bool(true) }
        if values?.isAliasFile == true { response["isAlias"] = .bool(true) }
        if values?.isHidden == true { response["isHidden"] = .bool(true) }
        if values?.isPackage == true { response["isPackage"] = .bool(true) }
        if let writable = values?.isWritable { response["isWritableOnDisk"] = .bool(writable) }

        // Whether the bytes are here, not just the name. An evicted iCloud
        // file describes exactly like a local one right up until a read.
        let availability = FilesystemCloudAvailability.of(url)
        response["cloudAvailability"] = .string(availability.rawValue)
        if availability == .notDownloaded {
            response["cloudNote"] = .string(
                "This file lives in iCloud and its contents are not on this Mac, so reading it would have to download it first."
            )
        }

        if let data = FilesystemMetadata.extendedAttribute(
            "com.apple.metadata:kMDItemWhereFroms",
            of: url.path
        ) {
            let sources = FilesystemMetadata.whereFroms(fromAttribute: data)
            if !sources.isEmpty {
                response["downloadedFrom"] = .array(sources.map { .string($0) })
            }
        }
        if let data = FilesystemMetadata.extendedAttribute("com.apple.quarantine", of: url.path),
            let record = FilesystemMetadata.quarantineRecord(
                fromAttribute: String(decoding: data, as: UTF8.self)
            )
        {
            var quarantine: [String: Value] = [:]
            if let agent = record.agentName { quarantine["downloadedBy"] = .string(agent) }
            if let timestamp = record.timestamp {
                quarantine["downloadedAt"] = .string(formatter.string(from: timestamp))
            }
            quarantine["note"] = .string(
                "macOS marked this file as coming from outside the Mac. Opening it prompts for confirmation the first time."
            )
            response["quarantine"] = .object(quarantine)
        }

        if let spotlight = Self.spotlightAttributes(for: url), !spotlight.isEmpty {
            response["spotlight"] = .object(spotlight)
        } else {
            response["spotlightNote"] = .string(
                "Spotlight has nothing indexed for this file. Its volume may have indexing switched off, or the file may be too new."
            )
        }
        return Value.object(response)
    }

    /// The handful of Spotlight attributes that describe content rather than
    /// the file: page count, dimensions, duration, the title inside the
    /// document. Read one by one so an attribute the file does not carry is
    /// absent rather than null.
    private static func spotlightAttributes(for url: URL) -> [String: Value]? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        var described: [String: Value] = [:]
        let formatter = ISO8601DateFormatter()
        for attribute in FilesystemMetadata.spotlightAttributes {
            guard let raw = MDItemCopyAttribute(item, attribute as CFString) else { continue }
            let key = FilesystemMetadata.responseKey(forSpotlightAttribute: attribute)
            switch raw {
            case let text as String where !text.isEmpty:
                described[key] = .string(text)
            case let strings as [String] where !strings.isEmpty:
                described[key] = .array(strings.map { .string($0) })
            case let date as Date:
                described[key] = .string(formatter.string(from: date))
            case let number as NSNumber:
                // A count is an integer and a duration is not; reporting a
                // page count as 12.0 reads as a measurement rather than a
                // number of pages.
                let value = number.doubleValue
                described[key] =
                    value == value.rounded() && abs(value) < 1e15
                    ? .int(Int(value)) : .double(value)
            default:
                continue
            }
        }
        return described
    }

    private static func describe(_ url: URL) -> Value {
        let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        )
        var entry: [String: Value] = [
            "name": .string(url.lastPathComponent),
            "path": .string(url.path),
            "isDirectory": .bool(values?.isDirectory ?? false),
        ]
        if let size = values?.fileSize {
            entry["sizeBytes"] = .int(size)
        }
        if let modified = values?.contentModificationDate {
            entry["modified"] = .string(ISO8601DateFormatter().string(from: modified))
        }
        return Value.object(entry)
    }
}

enum FilesystemServiceError: LocalizedError {
    case missingArgument(String)
    /// Move and copy refuse rather than overwrite. Silently replacing a file
    /// the caller did not know was there is the one mistake in this surface
    /// with no undo, since the overwritten copy never reaches the Trash.
    case destinationExists(String)
    /// Write's version of `destinationExists`. Separate so the message can
    /// name the argument that unblocks it, rather than sending the caller to
    /// move or trash a file it probably meant to update.
    case refusingToOverwrite(String)
    case tooLargeToInline(path: String, sizeBytes: Int, limitBytes: Int)
    /// Two arguments that each make sense and cannot both apply.
    case conflictingArguments(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .destinationExists(path):
            return
                "Something already exists at \(path). Move or trash it first, or choose "
                + "another name; this will not overwrite it."
        case let .refusingToOverwrite(path):
            return
                "\(path) already exists, and replacing it would discard its contents without "
                + "sending anything to the Trash. Pass overwrite: true to replace it on purpose, "
                + "use filesystem_append to add to it, or choose another name."
        case let .conflictingArguments(explanation):
            return explanation
        case let .tooLargeToInline(path, sizeBytes, limitBytes):
            return
                "\(path) is \(sizeBytes / 1024)KB, over the \(limitBytes / 1024)KB limit for "
                + "reading a file inline. Leave it on disk and use filesystem_stat, or copy it "
                + "somewhere the user can open it."
        }
    }
}
