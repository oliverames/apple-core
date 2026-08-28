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
            let entries = sortedByName(
                try FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [
                        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    ]
                )
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
                "Read a text file inside a shared folder. Binary files are not returned; their metadata is.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to read")
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
            // Read only the cap, not the file: Data(contentsOf:) loaded a
            // multi-gigabyte file whole before the old slice applied.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let data = try handle.read(upToCount: maximumReadBytes + 3) else {
                return Value.object([
                    "path": .string(url.path),
                    "isText": .bool(true),
                    "sizeBytes": .int(metadataSize ?? 0),
                    "content": .string(""),
                ])
            }
            let truncated = data.count > maximumReadBytes
            var slice = Data(data.prefix(maximumReadBytes))
            // A cap that lands mid-codepoint used to fail UTF-8 validation
            // and misreport the whole file as binary. Drop any trailing
            // partial sequence (at most 3 continuation bytes) before decode.
            if truncated {
                while let last = slice.last,
                    last & 0b1100_0000 == 0b1000_0000
                {
                    slice.removeLast()
                }
                if let last = slice.last,
                    last & 0b1110_0000 == 0b1100_0000
                        || last & 0b1111_0000 == 0b1110_0000
                        || last & 0b1111_1000 == 0b1111_0000
                {
                    slice.removeLast()
                }
            }

            guard let text = String(data: slice, encoding: .utf8) else {
                return Value.object([
                    "path": .string(url.path),
                    "isText": .bool(false),
                    "sizeBytes": .int(metadataSize ?? data.count),
                    "note": .string("This file is not UTF-8 text, so its contents were not read."),
                ])
            }
            let sizeBytes = metadataSize ?? data.count
            var result: [String: Value] = [
                "path": .string(url.path),
                "isText": .bool(true),
                "sizeBytes": .int(sizeBytes),
                "content": .string(text),
            ]
            if truncated {
                result["truncated"] = .bool(true)
                result["note"] = .string("Only the first \(maximumReadBytes) bytes are shown.")
            }
            return Value.object(result)
        }

        Tool(
            name: "filesystem_write",
            description:
                "Create or replace a text file inside a shared folder that allows writing.",
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File to write"),
                    "content": .string(description: "Text to write"),
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
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
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

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        case let .destinationExists(path):
            return
                "Something already exists at \(path). Move or trash it first, or choose "
                + "another name; this will not overwrite it."
        }
    }
}
