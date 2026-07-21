// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

private let defaultMessageLimit = 20
private let maximumMessageLimit = 100
private let maximumBatchSize = 50
private let maximumRecipients = 50
private let maximumTemplateCount = 200
private let maximumTemplateBytes = 64 * 1024

// MARK: - Output models

private struct MailAccount: Codable, Sendable {
    let name: String
    let emailAddresses: [String]
    let enabled: Bool
}

private struct MailMailbox: Codable, Sendable {
    let name: String
    let accountName: String
    let unreadCount: Int
}

private struct MailMessageSummary: Codable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let dateReceived: String?
    let isRead: Bool
}

private struct MailBatchItemResult: Codable, Sendable {
    let id: Int
    let success: Bool
    let error: String?
}

private struct MailBatchResult: Codable, Sendable {
    let requested: Int
    let succeeded: Int
    let failed: Int
    let results: [MailBatchItemResult]
}

private struct MailComposeResult: Codable, Sendable {
    let status: String
    let subject: String
    let to: [String]
}

private struct MailReplyResult: Codable, Sendable {
    let status: String
    let messageId: Int
}

private struct MailUnreadCount: Codable, Sendable {
    let account: String?
    let mailbox: String?
    let unreadCount: Int
    let mailboxesCounted: Int
}

private struct MailMailboxStats: Codable, Sendable {
    let name: String
    let messageCount: Int
    let unreadCount: Int
}

private struct MailAccountStats: Codable, Sendable {
    let name: String
    let mailboxCount: Int
    let messageCount: Int
    let unreadCount: Int
    let mailboxes: [MailMailboxStats]
}

private struct MailStats: Codable, Sendable {
    let accounts: [MailAccountStats]
    let totalMessages: Int
    let totalUnread: Int
}

private struct MailThreadResult: Codable, Sendable {
    let subjectRoot: String
    let messages: [MailMessageSummary]
}

private struct MailAttachmentInfo: Codable, Sendable {
    let index: Int
    let name: String
    let mimeType: String?
    let fileSize: Int?
    let downloaded: Bool?
}

private struct MailSaveAttachmentResult: Codable, Sendable {
    let saved: String
    let attachmentName: String
}

private struct MailMailboxMutationResult: Codable, Sendable {
    let status: String
    let account: String
    let mailbox: String
}

private struct MailTemplate: Codable, Sendable {
    let name: String
    var subject: String
    var body: String
    var createdAt: String
    var updatedAt: String
}

private struct MailTemplateSummary: Codable, Sendable {
    let name: String
    let subject: String
    let updatedAt: String
}

private struct MailTemplateListResult: Codable, Sendable {
    let templates: [MailTemplateSummary]
}

private struct MailTemplateDeleteResult: Codable, Sendable {
    let status: String
    let name: String
}

private struct MailMessageDetail: Codable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let recipients: [String]
    let ccRecipients: [String]
    let dateSent: String?
    let dateReceived: String?
    let isRead: Bool
    let mailbox: String
    let accountName: String
    let body: String
}

// MARK: - JXA sources
//
// Scripts are constants; user input travels exclusively through argv so
// untrusted text is never interpolated into script source. All property
// reads are batched where Mail's scripting interface allows, because each
// Apple Event round-trip against Mail.app is slow.

private let listAccountsScript = """
    function run(argv) {
        const Mail = Application('Mail');
        const result = Mail.accounts().map(account => ({
            name: account.name(),
            emailAddresses: account.emailAddresses() || [],
            enabled: account.enabled(),
        }));
        return JSON.stringify(result);
    }
    """

private let listMailboxesScript = """
    function run(argv) {
        const accountName = argv[0];
        const Mail = Application('Mail');
        let accounts;
        if (accountName === '') {
            accounts = Mail.accounts();
        } else {
            accounts = Mail.accounts.whose({ name: accountName })();
            if (accounts.length === 0) {
                throw new Error('NOT_FOUND: no account named ' + accountName);
            }
        }
        const result = [];
        for (const account of accounts) {
            const name = account.name();
            for (const mailbox of account.mailboxes()) {
                result.push({
                    name: mailbox.name(),
                    accountName: name,
                    unreadCount: mailbox.unreadCount(),
                });
            }
        }
        return JSON.stringify(result);
    }
    """

private let listMessagesScript = """
    function run(argv) {
        const accountName = argv[0];
        const mailboxName = argv[1];
        const limit = parseInt(argv[2], 10);
        const unreadOnly = argv[3] === 'true';
        const Mail = Application('Mail');

        const accounts = Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const mailboxes = accounts[0].mailboxes.whose({ name: mailboxName })();
        if (mailboxes.length === 0) {
            throw new Error('NOT_FOUND: no mailbox named ' + mailboxName + ' in ' + accountName);
        }

        let messages = mailboxes[0].messages;
        if (unreadOnly) {
            messages = messages.whose({ readStatus: false });
        }
        const count = Math.min(limit, messages.length);
        const rows = [];
        for (let i = 0; i < count; i++) {
            const message = messages[i];
            rows.push({
                id: message.id(),
                subject: message.subject() || '',
                sender: message.sender() || '',
                dateReceived: message.dateReceived() ? message.dateReceived().toISOString() : null,
                isRead: message.readStatus() === true,
            });
        }
        return JSON.stringify(rows);
    }
    """

