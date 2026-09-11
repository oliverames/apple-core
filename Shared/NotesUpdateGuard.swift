// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// Optimistic concurrency and attachment safety for Notes' non-transactional
/// scripting interface.
///
/// Two hazards share this file because they share a script. Notes exposes no
/// atomic compare-and-swap, so the script rechecks the captured body to narrow
/// the read/write race. And `set body of note` replaces the rendered document,
/// which silently drops embedded images, tables and other attachments, so the
/// same script counts attachments immediately before it writes and refuses
/// rather than attempting a rewrite it cannot do losslessly.
///
/// Both checks live inside the script, one Apple Event away from the write,
/// because a check made from Swift would open the very window it is meant to
/// close.
enum NotesUpdateGuard {
    /// Refusal prefixes. Tests and clients match on these, so they are
    /// declared once and interpolated into the scripts below.
    static let conflictPrefix = "notes_update_conflict:"
    static let attachmentPresentPrefix = "notes_attachment_present:"
    static let attachmentUnknownPrefix = "notes_attachment_state_unknown:"

    static let conflictMessage =
        "\(conflictPrefix) The note changed. Read it again with notes_get before writing."

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
                userInfo: [NSLocalizedDescriptionKey: conflictMessage]
            )
        }
        return body
    }

    /// What the script could establish about a note's attachments.
    ///
    /// `unknown` is a distinct answer from `none` on purpose: "this note has
    /// no attachments" and "I could not tell" lead to opposite decisions, and
    /// conflating them is how an image gets destroyed.
    enum AttachmentState: Equatable, Sendable {
        case none
        case present(Int)
        case unknown

        /// Scripts report a count, or -1 when the count could not be read.
        init(probeCount: Int) {
            switch probeCount {
            case 0: self = .none
            case ..<0: self = .unknown
            default: self = .present(probeCount)
            }
        }
    }

    /// The refusal a body rewrite deserves in this state, or nil to proceed.
    ///
    /// `allowAttachmentLoss` is the caller's explicit acceptance of the loss.
    /// It does not make the write lossless; it records that the client was
    /// told and asked for it anyway.
    static func attachmentRefusal(
        for state: AttachmentState,
        operation: String,
        allowAttachmentLoss: Bool
    ) -> String? {
        if allowAttachmentLoss { return nil }
        switch state {
        case .none:
            return nil
        case let .present(count):
            return
                "\(attachmentPresentPrefix) \(operation) rewrites the whole body and would drop "
                + "the \(count) attachment\(count == 1 ? "" : "s") on this note. Refused. Edit it "
                + "in the Notes app, or pass allow_attachment_loss: true to accept the loss."
        case .unknown:
            return
                "\(attachmentUnknownPrefix) \(operation) could not read this note's attachment "
                + "state, so it cannot tell whether a body rewrite would destroy anything. "
                + "Refused. Edit it in the Notes app, or pass allow_attachment_loss: true to "
                + "write anyway."
        }
    }

    /// Shared JXA prelude: resolves the note, enforces the attachment guard,
    /// then enforces the body snapshot. argv is
    /// `[id, payload, guarded, snapshot, allowAttachmentLoss]`.
    private static let guardPrelude = """
            const note = Application('Notes').notes.byId(argv[0]);
            const allowLoss = argv[4] === '1';
            if (!allowLoss) {
                let count = -1;
                try {
                    const found = note.attachments();
                    count = (found && typeof found.length === 'number') ? found.length : -1;
                } catch (e) {
                    count = -1;
                }
                if (count < 0) {
                    throw new Error('\(attachmentUnknownPrefix) ' + OPERATION + ' could not read this note\\'s attachment state, so it cannot tell whether a body rewrite would destroy anything. Refused. Edit it in the Notes app, or pass allow_attachment_loss: true to write anyway.');
                }
                if (count > 0) {
                    throw new Error('\(attachmentPresentPrefix) ' + OPERATION + ' rewrites the whole body and would drop the ' + count + ' attachment' + (count === 1 ? '' : 's') + ' on this note. Refused. Edit it in the Notes app, or pass allow_attachment_loss: true to accept the loss.');
                }
            }
            if (argv[2] === '1' && note.body() !== argv[3]) {
                throw new Error('\(conflictMessage)');
            }
        """

    private static let writeResult = """
            return JSON.stringify({ id: argv[0], name: note.name(), folderName: note.container().name() });
        """

    static let updateScript = """
        function run(argv) {
            const OPERATION = 'notes_update';
        \(guardPrelude)
            note.body = argv[1];
        \(writeResult)
        }
        """

    /// Append is a read-modify-write of the whole body, so it carries exactly
    /// the same two hazards as a replacement and gets the same guard. The
    /// concatenation happens inside the script, against the body the guard
    /// just inspected.
    static let appendScript = """
        function run(argv) {
            const OPERATION = 'notes_append';
        \(guardPrelude)
            note.body = note.body() + argv[1];
        \(writeResult)
        }
        """
}
