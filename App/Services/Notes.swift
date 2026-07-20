// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("notes")

private let defaultListLimit = 50
private let defaultSearchLimit = 20
private let maximumLimit = 200

// MARK: - Output models

private struct NoteFolder: Codable, Sendable {
    let id: String
    let name: String
    let accountName: String
    let noteCount: Int
}

private struct NoteSummary: Codable, Sendable {
    let id: String
    let name: String
    let folderName: String?
    let creationDate: String?
    let modificationDate: String?
    let isLocked: Bool
}

private struct NoteContent: Codable, Sendable {
    let id: String
    let name: String
    let folderName: String?
    let creationDate: String?
    let modificationDate: String?
    let isLocked: Bool
    let bodyHTML: String
    let bodyText: String
}

private struct NoteDetail: Codable, Sendable {
    let id: String
    let name: String
    let folderName: String?
    let creationDate: String?
    let modificationDate: String?
    let isLocked: Bool
    let bodyHTML: String
    let bodyText: String
    let bodyHash: String
}

private struct NoteWriteResult: Codable, Sendable {
    let id: String
    let name: String
    let folderName: String?
}

private struct NoteDeleteResult: Codable, Sendable {
    let deleted: Bool
    let id: String
}

// MARK: - JXA / AppleScript sources
//
// Every script is a constant; user input travels exclusively through argv
// (`function run(argv)` / `on run argv`) so untrusted text is never
// interpolated into script source. See AppleScriptRunner.

private let listFoldersScript = """
    function run(argv) {
        const Notes = Application('Notes');
        const result = [];
        const accounts = Notes.accounts();
        for (const account of accounts) {
            const accountName = account.name();
            const folders = account.folders();
            for (const folder of folders) {
                result.push({
                    id: folder.id(),
                    name: folder.name(),
                    accountName: accountName,
                    noteCount: folder.notes.length,
                });
            }
        }
        return JSON.stringify(result);
    }
    """

private let listNotesScript = """
    function run(argv) {
        const folderName = argv[0];
        const limit = parseInt(argv[1], 10);
        const Notes = Application('Notes');

        let collection;
        if (folderName === '') {
            collection = Notes.notes;
        } else {
            const matches = Notes.folders.whose({ name: folderName })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no folder named ' + folderName);
            }
            collection = matches[0].notes;
        }

        const ids = collection.id();
        const names = collection.name();
        const modified = collection.modificationDate();
        const created = collection.creationDate();
        const locked = collection.passwordProtected();

        const rows = [];
        for (let i = 0; i < ids.length; i++) {
            rows.push({
                index: i,
                id: ids[i],
                name: names[i],
                folderName: null,
                creationDate: created[i] ? created[i].toISOString() : null,
                modificationDate: modified[i] ? modified[i].toISOString() : null,
                isLocked: locked[i] === true,
            });
        }
        rows.sort((a, b) =>
            (b.modificationDate || '').localeCompare(a.modificationDate || '')
        );
        const page = rows.slice(0, limit);
        // Containers can't be bulk-fetched; resolve them one by one, but
        // only for the returned page.
        for (const row of page) {
            if (folderName !== '') {
                row.folderName = folderName;
            } else {
                try { row.folderName = collection[row.index].container().name(); } catch (e) {}
            }
            delete row.index;
        }
        return JSON.stringify(page);
    }
    """

private let searchNotesScript = """
    function run(argv) {
        const query = argv[0];
        const folderName = argv[1];
        const scope = argv[2];
        const limit = parseInt(argv[3], 10);
        const Notes = Application('Notes');

        let collection;
        if (folderName === '') {
            collection = Notes.notes;
        } else {
            const matches = Notes.folders.whose({ name: folderName })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no folder named ' + folderName);
            }
            collection = matches[0].notes;
        }

        let predicate;
        if (scope === 'title') {
            predicate = { name: { _contains: query } };
        } else if (scope === 'body') {
            predicate = { plaintext: { _contains: query } };
        } else {
            predicate = {
                _or: [
                    { name: { _contains: query } },
                    { plaintext: { _contains: query } },
                ],
            };
        }

        const hits = collection.whose(predicate)();
        const rows = [];
        const seen = {};
        for (const note of hits) {
            if (rows.length >= limit) break;
            // The whole-store notes collection surfaces the same note once
            // per smart-folder view; dedupe by id.
            const id = note.id();
            if (seen[id]) continue;
            seen[id] = true;
            let container = null;
            try { container = note.container().name(); } catch (e) {}
            rows.push({
                id: id,
                name: note.name(),
                folderName: container,
                creationDate: note.creationDate() ? note.creationDate().toISOString() : null,
                modificationDate: note.modificationDate() ? note.modificationDate().toISOString() : null,
                isLocked: note.passwordProtected() === true,
            });
        }
        return JSON.stringify(rows);
    }
    """