private let getMessageScript = """
    function run(argv) {
        const accountName = argv[0];
        const mailboxName = argv[1];
        const messageId = parseInt(argv[2], 10);
        const Mail = Application('Mail');

        const accounts = Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const mailboxes = accounts[0].mailboxes.whose({ name: mailboxName })();
        if (mailboxes.length === 0) {
            throw new Error('NOT_FOUND: no mailbox named ' + mailboxName + ' in ' + accountName);
        }

        const matches = mailboxes[0].messages.whose({ id: messageId })();
        if (matches.length === 0) {
            throw new Error('NOT_FOUND: no message with id ' + messageId);
        }
        const message = matches[0];

        const recipients = message.toRecipients().map(r => r.address());
        const ccRecipients = message.ccRecipients().map(r => r.address());

        return JSON.stringify({
            id: message.id(),
            subject: message.subject() || '',
            sender: message.sender() || '',
            recipients: recipients,
            ccRecipients: ccRecipients,
            dateSent: message.dateSent() ? message.dateSent().toISOString() : null,
            dateReceived: message.dateReceived() ? message.dateReceived().toISOString() : null,
            isRead: message.readStatus() === true,
            mailbox: mailboxName,
            accountName: accountName,
            body: message.content() || '',
        });
    }
    """

private let searchMessagesScript = """
    function run(argv) {
        const accountName = argv[0];
        const mailboxName = argv[1];
        const scope = argv[2];
        const query = argv[3];
        const limit = parseInt(argv[4], 10);
        const Mail = Application('Mail');

        const accounts = Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const mailboxes = accounts[0].mailboxes.whose({ name: mailboxName })();
        if (mailboxes.length === 0) {
            throw new Error('NOT_FOUND: no mailbox named ' + mailboxName + ' in ' + accountName);
        }

        const predicate =
            scope === 'sender'
                ? { sender: { _contains: query } }
                : { subject: { _contains: query } };
        const matches = mailboxes[0].messages.whose(predicate)();
        const count = Math.min(limit, matches.length);
        const rows = [];
        for (let i = 0; i < count; i++) {
            const message = matches[i];
            rows.push({
                id: message.id(),
                subject: message.subject() || '',
                sender: message.sender() || '',
                dateReceived: message.dateReceived() ? message.dateReceived().toISOString() : null,
                isRead: message.readStatus() === true,
            });
        }
        return JSON.stringify(rows);
    }
    """

// Shared JXA helper source, prepended to the write scripts below.
// Resolves an account + mailbox pair or throws NOT_FOUND.
private let resolveMailboxHelper = """
    function resolveMailbox(Mail, accountName, mailboxName) {
        const accounts = Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const mailboxes = accounts[0].mailboxes.whose({ name: mailboxName })();
        if (mailboxes.length === 0) {
            throw new Error('NOT_FOUND: no mailbox named ' + mailboxName + ' in ' + accountName);
        }
        return mailboxes[0];
    }
    """

// Applies one mutation per message id, collecting per-id success/failure
// rather than aborting the whole batch on the first bad id.
private let batchMutationRunner = """
    function runBatch(mailbox, ids, mutate) {
        const results = [];
        for (const messageId of ids) {
            try {
                const matches = mailbox.messages.whose({ id: messageId })();
                if (matches.length === 0) {
                    throw new Error('no message with id ' + messageId);
                }
                mutate(matches[0]);
                results.push({ id: messageId, success: true, error: null });
            } catch (error) {
                results.push({
                    id: messageId,
                    success: false,
                    error: String(error && error.message ? error.message : error),
                });
            }
        }
        return JSON.stringify(results);
    }
    """

private let setReadScript =
    resolveMailboxHelper + "\n" + batchMutationRunner + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const ids = JSON.parse(argv[2]);
            const read = argv[3] === 'true';
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            return runBatch(mailbox, ids, message => {
                message.readStatus = read;
            });
        }
        """

private let setFlaggedScript =
    resolveMailboxHelper + "\n" + batchMutationRunner + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const ids = JSON.parse(argv[2]);
            const flagged = argv[3] === 'true';
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            return runBatch(mailbox, ids, message => {
                message.flaggedStatus = flagged;
            });
        }
        """

private let moveMessagesScript =
    resolveMailboxHelper + "\n" + batchMutationRunner + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const ids = JSON.parse(argv[2]);
            const targetAccountName = argv[3] === '' ? accountName : argv[3];
            const targetMailboxName = argv[4];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            const target = resolveMailbox(Mail, targetAccountName, targetMailboxName);
            return runBatch(mailbox, ids, message => {
                Mail.move(message, { to: target });
            });
        }
        """

private let deleteMessagesScript =
    resolveMailboxHelper + "\n" + batchMutationRunner + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const ids = JSON.parse(argv[2]);
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            return runBatch(mailbox, ids, message => {
                Mail.delete(message);
            });
        }
        """

// Compose payload travels as one JSON argv string:
// { to, cc, bcc, subject, body, account }. argv[1] selects the action.
private let composeScript = """
    function run(argv) {
        const payload = JSON.parse(argv[0]);
        const action = argv[1];
        const Mail = Application('Mail');

        const message = Mail.OutgoingMessage({
            subject: payload.subject,
            content: payload.body,
            visible: false,
        });
        if (payload.account) {
            const accounts = Mail.accounts.whose({ name: payload.account })();
            if (accounts.length === 0) {
                throw new Error('NOT_FOUND: no account named ' + payload.account);
            }
            const addresses = accounts[0].emailAddresses();
            if (addresses && addresses.length > 0) {
                message.sender = addresses[0];
            }
        }
        Mail.outgoingMessages.push(message);
        for (const address of payload.to) {
            message.toRecipients.push(Mail.Recipient({ address: address }));
        }
        for (const address of payload.cc) {
            message.ccRecipients.push(Mail.Recipient({ address: address }));
        }
        for (const address of payload.bcc) {
            message.bccRecipients.push(Mail.Recipient({ address: address }));
        }

        if (action === 'send') {
            message.send();
            return JSON.stringify({ status: 'sent', subject: payload.subject, to: payload.to });
        }
        message.save();
        return JSON.stringify({ status: 'draft_saved', subject: payload.subject, to: payload.to });
    }
    """

