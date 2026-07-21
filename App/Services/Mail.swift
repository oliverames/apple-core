// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

private let defaultMessageLimit = 20
private let maximumMessageLimit = 100
private let maximumBatchSize = 50
private let maximumRecipients = 50

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

// MARK: - Service

/// Apple Mail access — AppleScript/JXA slice.
///
/// Reads plus triage writes (read/flag/move/delete, batched) and compose
/// (send/reply/forward/draft), all against Mail.app via the shared
/// AppleScriptRunner. The full design in docs/planning/BUILD_PLAN.md §3.1
/// (disk-first .emlx parsing with an FTS5 index for fast search across
/// the whole store) is explicitly multi-week future work; this file is
/// the scaffold it will grow into.
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

    private struct ComposePayload: Encodable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let account: String?
    }
}