private let getNoteScript = """
    function run(argv) {
        const noteId = argv[0];
        const Notes = Application('Notes');
        const note = Notes.notes.byId(noteId);

        let name;
        try { name = note.name(); } catch (e) {
            throw new Error('NOT_FOUND: no note with id ' + noteId);
        }

        const isLocked = note.passwordProtected() === true;
        let container = null;
        try { container = note.container().name(); } catch (e) {}

        return JSON.stringify({
            id: note.id(),
            name: name,
            folderName: container,
            creationDate: note.creationDate() ? note.creationDate().toISOString() : null,
            modificationDate: note.modificationDate() ? note.modificationDate().toISOString() : null,
            isLocked: isLocked,
            bodyHTML: isLocked ? '' : (note.body() || ''),
            bodyText: isLocked ? '' : (note.plaintext() || ''),
        });
    }
    """

private let createNoteScript = """
    on run argv
        set noteBody to item 1 of argv
        set folderName to item 2 of argv
        tell application "Notes"
            if folderName is "" then
                set newNote to make new note with properties {body:noteBody}
            else
                set targetFolder to first folder whose name is folderName
                set newNote to make new note at targetFolder with properties {body:noteBody}
            end if
            set noteId to id of newNote
            set noteName to name of newNote
            set noteFolder to name of container of newNote
        end tell
        return noteId & linefeed & noteName & linefeed & noteFolder
    end run
    """

private let appendNoteScript = """
    on run argv
        set noteId to item 1 of argv
        set appendedHTML to item 2 of argv
        tell application "Notes"
            set targetNote to note id noteId
            set body of targetNote to (body of targetNote) & appendedHTML
            set noteName to name of targetNote
            set noteFolder to name of container of targetNote
        end tell
        return noteId & linefeed & noteName & linefeed & noteFolder
    end run
    """

private let updateNoteScript = """
    on run argv
        set noteId to item 1 of argv
        set newBody to item 2 of argv
        tell application "Notes"
            set targetNote to note id noteId
            set body of targetNote to newBody
            set noteName to name of targetNote
            set noteFolder to name of container of targetNote
        end tell
        return noteId & linefeed & noteName & linefeed & noteFolder
    end run
    """

private let deleteNoteScript = """
    on run argv
        set noteId to item 1 of argv
        tell application "Notes"
            delete note id noteId
        end tell
        return "deleted"
    end run
    """

// MARK: - Service

/// Apple Notes access via AppleScript/JXA (there is no native Notes API).
/// Design: docs/planning/BUILD_PLAN.md §3.5.
final class NotesService: Service {
    static let shared = NotesService()

    var tools: [Tool] {
        Tool(
            name: "notes_list_folders",
            description: "List all folders in Apple Notes, across all accounts",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Folders",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listFoldersScript,
                as: [NoteFolder].self
            )
        }