private let replyScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const body = argv[3];
            const replyAll = argv[4] === 'true';
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const outgoing = Mail.reply(matches[0], {
                openingWindow: false,
                replyToAll: replyAll,
            });
            try {
                outgoing.content = body + '\\n\\n' + outgoing.content();
            } catch (error) {
                outgoing.content = body;
            }
            outgoing.send();
            return JSON.stringify({ status: 'sent', messageId: messageId });
        }
        """

private let forwardScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const recipients = JSON.parse(argv[3]);
            const body = argv[4];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const outgoing = Mail.forward(matches[0], { openingWindow: false });
            for (const address of recipients) {
                outgoing.toRecipients.push(Mail.Recipient({ address: address }));
            }
            if (body !== '') {
                try {
                    outgoing.content = body + '\\n\\n' + outgoing.content();
                } catch (error) {
                    outgoing.content = body;
                }
            }
            outgoing.send();
            return JSON.stringify({ status: 'sent', messageId: messageId });
        }
        """

// Thread reconstruction is an approximation: Mail's scripting interface
// does not expose Message-ID/References headers, so the "thread" is every
// message in the same mailbox whose subject contains the anchor message's
// subject stripped of Re:/Fwd: prefixes. Unrelated messages that share a
// short subject may be included; true header-based threading arrives with
// the disk-first index (BUILD_PLAN §3.1).
private let getThreadScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const limit = parseInt(argv[3], 10);
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const subject = matches[0].subject() || '';
            const root = subject.replace(/^((re|fwd?|fw)(\\[\\d+\\])?:\\s*)+/i, '').trim();

            let related = matches;
            if (root !== '') {
                related = mailbox.messages.whose({ subject: { _contains: root } })();
            }
            const count = Math.min(limit, related.length);
            const rows = [];
            for (let i = 0; i < count; i++) {
                const message = related[i];
                rows.push({
                    id: message.id(),
                    subject: message.subject() || '',
                    sender: message.sender() || '',
                    dateReceived: message.dateReceived() ? message.dateReceived().toISOString() : null,
                    isRead: message.readStatus() === true,
                });
            }
            return JSON.stringify({ subjectRoot: root, messages: rows });
        }
        """

private let unreadCountScript = """
    function run(argv) {
        const accountName = argv[0];
        const mailboxName = argv[1];
        const Mail = Application('Mail');

        let accounts;
        if (accountName === '') {
            accounts = Mail.accounts();
        } else {
            accounts = Mail.accounts.whose({ name: accountName })();
            if (accounts.length === 0) {
                throw new Error('NOT_FOUND: no account named ' + accountName);
            }
        }

        let total = 0;
        let counted = 0;
        for (const account of accounts) {
            for (const mailbox of account.mailboxes()) {
                if (mailboxName !== '' && mailbox.name() !== mailboxName) {
                    continue;
                }
                total += mailbox.unreadCount();
                counted += 1;
            }
        }
        if (mailboxName !== '' && counted === 0) {
            throw new Error('NOT_FOUND: no mailbox named ' + mailboxName);
        }
        return JSON.stringify({
            account: accountName === '' ? null : accountName,
            mailbox: mailboxName === '' ? null : mailboxName,
            unreadCount: total,
            mailboxesCounted: counted,
        });
    }
    """

private let statsScript = """
    function run(argv) {
        const accountName = argv[0];
        const Mail = Application('Mail');

        let accounts;
        if (accountName === '') {
            accounts = Mail.accounts();
        } else {
            accounts = Mail.accounts.whose({ name: accountName })();
            if (accounts.length === 0) {
                throw new Error('NOT_FOUND: no account named ' + accountName);
            }
        }

        const rows = [];
        let totalMessages = 0;
        let totalUnread = 0;
        for (const account of accounts) {
            const mailboxes = [];
            let accountMessages = 0;
            let accountUnread = 0;
            for (const mailbox of account.mailboxes()) {
                const messageCount = mailbox.messages.length;
                const unreadCount = mailbox.unreadCount();
                mailboxes.push({
                    name: mailbox.name(),
                    messageCount: messageCount,
                    unreadCount: unreadCount,
                });
                accountMessages += messageCount;
                accountUnread += unreadCount;
            }
            rows.push({
                name: account.name(),
                mailboxCount: mailboxes.length,
                messageCount: accountMessages,
                unreadCount: accountUnread,
                mailboxes: mailboxes,
            });
            totalMessages += accountMessages;
            totalUnread += accountUnread;
        }
        return JSON.stringify({
            accounts: rows,
            totalMessages: totalMessages,
            totalUnread: totalUnread,
        });
    }
    """

private let listAttachmentsScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const attachments = matches[0].mailAttachments();
            const rows = [];
            for (let i = 0; i < attachments.length; i++) {
                const attachment = attachments[i];
                let mimeType = null;
                let fileSize = null;
                let downloaded = null;
                try { mimeType = attachment.mimeType(); } catch (error) {}
                try { fileSize = attachment.fileSize(); } catch (error) {}
                try { downloaded = attachment.downloaded(); } catch (error) {}
                rows.push({
                    index: i,
                    name: attachment.name() || '',
                    mimeType: mimeType,
                    fileSize: fileSize,
                    downloaded: downloaded,
                });
            }
            return JSON.stringify(rows);
        }
        """

