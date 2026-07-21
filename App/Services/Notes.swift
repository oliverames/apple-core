// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("notes")

// Deliberately excluded tool surface (vs sweetrb/apple-notes-mcp):
// - get-checklist-state / sync status: not exposed by Notes' scripting
//   dictionary or its HTML bodies.
// - show-note / show-folder / show-attachment / get-selected-notes:
//   GUI-context tools; Apple Core is headless by design.
// - health-check / doctor: a cross-service doctor is planned separately
//   (DONORS §4), not per-service.
// - get-note-link: the notes:// deep-link UUID lives only in the NoteStore
//   SQLite DB (ruled out by BUILD_PLAN §3.5), and this macOS's scripting
//   dictionary has no `note link` property (verified 2026-07-21: it is
//   absent from `note.properties()` and fails to compile in AppleScript).
// - fetch-attachment (inline base64): notes_save_attachment covers the
//   need without pushing megabytes of base64 through the MCP transport.

private let defaultListLimit = 50
private let defaultSearchLimit = 20
private let maximumLimit = 200
private let maximumBatchSize = 50

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

private struct NoteAccount: Codable, Sendable {
    let id: String
    let name: String
    let isDefault: Bool
    let defaultFolderId: String?
    let defaultFolderName: String?
}

private struct NoteFolderResult: Codable, Sendable {
    let id: String
    let name: String
    let accountName: String
}

private struct NoteFolderDeleteResult: Codable, Sendable {
    let deleted: Bool
    let name: String
    let accountName: String
}

private struct NoteMarkdown: Codable, Sendable {
    let id: String
    let name: String
    let folderName: String?
    let markdown: String
}

private struct NotesStatsFolder: Codable, Sendable {
    let name: String
    let noteCount: Int
}

private struct NotesStatsAccount: Codable, Sendable {
    let name: String
    let noteCount: Int
    let folders: [NotesStatsFolder]
}

private struct NotesStats: Codable, Sendable {
    let totalNotes: Int
    let totalFolders: Int
    let accounts: [NotesStatsAccount]
    let modifiedLast24h: Int
    let modifiedLast7d: Int
    let modifiedLast30d: Int
}

private struct NoteAttachment: Codable, Sendable {
    let index: Int
    let id: String
    let name: String
    let contentIdentifier: String?
    let creationDate: String?
    let modificationDate: String?
    let isShared: Bool
}

private struct AttachmentSaveResult: Codable, Sendable {
    let saved: Bool
    let noteId: String
    let attachmentId: String
    let attachmentName: String
    let savedPath: String
}

private struct BatchItemResult: Codable, Sendable {
    let id: String
    let success: Bool
    let error: String?
}

