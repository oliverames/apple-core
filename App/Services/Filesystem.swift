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
                    "path": .string(description: "Directory to list")
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
            let entries = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            )
            return Value.object([
                "path": .string(url.path),
                "entries": .array(entries.map { FilesystemService.describe($0) }),
            ])
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

            var matches: [Value] = []
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            while let entry = enumerator?.nextObject() as? URL, matches.count < 200 {
                if entry.lastPathComponent.localizedCaseInsensitiveContains(query) {
                    matches.append(FilesystemService.describe(entry))
                }
            }
            return Value.object([
                "path": .string(url.path),
                "query": .string(query),
                "matches": .array(matches),
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

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing required argument: \(name)"
        }
    }
}