// Saves one attachment (selected by list index, resolved in Swift) to a
// destination path that Swift has already validated and de-duplicated.
private let saveAttachmentScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const attachmentIndex = parseInt(argv[3], 10);
            const destinationPath = argv[4];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const attachments = matches[0].mailAttachments();
            if (attachmentIndex < 0 || attachmentIndex >= attachments.length) {
                throw new Error('NOT_FOUND: no attachment at index ' + attachmentIndex);
            }
            const attachment = attachments[attachmentIndex];
            Mail.save(attachment, { in: Path(destinationPath) });
            return JSON.stringify({
                saved: destinationPath,
                attachmentName: attachment.name() || '',
            });
        }
        """

private let createMailboxScript = """
    function run(argv) {
        const accountName = argv[0];
        const mailboxName = argv[1];
        const Mail = Application('Mail');

        const accounts = Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const existing = accounts[0].mailboxes.whose({ name: mailboxName })();
        if (existing.length > 0) {
            throw new Error('EXISTS: mailbox ' + mailboxName + ' already exists in ' + accountName);
        }
        accounts[0].mailboxes.push(Mail.Mailbox({ name: mailboxName }));
        return JSON.stringify({ status: 'created', account: accountName, mailbox: mailboxName });
    }
    """

private let renameMailboxScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const newName = argv[2];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            mailbox.name = newName;
            return JSON.stringify({ status: 'renamed', account: accountName, mailbox: newName });
        }
        """

