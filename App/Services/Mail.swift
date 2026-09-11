// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import JSONSchema
import OSLog

/// The app this service drives. Opened on demand before any script runs.
private let scriptedMailApp = ScriptedApp("com.apple.mail")

private let log = Logger.service("mail")

private let mailPermissionProbeScript = """
    function run(argv) {
        const Mail = Application('Mail');
        return Mail.name();
    }
    """

private let defaultMessageLimit = 20
private let maximumMessageLimit = 100
private let maximumBatchSize = 50

/// Byte budgets for `mail_get_source`. A message with a photo attached is
/// megabytes of base64, so the default returns enough to answer a delivery
/// question and the result says how much it cut.
private let defaultSourceByteBudget = 65_536
private let maximumSourceByteBudget = 1_048_576

/// Caps for `mail_extract_links`. A newsletter routinely carries a couple of
/// hundred distinct URLs.
private let defaultLinkLimit = 100
private let maximumLinkLimit = 500
private let maximumRecipients = 50

/// Base64 inflates by roughly a third, so this cap is about the transport and
/// the client's context window rather than the disk. Matches the Notes
/// attachment contract deliberately: a client that has learned one should not
/// have to learn the other.
private let maximumInlineAttachmentBytes = 256 * 1024

/// Ceiling on one index pass. A first run against a very large store has to
/// stop somewhere rather than hold a tool call open indefinitely; stopping
/// early is reported as an incomplete scan rather than as a finished one.
private let maximumIndexFileLimit = 200_000

/// How long a tool call may block waiting for an index pass.
///
/// The ceiling is set by the shortest client timeout seen in the field, which
/// is 60 seconds, minus room for the rest of the call. Nothing here waits
/// longer; a pass that needs more time is polled, not waited on.
private let maximumRefreshWaitSeconds = 45
private let defaultRefreshWaitSeconds = 5
private let defaultSearchRefreshWaitSeconds = 10

/// How many messages `mail_get_thread` will read headers from. Reading `all
/// headers` is one Apple Event per message, so this is the real cost ceiling
/// on threading.
private let maximumThreadCandidates = 60

/// Ceiling on one rules listing. Every rule costs a dozen Apple Events to
/// read, so a pathological rule set cannot turn into a minute-long call.
private let maximumRuleCount = 200

/// Above this many indexed messages the per-account breakdown in mail_doctor
/// is skipped, because it walks every row. The report says it was skipped
/// rather than reporting nothing.
private let maximumDiagnosticIndexRows = 50_000

// MARK: - Output models

private struct MailAccount: Codable, Sendable {
    /// Mail's own account id, which is also the name of the account's
    /// directory inside ~/Library/Mail/V10. It is the only join between the
    /// display names these tools take and the keys the local index uses.
    let id: String
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

/// What the compose script hands back after Mail has actually built the
/// message. `body` and `attachments` are read off the composed message, not
/// echoed from the request, so a draft can be inspected rather than assumed.
private struct MailComposeScriptResult: Codable, Sendable {
    let status: String
    let subject: String
    let to: [String]
    let body: String
    let attachments: [String]
}

private struct MailComposeAttachmentSummary: Codable, Sendable {
    let name: String
    let mimeType: String
    let byteCount: Int
}

private struct MailComposeResult: Codable, Sendable {
    let status: String
    let subject: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
    let account: String?
    /// The body as composed, for draft inspection.
    let body: String
    let attachmentCount: Int
    let attachments: [MailComposeAttachmentSummary]
}

private struct MailReplyResult: Codable, Sendable {
    let status: String
    let messageId: Int
}

/// One condition of a Mail rule, as Mail's own scripting interface reports
/// it. Empty strings are what Mail gives for a field a condition does not
/// use, and they are passed through rather than dropped, so a condition that
/// reads oddly can be recognized as Mail's answer rather than as a parse.
private struct MailRuleCondition: Codable, Sendable {
    let ruleType: String
    let header: String
    let qualifier: String
    let expression: String
}

private struct MailRule: Codable, Sendable {
    let name: String
    let enabled: Bool
    let allConditionsMustBeMet: Bool
    let stopEvaluatingRules: Bool
    let conditions: [MailRuleCondition]
    /// The rule's configured actions, already rendered as text. Mail spreads
    /// one action across two or three properties (a move is a boolean and a
    /// mailbox), and a client has no use for that shape.
    let actions: [String]
}

private struct MailRuleListing: Codable, Sendable {
    let rules: [MailRule]
    let total: Int
    let note: String
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

/// One candidate message, with its raw header block, on the way to
/// MailThreadResolver. Only Mail.swift ever sees this shape.
private struct MailThreadCandidateRow: Codable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let dateReceived: String?
    let isRead: Bool
    let mailbox: String
    let accountName: String
    let rawHeaders: String
}

private struct MailThreadCandidates: Codable, Sendable {
    let subjectRoot: String
    let mailboxesSearched: Int
    let candidates: [MailThreadCandidateRow]
}

/// A thread member. The first five fields are what `mail_get_thread` has
/// always returned; `mailbox`, `accountName` and `messageId` are new, and
/// matter now that a thread can span mailboxes.
private struct MailThreadMessage: Codable, Sendable {
    let id: Int
    let subject: String
    let sender: String
    let dateReceived: String?
    let isRead: Bool
    let mailbox: String
    let accountName: String
    let messageId: String?
}

private struct MailThreadResult: Codable, Sendable {
    let subjectRoot: String
    /// "headers" or "subject": which rule decided this thread.
    let matching: String
    /// True only for the subject fallback, which may include unrelated mail.
    let approximate: Bool
    let note: String
    let mailboxesSearched: Int
    let candidatesConsidered: Int
    let messages: [MailThreadMessage]
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

/// The remote-client answer to "give me this attachment". A path on the
/// serving Mac is useless to a client that cannot read that filesystem, so
/// this carries the bytes, bounded, with the type and size beside them.
private struct MailAttachmentData: Codable, Sendable {
    let messageId: Int
    let mailbox: String
    let accountName: String
    let attachmentIndex: Int
    let attachmentName: String
    let mimeType: String
    let byteCount: Int
    let base64: String
}

private struct MailMailboxMutationResult: Codable, Sendable {
    let status: String
    let account: String
    let mailbox: String
}

private struct MailTemplateListResult: Codable, Sendable {
    let templates: [MailTemplateSummary]
}

private struct MailTemplateDeleteResult: Codable, Sendable {
    let status: String
    let name: String
}

/// One page of index-backed messages, always carrying the index's own
/// account of how complete it is. The completeness block is not optional
/// decoration: a caller that cannot tell "not in the mailbox" from "not
/// indexed yet" is worse off than one that waited for a slow scan.
private struct MailIndexMessagePage: Codable, Sendable {
    let messages: [MailIndexedMessage]
    let mailbox: String?
    let limit: Int
    let offset: Int
    let returned: Int
    /// The `account/mailbox` keys the index knows, so a caller that guessed
    /// a mailbox name wrong can see the real vocabulary.
    let indexedMailboxes: [String]
    let status: MailIndexStatus
}

/// What `mail_index_refresh` returns now that a pass is a job rather than a
/// blocking call.
///
/// The fields are ordered the way a caller has to think: which job, whether
/// this call started it, where it got to, and only then the finished report
/// if there is one. `guidance` is the sentence a client can relay without
/// having to infer anything from the rest.
private struct MailIndexRefreshJob: Codable, Sendable {
    let jobId: String
    /// False when a pass was already running and this call joined it.
    let started: Bool
    /// `running`, `succeeded` or `failed`.
    let state: String
    let startedAt: String
    let finishedAt: String?
    let elapsedSeconds: Double
    let fileLimit: Int
    /// How long this call waited before answering.
    let waitedSeconds: Double
    let progress: MailIndexProgress
    /// Present only when the pass failed, in the words it used.
    let failure: String?
    /// Present only when the pass finished inside the wait.
    let report: MailIndexRefreshReport?
    let guidance: String
    let status: MailIndexStatus
}

/// What the search did about staleness before answering, said out loud.
///
/// The index tools never refresh implicitly, and search is the one place
/// where that rule had to be revisited rather than inherited: a caller asking
/// "do I have anything from the landlord" cannot be expected to know that the
/// right answer today is "run a different tool first". So search does refresh
/// by default, and reports it, because a refresh that happens silently is
/// just as misleading as a stale answer that arrives silently.
private struct MailSearchRefreshNote: Codable, Sendable {
    /// `auto`, `never` or `always`, as requested.
    let policy: String
    let performed: Bool
    /// Why it did or did not refresh, in a sentence a client can relay.
    let reason: String
    let durationSeconds: Double?
    let inserted: Int?
    let updated: Int?
    let removed: Int?
    /// False when the refresh stopped at its file limit, which leaves the
    /// index usable but incomplete.
    let scanComplete: Bool?
    /// The pass this search started or joined, when it did either. A search
    /// never waits for a pass indefinitely, so this is how a caller finds the
    /// one that is still running after the answer came back.
    let jobId: String?
    /// True when a pass was still running when the search answered, which
    /// means the answer came from the index as it stood.
    let stillRunning: Bool?
}

/// One page of search results, with the index's own account of itself
/// attached. The status block travels with every page for the same reason it
/// travels with every index listing: a caller that cannot tell "no such
/// message" from "not indexed yet" has been given a number, not an answer.
private struct MailSearchPage: Codable, Sendable {
    let hits: [MailSearchHit]
    let returned: Int
    let limit: Int
    let hasMore: Bool
    /// Pass back as `cursor` for the next page. Absent on the last page.
    let nextCursor: String?
    let query: String?
    let scope: String
    /// The mailboxes actually searched, under both names.
    let searchedMailboxes: [MailMailboxName]
    /// Every mailbox the index holds, so a caller can see the vocabulary.
    let indexedMailboxes: [MailMailboxName]
    /// False when bodies could not be matched on this Mac.
    let bodySearched: Bool
    /// Messages a date filter excluded because they carry no parsable date.
    let undatedExcluded: Int?
    let warnings: [String]
    let refresh: MailSearchRefreshNote
    let status: MailIndexStatus
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

/// What `mail_redirect` did, echoed back from the script.
private struct MailRedirectResult: Codable, Sendable {
    let redirected: Bool
    let id: Int
    let subject: String
    let originalSender: String
    let to: [String]
    let cc: [String]
    let bcc: [String]
}

/// The raw header block, and optionally the whole message, as Mail holds it.
private struct MailMessageSourceRaw: Codable, Sendable {
    let id: Int
    let subject: String
    let messageSize: Int?
    let headers: String?
    let source: String?
}

/// `mail_get_source` as the caller sees it: parsed fields beside the text
/// they were parsed from, and an honest count of anything the byte budget cut.
private struct MailMessageSourceReport: Codable, Sendable {
    let id: Int
    let subject: String
    let messageSize: Int?
    let headerFields: [MailHeaderField]
    let rawHeaders: String
    let source: String?
    let omittedBytes: Int
    let note: String?
}

private struct MailAccountMailboxNames: Codable, Sendable {
    let accountName: String
    let mailboxes: [String]
}

/// The well-known mailboxes of one account, named as that account names them.
private struct MailMailboxRoleReport: Codable, Sendable {
    let accountName: String
    let roles: [MailMailboxRoleMatch]
    /// Roles this account has no mailbox for. Reported rather than guessed:
    /// handing back "Trash" for an account that has none sends a delete into
    /// a mailbox that does not exist.
    let unresolved: [String]
    let mailboxCount: Int
}

/// The links inside one message body.
private struct MailLinkReport: Codable, Sendable {
    let id: Int
    let subject: String
    /// The MIME type the links were read out of, e.g. `text/html`.
    let bodyType: String?
    let links: [MailBodyLink]
    /// Distinct links found, which can exceed `links.count` when limited.
    let distinctLinks: Int
    let note: String?
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
            id: account.id(),
            name: account.name(),
            emailAddresses: account.emailAddresses() || [],
            enabled: account.enabled(),
        }));
        return JSON.stringify(result);
    }
    """

private let listRulesScript = """
    function run(argv) {
        const limit = parseInt(argv[0], 10);
        const Mail = Application('Mail');
        // Every property is read behind its own try. Mail returns
        // 'missing value' for an action that is not configured, and reading
        // one of those through JXA throws rather than returning null; a
        // single unset action must not lose the whole rule.
        function read(fn, fallback) {
            try {
                const value = fn();
                return value === null || value === undefined ? fallback : value;
            } catch (e) {
                return fallback;
            }
        }
        const rules = read(() => Mail.rules(), []);
        const result = [];
        for (let i = 0; i < rules.length && i < limit; i++) {
            const rule = rules[i];
            const conditions = [];
            const rawConditions = read(() => rule.ruleConditions(), []);
            for (let c = 0; c < rawConditions.length; c++) {
                const condition = rawConditions[c];
                conditions.push({
                    ruleType: String(read(() => condition.ruleType(), '')),
                    header: String(read(() => condition.header(), '')),
                    qualifier: String(read(() => condition.qualifier(), '')),
                    expression: String(read(() => condition.expression(), '')),
                });
            }
            const actions = [];
            if (read(() => rule.shouldMoveMessage(), false)) {
                actions.push('move to ' + String(read(() => rule.moveMessage.name(), 'a mailbox')));
            }
            if (read(() => rule.shouldCopyMessage(), false)) {
                actions.push('copy to ' + String(read(() => rule.copyMessage.name(), 'a mailbox')));
            }
            if (read(() => rule.deleteMessage(), false)) { actions.push('delete message'); }
            if (read(() => rule.markRead(), false)) { actions.push('mark read'); }
            if (read(() => rule.markFlagged(), false)) { actions.push('mark flagged'); }
            const color = String(read(() => rule.colorMessage(), 'none'));
            if (color && color !== 'none') { actions.push('color message ' + color); }
            const forward = String(read(() => rule.forwardMessage(), ''));
            if (forward) { actions.push('forward to ' + forward); }
            const redirect = String(read(() => rule.redirectMessage(), ''));
            if (redirect) { actions.push('redirect to ' + redirect); }
            const replyText = String(read(() => rule.replyText(), ''));
            if (replyText) { actions.push('reply with stored text'); }
            const sound = String(read(() => rule.playSound(), ''));
            if (sound) { actions.push('play sound ' + sound); }
            const script = read(() => rule.runScript(), null);
            if (script) { actions.push('run script ' + String(script)); }
            result.push({
                name: String(read(() => rule.name(), '')),
                enabled: read(() => rule.enabled(), false) === true,
                allConditionsMustBeMet: read(() => rule.allConditionsMustBeMet(), false) === true,
                stopEvaluatingRules: read(() => rule.stopEvaluatingRules(), false) === true,
                conditions: conditions,
                actions: actions,
            });
        }
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
            // 'flag', 'unflag', or a flag index 0-6. MailFlagInstruction in
            // Shared/MailFlagColor.swift settled the three arguments into one
            // token, so nothing is decided here.
            const instruction = argv[3];
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            return runBatch(mailbox, ids, message => {
                if (instruction === 'unflag') {
                    message.flaggedStatus = false;
                    return;
                }
                message.flaggedStatus = true;
                if (instruction === 'flag') { return; }
                // Mail only honours `flag index` on a message that is already
                // flagged, which is why the order above matters. Nothing is
                // read back afterwards: the write has committed, and failing
                // it on a read is how a caller ends up retrying a write that
                // already succeeded.
                message.flagIndex = parseInt(instruction, 10);
            });
        }
        """

private let setJunkScript =
    resolveMailboxHelper + "\n" + batchMutationRunner + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const ids = JSON.parse(argv[2]);
            const junk = argv[3] === 'true';
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            return runBatch(mailbox, ids, message => {
                message.junkMailStatus = junk;
            });
        }
        """

