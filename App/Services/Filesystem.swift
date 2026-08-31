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

import CryptoKit
import Foundation
import JSONSchema
import OSLog

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

final class FilesystemService: Service {
    static let shared = FilesystemService()

    /// Read fresh each call rather than cached: the user can share or unshare a
    /// folder while a client is connected, and the next call must respect it.
    private var roots: [FilesystemRoot] {
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
            name: "filesystem_read",
            description:
                "Read a text file inside a shared folder. Binary files are not returned; their metadata is. Large files come back capped, with nextOffset for reading on from there.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to read"),
                    "offset": .integer(
                        description:
                            "Byte to start reading from; pass a previous call's nextOffset",
                        default: .int(0)
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
            let ceiling = offset + limit
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
            let url = try FilesystemAccess.resolve(
                requested: path,
                roots: FilesystemService.shared.roots,
                requiringWrite: false
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
            name: "filesystem_search_content",
            description:
                "Find files by what is inside them, not just their name, using Spotlight. Reaches inside PDFs, Pages and Word documents and anything else Spotlight indexes. Use filesystem_search when you know part of the file name instead.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "Directory to search beneath"),
                    "query": .string(description: "Text the file's contents must contain"),
                    "limit": .integer(
                        description: "Maximum matches to return",
                        default: .int(defaultPageSize)
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
            let expression = "kMDItemTextContent == '*\(Spotlight.quoted(query))*'c"
            let hits = try Spotlight.run(arguments: ["-onlyin", url.path, expression])

            // mdfind is told where to look, but it is a separate process with
            // its own view of the disk. Re-check every hit against the
            // allowlist rather than trusting -onlyin to be the access control.
            // Resolve every hit before taking the page. Comparing raw hits
            // against returned matches made `truncated` true whenever
            // Spotlight saw anything outside the shared roots, so a search
            // that had in fact returned everything the caller was allowed to
            // see told them to narrow it.
            var permitted: [Value] = []
            for hit in hits {
                guard
                    let resolved = try? FilesystemAccess.resolve(
                        requested: hit,
                        roots: roots,
                        requiringWrite: false
                    )
                else { continue }
                permitted.append(FilesystemService.describe(resolved))
            }
            let matches = Array(permitted.prefix(limit))
            return Value.object([
                "path": .string(url.path),
                "query": .string(query),
                "matches": .array(matches),
                "truncated": .bool(
                    FilesystemContent.isTruncated(permittedCount: permitted.count, limit: limit)
                ),
            ])
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
            let seconds = days * 24 * 60 * 60
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
        case let .tooLargeToInline(path, sizeBytes, limitBytes):
            return
                "\(path) is \(sizeBytes / 1024)KB, over the \(limitBytes / 1024)KB limit for "
                + "reading a file inline. Leave it on disk and use filesystem_stat, or copy it "
                + "somewhere the user can open it."
        }
    }
}