private let deleteMailboxScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            Mail.delete(mailbox);
            return JSON.stringify({ status: 'deleted', account: accountName, mailbox: mailboxName });
        }
        """

// MARK: - Service

/// Apple Mail access — AppleScript/JXA slice.
///
/// Reads (including thread approximation, unread counts, stats, and
/// attachments), triage writes (read/flag/move/delete, batched), compose
/// (send/reply/forward/draft), mailbox CRUD, and a local template store,
/// all against Mail.app via the shared AppleScriptRunner except templates,
/// which live in a JSON file under ~/.config/apple-core (mode 0600;
/// override the directory with APPLECORE_CONFIG_HOME for tests).
///
/// Deliberately excluded:
/// - Mail rules (create/list/enable/disable/delete): Mail's rule scripting
///   surface is fragile — rule conditions are only partially scriptable,
///   silently drop qualifiers, and differ across macOS releases. A broken
///   rule mutates every future inbound message, so the risk/benefit is
///   poor; manage rules in Mail's own settings UI.
/// - Cross-mailbox and body search: deferred to the disk-first .emlx +
///   FTS5 index design in docs/planning/BUILD_PLAN.md §3.1, which this
///   file remains the scaffold for. Per-mailbox subject/sender search is
///   the AppleScript-feasible ceiling.
final class MailService: Service {
    static let shared = MailService()

    var tools: [Tool] {
        Tool(
            name: "mail_list_accounts",
            description: "List mail accounts configured in Mail.app",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mail Accounts",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listAccountsScript,
                as: [MailAccount].self
            )
        }

        Tool(
            name: "mail_list_mailboxes",
            description: "List mailboxes, optionally scoped to one account",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name; all accounts if omitted"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = arguments["account"]?.stringValue ?? ""
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listMailboxesScript,
                arguments: [account],
                as: [MailMailbox].self,
                timeout: 60
            )
        }

        Tool(
            name: "mail_list_messages",
            description:
                "List messages in a mailbox (newest first) with id, subject, sender, date, and read status",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name (from mail_list_mailboxes), e.g. INBOX"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return (max \(maximumMessageLimit))",
                        default: .int(defaultMessageLimit)
                    ),
                    "unread_only": .boolean(
                        default: false
                    ),
                ],
                required: ["account", "mailbox"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let limit = Self.clampedLimit(arguments["limit"]?.intValue)
            let unreadOnly = arguments["unread_only"]?.boolValue ?? false
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listMessagesScript,
                arguments: [account, mailbox, String(limit), unreadOnly ? "true" : "false"],
                as: [MailMessageSummary].self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_get_message",
            description:
                "Get a single message by id, including headers and plain-text body",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the message"
                    ),
                    "id": .integer(
                        description: "Message id (from mail_list_messages or mail_search)"
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Message",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            guard let id = arguments["id"]?.intValue else {
                throw NSError(
                    domain: "MailError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "id is required"]
                )
            }
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: getMessageScript,
                arguments: [account, mailbox, String(id)],
                as: MailMessageDetail.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_search",
            description: "Search messages in a mailbox by subject or sender",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name to search in"
                    ),
                    "scope": .string(
                        description: "Which field to match against",
                        default: "subject",
                        enum: ["subject", "sender"]
                    ),
                    "query": .string(
                        description: "Text to search for (substring match)"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return (max \(maximumMessageLimit))",
                        default: .int(defaultMessageLimit)
                    ),
                ],
                required: ["account", "mailbox", "query"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let query = try Self.requiredString("query", from: arguments)
            let scope = arguments["scope"]?.stringValue ?? "subject"
            let limit = Self.clampedLimit(arguments["limit"]?.intValue)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: searchMessagesScript,
                arguments: [account, mailbox, scope, query, String(limit)],
                as: [MailMessageSummary].self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_set_read",
            description:
                "Mark messages read or unread. Accepts up to \(maximumBatchSize) message ids and reports per-id success/failure",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the messages"
                    ),
                    "ids": .array(
                        description:
                            "Message ids (from mail_list_messages or mail_search); max \(maximumBatchSize)",
                        items: .integer()
                    ),
                    "read": .boolean(
                        description: "true to mark read, false to mark unread",
                        default: true
                    ),
                ],
                required: ["account", "mailbox", "ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Mark Read/Unread",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let ids = try Self.requiredIDs(from: arguments)
            let read = arguments["read"]?.boolValue ?? true
            return try await Self.runBatch(
                script: setReadScript,
                arguments: [account, mailbox, try Self.encodeJSON(ids), read ? "true" : "false"]
            )
        }

        Tool(
            name: "mail_set_flagged",
            description:
                "Flag or unflag messages. Accepts up to \(maximumBatchSize) message ids and reports per-id success/failure",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the messages"
                    ),
                    "ids": .array(
                        description:
                            "Message ids (from mail_list_messages or mail_search); max \(maximumBatchSize)",
                        items: .integer()
                    ),
                    "flagged": .boolean(
                        description: "true to flag, false to unflag",
                        default: true
                    ),
                ],
                required: ["account", "mailbox", "ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Flag/Unflag Messages",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let ids = try Self.requiredIDs(from: arguments)
            let flagged = arguments["flagged"]?.boolValue ?? true
            return try await Self.runBatch(
                script: setFlaggedScript,
                arguments: [account, mailbox, try Self.encodeJSON(ids), flagged ? "true" : "false"]
            )
        }

        Tool(
            name: "mail_move_message",
            description:
                "Move messages to another mailbox (optionally in another account). Accepts up to \(maximumBatchSize) message ids and reports per-id success/failure",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Source account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Source mailbox name containing the messages"
                    ),
                    "ids": .array(
                        description:
                            "Message ids (from mail_list_messages or mail_search); max \(maximumBatchSize)",
                        items: .integer()
                    ),
                    "to_mailbox": .string(
                        description: "Destination mailbox name"
                    ),
                    "to_account": .string(
                        description: "Destination account name; source account if omitted"
                    ),
                ],
                required: ["account", "mailbox", "ids", "to_mailbox"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Move Messages",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let ids = try Self.requiredIDs(from: arguments)
            let toMailbox = try Self.requiredString("to_mailbox", from: arguments)
            let toAccount = arguments["to_account"]?.stringValue ?? ""
            return try await Self.runBatch(
                script: moveMessagesScript,
                arguments: [account, mailbox, try Self.encodeJSON(ids), toAccount, toMailbox],
                timeout: 180
            )
        }

        Tool(
            name: "mail_delete_message",
            description:
                "Delete messages (moves them to the account's Trash). Accepts up to \(maximumBatchSize) message ids and reports per-id success/failure",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the messages"
                    ),
                    "ids": .array(
                        description:
                            "Message ids (from mail_list_messages or mail_search); max \(maximumBatchSize)",
                        items: .integer()
                    ),
                ],
                required: ["account", "mailbox", "ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Messages",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let ids = try Self.requiredIDs(from: arguments)
            return try await Self.runBatch(
                script: deleteMessagesScript,
                arguments: [account, mailbox, try Self.encodeJSON(ids)],
                timeout: 180
            )
        }

        Tool(
            name: "mail_send",
            description: "Compose and send an email via Mail.app",
            inputSchema: Self.composeSchema(requireTo: true),
            annotations: .init(
                title: "Send Email",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            try await Self.runCompose(action: "send", arguments: arguments)
        }

        Tool(
            name: "mail_create_draft",
            description:
                "Compose an email and save it to Drafts without sending",
            inputSchema: Self.composeSchema(requireTo: false),
            annotations: .init(
                title: "Create Draft",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            try await Self.runCompose(action: "draft", arguments: arguments)
        }

        Tool(
            name: "mail_reply",
            description:
                "Reply to a message and send the reply immediately. The reply body is prepended above the quoted original",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the message"
                    ),
                    "id": .integer(
                        description: "Message id (from mail_list_messages or mail_search)"
                    ),
                    "body": .string(
                        description: "Plain-text reply body"
                    ),
                    "reply_all": .boolean(
                        description: "Reply to all recipients instead of only the sender",
                        default: false
                    ),
                ],
                required: ["account", "mailbox", "id", "body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Reply to Message",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let body = try Self.requiredString("body", from: arguments)
            let replyAll = arguments["reply_all"]?.boolValue ?? false
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: replyScript,
                arguments: [account, mailbox, String(id), body, replyAll ? "true" : "false"],
                as: MailReplyResult.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_forward",
            description:
                "Forward a message to new recipients and send it immediately",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the message"
                    ),
                    "id": .integer(
                        description: "Message id (from mail_list_messages or mail_search)"
                    ),
                    "to": .array(
                        description: "Recipient email addresses; max \(maximumRecipients)",
                        items: .string()
                    ),
                    "body": .string(
                        description: "Optional note prepended above the forwarded content"
                    ),
                ],
                required: ["account", "mailbox", "id", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Forward Message",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let to = try Self.requiredAddresses("to", from: arguments)
            let body = arguments["body"]?.stringValue ?? ""
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: forwardScript,
                arguments: [account, mailbox, String(id), try Self.encodeJSON(to), body],
                as: MailReplyResult.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_get_thread",
            description:
                "Get the conversation around a message. Approximation: returns messages in the same mailbox whose subject matches the anchor's subject with Re:/Fwd: prefixes stripped (Mail's scripting interface exposes no Message-ID/References headers)",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the anchor message"
                    ),
                    "id": .integer(
                        description: "Anchor message id (from mail_list_messages or mail_search)"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return (max \(maximumMessageLimit))",
                        default: .int(defaultMessageLimit)
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Thread",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let limit = Self.clampedLimit(arguments["limit"]?.intValue)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: getThreadScript,
                arguments: [account, mailbox, String(id), String(limit)],
                as: MailThreadResult.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_get_unread_count",
            description:
                "Get the unread message count, across all accounts or scoped to one account and/or mailbox",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name; all accounts if omitted"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name; all mailboxes if omitted"
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Unread Count",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = arguments["account"]?.stringValue ?? ""
            let mailbox = arguments["mailbox"]?.stringValue ?? ""
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: unreadCountScript,
                arguments: [account, mailbox],
                as: MailUnreadCount.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_get_stats",
            description:
                "Summarize message and unread counts per mailbox and per account. Can be slow across large stores; scope to one account when possible",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name; all accounts if omitted"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Mail Stats",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = arguments["account"]?.stringValue ?? ""
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: statsScript,
                arguments: [account],
                as: MailStats.self,
                timeout: 180
            )
        }

        Tool(
            name: "mail_list_attachments",
            description:
                "List a message's attachments with index, name, MIME type, size, and download status",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the message"
                    ),
                    "id": .integer(
                        description: "Message id (from mail_list_messages or mail_search)"
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Attachments",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: listAttachmentsScript,
                arguments: [account, mailbox, String(id)],
                as: [MailAttachmentInfo].self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_save_attachment",
            description:
                "Save one attachment to disk (default ~/Downloads). Never overwrites: an existing filename gets a numeric suffix. save_dir must be an existing directory inside the user's home",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "mailbox": .string(
                        description: "Mailbox name containing the message"
                    ),
                    "id": .integer(
                        description: "Message id (from mail_list_messages or mail_search)"
                    ),
                    "attachment": .string(
                        description:
                            "Attachment name or zero-based index (from mail_list_attachments). A name matches the first attachment with that name"
                    ),
                    "save_dir": .string(
                        description:
                            "Destination directory; ~/Downloads if omitted. Must already exist and be inside the user's home directory"
                    ),
                ],
                required: ["account", "mailbox", "id", "attachment"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Save Attachment",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let selector = try Self.requiredString("attachment", from: arguments)
            let saveDir = arguments["save_dir"]?.stringValue
            return try await Self.saveAttachment(
                account: account,
                mailbox: mailbox,
                id: id,
                selector: selector,
                saveDir: saveDir
            )
        }

        Tool(
            name: "mail_create_mailbox",
            description: "Create a new mailbox in an account",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "name": .string(
                        description: "Name for the new mailbox"
                    ),
                ],
                required: ["account", "name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Create Mailbox",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let name = try Self.requiredString("name", from: arguments)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: createMailboxScript,
                arguments: [account, name],
                as: MailMailboxMutationResult.self,
                timeout: 60
            )
        }

        Tool(
            name: "mail_rename_mailbox",
            description: "Rename a mailbox",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "name": .string(
                        description: "Current mailbox name"
                    ),
                    "new_name": .string(
                        description: "New mailbox name"
                    ),
                ],
                required: ["account", "name", "new_name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Rename Mailbox",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let name = try Self.requiredString("name", from: arguments)
            let newName = try Self.requiredString("new_name", from: arguments)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: renameMailboxScript,
                arguments: [account, name, newName],
                as: MailMailboxMutationResult.self,
                timeout: 60
            )
        }

        Tool(
            name: "mail_delete_mailbox",
            description:
                "Delete a mailbox and the messages it contains",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name (from mail_list_accounts)"
                    ),
                    "name": .string(
                        description: "Mailbox name to delete"
                    ),
                ],
                required: ["account", "name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Mailbox",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let name = try Self.requiredString("name", from: arguments)
            return try await AppleScriptRunner.shared.runJSON(
                .jxa,
                script: deleteMailboxScript,
                arguments: [account, name],
                as: MailMailboxMutationResult.self,
                timeout: 60
            )
        }

        Tool(
            name: "mail_save_template",
            description:
                "Save (or overwrite) a reusable email template in the local template store (~/.config/apple-core/mail_templates.json; not stored in Mail)",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Template name (unique key)"
                    ),
                    "subject": .string(
                        description: "Template subject; may contain {{placeholders}}"
                    ),
                    "body": .string(
                        description: "Template plain-text body; may contain {{placeholders}}"
                    ),
                ],
                required: ["name", "subject", "body"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Save Template",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.requiredString("name", from: arguments)
            let subject = try Self.requiredString("subject", from: arguments)
            let body = try Self.requiredString("body", from: arguments)
            return try Self.saveTemplate(name: name, subject: subject, body: body)
        }

        Tool(
            name: "mail_list_templates",
            description: "List saved email templates from the local template store",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Templates",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            let templates = try Self.loadTemplates()
            let summaries = templates.values
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { MailTemplateSummary(name: $0.name, subject: $0.subject, updatedAt: $0.updatedAt) }
            return MailTemplateListResult(templates: summaries)
        }

        Tool(
            name: "mail_get_template",
            description: "Get one saved email template, including its body",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Template name (from mail_list_templates)"
                    )
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Template",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.requiredString("name", from: arguments)
            guard let template = try Self.loadTemplates()[name] else {
                throw Self.error("NOT_FOUND: no template named \(name)")
            }
            return template
        }

        Tool(
            name: "mail_delete_template",
            description: "Delete a saved email template from the local template store",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Template name (from mail_list_templates)"
                    )
                ],
                required: ["name"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Delete Template",
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: false,
                openWorldHint: false
            )
        ) { arguments in
            let name = try Self.requiredString("name", from: arguments)
            var templates = try Self.loadTemplates()
            guard templates.removeValue(forKey: name) != nil else {
                throw Self.error("NOT_FOUND: no template named \(name)")
            }
            try Self.storeTemplates(templates)
            return MailTemplateDeleteResult(status: "deleted", name: name)
        }

        Tool(
            name: "mail_use_template",
            description:
                "Compose an email from a saved template, substituting {{placeholder}} variables, then save it as a draft or send it",
            inputSchema: .object(
                properties: [
                    "name": .string(
                        description: "Template name (from mail_list_templates)"
                    ),
                    "to": .array(
                        description: "Recipient email addresses; max \(maximumRecipients)",
                        items: .string()
                    ),
                    "cc": .array(
                        description: "Cc email addresses",
                        items: .string()
                    ),
                    "bcc": .array(
                        description: "Bcc email addresses",
                        items: .string()
                    ),
                    "account": .string(
                        description:
                            "Account name to send from (from mail_list_accounts); Mail's default if omitted"
                    ),
                    "variables": .object(
                        description:
                            "Placeholder values: {\"key\": \"value\"} replaces every {{key}} in the subject and body",
                        additionalProperties: true
                    ),
                    "action": .string(
                        description: "Save to Drafts or send immediately",
                        default: "draft",
                        enum: ["draft", "send"]
                    ),
                ],
                required: ["name", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Use Template",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true
            )
        ) { arguments in
            try await Self.useTemplate(arguments: arguments)
        }
    }

    // MARK: - Helpers

    private static func requiredString(
        _ key: String,
        from arguments: [String: Value]
    ) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw NSError(
                domain: "MailError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(key) is required"]
            )
        }
        return value
    }

    private static func clampedLimit(_ requested: Int?) -> Int {
        min(max(requested ?? defaultMessageLimit, 1), maximumMessageLimit)
    }

    private static func requiredID(from arguments: [String: Value]) throws -> Int {
        guard let id = arguments["id"]?.intValue else {
            throw Self.error("id is required")
        }
        return id
    }

    private static func requiredIDs(from arguments: [String: Value]) throws -> [Int] {
        guard let values = arguments["ids"]?.arrayValue, !values.isEmpty else {
            throw Self.error("ids is required and must be a non-empty array")
        }
        guard values.count <= maximumBatchSize else {
            throw Self.error("ids exceeds the batch limit of \(maximumBatchSize)")
        }
        return try values.map { value in
            guard let id = value.intValue else {
                throw Self.error("ids must contain only integers")
            }
            return id
        }
    }

    private static func requiredAddresses(
        _ key: String,
        from arguments: [String: Value]
    ) throws -> [String] {
        let addresses = Self.addresses(key, from: arguments)
        guard !addresses.isEmpty else {
            throw Self.error("\(key) is required and must be a non-empty array")
        }
        return addresses
    }

    private static func addresses(
        _ key: String,
        from arguments: [String: Value]
    ) -> [String] {
        arguments[key]?.arrayValue?.compactMap { $0.stringValue } ?? []
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw Self.error("failed to encode arguments")
        }
        return string
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "MailError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Runs a batch mutation script and folds the per-id rows into a summary.
    private static func runBatch(
        script: String,
        arguments: [String],
        timeout: TimeInterval = 120
    ) async throws -> MailBatchResult {
        let results = try await AppleScriptRunner.shared.runJSON(
            .jxa,
            script: script,
            arguments: arguments,
            as: [MailBatchItemResult].self,
            timeout: timeout
        )
        let succeeded = results.count(where: { $0.success })
        return MailBatchResult(
            requested: results.count,
            succeeded: succeeded,
            failed: results.count - succeeded,
            results: results
        )
    }

    private static func composeSchema(requireTo: Bool) -> JSONSchema {
        .object(
            properties: [
                "to": .array(
                    description: "Recipient email addresses; max \(maximumRecipients)",
                    items: .string()
                ),
                "cc": .array(
                    description: "Cc email addresses",
                    items: .string()
                ),
                "bcc": .array(
                    description: "Bcc email addresses",
                    items: .string()
                ),
                "subject": .string(
                    description: "Message subject"
                ),
                "body": .string(
                    description: "Plain-text message body"
                ),
                "account": .string(
                    description:
                        "Account name to send from (from mail_list_accounts); Mail's default if omitted"
                ),
            ],
            required: requireTo ? ["to", "subject", "body"] : ["subject", "body"],
            additionalProperties: false
        )
    }

    private static func runCompose(
        action: String,
        arguments: [String: Value]
    ) async throws -> MailComposeResult {
        let to =
            action == "send"
            ? try Self.requiredAddresses("to", from: arguments)
            : Self.addresses("to", from: arguments)
        let cc = Self.addresses("cc", from: arguments)
        let bcc = Self.addresses("bcc", from: arguments)
        guard to.count + cc.count + bcc.count <= maximumRecipients else {
            throw Self.error("recipient count exceeds the limit of \(maximumRecipients)")
        }
        let subject = try Self.requiredString("subject", from: arguments)
        let body = try Self.requiredString("body", from: arguments)
        let account = arguments["account"]?.stringValue

        let payload = ComposePayload(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: account
        )
        return try await AppleScriptRunner.shared.runJSON(
            .jxa,
            script: composeScript,
            arguments: [try Self.encodeJSON(payload), action],
            as: MailComposeResult.self,
            timeout: 120
        )
    }

    // MARK: - Attachments

    /// Resolves the attachment selector, validates and de-duplicates the
    /// destination path, then saves via JXA. Two script runs (list, save)
    /// keep filename sanitation and overwrite protection in Swift.
    private static func saveAttachment(
        account: String,
        mailbox: String,
        id: Int,
        selector: String,
        saveDir: String?
    ) async throws -> MailSaveAttachmentResult {
        let attachments = try await AppleScriptRunner.shared.runJSON(
            .jxa,
            script: listAttachmentsScript,
            arguments: [account, mailbox, String(id)],
            as: [MailAttachmentInfo].self,
            timeout: 120
        )
        guard !attachments.isEmpty else {
            throw Self.error("NOT_FOUND: message \(id) has no attachments")
        }

        let attachment: MailAttachmentInfo
        if let index = Int(selector) {
            guard let match = attachments.first(where: { $0.index == index }) else {
                throw Self.error("NOT_FOUND: no attachment at index \(index) (message has \(attachments.count))")
            }
            attachment = match
        } else {
            guard let match = attachments.first(where: { $0.name == selector }) else {
                throw Self.error("NOT_FOUND: no attachment named \(selector)")
            }
            attachment = match
        }

        let directory = try AttachmentSaveDirectory.resolve(saveDir)
        let destination = Self.uniqueDestination(
            in: directory,
            fileName: Self.sanitizedFileName(attachment.name)
        )

        _ = try await AppleScriptRunner.shared.runJSON(
            .jxa,
            script: saveAttachmentScript,
            arguments: [account, mailbox, String(id), String(attachment.index), destination.path],
            as: MailSaveAttachmentResult.self,
            timeout: 180
        )
        return MailSaveAttachmentResult(saved: destination.path, attachmentName: attachment.name)
    }

    /// Strips path separators and control characters; an empty or
    /// dot-leading result falls back to a safe default.
    private static func sanitizedFileName(_ name: String) -> String {
        var cleaned =
            name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters))
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") {
            cleaned.removeFirst()
        }
        return cleaned.isEmpty ? "attachment" : cleaned
    }

    /// Appends " 2", " 3", ... before the extension until the name is free.
    private static func uniqueDestination(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    // MARK: - Templates
    //
    // Templates are Apple Core's own data (Mail has no template concept),
    // stored as JSON at ~/.config/apple-core/mail_templates.json with
    // 0600 permissions. APPLECORE_CONFIG_HOME overrides the directory so
    // tests never touch the real store.

    private static var templatesFileURL: URL {
        let configDir: URL
        if let override = ProcessInfo.processInfo.environment["APPLECORE_CONFIG_HOME"],
            !override.isEmpty
        {
            configDir = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            configDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/apple-core", isDirectory: true)
        }
        return configDir.appendingPathComponent("mail_templates.json")
    }

    private static func loadTemplates() throws -> [String: MailTemplate] {
        let url = Self.templatesFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: MailTemplate].self, from: data)
    }

    private static func storeTemplates(_ templates: [String: MailTemplate]) throws {
        let url = Self.templatesFileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(templates)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func saveTemplate(
        name: String,
        subject: String,
        body: String
    ) throws -> MailTemplate {
        guard subject.utf8.count + body.utf8.count <= maximumTemplateBytes else {
            throw Self.error("template exceeds the size limit of \(maximumTemplateBytes) bytes")
        }
        var templates = try Self.loadTemplates()
        let now = ISO8601DateFormatter().string(from: Date())
        var template =
            templates[name]
            ?? MailTemplate(name: name, subject: subject, body: body, createdAt: now, updatedAt: now)
        template.subject = subject
        template.body = body
        template.updatedAt = now
        if templates[name] == nil, templates.count >= maximumTemplateCount {
            throw Self.error("template store is full (limit \(maximumTemplateCount))")
        }
        templates[name] = template
        try Self.storeTemplates(templates)
        return template
    }

    private static func useTemplate(arguments: [String: Value]) async throws -> MailComposeResult {
        let name = try Self.requiredString("name", from: arguments)
        guard let template = try Self.loadTemplates()[name] else {
            throw Self.error("NOT_FOUND: no template named \(name)")
        }

        var variables: [String: String] = [:]
        if case .object(let values)? = arguments["variables"] {
            for (key, value) in values {
                variables[key] = value.stringValue ?? ""
            }
        }
        var subject = template.subject
        var body = template.body
        for (key, value) in variables {
            subject = subject.replacingOccurrences(of: "{{\(key)}}", with: value)
            body = body.replacingOccurrences(of: "{{\(key)}}", with: value)
        }

        let to = try Self.requiredAddresses("to", from: arguments)
        let cc = Self.addresses("cc", from: arguments)
        let bcc = Self.addresses("bcc", from: arguments)
        guard to.count + cc.count + bcc.count <= maximumRecipients else {
            throw Self.error("recipient count exceeds the limit of \(maximumRecipients)")
        }
        let action = arguments["action"]?.stringValue ?? "draft"
        guard action == "draft" || action == "send" else {
            throw Self.error("action must be draft or send")
        }

        let payload = ComposePayload(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: arguments["account"]?.stringValue
        )
        return try await AppleScriptRunner.shared.runJSON(
            .jxa,
            script: composeScript,
            arguments: [try Self.encodeJSON(payload), action == "send" ? "send" : "draft"],
            as: MailComposeResult.self,
            timeout: 120
        )
    }

    private struct ComposePayload: Encodable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let account: String?
    }
}