// `redirect` is a distinct Mail command from `forward`, and the difference is
// the whole point: a redirected message keeps its original From and Date, so
// it reaches the new recipient as though the original sender had addressed
// them. Forwarding rewrites the sender to you and quotes the message inside a
// new one. Neither of the two maintained Apple Mail MCP servers exposes
// `redirect`; Mail has had it since OS X 10.0.
//
// Nothing is read back after the send. Mail's `send` either raises or it
// does not, and a property read afterwards that failed would tell a caller a
// committed send had failed.
private let redirectMessageScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const to = JSON.parse(argv[3]);
            const cc = JSON.parse(argv[4]);
            const bcc = JSON.parse(argv[5]);
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const original = matches[0];
            let subject = '';
            try { subject = original.subject() || ''; } catch (error) {}
            let sender = '';
            try { sender = original.sender() || ''; } catch (error) {}

            const outgoing = Mail.redirect(original, { openingWindow: false });
            for (const address of to) {
                outgoing.toRecipients.push(Mail.Recipient({ address: address }));
            }
            for (const address of cc) {
                outgoing.ccRecipients.push(Mail.Recipient({ address: address }));
            }
            for (const address of bcc) {
                outgoing.bccRecipients.push(Mail.Recipient({ address: address }));
            }
            outgoing.send();
            return JSON.stringify({
                redirected: true,
                id: messageId,
                subject: subject,
                originalSender: sender,
                to: to,
                cc: cc,
                bcc: bcc,
            });
        }
        """

// `all headers` is the RFC 5322 header block as it arrived and `source` is
// the whole message including its MIME parts. Both are read behind their own
// try: a message Mail has only a stub for answers neither, and that is a
// partial answer rather than a failure.
private let messageSourceScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const wantSource = argv[3] === 'true';
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);
            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const message = matches[0];
            let headers = null;
            try { headers = message.allHeaders() || null; } catch (error) {}
            let source = null;
            if (wantSource) {
                try { source = message.source() || null; } catch (error) {}
            }
            let subject = '';
            try { subject = message.subject() || ''; } catch (error) {}
            let size = null;
            try { size = message.messageSize(); } catch (error) {}
            return JSON.stringify({
                id: messageId,
                subject: subject,
                messageSize: size,
                headers: headers,
                source: source,
            });
        }
        """

