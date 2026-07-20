// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JSONSchema
import OSLog

private let log = Logger.service("mail")

private let defaultMessageLimit = 20
private let maximumMessageLimit = 100

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

// MARK: - Service

/// Apple Mail access — first slice only.
///
/// This is a read-only AppleScript/JXA slice against Mail.app via the
/// shared AppleScriptRunner. The full design in
/// docs/planning/BUILD_PLAN.md §3.1 (disk-first .emlx parsing with an
/// FTS5 index for fast search across the whole store) is explicitly
/// multi-week future work; this file is the scaffold it will grow into.
/// No send/delete/move in this pass.
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
}
