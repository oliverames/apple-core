// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Optimistic concurrency for Notes' non-transactional scripting interface.
/// The script rechecks the captured body to narrow the read/write race, but
/// Notes does not expose an atomic compare-and-swap operation.
enum NotesUpdateGuard {
    static func hash(of body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func snapshot(
        expectedHash: String?,
        readBody: () async throws -> String
    ) async throws -> String? {
        guard let expectedHash else { return nil }
        let body = try await readBody()
        guard hash(of: body) == expectedHash else {
            throw NSError(
                domain: "NotesError",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "notes_update_conflict: The note changed. Read it again with notes_get before updating."
                ]
            )
        }
        return body
    }

    static let updateScript = """
        function run(argv) {
            const note = Application('Notes').notes.byId(argv[0]);
            if (argv[2] === '1' && note.body() !== argv[3]) {
                throw new Error('notes_update_conflict: The note changed. Read it again with notes_get before updating.');
            }
            note.body = argv[1];
            return JSON.stringify({ id: argv[0], name: note.name(), folderName: note.container().name() });
        }
        """
}