// The mailbox names of one account, or of every account. Roles are decided in
// Swift (Shared/MailMailboxRoles.swift) so the alias table is testable without
// Mail running.
private let mailboxNamesScript = """
    function run(argv) {
        const accountName = argv[0];
        const Mail = Application('Mail');
        const accounts = accountName === ''
            ? Mail.accounts()
            : Mail.accounts.whose({ name: accountName })();
        if (accounts.length === 0) {
            throw new Error('NOT_FOUND: no account named ' + accountName);
        }
        const rows = [];
        for (const account of accounts) {
            const names = [];
            try {
                for (const mailbox of account.mailboxes()) {
                    try { names.push(mailbox.name()); } catch (error) {}
                }
            } catch (error) {}
            rows.push({ accountName: account.name(), mailboxes: names });
        }
        return JSON.stringify(rows);
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
// { to, cc, bcc, subject, body, account, attachmentPaths }. argv[1] selects
// the action.
//
// Attachment paths have already been validated in Swift — resolved against
// the folders the user shared, or staged from inline base64 — so this script
// only hands Mail file references it was given.
//
// The body and attachment list are read back off the composed message before
// it is sent or saved, so the caller learns what the draft actually contains
// rather than what it asked for. Mail does not always answer those reads on
// an outgoing message, so each falls back to the requested value.
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
        const attachmentPaths = payload.attachmentPaths || [];
        for (const path of attachmentPaths) {
            message.attachments.push(Mail.Attachment({ fileName: Path(path) }));
        }

        let composedBody = payload.body;
        try {
            const actual = message.content();
            if (typeof actual === 'string') { composedBody = actual; }
        } catch (error) {}

        let attachmentNames = payload.attachmentNames || [];
        try {
            const actual = message.attachments();
            if (actual && actual.length > 0) {
                const names = [];
                for (let i = 0; i < actual.length; i++) {
                    try { names.push(actual[i].name() || ''); } catch (error) { names.push(''); }
                }
                attachmentNames = names;
            }
        } catch (error) {}

        if (action === 'send') {
            message.send();
            return JSON.stringify({
                status: 'sent',
                subject: payload.subject,
                to: payload.to,
                body: composedBody,
                attachments: attachmentNames,
            });
        }
        message.save();
        return JSON.stringify({
            status: 'draft_saved',
            subject: payload.subject,
            to: payload.to,
            body: composedBody,
            attachments: attachmentNames,
        });
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

// Thread identity comes from RFC 5322 headers, not from subject text.
//
// This script is only the gathering half. It narrows to plausible candidates
// with Mail's own subject filter — which runs inside Mail and is cheap — then
// reads each candidate's raw header block, which is not cheap: `all headers`
// costs one Apple Event per message. The decision itself lives in
// Shared/MailThreadResolver.swift, as a pure function over these headers, so
// it can be tested against fixtures without Mail running.
//
// Mailboxes are visited anchor-first, then Sent-like, then the rest, and each
// gets a share of the candidate budget. Spending the whole budget on a busy
// Inbox would reintroduce exactly the bug this replaces: a conversation that
// never reaches its own replies in Sent.
private let threadCandidatesScript =
    resolveMailboxHelper + "\n"
        + """
        function run(argv) {
            const accountName = argv[0];
            const mailboxName = argv[1];
            const messageId = parseInt(argv[2], 10);
            const candidateCap = parseInt(argv[3], 10);
            const Mail = Application('Mail');
            const mailbox = resolveMailbox(Mail, accountName, mailboxName);

            const matches = mailbox.messages.whose({ id: messageId })();
            if (matches.length === 0) {
                throw new Error('NOT_FOUND: no message with id ' + messageId);
            }
            const anchor = matches[0];
            const anchorSubject = anchor.subject() || '';
            const root = anchorSubject.replace(/^((re|fwd?|fw)(\\[\\d+\\])?:\\s*)+/i, '').trim();

            function headersOf(message) {
                try { return message.allHeaders() || ''; } catch (error) { return ''; }
            }
            function rowFor(message, boxName) {
                return {
                    id: message.id(),
                    subject: message.subject() || '',
                    sender: message.sender() || '',
                    dateReceived: message.dateReceived() ? message.dateReceived().toISOString() : null,
                    isRead: message.readStatus() === true,
                    mailbox: boxName,
                    accountName: accountName,
                    rawHeaders: headersOf(message),
                };
            }

            const rows = [rowFor(anchor, mailboxName)];
            const seen = {};
            seen[messageId] = true;
            let mailboxesSearched = 0;

            if (root !== '') {
                const accounts = Mail.accounts.whose({ name: accountName })();
                let boxes = [];
                try {
                    boxes = accounts.length > 0 ? accounts[0].mailboxes() : [mailbox];
                } catch (error) {
                    boxes = [mailbox];
                }
                const ordered = [];
                const sentish = [];
                const rest = [];
                for (const box of boxes) {
                    let name = '';
                    try { name = box.name() || ''; } catch (error) { continue; }
                    if (name === mailboxName) { ordered.push(box); }
                    else if (/sent|outbox|archive/i.test(name)) { sentish.push(box); }
                    else { rest.push(box); }
                }
                const visiting = ordered.concat(sentish).concat(rest);
                const perBox = Math.max(5, Math.floor(candidateCap / Math.max(visiting.length, 1)));

                for (const box of visiting) {
                    if (rows.length >= candidateCap) { break; }
                    let related = [];
                    let boxName = '';
                    try {
                        boxName = box.name() || '';
                        related = box.messages.whose({ subject: { _contains: root } })();
                    } catch (error) {
                        continue;
                    }
                    mailboxesSearched += 1;
                    let taken = 0;
                    for (let i = 0; i < related.length; i++) {
                        if (taken >= perBox || rows.length >= candidateCap) { break; }
                        const message = related[i];
                        let id;
                        try { id = message.id(); } catch (error) { continue; }
                        if (seen[id]) { continue; }
                        seen[id] = true;
                        rows.push(rowFor(message, boxName));
                        taken += 1;
                    }
                }
            }

            return JSON.stringify({
                subjectRoot: root,
                mailboxesSearched: Math.max(mailboxesSearched, 1),
                candidates: rows,
            });
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

// Mail will only hand an attachment to a file path, so the inline fetch
// stages it exactly the way the save path does and reads it back. The
// difference is that this destination is a scratch directory Swift removes on
// the way out, rather than somewhere the user chose.
private let fetchAttachmentScript = saveAttachmentScript

private let selectedMessagesScript = """
    function run() {
        const Mail = Application('Mail');
        const viewers = Mail.messageViewers();
        if (viewers.length === 0) {
            return JSON.stringify([]);
        }
        const selected = viewers[0].selectedMessages();
        return JSON.stringify(selected.map(function (message) {
            const mailbox = message.mailbox();
            return {
                id: message.id(),
                subject: message.subject(),
                sender: message.sender(),
                dateSent: message.dateSent().toISOString(),
                readStatus: message.readStatus(),
                mailbox: mailbox ? mailbox.name() : null,
                account: mailbox && mailbox.account() ? mailbox.account().name() : null,
            };
        }));
    }
    """

private let checkMailScript = """
    function run() {
        const Mail = Application('Mail');
        Mail.checkForNewMail();
        return JSON.stringify({ status: 'checking' });
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
/// - Signatures (list, or apply when composing): the `signature` element is
///   gated behind Mail's `com.apple.mail.compose` access group, so an
///   unentitled script reads it as null. Confirmed against Mail's own
///   dictionary rather than assumed; there is no unentitled path to it.
/// - Smart mailbox writes (create/delete): there is no smart mailbox in
///   Mail's scripting dictionary at all, so the only way to write one is to
///   edit Mail's private SyncedSmartMailboxes.plist, which a running Mail
///   holds in memory and rewrites on quit. A tool that writes it would have
///   its work silently discarded whenever Mail happened to be open, which is
///   most of the time. `mail_list_smart_mailboxes` reads that file and stays
///   read-only for the same reason.
/// - `bounce`: the command is still in Mail's dictionary but the feature was
///   removed from Mail's UI, and a bounce forges a delivery failure from an
///   address the user controls. It is a deliverability hazard aimed at the
///   user's own sending reputation, and mail_delete_message plus
///   mail_set_junk cover what people actually want from it.
/// - Batch variants of the triage tools: `mail_set_read`, `mail_set_flagged`,
///   `mail_set_junk`, `mail_move_message` and `mail_delete_message` each take
///   an `ids` array up to \(maximumBatchSize) and report per-id
///   success/failure, so separate `batch_*` tools would be six more names for
///   capability that is already here.
/// - Cross-mailbox and body search through Apple Events: per-mailbox
///   subject/sender search is the AppleScript-feasible ceiling, so
///   `mail_search` stays there and keeps returning Mail's own live message
///   ids, which every mutating tool here needs. Searching across accounts
///   and inside bodies is served instead by `mail_index_search` over the
///   disk-first .emlx index (Shared/MailIndex.swift, issue #19), which
///   answers from a snapshot and reports how old that snapshot is.
final class MailService: Service {
    static let shared = MailService()

    func activate() async throws {
        _ = try await scriptedMailApp.run(
            .jxa,
            script: mailPermissionProbeScript
        )
    }

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
            try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
                "List messages in a mailbox with id, subject, sender, date, and read status, in the order Mail returns them",
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
                .jxa,
                script: getMessageScript,
                arguments: [account, mailbox, String(id)],
                as: MailMessageDetail.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_search",
            description:
                "Search one mailbox by subject or sender through Mail itself, returning live message ids the other Mail tools accept. For searching across accounts, inside message bodies, or by date, attachment or read state, use mail_index_search.",
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
            return try await scriptedMailApp.runJSON(
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
                    "color": .string(
                        description:
                            "Flag colour: \(MailFlagColor.acceptedNames.joined(separator: ", ")). Omit to flag without choosing a colour. Cannot be combined with flagged=false."
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
            let instruction: MailFlagInstruction
            do {
                instruction = try MailFlagInstruction.resolve(
                    flagged: flagged,
                    color: arguments["color"]?.stringValue
                )
            } catch let failure as MailFlagColorError {
                throw Self.error(failure.description)
            }
            return try await Self.runBatch(
                script: setFlaggedScript,
                arguments: [
                    account, mailbox, try Self.encodeJSON(ids), instruction.scriptArgument,
                ]
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
            name: "mail_selected",
            description:
                "Get the messages the user currently has selected in Mail. Use this when the user refers to "
                + "\"this email\" or \"the message I am looking at\".",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Get Selected Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            try await scriptedMailApp.runJSON(
                .jxa,
                script: selectedMessagesScript,
                arguments: [],
                as: [MailSelectedMessage].self,
                timeout: 30
            )
        }

        Tool(
            name: "mail_check_for_new_mail",
            description:
                "Ask Mail to fetch new messages now. Returns as soon as the check starts, not when it finishes.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Check for New Mail",
                readOnlyHint: false,
                idempotentHint: true,
                openWorldHint: true
            )
        ) { _ in
            try await scriptedMailApp.runJSON(
                .jxa,
                script: checkMailScript,
                arguments: [],
                as: MailCheckResult.self,
                timeout: 30
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
                "Get the conversation around a message, decided on RFC 5322 Message-ID, In-Reply-To and "
                + "References headers and searched across every mailbox in the account, so a reply chain "
                + "split between Inbox and Sent comes back whole and unrelated mail sharing the subject "
                + "does not. A message carrying no usable headers falls back to subject matching; the "
                + "response says which rule was used in \"matching\" and sets \"approximate\" when it was "
                + "the fallback.",
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
            return try await Self.getThread(
                account: account,
                mailbox: mailbox,
                id: id,
                limit: limit
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
            name: "mail_fetch_attachment",
            description:
                "Get a message attachment's bytes as base64, for attachments up to "
                + "\(maximumInlineAttachmentBytes / 1024)KB. Use this from a remote client: "
                + "mail_save_attachment writes to the serving Mac's disk, which a remote client cannot "
                + "read. Use mail_save_attachment instead for anything larger, or when the file only "
                + "needs to land on that disk.",
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
                ],
                required: ["account", "mailbox", "id", "attachment"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Fetch Attachment",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let selector = try Self.requiredString("attachment", from: arguments)
            return try await Self.fetchAttachment(
                account: account,
                mailbox: mailbox,
                id: id,
                selector: selector
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
            return try await scriptedMailApp.runJSON(
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
            return try MailTemplateStore.default.save(name: name, subject: subject, body: body)
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
            return MailTemplateListResult(templates: try MailTemplateStore.default.list())
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
            return try MailTemplateStore.default.get(name: name)
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
            try MailTemplateStore.default.delete(name: name)
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

        Tool(
            name: "mail_index_status",
            description:
                "Report Apple Core's read-only local mail index: index_state (no_disk_access, no_local_mail, building, refreshing, empty, stale or current), the progress of a refresh pass running right now, how stale it is, how many messages and mailboxes it covers, how many bodies are not downloaded, and which files could not be read. Readable while a pass is running, so this is how you poll one. Ask this before trusting any index-backed read.",
            inputSchema: .object(
                properties: [:],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Mail Index Status",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            MailIndex.status()
        }

        Tool(
            name: "mail_index_refresh",
            description:
                "Start a pass over Mail's own files on disk to build or update the local mail index, and return a job id rather than blocking until it finishes. A first pass over a large mail store takes many minutes, far longer than a client will wait. Waits a few seconds for a quick pass, then returns whatever state the pass is in; poll mail_index_status with the job id to watch it, which stays readable while the pass runs. Only one pass runs at a time: calling this while one is running joins that pass and returns started=false, it never starts a second. Reads Mail's storage read-only and writes only Apple Core's index under ~/.config/apple-core. Needs Full Disk Access.",
            inputSchema: .object(
                properties: [
                    "file_limit": .integer(
                        description:
                            "Maximum message files to walk in one pass; a pass that stops here is reported as incomplete",
                        default: .int(maximumIndexFileLimit)
                    ),
                    "wait_seconds": .integer(
                        description:
                            "Seconds to wait for the pass to finish before answering (0 to \(maximumRefreshWaitSeconds)). An incremental pass usually finishes inside the default; a first pass over a large store will not, and the answer says so rather than timing out",
                        default: .int(defaultRefreshWaitSeconds)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Refresh Mail Index",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try Self.startIndexRefresh(arguments: arguments)
        }

        Tool(
            name: "mail_index_messages",
            description:
                "Read messages out of the local index instead of through Mail, which is what makes a large mailbox readable. Returns a bounded page newest first, with the index's staleness, undownloaded-body and unreadable-file counts attached. This is a listing, not a search: it takes no query terms.",
            inputSchema: .object(
                properties: [
                    "mailbox": .string(
                        description:
                            "Mailbox to scope to: either an 'account/mailbox' key from indexed_mailboxes, or a mailbox path on its own such as INBOX. Every indexed mailbox if omitted"
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return (max \(maximumMessageLimit))",
                        default: .int(defaultMessageLimit)
                    ),
                    "offset": .integer(
                        description: "Messages to skip, for paging",
                        default: .int(0)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Read Indexed Messages",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try Self.indexedMessages(arguments: arguments)
        }

        Tool(
            name: "mail_index_search",
            description:
                "Search mail across every account and mailbox at once, including message bodies, using Apple Core's local index. Filters on date range, mailbox, attachments, read state and download state. Pages by cursor, not offset, so a page boundary stays correct while mail arrives. Every result carries the index's staleness and completeness, and says whether it refreshed the index before answering. Needs Full Disk Access. Use mail_search instead when you need Mail's own live message ids for a follow-up action.",
            inputSchema: .object(
                properties: [
                    "query": .string(
                        description:
                            "Words to match. Quote a phrase; a trailing * matches by prefix. Omit to return every message the filters allow, newest first"
                    ),
                    "scope": .string(
                        description:
                            "Which indexed text to match: all of subject, sender and body, or just one of them",
                        default: "all",
                        enum: ["all", "subject", "sender", "body"]
                    ),
                    "mailboxes": .array(
                        description:
                            "Mailboxes to search: an account/mailbox key from indexed_mailboxes, a display path such as 'iCloud/INBOX', an account name on its own, or a bare mailbox path such as INBOX meaning that mailbox in every account. Every indexed mailbox if omitted",
                        items: .string()
                    ),
                    "since": .string(
                        description: "Only messages sent on or after this date (YYYY-MM-DD or ISO 8601)"
                    ),
                    "until": .string(
                        description: "Only messages sent on or before this date (YYYY-MM-DD or ISO 8601)"
                    ),
                    "attachments": .string(
                        description: "Filter on whether the message has attachments",
                        default: "any",
                        enum: ["any", "with", "without"]
                    ),
                    "read_state": .string(
                        description: "Filter on read state",
                        default: "any",
                        enum: ["any", "read", "unread"]
                    ),
                    "body_state": .string(
                        description:
                            "Filter on whether the body is fully on this Mac. 'incomplete' finds messages whose text was never downloaded and so could not be matched",
                        default: "any",
                        enum: ["any", "complete", "incomplete"]
                    ),
                    "limit": .integer(
                        description: "Maximum messages to return (max \(maximumMessageLimit))",
                        default: .int(defaultMessageLimit)
                    ),
                    "cursor": .string(
                        description:
                            "next_cursor from a previous search, to continue it. Do not construct one by hand"
                    ),
                    "refresh": .string(
                        description:
                            "What to do about a stale index: 'auto' starts a bounded refresh when the index is stale and answers from the index as it stands if that refresh is still running, 'never' refuses to search a stale index, 'always' starts one whatever the age. None of them blocks past refresh_wait_seconds. An index that has never completed a pass is never searched: the call starts a pass and refuses, so poll mail_index_status instead. The answer says which happened",
                        default: "auto",
                        enum: ["auto", "never", "always"]
                    ),
                    "refresh_wait_seconds": .integer(
                        description:
                            "Seconds to wait for a refresh this search started before answering from the index as it stands (0 to \(maximumRefreshWaitSeconds))",
                        default: .int(defaultSearchRefreshWaitSeconds)
                    ),
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Search Indexed Mail",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            try await Self.indexSearch(arguments: arguments)
        }

        Tool(
            name: "mail_health_check",
            description:
                "Check quickly whether the Mail surface is usable: one probe confirming Mail.app is reachable and Apple Core holds Automation permission. Use mail_doctor when something is wrong and you want the fuller picture.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Mail Health Check",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            await MailService.diagnose(deep: false)
        }

        Tool(
            name: "mail_doctor",
            description:
                "Diagnose the Mail surface end to end: Apple Events reachability, Automation permission, account state, Full Disk Access to Mail's own files, the local index, and how much mail is actually downloaded to this Mac, each reported as ok, warn or fail with what to do about it. Reports evidence of sync state rather than claiming it: Mail exposes no way to test that an account is connected, and mail_check_for_new_mail returns when Mail accepts the command, not when a sync finishes.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "Mail Doctor",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            await MailService.diagnose(deep: true)
        }

        Tool(
            name: "mail_list_rules",
            description:
                "List Mail's message rules read-only: name, whether it is enabled, whether all conditions must match, each condition, and the actions it takes. Inspection only. Apple Core does not create, change, enable or delete rules, and changing a rule while Mail is running is not a supported operation.",
            inputSchema: .object(
                properties: [
                    "limit": .integer(
                        description: "Maximum rules to return (max \(maximumRuleCount))",
                        default: .int(maximumRuleCount)
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "List Mail Rules",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let limit = min(max(arguments["limit"]?.intValue ?? maximumRuleCount, 1), maximumRuleCount)
            let rules = try await scriptedMailApp.runJSON(
                .jxa,
                script: listRulesScript,
                arguments: [String(limit)],
                as: [MailRule].self,
                timeout: 120
            )
            return MailRuleListing(
                rules: rules,
                total: rules.count,
                note:
                    "Read-only. A rule reported with no conditions or no actions is a rule Mail "
                    + "would not describe further over scripting, not an empty rule."
            )
        }

        Tool(
            name: "mail_list_smart_mailboxes",
            description:
                "List Mail's smart mailboxes read-only, with their conditions. Mail's scripting interface has no smart mailbox in it, so this reads Mail's own private SyncedSmartMailboxes.plist and needs Full Disk Access. That file has no published schema: the reader reports every field it could not place instead of dropping it, and a file whose layout it cannot follow comes back as state=unrecognized rather than as an empty list. Inspection only; nothing here writes.",
            inputSchema: .object(properties: [:], additionalProperties: false),
            annotations: .init(
                title: "List Smart Mailboxes",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { _ in
            MailSmartMailboxes.list()
        }

        Tool(
            name: "mail_set_junk",
            description:
                "Mark messages as junk or not junk. Sets Mail's junk mail status, which is what trains Mail's junk filter; it does not move the messages. Accepts up to \(maximumBatchSize) message ids and reports per-id success/failure",
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
                    "junk": .boolean(
                        description: "true to mark as junk, false to mark as not junk",
                        default: true
                    ),
                ],
                required: ["account", "mailbox", "ids"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Mark Junk/Not Junk",
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let ids = try Self.requiredIDs(from: arguments)
            let junk = arguments["junk"]?.boolValue ?? true
            return try await Self.runBatch(
                script: setJunkScript,
                arguments: [account, mailbox, try Self.encodeJSON(ids), junk ? "true" : "false"]
            )
        }

        Tool(
            name: "mail_redirect",
            description:
                "Redirect a message to other recipients. Unlike mail_forward, a redirect keeps the original sender, date and subject, so it arrives as though the original sender had addressed the new recipient, and a reply goes back to them rather than to you. Sends immediately.",
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
                    "cc": .array(
                        description: "Cc email addresses",
                        items: .string()
                    ),
                    "bcc": .array(
                        description: "Bcc email addresses",
                        items: .string()
                    ),
                ],
                required: ["account", "mailbox", "id", "to"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Redirect Message",
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
            let cc = Self.addresses("cc", from: arguments)
            let bcc = Self.addresses("bcc", from: arguments)
            guard to.count + cc.count + bcc.count <= maximumRecipients else {
                throw Self.error("recipients exceed the limit of \(maximumRecipients)")
            }
            return try await scriptedMailApp.runJSON(
                .jxa,
                script: redirectMessageScript,
                arguments: [
                    account, mailbox, String(id), try Self.encodeJSON(to),
                    try Self.encodeJSON(cc), try Self.encodeJSON(bcc),
                ],
                as: MailRedirectResult.self,
                timeout: 120
            )
        }

        Tool(
            name: "mail_get_source",
            description:
                "Get a message's raw RFC 5322 headers, parsed and unfolded, and optionally its full source including MIME parts. This is the ground truth behind delivery questions: Received hops, SPF/DKIM/DMARC results, List-Unsubscribe, Message-ID and References. Repeated headers keep their order.",
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
                    "part": .string(
                        description:
                            "headers for the header block only, full to include the entire message source",
                        default: "headers",
                        enum: ["headers", "full"]
                    ),
                    "max_bytes": .integer(
                        description:
                            "Byte budget for the returned text; anything cut is reported as omittedBytes. Default \(defaultSourceByteBudget), max \(maximumSourceByteBudget)"
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Get Message Source",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let wantsSource = (arguments["part"]?.stringValue ?? "headers") == "full"
            let budget = min(
                max(arguments["max_bytes"]?.intValue ?? defaultSourceByteBudget, 1),
                maximumSourceByteBudget
            )
            let raw = try await scriptedMailApp.runJSON(
                .jxa,
                script: messageSourceScript,
                arguments: [account, mailbox, String(id), wantsSource ? "true" : "false"],
                as: MailMessageSourceRaw.self,
                timeout: 120
            )
            // Mail answers `all headers` for a downloaded message and nothing
            // for a stub it has only the summary of. When it is silent, the
            // header block is recovered from the source if that came back.
            let rawHeaders =
                raw.headers ?? raw.source.map { MailHeaderBlock.split(rawMessage: $0).headers } ?? ""
            let clampedHeaders = MailHeaderBlock.clamp(rawHeaders, toBytes: budget)
            var omitted = clampedHeaders.omittedBytes
            var source: String?
            if wantsSource, let full = raw.source {
                let remaining = max(0, budget - clampedHeaders.text.utf8.count)
                let clampedSource = MailHeaderBlock.clamp(full, toBytes: remaining)
                source = clampedSource.text
                omitted += clampedSource.omittedBytes
            }
            var note: String?
            if rawHeaders.isEmpty {
                note =
                    "Mail returned no header block for this message, which usually means only its summary has been downloaded. Run mail_check_for_new_mail or open the message in Mail, then retry."
            } else if wantsSource, raw.source == nil {
                note = "Mail returned no message source; the headers above are all it had."
            }
            return MailMessageSourceReport(
                id: raw.id,
                subject: raw.subject,
                messageSize: raw.messageSize,
                headerFields: MailHeaderBlock.parse(clampedHeaders.text),
                rawHeaders: clampedHeaders.text,
                source: source,
                omittedBytes: omitted,
                note: note
            )
        }

        Tool(
            name: "mail_extract_links",
            description:
                "List the links inside a message, with the label each one was shown under. Reads the message's HTML part, so it sees real href targets rather than the flattened text Mail's content property returns. Identical URLs are merged and counted, and a link whose visible label names a different host than it points at is marked displayMismatch.",
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
                    "limit": .integer(
                        description:
                            "Maximum distinct links to return, first seen first. Default \(defaultLinkLimit), max \(maximumLinkLimit)"
                    ),
                ],
                required: ["account", "mailbox", "id"],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Extract Message Links",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = try Self.requiredString("account", from: arguments)
            let mailbox = try Self.requiredString("mailbox", from: arguments)
            let id = try Self.requiredID(from: arguments)
            let limit = min(
                max(arguments["limit"]?.intValue ?? defaultLinkLimit, 1),
                maximumLinkLimit
            )
            let raw = try await scriptedMailApp.runJSON(
                .jxa,
                script: messageSourceScript,
                arguments: [account, mailbox, String(id), "true"],
                as: MailMessageSourceRaw.self,
                timeout: 120
            )
            guard let full = raw.source, !full.isEmpty else {
                return MailLinkReport(
                    id: raw.id,
                    subject: raw.subject,
                    bodyType: nil,
                    links: [],
                    distinctLinks: 0,
                    note:
                        "Mail returned no source for this message, which usually means only its summary has been downloaded. Run mail_check_for_new_mail or open the message in Mail, then retry."
                )
            }
            let split = MailHeaderBlock.split(rawMessage: full)
            let headers = MailHeaderBlock.parse(split.headers).map {
                (name: $0.name, value: $0.value)
            }
            let part = MailEmlxParser.textPart(
                body: split.body ?? "",
                headers: headers,
                preferring: "text/html"
            )
            guard let part else {
                return MailLinkReport(
                    id: raw.id,
                    subject: raw.subject,
                    bodyType: nil,
                    links: [],
                    distinctLinks: 0,
                    note: "This message has no text part to read links out of."
                )
            }
            let extracted = MailBodyLinks.extract(from: part.text, limit: limit)
            return MailLinkReport(
                id: raw.id,
                subject: raw.subject,
                bodyType: part.mimeType,
                links: extracted.links,
                distinctLinks: extracted.total,
                note: extracted.total > extracted.links.count
                    ? "\(extracted.total) distinct links found; the first \(extracted.links.count) are listed. Raise limit to see more."
                    : nil
            )
        }

        Tool(
            name: "mail_mailbox_roles",
            description:
                "Resolve each account's well-known mailboxes (inbox, drafts, sent, trash, junk, archive, outbox) to the names that account actually uses, so the other Mail tools can be given a real mailbox name. Necessary because those names are localised and provider-specific: Trash is Papierkorb on a German account and [Gmail]/Trash on Gmail. A role the account has no mailbox for is listed as unresolved rather than guessed.",
            inputSchema: .object(
                properties: [
                    "account": .string(
                        description: "Account name; all accounts if omitted"
                    )
                ],
                additionalProperties: false
            ),
            annotations: .init(
                title: "Resolve Mailbox Roles",
                readOnlyHint: true,
                openWorldHint: false
            )
        ) { arguments in
            let account = arguments["account"]?.stringValue ?? ""
            let rows = try await scriptedMailApp.runJSON(
                .jxa,
                script: mailboxNamesScript,
                arguments: [account],
                as: [MailAccountMailboxNames].self,
                timeout: 120
            )
            return rows.map { row in
                let matches = MailMailboxRoles.resolve(mailboxes: row.mailboxes)
                let resolved = Set(matches.map(\.role))
                return MailMailboxRoleReport(
                    accountName: row.accountName,
                    roles: matches,
                    unresolved: MailMailboxRole.allCases.filter { !resolved.contains($0) }
                        .map(\.rawValue),
                    mailboxCount: row.mailboxes.count
                )
            }
        }
    }

    // MARK: - Helpers

    /// The Mail diagnosis, assembled here and worded in MailDiagnostics.
    ///
    /// Shallow is one Apple Event and nothing else. Deep adds the account
    /// list, Mail's on-disk store, the local index and the download state,
    /// each of which can fail on its own without making the rest unreadable.
    static func diagnose(deep: Bool) async -> MailDiagnosticReport {
        do {
            _ = try await scriptedMailApp.run(.jxa, script: mailPermissionProbeScript)
        } catch {
            return MailDiagnostics.unreachableReport(error.localizedDescription)
        }
        var checks: [MailCheck] = [MailDiagnostics.reachableCheck]
        guard deep else { return MailDiagnostics.report(checks: checks) }

        var accounts: [MailDiagnosticAccount] = []
        do {
            accounts = try await scriptedMailApp.runJSON(
                .jxa,
                script: listAccountsScript,
                as: [MailAccount].self
            )
            .map {
                MailDiagnosticAccount(
                    id: $0.id,
                    name: $0.name,
                    enabled: $0.enabled,
                    emailAddresses: $0.emailAddresses
                )
            }
            checks.append(MailDiagnostics.accountsCheck(accounts: accounts, error: nil))
        } catch {
            checks.append(
                MailDiagnostics.accountsCheck(
                    accounts: nil,
                    error: error.localizedDescription
                )
            )
        }

        checks.append(MailDiagnostics.localStoreCheck(MailLocalStore.default.access))

        let status = MailIndex.status()
        checks.append(MailDiagnostics.indexCheck(status))
        checks.append(MailDiagnostics.downloadCheck(status))
        if let unreadable = MailDiagnostics.unreadableFilesCheck(status) {
            checks.append(unreadable)
        }

        var notes: [String] = []
        if !accounts.isEmpty, status.messageCount > 0 {
            if status.messageCount > maximumDiagnosticIndexRows {
                notes.append(
                    "The per-account breakdown was skipped: the index holds "
                        + "\(status.messageCount) messages, over the \(maximumDiagnosticIndexRows) "
                        + "row ceiling this report walks."
                )
            } else {
                do {
                    let coverage = try Self.accountCoverage()
                    checks.append(
                        contentsOf: MailDiagnostics.coverageChecks(
                            accounts: accounts,
                            coverage: coverage,
                            now: Date()
                        )
                    )
                } catch {
                    notes.append(
                        "The per-account breakdown could not be read: "
                            + error.localizedDescription
                    )
                }
            }
        }

        return MailDiagnostics.report(checks: checks, extraNotes: notes)
    }

    /// Per-account counts folded out of the index's own rows. Read here
    /// rather than queried, so no new statement is added to the index store
    /// for a diagnostic.
    private static func accountCoverage() throws -> [MailAccountCoverage] {
        var counts: [String: (messages: Int, incomplete: Int, newest: Date?)] = [:]
        for entry in try MailIndexStore.default.entries() {
            var row = counts[entry.accountID] ?? (0, 0, nil)
            row.messages += 1
            if entry.isPartial { row.incomplete += 1 }
            if let newest = row.newest {
                row.newest = max(newest, entry.modified)
            } else {
                row.newest = entry.modified
            }
            counts[entry.accountID] = row
        }
        return counts.keys.sorted().map { id in
            let row = counts[id]!
            return MailAccountCoverage(
                accountID: id,
                messageCount: row.messages,
                incompleteCount: row.incomplete,
                newestMessage: row.newest
            )
        }
    }

    /// Why an index-backed read refused, told apart by whether a pass is
    /// running. "Run a refresh" and "wait for the refresh already running"
    /// are different instructions, and a caller given the first when the
    /// second is true starts work that will only be joined anyway.
    private static func emptyIndexExplanation(_ status: MailIndexStatus) -> String {
        if let active = status.activeRefresh {
            return
                "INDEX_BUILDING: the local mail index has never completed a full pass, and one "
                + "(\(active.jobID)) has been running for \(Int(active.elapsedSeconds)) "
                + "second(s): \(active.detail) Poll mail_index_status until index_state is no "
                + "longer building, then ask again. Do not start another pass."
        }
        return
            "INDEX_EMPTY: the local mail index has never completed a full pass, so it cannot "
            + "say what is or is not in your mail. Run mail_index_refresh first; it returns a "
            + "job id immediately and mail_index_status reports its progress."
    }

    /// Starts an index pass, or joins the one already running, and answers
    /// with where it got to.
    ///
    /// The old shape of this tool was a blocking call over the whole store.
    /// On an 11 GB ~/Library/Mail it ran for many minutes while the client
    /// gave up at sixty seconds, which produced the worst possible report: a
    /// failure to the caller, an indexing process still running on the Mac,
    /// and a retry that would have started a second pass over the same files.
    /// A job id and a bounded wait replace all three.
    private static func startIndexRefresh(arguments: [String: Value]) throws
        -> MailIndexRefreshJob
    {
        let requestedLimit = arguments["file_limit"]?.intValue ?? maximumIndexFileLimit
        let fileLimit = min(max(requestedLimit, 1), maximumIndexFileLimit)
        let wait = Double(
            min(
                max(arguments["wait_seconds"]?.intValue ?? defaultRefreshWaitSeconds, 0),
                maximumRefreshWaitSeconds
            )
        )
        let coordinator = MailIndexJobCoordinator.shared
        // The access check runs here, on this call's thread, so a Mac without
        // Full Disk Access is told so in the answer to the call that asked
        // rather than in a job that fails out of sight.
        let outcome = try coordinator.startRefresh(fileLimit: fileLimit)
        let waitStarted = Date()
        var snapshot = outcome.snapshot
        if wait > 0, snapshot.isRunning {
            snapshot = coordinator.wait(upTo: wait) ?? snapshot
        }
        let waited = Date().timeIntervalSince(waitStarted)

        let guidance: String
        switch snapshot.state {
        case "running":
            guidance =
                (outcome.started
                    ? "A pass started and is still running after \(Int(waited)) second(s). "
                    : "A pass was already running and this call joined it rather than starting a "
                        + "second one. ")
                + "Nothing is wrong: a first pass over a large mail store takes minutes. Poll "
                + "mail_index_status until index_state stops being building or refreshing, and "
                + "do not call mail_index_refresh again to hurry it."
        case "failed":
            guidance =
                "The pass stopped before it finished: \(snapshot.failure ?? "no reason given"). "
                + "The index is unchanged apart from any rows written before it stopped, and it "
                + "still reports itself as incomplete."
        default:
            guidance =
                "The pass finished in \(Int(snapshot.elapsedSeconds)) second(s). The report and "
                + "status below describe the index as it now stands."
        }

        return MailIndexRefreshJob(
            jobId: snapshot.jobID,
            started: outcome.started,
            state: snapshot.state,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
            elapsedSeconds: snapshot.elapsedSeconds,
            fileLimit: fileLimit,
            waitedSeconds: waited,
            progress: snapshot.progress,
            failure: snapshot.failure,
            report: snapshot.report,
            guidance: guidance,
            status: snapshot.report?.status ?? MailIndex.status()
        )
    }

    /// Reads a page out of the index, refusing rather than answering with an
    /// empty list when the index cannot be read or has never completed a
    /// pass. An empty page from an unusable index reads exactly like an empty
    /// mailbox, which is the failure this whole surface exists to avoid.
    private static func indexedMessages(arguments: [String: Value]) throws
        -> MailIndexMessagePage
    {
        let status = MailIndex.status()
        guard status.access == "available" else {
            throw Self.error(status.accessDetail)
        }
        guard status.lastCompleteRefresh != nil else {
            throw Self.error(Self.emptyIndexExplanation(status))
        }
        let mailbox = arguments["mailbox"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let limit = Self.clampedLimit(arguments["limit"]?.intValue)
        let offset = max(arguments["offset"]?.intValue ?? 0, 0)
        let index = MailIndexStore.default
        let messages = try index.messages(inMailbox: mailbox, limit: limit, offset: offset)
        return MailIndexMessagePage(
            messages: messages,
            mailbox: mailbox,
            limit: limit,
            offset: offset,
            returned: messages.count,
            indexedMailboxes: try index.mailboxKeys(),
            status: status
        )
    }

    /// Runs one page of index-backed search.
    ///
    /// The order here is the contract: decide about staleness first, refuse
    /// or refresh and record which, then resolve the caller's mailbox names
    /// into index keys, then query. Nothing is answered from an index that
    /// has never completed a pass, and nothing is answered from a stale one
    /// without the answer saying so.
    private static func indexSearch(arguments: [String: Value]) async throws -> MailSearchPage {
        var status = MailIndex.status()
        guard status.access == "available" else {
            throw Self.error(status.accessDetail)
        }

        let policy = arguments["refresh"]?.stringValue ?? "auto"
        let wait = Double(
            min(
                max(
                    arguments["refresh_wait_seconds"]?.intValue ?? defaultSearchRefreshWaitSeconds,
                    0
                ),
                maximumRefreshWaitSeconds
            )
        )
        let (note, refreshedStatus) = try Self.applyRefreshPolicy(
            policy,
            status: status,
            waitSeconds: wait
        )
        status = refreshedStatus

        guard status.lastCompleteRefresh != nil else {
            throw Self.error(Self.emptyIndexExplanation(status))
        }

        var warnings: [String] = []
        // Display names come from Mail itself. Losing them is survivable —
        // the index keys still identify every mailbox — so a failure here
        // degrades the naming rather than the search.
        var accounts: [MailAccountDescriptor] = []
        do {
            accounts = try await scriptedMailApp.runJSON(
                .jxa,
                script: listAccountsScript,
                as: [MailAccount].self
            )
            .map {
                MailAccountDescriptor(id: $0.id, name: $0.name, emailAddresses: $0.emailAddresses)
            }
        } catch {
            warnings.append(
                "Mail's account list could not be read (\(error.localizedDescription)), so "
                    + "mailboxes are named by their account directory rather than by the account "
                    + "names the other Mail tools take."
            )
        }

        let index = MailIndexStore.default
        let keys = try index.mailboxKeys()
        let named = MailMailboxNaming.names(keys: keys, accounts: accounts)

        var requested = arguments["mailboxes"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        if let single = arguments["mailbox"]?.stringValue, !single.isEmpty {
            requested.append(single)
        }
        let resolution = MailMailboxNaming.resolve(requested, keys: keys, accounts: accounts)
        if !resolution.unmatched.isEmpty {
            throw Self.error(
                MailMailboxNaming.unmatchedExplanation(resolution.unmatched, names: named)
            )
        }
        if named.contains(where: { $0.accountName == nil }) {
            warnings.append(
                "Some indexed mailboxes belong to account directories no live Mail account "
                    + "claims, usually an account that was removed. Their messages are still on "
                    + "disk and are searched; they have no display name and the Apple Events Mail "
                    + "tools cannot open them."
            )
        }

        var request = MailSearchRequest()
        request.query = arguments["query"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let scopeName = arguments["scope"]?.stringValue ?? "all"
        guard let scope = MailSearchScope(rawValue: scopeName) else {
            throw Self.error("scope must be one of: all, subject, sender, body")
        }
        request.scope = scope
        request.mailboxKeys = resolution.keys
        request.since = try Self.searchDate(arguments["since"]?.stringValue, key: "since")
        request.until = try Self.searchDate(arguments["until"]?.stringValue, key: "until")
        request.hasAttachments = Self.triState(
            arguments["attachments"]?.stringValue,
            trueValue: "with",
            falseValue: "without"
        )
        request.isRead = Self.triState(
            arguments["read_state"]?.stringValue,
            trueValue: "read",
            falseValue: "unread"
        )
        request.bodyComplete = Self.triState(
            arguments["body_state"]?.stringValue,
            trueValue: "complete",
            falseValue: "incomplete"
        )
        request.limit = Self.clampedLimit(arguments["limit"]?.intValue)
        request.fullTextAvailable = status.bodySearchAvailable

        if let token = arguments["cursor"]?.stringValue, !token.isEmpty {
            guard let cursor = MailSearchCursor.decode(token) else {
                throw Self.error(
                    MailSearchQueryError.badCursor("\"\(token)\" is not a cursor this build wrote.")
                        .localizedDescription
                )
            }
            request.cursor = cursor
        }

        let bodySearched =
            status.bodySearchAvailable && request.query != nil && scope != .subject
            && scope != .sender
        if request.query != nil, !status.bodySearchAvailable {
            warnings.append(
                "This SQLite has no FTS5 module, so the query matched subject and sender by "
                    + "substring only. Message bodies were not searched."
            )
        }
        if status.incompleteBodyCount > 0, bodySearched {
            warnings.append(
                "\(status.incompleteBodyCount) indexed message(s) have bodies that were never "
                    + "downloaded to this Mac. Their text could not be matched, so a message whose "
                    + "only match is in an undownloaded body will not appear. Filter with "
                    + "body_state=incomplete to see them."
            )
        }

        let result = try index.search(request)
        return MailSearchPage(
            hits: result.hits,
            returned: result.hits.count,
            limit: request.limit,
            hasMore: result.hasMore,
            nextCursor: result.nextCursor,
            query: request.query,
            scope: scope.rawValue,
            searchedMailboxes: resolution.matched.isEmpty ? named : resolution.matched,
            indexedMailboxes: named,
            bodySearched: bodySearched,
            undatedExcluded: result.undatedExcluded,
            warnings: warnings + status.warnings,
            refresh: note,
            status: status
        )
    }

    /// Decides what to do about a stale index, and says what it decided.
    ///
    /// `auto` survives, but it no longer means "block until the index is
    /// current". That default was written for an index that refreshes
    /// incrementally in a second or two, and it was correct for every case
    /// except the one that matters most: the first one. On a real store the
    /// first `auto` search started a pass that could not finish inside any
    /// client timeout, so the feature was unreachable through its own front
    /// door.
    ///
    /// Two rules fix it without giving up the convenience:
    ///
    ///   - An index with no completed pass is never searched. The call starts
    ///     a pass and refuses with the job id, because answering "no results"
    ///     from an empty index is the dishonesty this whole surface exists to
    ///     remove, and waiting for it is the timeout.
    ///   - A stale-but-complete index is refreshed with a wait budget. If the
    ///     pass finishes inside it the answer is fresh; if it does not, the
    ///     answer comes from the index as it stands and says a pass is still
    ///     running. Either way the call returns.
    private static func applyRefreshPolicy(
        _ policy: String,
        status: MailIndexStatus,
        waitSeconds: Double
    ) throws -> (MailSearchRefreshNote, MailIndexStatus) {
        let needsRefresh = status.lastCompleteRefresh == nil || status.stale
        let coordinator = MailIndexJobCoordinator.shared

        func note(
            performed: Bool,
            reason: String,
            snapshot: MailIndexJobSnapshot? = nil
        ) -> MailSearchRefreshNote {
            MailSearchRefreshNote(
                policy: policy,
                performed: performed,
                reason: reason,
                durationSeconds: snapshot?.report?.durationSeconds,
                inserted: snapshot?.report?.inserted,
                updated: snapshot?.report?.updated,
                removed: snapshot?.report?.removed,
                scanComplete: snapshot?.report?.scanComplete,
                jobId: snapshot?.jobID,
                stillRunning: snapshot.map(\.isRunning)
            )
        }

        /// Starts or joins a pass, waits out the budget, and reports from
        /// wherever it got to.
        func bounded(_ reason: String) throws -> (MailSearchRefreshNote, MailIndexStatus) {
            let outcome = try coordinator.startRefresh(fileLimit: maximumIndexFileLimit)
            var snapshot = outcome.snapshot
            if waitSeconds > 0, snapshot.isRunning {
                snapshot = coordinator.wait(upTo: waitSeconds) ?? snapshot
            }
            if let report = snapshot.report, !snapshot.isRunning {
                return (note(performed: true, reason: reason, snapshot: snapshot), report.status)
            }
            let stillRunning =
                reason
                + (outcome.started
                    ? " The pass did not finish inside \(Int(waitSeconds)) second(s), so this "
                    : " A pass was already running, and it did not finish inside "
                        + "\(Int(waitSeconds)) second(s), so this ")
                + "answer comes from the index as it stood. Poll mail_index_status with job "
                + "\(snapshot.jobID) and search again when it reports a completed pass."
            return (
                note(performed: false, reason: stillRunning, snapshot: snapshot),
                MailIndex.status()
            )
        }

        /// The index has never completed a pass. Start one, refuse to answer.
        func refuseAndBuild() throws -> Never {
            let outcome = try coordinator.startRefresh(fileLimit: maximumIndexFileLimit)
            throw Self.error(
                "INDEX_BUILDING: the local mail index has never completed a full pass, so it "
                    + "cannot say what is or is not in your mail, and building it takes minutes "
                    + "on a large store rather than the seconds a search can wait. "
                    + (outcome.started
                        ? "A pass (\(outcome.snapshot.jobID)) has been started for you. "
                        : "A pass (\(outcome.snapshot.jobID)) was already running. ")
                    + "Poll mail_index_status until index_state is no longer building, then "
                    + "search again."
            )
        }

        switch policy {
        case "always":
            if status.lastCompleteRefresh == nil { try refuseAndBuild() }
            return try bounded("Refreshed because refresh=always was requested.")
        case "never":
            guard needsRefresh else {
                return (
                    note(
                        performed: false,
                        reason: "The index was already current, so nothing was refreshed."
                    ),
                    status
                )
            }
            throw Self.error(
                "INDEX_STALE: refresh=never was requested and the index is not current. "
                    + status.completeness
                    + " Run mail_index_refresh, or search again with refresh=auto."
            )
        case "auto":
            guard needsRefresh else {
                return (
                    note(
                        performed: false,
                        reason:
                            "The index was refreshed \(status.ageSeconds ?? 0) second(s) ago, "
                            + "inside its freshness window, so it was used as it stood."
                    ),
                    status
                )
            }
            if status.lastCompleteRefresh == nil { try refuseAndBuild() }
            return try bounded(
                "Refreshed because the index was \(status.ageSeconds ?? 0) second(s) old, past "
                    + "its freshness window."
            )
        default:
            throw Self.error("refresh must be one of: auto, never, always")
        }
    }

    /// `YYYY-MM-DD` or ISO 8601. A date that will not parse is refused rather
    /// than dropped, because a silently ignored filter returns more mail than
    /// the caller asked for and looks like a working search.
    private static func searchDate(_ value: String?, key: String) throws -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        let plain = DateFormatter()
        plain.locale = Locale(identifier: "en_US_POSIX")
        plain.timeZone = TimeZone.current
        plain.dateFormat = "yyyy-MM-dd"
        if let date = plain.date(from: value) { return date }
        throw Self.error(
            "\(key) must be a date as YYYY-MM-DD or ISO 8601; \"\(value)\" is neither."
        )
    }

    /// Reads a three-valued filter argument: a value, its opposite, or no
    /// filter at all. A tri-state is spelled out rather than left as an
    /// optional boolean because a client that defaults booleans to false
    /// would otherwise silently ask for unread mail only.
    private static func triState(
        _ value: String?,
        trueValue: String,
        falseValue: String
    ) -> Bool? {
        switch value {
        case trueValue: return true
        case falseValue: return false
        default: return nil
        }
    }

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
        let results = try await scriptedMailApp.runJSON(
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
                "attachments": .array(
                    description:
                        "Files to attach; max \(MailComposeAttachments.maximumCount), "
                        + "\(MailComposeAttachments.maximumAttachmentBytes / (1024 * 1024))MB each and "
                        + "\(MailComposeAttachments.maximumTotalBytes / (1024 * 1024))MB in total. Each "
                        + "entry takes either \"path\" (a file inside a folder the user shared with "
                        + "Apple Core; see filesystem_roots) or \"base64\" plus \"name\" (bytes the "
                        + "client already holds, which is the route a remote client must use).",
                    items: .object(
                        properties: [
                            "path": .string(
                                description:
                                    "Absolute path to an existing file inside a shared folder"
                            ),
                            "base64": .string(
                                description: "Base64-encoded file contents"
                            ),
                            "name": .string(
                                description:
                                    "Filename the recipient sees. Required with base64; defaults to the path's filename"
                            ),
                        ],
                        additionalProperties: false
                    )
                ),
            ],
            required: requireTo ? ["to", "subject", "body"] : ["subject", "body"],
            additionalProperties: false
        )
    }

    /// Reads the `attachments` argument into specs, without touching disk.
    private static func attachmentSpecs(
        from arguments: [String: Value]
    ) throws -> [MailComposeAttachmentSpec] {
        guard let values = arguments["attachments"]?.arrayValue else { return [] }
        return try values.map { value in
            guard case let .object(fields) = value else {
                throw Self.error("attachments must contain objects with path or base64")
            }
            return MailComposeAttachmentSpec(
                name: fields["name"]?.stringValue,
                path: fields["path"]?.stringValue,
                base64: fields["base64"]?.stringValue
            )
        }
    }

    /// Validates attachments against the shared-folder allowlist and the size
    /// caps. The allowlist is the filesystem surface's, read fresh, because
    /// the user can unshare a folder while a client is connected.
    private static func prepareAttachments(
        from arguments: [String: Value]
    ) throws -> [MailPreparedAttachment] {
        let specs = try Self.attachmentSpecs(from: arguments)
        guard !specs.isEmpty else { return [] }
        let roots = ServingConfigManager.load().filesystemRoots ?? []
        return try MailComposeAttachments.prepare(specs) { path in
            try FilesystemAccess.resolve(
                requested: path,
                roots: roots,
                requiringWrite: false
            )
        }
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
        let attachments = try Self.prepareAttachments(from: arguments)

        return try await Self.compose(
            action: action,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: account,
            attachments: attachments
        )
    }

    /// Stages any inline attachment bytes, runs the compose script, and folds
    /// what Mail reports back into the result.
    ///
    /// The scratch directory is removed on every exit, including the throwing
    /// ones, so inline attachment bytes never outlive the call that carried
    /// them.
    private static func compose(
        action: String,
        to: [String],
        cc: [String],
        bcc: [String],
        subject: String,
        body: String,
        account: String?,
        attachments: [MailPreparedAttachment]
    ) async throws -> MailComposeResult {
        var staging: URL?
        defer {
            if let staging { try? FileManager.default.removeItem(at: staging) }
        }
        var paths: [String] = []
        if !attachments.isEmpty {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-core-mail-compose-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            staging = directory
            paths = try MailComposeAttachments.stage(attachments, in: directory)
        }

        let payload = ComposePayload(
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: account,
            attachmentPaths: paths,
            attachmentNames: attachments.map(\.name)
        )
        let result = try await scriptedMailApp.runJSON(
            .jxa,
            script: composeScript,
            arguments: [try Self.encodeJSON(payload), action],
            as: MailComposeScriptResult.self,
            timeout: 180
        )

        // Report the names Mail ended up with, but keep the sizes and types
        // this side measured: Mail will not tell us either for an outgoing
        // message, and a caller inspecting a draft wants both.
        let summaries = result.attachments.enumerated().map { offset, name -> MailComposeAttachmentSummary in
            let measured = offset < attachments.count ? attachments[offset] : nil
            return MailComposeAttachmentSummary(
                name: name.isEmpty ? (measured?.name ?? "attachment") : name,
                mimeType: measured?.mimeType
                    ?? MailComposeAttachments.mimeType(forFileName: name),
                byteCount: measured?.byteCount ?? 0
            )
        }
        return MailComposeResult(
            status: result.status,
            subject: result.subject,
            to: result.to,
            cc: cc,
            bcc: bcc,
            account: account,
            body: result.body,
            attachmentCount: summaries.count,
            attachments: summaries
        )
    }

    // MARK: - Threads

    /// Gathers candidates through Mail, then hands the decision to
    /// MailThreadResolver.
    ///
    /// Behaviour change for existing clients: this no longer returns every
    /// same-subject message in one mailbox. It returns the actual
    /// conversation, which can span mailboxes, and it says in `matching`
    /// whether headers or the subject fallback decided it.
    private static func getThread(
        account: String,
        mailbox: String,
        id: Int,
        limit: Int
    ) async throws -> MailThreadResult {
        let gathered = try await scriptedMailApp.runJSON(
            .jxa,
            script: threadCandidatesScript,
            arguments: [account, mailbox, String(id), String(maximumThreadCandidates)],
            as: MailThreadCandidates.self,
            timeout: 180
        )

        let resolution = MailThreadResolver.resolve(
            anchorID: id,
            candidates: gathered.candidates.map {
                MailThreadCandidate(
                    id: $0.id,
                    mailbox: $0.mailbox,
                    accountName: $0.accountName,
                    subject: $0.subject,
                    rawHeaders: $0.rawHeaders
                )
            }
        )

        var rowsByID: [Int: MailThreadCandidateRow] = [:]
        for row in gathered.candidates { rowsByID[row.id] = row }

        let messages = resolution.members.prefix(limit).compactMap {
            member -> MailThreadMessage? in
            guard let row = rowsByID[member.id] else { return nil }
            return MailThreadMessage(
                id: row.id,
                subject: row.subject,
                sender: row.sender,
                dateReceived: row.dateReceived,
                isRead: row.isRead,
                mailbox: member.mailbox,
                accountName: member.accountName,
                messageId: member.messageId
            )
        }

        return MailThreadResult(
            subjectRoot: resolution.subjectRoot,
            matching: resolution.matching.rawValue,
            approximate: resolution.approximate,
            note: resolution.note,
            mailboxesSearched: gathered.mailboxesSearched,
            candidatesConsidered: gathered.candidates.count,
            messages: Array(messages)
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
        let attachments = try await scriptedMailApp.runJSON(
            .jxa,
            script: listAttachmentsScript,
            arguments: [account, mailbox, String(id)],
            as: [MailAttachmentInfo].self,
            timeout: 120
        )
        let attachment = try Self.selectAttachment(selector, from: attachments, messageID: id)

        let directory = try AttachmentSaveDirectory.resolve(saveDir)
        let destination = Self.uniqueDestination(
            in: directory,
            fileName: Self.sanitizedFileName(attachment.name)
        )

        _ = try await scriptedMailApp.runJSON(
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
    /// Stages one attachment into a scratch directory, reads the bytes back,
    /// and takes the directory with it on the way out.
    ///
    /// Mail will only hand an attachment to a file path, which is exactly the
    /// problem this tool exists to solve: a path on the serving Mac is not a
    /// result a remote client can use. The staging is an implementation
    /// detail the caller never sees, and the `defer` is what keeps it that
    /// way even when the read or the size check throws.
    private static func fetchAttachment(
        account: String,
        mailbox: String,
        id: Int,
        selector: String
    ) async throws -> MailAttachmentData {
        let attachments = try await scriptedMailApp.runJSON(
            .jxa,
            script: listAttachmentsScript,
            arguments: [account, mailbox, String(id)],
            as: [MailAttachmentInfo].self,
            timeout: 60
        )
        let attachment = try Self.selectAttachment(selector, from: attachments, messageID: id)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-mail-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let staged = staging.appendingPathComponent(
            Self.sanitizedFileName(attachment.name)
        )
        _ = try await scriptedMailApp.runJSON(
            .jxa,
            script: fetchAttachmentScript,
            arguments: [account, mailbox, String(id), String(attachment.index), staged.path],
            as: MailSaveAttachmentResult.self,
            timeout: 120
        )

        let data = try Data(contentsOf: staged)
        guard data.count <= maximumInlineAttachmentBytes else {
            throw Self.error(
                "TOO_LARGE: \"\(attachment.name)\" is \(data.count / 1024)KB, over the "
                    + "\(maximumInlineAttachmentBytes / 1024)KB inline limit. "
                    + "Use mail_save_attachment to write it to disk instead."
            )
        }

        log.notice("Fetched mail attachment at index \(attachment.index, privacy: .public)")
        return MailAttachmentData(
            messageId: id,
            mailbox: mailbox,
            accountName: account,
            attachmentIndex: attachment.index,
            attachmentName: attachment.name,
            mimeType: attachment.mimeType
                ?? MailComposeAttachments.mimeType(forFileName: attachment.name),
            byteCount: data.count,
            base64: data.base64EncodedString()
        )
    }

    /// Index-or-name selection, shared by the save and fetch paths so the two
    /// cannot drift into resolving the same selector differently.
    private static func selectAttachment(
        _ selector: String,
        from attachments: [MailAttachmentInfo],
        messageID: Int
    ) throws -> MailAttachmentInfo {
        guard !attachments.isEmpty else {
            throw Self.error("NOT_FOUND: message \(messageID) has no attachments")
        }
        if let index = Int(selector) {
            guard let match = attachments.first(where: { $0.index == index }) else {
                throw Self.error(
                    "NOT_FOUND: no attachment at index \(index) (message has \(attachments.count))"
                )
            }
            return match
        }
        guard let match = attachments.first(where: { $0.name == selector }) else {
            throw Self.error("NOT_FOUND: no attachment named \(selector)")
        }
        return match
    }

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
    // The store itself lives in Shared/MailTemplateStore.swift so its
    // not-found contract can be tested.

    private static func useTemplate(arguments: [String: Value]) async throws -> MailComposeResult {
        let name = try Self.requiredString("name", from: arguments)
        let template = try MailTemplateStore.default.get(name: name)

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

        return try await Self.compose(
            action: action == "send" ? "send" : "draft",
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            body: body,
            account: arguments["account"]?.stringValue,
            attachments: try Self.prepareAttachments(from: arguments)
        )
    }

    struct MailSelectedMessage: Codable {
        let id: Int
        let subject: String?
        let sender: String?
        let dateSent: String?
        let readStatus: Bool?
        let mailbox: String?
        let account: String?
    }

    struct MailCheckResult: Codable {
        let status: String
    }

    private struct ComposePayload: Encodable {
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let body: String
        let account: String?
        let attachmentPaths: [String]
        let attachmentNames: [String]
    }
}