private struct BatchResult: Codable, Sendable {
    let succeeded: Int
    let failed: Int
    let results: [BatchItemResult]
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

private let createFolderScript = """
    on run argv
        set folderName to item 1 of argv
        set accountName to item 2 of argv
        tell application "Notes"
            if accountName is "" then
                set targetAccount to default account
            else
                set targetAccount to account accountName
            end if
            tell targetAccount
                if (exists folder folderName) then
                    error "ALREADY_EXISTS: folder " & folderName & " already exists in this account"
                end if
                set newFolder to make new folder with properties {name:folderName}
                set folderId to id of newFolder
            end tell
            set acctName to name of targetAccount
        end tell
        return folderId & linefeed & folderName & linefeed & acctName
    end run
    """

private let deleteFolderScript = """
    on run argv
        set folderName to item 1 of argv
        set accountName to item 2 of argv
        tell application "Notes"
            if accountName is "" then
                set targetAccount to default account
            else
                set targetAccount to account accountName
            end if
            set acctName to name of targetAccount
            delete folder folderName of targetAccount
        end tell
        return acctName
    end run
    """

private let moveNoteScript = """
    on run argv
        set noteId to item 1 of argv
        set folderName to item 2 of argv
        set accountName to item 3 of argv
        tell application "Notes"
            if accountName is "" then
                set destFolder to first folder whose name is folderName
            else
                set destFolder to folder folderName of account accountName
            end if
            set targetNote to note id noteId
            move targetNote to destFolder
            set movedNote to note id noteId
            set noteName to name of movedNote
            set destName to name of destFolder
        end tell
        return noteId & linefeed & noteName & linefeed & destName
    end run
    """

private let listAccountsScript = """
    function run(argv) {
        const Notes = Application('Notes');
        let defaultId = null;
        try { defaultId = Notes.defaultAccount().id(); } catch (e) {}
        const rows = [];
        for (const account of Notes.accounts()) {
            let folderId = null;
            let folderName = null;
            try {
                const folder = account.defaultFolder();
                folderId = folder.id();
                folderName = folder.name();
            } catch (e) {}
            const id = account.id();
            rows.push({
                id: id,
                name: account.name(),
                isDefault: id === defaultId,
                defaultFolderId: folderId,
                defaultFolderName: folderName,
            });
        }
        return JSON.stringify(rows);
    }
    """

private let statsScript = """
    function run(argv) {
        const Notes = Application('Notes');
        const accounts = [];
        let totalNotes = 0;
        let totalFolders = 0;
        for (const account of Notes.accounts()) {
            const folders = [];
            let accountNotes = 0;
            for (const folder of account.folders()) {
                const count = folder.notes.length;
                folders.push({ name: folder.name(), noteCount: count });
                accountNotes += count;
                totalFolders += 1;
            }
            accounts.push({
                name: account.name(),
                noteCount: accountNotes,
                folders: folders,
            });
            totalNotes += accountNotes;
        }
        const now = Date.now();
        const countSince = (days) => {
            const cutoff = new Date(now - days * 24 * 60 * 60 * 1000);
            try {
                return Notes.notes.whose({
                    modificationDate: { _greaterThan: cutoff },
                })().length;
            } catch (e) {
                return 0;
            }
        };
        return JSON.stringify({
            totalNotes: totalNotes,
            totalFolders: totalFolders,
            accounts: accounts,
            modifiedLast24h: countSince(1),
            modifiedLast7d: countSince(7),
            modifiedLast30d: countSince(30),
        });
    }
    """

private let exportNotesScript = """
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
                folderName: folderName === '' ? null : folderName,
                creationDate: created[i] ? created[i].toISOString() : null,
                modificationDate: modified[i] ? modified[i].toISOString() : null,
                isLocked: locked[i] === true,
            });
        }
        rows.sort((a, b) =>
            (b.modificationDate || '').localeCompare(a.modificationDate || '')
        );
        const page = rows.slice(0, limit);
        const seen = {};
        const result = [];
        for (const row of page) {
            if (seen[row.id]) continue;
            seen[row.id] = true;
            const note = collection[row.index];
            if (folderName === '') {
                try { row.folderName = note.container().name(); } catch (e) {}
            }
            row.bodyHTML = row.isLocked ? '' : (note.body() || '');
            row.bodyText = row.isLocked ? '' : (note.plaintext() || '');
            delete row.index;
            result.push(row);
        }
        return JSON.stringify(result);
    }
    """

private let listAttachmentsScript = """
    function run(argv) {
        const noteId = argv[0];
        const Notes = Application('Notes');
        const note = Notes.notes.byId(noteId);

        let attachments;
        try { attachments = note.attachments(); } catch (e) {
            throw new Error('NOT_FOUND: no note with id ' + noteId);
        }

        const rows = [];
        for (let i = 0; i < attachments.length; i++) {
            const attachment = attachments[i];
            let contentIdentifier = null;
            try { contentIdentifier = attachment.contentIdentifier(); } catch (e) {}
            rows.push({
                index: i,
                id: attachment.id(),
                name: attachment.name() || '',
                contentIdentifier: contentIdentifier,
                creationDate: attachment.creationDate()
                    ? attachment.creationDate().toISOString() : null,
                modificationDate: attachment.modificationDate()
                    ? attachment.modificationDate().toISOString() : null,
                isShared: attachment.shared() === true,
            });
        }
        return JSON.stringify(rows);
    }
    """

private let saveAttachmentScript = """
    on run argv
        set noteId to item 1 of argv
        set attachmentId to item 2 of argv
        set savePath to item 3 of argv
        tell application "Notes"
            set targetNote to note id noteId
            repeat with anAttachment in attachments of targetNote
                if (id of anAttachment as text) is attachmentId then
                    save anAttachment in (POSIX file savePath)
                    return "saved"
                end if
            end repeat
        end tell
        error "NOT_FOUND: no attachment with id " & attachmentId
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

        Tool(
            name: "notes_get_markdown",
            description:
                "Get a single note's body converted to Markdown (headings, bold/italic, lists, links, code). Checklist checked-state is not exposed by Notes' HTML, so checklist items render as plain list items.",
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
                title: "Get Note as Markdown",
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
            return NoteMarkdown(
                id: content.id,
                name: content.name,
                folderName: content.folderName,
                markdown: NotesHTMLMarkdown.convert(content.bodyHTML)
            )
        }

        Tool(
            name: "notes_move",
            description:
                "Move a note to a different folder using Notes' native move, preserving the note's id, dates, and attachments. If multiple accounts have a folder with the same name, pass account to disambiguate.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    ),
                    "folder": .string(
                        description: "Destination folder name (must already exist)"
                    ),
                    "account": .string(
                        description:
                            "Account containing the destination folder (e.g. iCloud); first matching folder in any account if omitted"
                    ),
                ],
                required: ["id", "folder"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move Note",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            let folder = try Self.requiredString("folder", from: arguments)
            let account = arguments["account"]?.stringValue ?? ""
            let output = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: moveNoteScript,
                arguments: [id, folder, account]
            )
            return try Self.parseWriteResult(output)
        }

        Tool(
            name: "notes_create_folder",
            description:
                "Create a new folder in Apple Notes. Fails if a folder with that name already exists in the target account.",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name for the new folder"
                    ),
                    "account": .string(
                        description:
                            "Account to create the folder in (e.g. iCloud); the default account if omitted"
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Note Folder",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.requiredString("name", from: arguments)
            let account = arguments["account"]?.stringValue ?? ""
            let output = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: createFolderScript,
                arguments: [name, account]
            )
            let lines = output.components(separatedBy: "\n")
            guard lines.count >= 3, !lines[0].isEmpty else {
                throw NSError(
                    domain: "NotesError",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected script output: \(output)"]
                )
            }
            return NoteFolderResult(id: lines[0], name: lines[1], accountName: lines[2])
        }

        Tool(
            name: "notes_delete_folder",
            description:
                "Delete a folder from Apple Notes (moves its notes to Recently Deleted along with it)",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Name of the folder to delete"
                    ),
                    "account": .string(
                        description:
                            "Account containing the folder (e.g. iCloud); the default account if omitted"
                    ),
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Note Folder",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.requiredString("name", from: arguments)
            let account = arguments["account"]?.stringValue ?? ""
            let accountName = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: deleteFolderScript,
                arguments: [name, account]
            )
            log.notice("Deleted folder \(name, privacy: .private)")
            return NoteFolderDeleteResult(deleted: true, name: name, accountName: accountName)
        }

        Tool(
            name: "notes_list_accounts",
            description:
                "List Apple Notes accounts (iCloud, On My Mac, Gmail, ...), including each account's default folder and which account is the default for new notes",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Note Accounts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listAccountsScript,
                as: [NoteAccount].self
            )
        }

        Tool(
            name: "notes_stats",
            description:
                "Get note counts per account and folder, plus how many notes were modified in the last 24 hours, 7 days, and 30 days",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Notes Statistics",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: statsScript,
                as: NotesStats.self,
                timeout: 120
            )
        }

        Tool(
            name: "notes_export",
            description:
                "Batch-read notes (newest first by modification date) with full HTML and plain-text bodies, optionally scoped to a folder. Locked notes are included with empty bodies.",
            inputSchema: .object(
                properties: [
                    "folder": .string(
                        description: "Folder name to export from; all folders if omitted"
                    ),
                    "limit": .integer(
                        description: "Maximum notes to return",
                        default: .int(defaultSearchLimit)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Export Notes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let folder = arguments["folder"]?.stringValue ?? ""
            let limit = Self.clampedLimit(arguments["limit"]?.intValue, default: defaultSearchLimit)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: exportNotesScript,
                arguments: [folder, String(limit)],
                as: [NoteContent].self,
                timeout: 180
            )
        }

        Tool(
            name: "notes_list_attachments",
            description:
                "List a note's attachments (name, id, index, dates). Use the returned id or index with notes_save_attachment.",
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
                title: "List Note Attachments",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listAttachmentsScript,
                arguments: [id],
                as: [NoteAttachment].self
            )
        }

        Tool(
            name: "notes_save_attachment",
            description:
                "Save one of a note's attachments to disk. Identify the attachment by id, name, or index from notes_list_attachments. Never overwrites: an existing file gets a numbered suffix.",
            inputSchema: .object(
                properties: [
                    "id": .string(
                        description: "Note id (from notes_list or notes_search)"
                    ),
                    "attachment": .string(
                        description:
                            "Attachment id, exact name, or numeric index (from notes_list_attachments)"
                    ),
                    "directory": .string(
                        description:
                            "Existing destination directory inside the user's home; ~/Downloads if omitted"
                    ),
                ],
                required: ["id", "attachment"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Save Note Attachment",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let id = try Self.requiredString("id", from: arguments)
            let selector = try Self.requiredString("attachment", from: arguments)
            let attachments = try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listAttachmentsScript,
                arguments: [id],
                as: [NoteAttachment].self
            )
            guard let attachment = Self.selectAttachment(selector, from: attachments) else {
                throw NSError(
                    domain: "NotesError",
                    code: 4,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "NOT_FOUND: no attachment matching \"\(selector)\" (note has \(attachments.count))"
                    ]
                )
            }
            let directory = try AttachmentSaveDirectory.resolve(arguments["directory"]?.stringValue)
            let path = Self.unusedPath(
                in: directory,
                filename: Self.sanitizedFilename(attachment.name)
            )
            _ = try await AppleScriptRunner.shared.run(
                .appleScript,
                script: saveAttachmentScript,
                arguments: [id, attachment.id, path.path],
                timeout: 120
            )
            log.notice("Saved attachment \(attachment.id, privacy: .private)")
            return AttachmentSaveResult(
                saved: true,
                noteId: id,
                attachmentId: attachment.id,
                attachmentName: attachment.name,
                savedPath: path.path
            )
        }

        Tool(
            name: "notes_batch_move",
            description:
                "Move up to \(maximumBatchSize) notes to a folder in one call, reporting success or failure per note id. Uses Notes' native move, preserving ids, dates, and attachments.",
            inputSchema: .object(
                properties: [
                    "ids": .array(
                        description: "Note ids to move (from notes_list or notes_search)",
                        items: .string()
                    ),
                    "folder": .string(
                        description: "Destination folder name (must already exist)"
                    ),
                    "account": .string(
                        description:
                            "Account containing the destination folder (e.g. iCloud); first matching folder in any account if omitted"
                    ),
                ],
                required: ["ids", "folder"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Batch Move Notes",
                destructiveHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let ids = try Self.requiredIds(from: arguments)
            let folder = try Self.requiredString("folder", from: arguments)
            let account = arguments["account"]?.stringValue ?? ""
            return await Self.runBatch(ids: ids) { id in
                _ = try await AppleScriptRunner.shared.run(
                    .appleScript,
                    script: moveNoteScript,
                    arguments: [id, folder, account]
                )
            }
        }

        Tool(
            name: "notes_batch_delete",
            description:
                "Delete up to \(maximumBatchSize) notes in one call (each moves to Recently Deleted), reporting success or failure per note id",
            inputSchema: .object(
                properties: [
                    "ids": .array(
                        description: "Note ids to delete (from notes_list or notes_search)",
                        items: .string()
                    )
                ],
                required: ["ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Batch Delete Notes",
                destructiveHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let ids = try Self.requiredIds(from: arguments)
            let result = await Self.runBatch(ids: ids) { id in
                _ = try await AppleScriptRunner.shared.run(
                    .appleScript,
                    script: deleteNoteScript,
                    arguments: [id]
                )
            }
            log.notice("Batch-deleted \(result.succeeded) of \(ids.count) notes")
            return result
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

    /// Extracts a non-empty `ids` array capped at `maximumBatchSize`.
    private static func requiredIds(from arguments: [String: Value]) throws -> [String] {
        guard case .array(let values)? = arguments["ids"] else {
            throw NSError(
                domain: "NotesError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ids is required"]
            )
        }
        let ids = values.compactMap { $0.stringValue }.filter { !$0.isEmpty }
        guard !ids.isEmpty else {
            throw NSError(
                domain: "NotesError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "ids must contain at least one note id"]
            )
        }
        guard ids.count <= maximumBatchSize else {
            throw NSError(
                domain: "NotesError",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Too many ids (\(ids.count)); the maximum per batch is \(maximumBatchSize)"
                ]
            )
        }
        return ids
    }

    /// Runs `operation` for each id sequentially (Notes' AppleScript
    /// interface serializes anyway), collecting per-id outcomes.
    private static func runBatch(
        ids: [String],
        operation: (String) async throws -> Void
    ) async -> BatchResult {
        var results: [BatchItemResult] = []
        for id in ids {
            do {
                try await operation(id)
                results.append(BatchItemResult(id: id, success: true, error: nil))
            } catch {
                results.append(
                    BatchItemResult(id: id, success: false, error: error.localizedDescription)
                )
            }
        }
        let succeeded = results.filter(\.success).count
        return BatchResult(
            succeeded: succeeded,
            failed: results.count - succeeded,
            results: results
        )
    }

    /// Matches an attachment by id, exact name, or numeric index (from
    /// notes_list_attachments), in that order.
    private static func selectAttachment(
        _ selector: String,
        from attachments: [NoteAttachment]
    ) -> NoteAttachment? {
        if let byId = attachments.first(where: { $0.id == selector }) {
            return byId
        }
        if let byName = attachments.first(where: { $0.name == selector }) {
            return byName
        }
        if let index = Int(selector) {
            return attachments.first(where: { $0.index == index })
        }
        return nil
    }

    /// Strips path separators and control characters so an attachment name
    /// can't escape the destination directory.
    private static func sanitizedFilename(_ name: String) -> String {
        let separators = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned =
            name
            .components(separatedBy: separators)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    /// Returns a path in `directory` that does not exist yet, appending
    /// " 2", " 3", ... before the extension when needed (never overwrites).
    private static func unusedPath(in directory: URL, filename: String) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = directory.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
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

// MARK: - HTML to Markdown

/// Converts the constrained HTML that Apple Notes emits into Markdown.
///
/// Notes bodies use a small, predictable subset: one `<div>` per line,
/// `<h1>`-`<h3>` headings, `<b>`/`<i>`/`<u>`/`<strike>` inline styles,
/// `<ul>`/`<ol>` lists (nested via nested list tags), `<a href>` links,
/// `<tt>` monospace, and `<br>` for blank lines. This is a deliberately
/// small hand-rolled converter for exactly that subset; anything
/// unrecognized is dropped, keeping only its text content. Checklist
/// checked-state never appears in the HTML, so checklists come out as
/// plain list items.
enum NotesHTMLMarkdown {
    static func convert(_ html: String) -> String {
        var output = ""
        var listStack: [(ordered: Bool, index: Int)] = []
        var pendingHref: String? = nil
        var index = html.startIndex

        while index < html.endIndex {
            let character = html[index]
            if character == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let rawTag = String(html[html.index(after: index) ..< close])
                index = html.index(after: close)
                handle(
                    tag: rawTag,
                    output: &output,
                    listStack: &listStack,
                    pendingHref: &pendingHref
                )
            } else if character == "&" {
                let (decoded, next) = decodeEntity(in: html, at: index)
                output.append(decoded)
                index = next
            } else if character == "\n" {
                // Literal newlines between tags are formatting noise.
                index = html.index(after: index)
            } else {
                output.append(character)
                index = html.index(after: index)
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func handle(
        tag rawTag: String,
        output: inout String,
        listStack: inout [(ordered: Bool, index: Int)],
        pendingHref: inout String?
    ) {
        let isClosing = rawTag.hasPrefix("/")
        let body = isClosing ? String(rawTag.dropFirst()) : rawTag
        let name =
            body
            .prefix(while: { !$0.isWhitespace && $0 != "/" })
            .lowercased()

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if isClosing {
                endBlock(&output)
            } else {
                endBlock(&output)
                let level = Int(String(name.dropFirst())) ?? 1
                output.append(String(repeating: "#", count: level) + " ")
            }
        case "b", "strong":
            output.append("**")
        case "i", "em":
            output.append("*")
        case "strike", "s", "del":
            output.append("~~")
        case "tt", "code":
            output.append("`")
        case "pre":
            endBlock(&output)
            output.append(isClosing ? "```\n" : "```\n")
        case "blockquote":
            if !isClosing {
                endBlock(&output)
                output.append("> ")
            } else {
                endBlock(&output)
            }
        case "a":
            if isClosing {
                if let href = pendingHref {
                    output.append("](\(href))")
                    pendingHref = nil
                }
            } else if let href = attribute("href", in: body) {
                pendingHref = href
                output.append("[")
            }
        case "ul", "ol":
            if isClosing {
                if !listStack.isEmpty { listStack.removeLast() }
                if listStack.isEmpty { endBlock(&output) }
            } else {
                listStack.append((ordered: name == "ol", index: 0))
            }
        case "li":
            if !isClosing {
                endBlock(&output)
                let depth = max(listStack.count - 1, 0)
                output.append(String(repeating: "    ", count: depth))
                if listStack.isEmpty {
                    output.append("- ")
                } else {
                    var top = listStack.removeLast()
                    top.index += 1
                    listStack.append(top)
                    output.append(top.ordered ? "\(top.index). " : "- ")
                }
            }
        case "div", "p":
            if isClosing { endBlock(&output) }
        case "br":
            output.append("\n")
        case "img", "object":
            if !isClosing { output.append("[attachment]") }
        default:
            break
        }
    }

    /// Ends the current output line: trims trailing spaces and ensures a
    /// terminating newline.
    private static func endBlock(_ output: inout String) {
        while output.hasSuffix(" ") { output.removeLast() }
        if !output.isEmpty && !output.hasSuffix("\n") {
            output.append("\n")
        }
    }

    /// Extracts a quoted attribute value from a raw tag body.
    private static func attribute(_ attributeName: String, in tagBody: String) -> String? {
        let lowered = tagBody.lowercased()
        guard let nameRange = lowered.range(of: attributeName + "=\"") else { return nil }
        let valueStart = tagBody.index(nameRange.lowerBound, offsetBy: attributeName.count + 2)
        guard let valueEnd = tagBody[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(tagBody[valueStart ..< valueEnd])
    }

    /// Decodes the entity starting at `index`; returns the decoded text and
    /// the index to resume from. Unknown entities pass through literally.
    private static func decodeEntity(
        in html: String,
        at index: String.Index
    ) -> (String, String.Index) {
        guard let semicolon = html[index...].firstIndex(of: ";"),
            html.distance(from: index, to: semicolon) <= 10
        else {
            return ("&", html.index(after: index))
        }
        let entity = String(html[html.index(after: index) ..< semicolon])
        let next = html.index(after: semicolon)
        switch entity {
        case "amp": return ("&", next)
        case "lt": return ("<", next)
        case "gt": return (">", next)
        case "quot": return ("\"", next)
        case "apos": return ("'", next)
        case "nbsp": return (" ", next)
        default:
            if entity.hasPrefix("#"),
                let code = UInt32(entity.dropFirst()),
                let scalar = Unicode.Scalar(code)
            {
                return (String(Character(scalar)), next)
            }
            return ("&", html.index(after: index))
        }
    }
}