        Tool(
            name: "notes_list",
            description:
                "List notes (newest first by modification date), optionally scoped to a folder",
            inputSchema: .object(
                properties: [
                    "folder": .string(
                        description: "Folder name to list from; all folders if omitted"
                    ),
                    "limit": .integer(
                        description: "Maximum notes to return",
                        default: .int(defaultListLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let folder = arguments["folder"]?.stringValue ?? ""
            let limit = Self.clampedLimit(arguments["limit"]?.intValue, default: defaultListLimit)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listNotesScript,
                arguments: [folder, String(limit)],
                as: [NoteSummary].self,
                timeout: 120
            )
        }

        Tool(
            name: "notes_search",
            description: "Search notes by title and/or body text",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description: "Text to search for"
                    ),
                    "folder": .string(
                        description: "Folder name to search in; all folders if omitted"
                    ),
                    "scope": .string(
                        description: "Which fields to match against",
                        default: "all",
                        enum: ["all", "title", "body"]
                    ),
                    "limit": .integer(
                        description: "Maximum notes to return",
                        default: .int(defaultSearchLimit)
                    ),
                ],
                required: ["query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
                throw NSError(
                    domain: "NotesError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Search query is required"]
                )
            }
            let folder = arguments["folder"]?.stringValue ?? ""
            let scope = arguments["scope"]?.stringValue ?? "all"
            let limit = Self.clampedLimit(arguments["limit"]?.intValue, default: defaultSearchLimit)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: searchNotesScript,
                arguments: [query, folder, scope, String(limit)],
                as: [NoteSummary].self,
                timeout: 120
            )
        }

        Tool(
            name: "notes_get",
            description:
                "Get a single note by id, including its plain-text and HTML body. The returned bodyHash identifies the body version for later conflict checks.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Note",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            let content = try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: getNoteScript,
                arguments: [id],
                as: NoteContent.self
            )
            return NoteDetail(
                id: content.id,
                name: content.name,
                folderName: content.folderName,
                creationDate: content.creationDate,
                modificationDate: content.modificationDate,
                isLocked: content.isLocked,
                bodyHTML: content.bodyHTML,
                bodyText: content.bodyText,
                bodyHash: Self.hash(of: content.bodyHTML)
            )
        }

        Tool(
            name: "notes_create",
            description:
                "Create a new note. Provide plain text (converted to HTML) or raw HTML for the body; the title becomes the first heading.",
            inputSchema: .object(
                properties: [
                    "title": .string(
                        description: "Note title (becomes the first line/heading)"
                    ),
                    "body": .string(
                        description: "Plain-text body; newlines are preserved"
                    ),
                    "bodyHTML": .string(
                        description: "Raw HTML body (used instead of body if provided)"
                    ),
                    "folder": .string(
                        description: "Destination folder name; account default folder if omitted"
                    ),
                ],
                required: ["title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Note",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let title = try Self.requiredString("title", from: arguments)
            let folder = arguments["folder"]?.stringValue ?? ""
            let html = Self.composeBodyHTML(
                title: title,
                bodyText: arguments["body"]?.stringValue,
                bodyHTML: arguments["bodyHTML"]?.stringValue
            )
            let output = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: createNoteScript,
                arguments: [html, folder]
            )
            return try Self.parseWriteResult(output)
        }

        Tool(
            name: "notes_append",
            description: "Append text to the end of an existing note",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    ),
                    "text": .string(
                        description: "Plain text to append; newlines are preserved"
                    ),
                    "html": .string(
                        description: "Raw HTML to append (used instead of text if provided)"
                    ),
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Append to Note",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            let appended: String
            if let html = arguments["html"]?.stringValue, !html.isEmpty {
                appended = html
            } else if let text = arguments["text"]?.stringValue, !text.isEmpty {
                appended = "<div>\(Self.escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>"))</div>"
            } else {
                throw NSError(
                    domain: "NotesError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Either text or html is required"]
                )
            }
            let output = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: appendNoteScript,
                arguments: [id, appended]
            )
            return try Self.parseWriteResult(output)
        }

        Tool(
            name: "notes_update",
            description:
                "Replace a note's entire body. WARNING: last-writer-wins; attachments embedded in the old body may be lost. Read the note first with notes_get.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    ),
                    "title": .string(
                        description: "New title (becomes the first heading)"
                    ),
                    "body": .string(
                        description: "Plain-text body; newlines are preserved"
                    ),
                    "bodyHTML": .string(
                        description: "Raw HTML body (used instead of body if provided)"
                    ),
                ],
                required: ["id", "title"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Update Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            // TODO(BUILD_PLAN §3.5, v2.0): optimistic concurrency via
            // expected_hash — read current body, compare SHA-256 against a
            // caller-supplied hash, and fail with notes_update_conflict on
            // mismatch. v1 is last-writer-wins like every other AppleScript
            // Notes tool; notes_get already returns bodyHash so the plumbing
            // is ready.
            let id = try Self.requiredString("id", from: arguments)
            let title = try Self.requiredString("title", from: arguments)
            let html = Self.composeBodyHTML(
                title: title,
                bodyText: arguments["body"]?.stringValue,
                bodyHTML: arguments["bodyHTML"]?.stringValue
            )
            let output = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: updateNoteScript,
                arguments: [id, html]
            )
            return try Self.parseWriteResult(output)
        }

        Tool(
            name: "notes_delete",
            description: "Delete a note (moves it to Recently Deleted)",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    )
                ],
                required: ["id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Note",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            _ = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: deleteNoteScript,
                arguments: [id]
            )
            log.notice("Deleted note \(id, privacy: .private)")
            return NoteDeleteResult(deleted: true, id: id)
        }
    }

    // MARK: - Helpers

    private static func requiredString(
        _ key: String,
        from arguments: [String: Value]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw NSError(
                domain: "NotesError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(key) is required"]
            )
        }
        return value
    }

    private static func clampedLimit(_ requested: Int?, default defaultValue: Int) -> Int {
        min(max(requested ?? defaultValue, 1), maximumLimit)
    }

    /// Notes treats the first heading/line as the title, so the composer
    /// always emits `<h1>{title}</h1>` followed by the body content.
    /// Plain text is HTML-escaped with newlines mapped to line breaks.
    private static func composeBodyHTML(
        title: String,
        bodyText: String?,
        bodyHTML: String?
    ) -> String {
        var html = "<h1>\(escapeHTML(title))</h1>"
        if let bodyHTML, !bodyHTML.isEmpty {
            html += bodyHTML
        } else if let bodyText, !bodyText.isEmpty {
            html += "<div>\(escapeHTML(bodyText).replacingOccurrences(of: "\n", with: "<br>"))</div>"
        }
        return html
    }

    private static func escapeHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func hash(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Write scripts return `id\nname\nfolderName` on stdout.
    private static func parseWriteResult(_ output: String) throws -> NoteWriteResult {
        let lines = output.components(separatedBy: "\n")
        guard let id = lines.first, !id.isEmpty else {
            throw NSError(
                domain: "NotesError",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected script output: \(output)"]
            )
        }
        return NoteWriteResult(
            id: id,
            name: lines.count > 1 ? lines[1] : "",
            folderName: lines.count > 2 ? lines[2] : nil
        )
    }
}
