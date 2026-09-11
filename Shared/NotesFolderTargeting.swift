// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resolves a folder name, an account name, or a folder id to exactly one
/// folder before any note operation runs.
///
/// Folder names are not unique in Notes. "Notes", "Recipes" and "Work" all
/// commonly exist in both iCloud and an On My Mac account, and the scripting
/// interface's `folders.whose({name: ...})` happily returns the first one it
/// finds. A note filed into, or read from, the wrong account is a silent
/// wrong answer, so an ambiguous name is refused here rather than resolved by
/// accident.
struct NotesFolderTarget: Codable, Sendable, Equatable {
    /// `folder` when a single folder was identified, `account` when only an
    /// account was named and the whole account is the scope.
    let scope: String
    let id: String
    let name: String
    let accountName: String

    var isFolderScoped: Bool { scope == "folder" }
}

enum NotesFolderTargeting {
    static let ambiguousFolderPrefix = "AMBIGUOUS_FOLDER:"
    static let ambiguousAccountPrefix = "AMBIGUOUS_ACCOUNT:"
    static let notFoundPrefix = "NOT_FOUND:"

    /// Whether the caller asked for any targeting at all. All three empty
    /// means "every note, every account", which needs no resolution and no
    /// extra Apple Event.
    static func needsResolution(folder: String, account: String, folderId: String) -> Bool {
        !(folder.isEmpty && account.isEmpty && folderId.isEmpty)
    }

    /// argv is `[folderName, accountName, folderId]`, each possibly empty.
    static let resolveScript = """
        function run(argv) {
            const wantedName = argv[0];
            const wantedAccount = argv[1];
            const wantedId = argv[2];
            const Notes = Application('Notes');
            const accounts = Notes.accounts();
            const allNames = [];
            for (const a of accounts) { allNames.push(a.name()); }

            let scoped = accounts;
            if (wantedAccount !== '') {
                const named = [];
                for (const a of accounts) { if (a.name() === wantedAccount) { named.push(a); } }
                if (named.length === 0) {
                    throw new Error('\(notFoundPrefix) no Notes account named "' + wantedAccount + '". Accounts on this Mac: ' + allNames.join(', ') + '.');
                }
                if (named.length > 1) {
                    throw new Error('\(ambiguousAccountPrefix) "' + wantedAccount + '" names ' + named.length + ' accounts on this Mac. Use notes_list_accounts and pass folder_id instead.');
                }
                scoped = named;
            }

            if (wantedName === '' && wantedId === '') {
                return JSON.stringify({ scope: 'account', id: '', name: '', accountName: scoped[0].name() });
            }

            const matches = [];
            for (const account of scoped) {
                const accountName = account.name();
                for (const folder of account.folders()) {
                    const id = folder.id();
                    const name = folder.name();
                    if (wantedId !== '') {
                        if (id === wantedId) { matches.push({ scope: 'folder', id: id, name: name, accountName: accountName }); }
                    } else if (name === wantedName) {
                        matches.push({ scope: 'folder', id: id, name: name, accountName: accountName });
                    }
                }
            }

            if (matches.length === 0) {
                const what = wantedId !== '' ? 'with id ' + wantedId : 'named "' + wantedName + '"';
                const where = wantedAccount !== '' ? ' in account "' + wantedAccount + '"' : '';
                throw new Error('\(notFoundPrefix) no folder ' + what + where + '.');
            }
            if (matches.length > 1) {
                const where = [];
                for (const m of matches) { where.push(m.accountName); }
                throw new Error('\(ambiguousFolderPrefix) "' + wantedName + '" exists in ' + matches.length + ' accounts (' + where.join(', ') + '). Pass account to pick one, or folder_id from notes_list_folders.');
            }
            return JSON.stringify(matches[0]);
        }
        """
}
