// SPDX-License-Identifier: GPL-3.0-or-later
//
// Which mailbox is the trash, when the trash is not called "Trash".
//
// Every mutating tool in this service takes a mailbox *name*: move these
// messages to "Archive", delete from "INBOX". That works right up until the
// account is a German iCloud account whose trash is "Papierkorb", or a Gmail
// account whose archive is "[Gmail]/All Mail" and whose trash is
// "[Gmail]/Trash", or an Exchange account that spells its sent mailbox "Sent
// Items". A caller cannot guess those, and guessing wrong on a delete is not
// a recoverable mistake.
//
// Mail knows the answer and half-exposes it. The `message viewer` class has
// `inbox`, `drafts`, `sent`, `trash`, `junk` and `outbox` properties, but they
// are the viewer's *unified* mailboxes, not per-account ones, so they cannot
// tell you what to pass to a tool scoped to one account. The per-account
// answer has to be derived from the account's own mailbox list, which is what
// this file does.
//
// The matching is alias-table plus scoring, and three rules keep it honest:
//
//   - An exact match on a known name beats a prefix match, which beats a
//     contains match. "Sent" beats "Sent Items Archive" for the sent role.
//   - Every answer carries the confidence it was reached with, and a role
//     with no candidate is absent from the result rather than filled in with
//     the English default. A caller told "trash is Trash" when the account
//     has no Trash will delete into a mailbox that does not exist.
//   - Nothing here writes, moves, or deletes. It maps names to roles and the
//     caller does what it likes with the mapping.
//
// The alias table covers English, the localisations Apple ships for iCloud,
// and the provider-specific spellings for Gmail, Exchange/Outlook, Yahoo and
// Fastmail. It is a lookup table and it is meant to grow.

import Foundation

/// A well-known purpose a mailbox can serve.
enum MailMailboxRole: String, CaseIterable, Sendable, Codable, Equatable {
    case inbox
    case drafts
    case sent
    case trash
    case junk
    case archive
    case outbox
}

/// How the role was arrived at.
enum MailMailboxRoleConfidence: String, Sendable, Codable, Equatable {
    /// The mailbox name is a known name for this role.
    case exact
    /// The name begins with, or contains, a known name for this role.
    case heuristic
}

/// One resolved role for one account.
struct MailMailboxRoleMatch: Sendable, Codable, Equatable {
    let role: MailMailboxRole
    /// The mailbox name to pass to the other Mail tools.
    let mailbox: String
    let confidence: MailMailboxRoleConfidence
    /// Other mailboxes that also matched this role, best first.
    let alternatives: [String]
}

enum MailMailboxRoles {
    /// Known names per role, lowercased. Order within a role does not matter;
    /// scoring, not position, decides between two matches.
    static let aliases: [MailMailboxRole: [String]] = [
        .inbox: [
            "inbox", "in", "boîte de réception", "boite de reception", "posteingang",
            "bandeja de entrada", "posta in arrivo", "caixa de entrada", "inkorg",
            "postvak in", "innboks", "indbakke", "受信", "收件箱", "받은편지함",
        ],
        .drafts: [
            "drafts", "draft", "brouillons", "entwürfe", "entwurfe", "borradores",
            "bozze", "rascunhos", "utkast", "concepten", "kladder", "下書き", "草稿",
            "임시보관함",
        ],
        .sent: [
            "sent", "sent messages", "sent items", "sent mail", "messages envoyés",
            "messages envoyes", "envoyés", "gesendet", "enviados", "posta inviata",
            "skickat", "verzonden items", "sendt", "sendte", "送信済み", "已发送",
            "보낸편지함",
        ],
        .trash: [
            "trash", "deleted messages", "deleted items", "bin", "corbeille",
            "papierkorb", "papelera", "cestino", "lixeira", "papperskorgen",
            "prullenmand", "slettet", "ゴミ箱", "已删除邮件", "지운편지함",
        ],
        .junk: [
            "junk", "junk e-mail", "junk email", "spam", "bulk mail", "indésirables",
            "indesirables", "courrier indésirable", "werbung", "correo no deseado",
            "posta indesiderata", "skräppost", "ongewenste e-mail", "迷惑メール",
            "垃圾邮件", "스팸",
        ],
        .archive: [
            "archive", "archives", "all mail", "archiv", "archivo", "archivio",
            "arkiv", "arquivo", "アーカイブ", "所有邮件",
        ],
        .outbox: ["outbox", "boîte d'envoi", "postausgang", "bandeja de salida"],
    ]

    /// Resolves as many roles as the account's mailbox names support.
    ///
    /// `mailboxes` is the account's mailbox names exactly as Mail reports
    /// them, including any provider prefix; the prefix is stripped only for
    /// matching, never in the returned name, because the returned name is what
    /// gets handed back to Mail.
    static func resolve(mailboxes: [String]) -> [MailMailboxRoleMatch] {
        var matches: [MailMailboxRoleMatch] = []
        for role in MailMailboxRole.allCases {
            let scored =
                mailboxes
                .compactMap { name -> (name: String, score: Int)? in
                    guard let score = score(name: name, role: role) else { return nil }
                    return (name, score)
                }
                // Higher score first; ties broken by the shorter name, which
                // is the plainer one ("Sent" over "Sent Items Archive"), then
                // alphabetically so the result is stable across runs.
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    if $0.name.count != $1.name.count { return $0.name.count < $1.name.count }
                    return $0.name < $1.name
                }
            guard let best = scored.first else { continue }
            matches.append(
                MailMailboxRoleMatch(
                    role: role,
                    mailbox: best.name,
                    confidence: best.score >= exactScore ? .exact : .heuristic,
                    alternatives: scored.dropFirst().map(\.name)
                )
            )
        }
        return matches
    }

    /// The mailbox name for one role, or nil when the account has none.
    static func mailbox(for role: MailMailboxRole, in mailboxes: [String]) -> String? {
        resolve(mailboxes: mailboxes).first { $0.role == role }?.mailbox
    }

    private static let exactScore = 100

    /// Scores one name against one role, or nil when it does not match at all.
    private static func score(name: String, role: MailMailboxRole) -> Int? {
        guard let candidates = aliases[role] else { return nil }
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return nil }
        var best: Int?
        for alias in candidates {
            let score: Int
            if normalized == alias {
                score = exactScore
            } else if normalized.hasPrefix(alias + " ") || normalized.hasPrefix(alias + "-") {
                score = 60 + alias.count
            } else if normalized.contains(alias) {
                // A contains match on a very short alias is noise: "in" is
                // inside "Invoices". Require the alias to carry some weight.
                guard alias.count >= 4 else { continue }
                score = 30 + alias.count
            } else {
                continue
            }
            best = max(best ?? 0, score)
        }
        return best
    }

    /// Lowercases, strips a provider prefix, and drops decoration.
    ///
    /// Gmail hands back `[Gmail]/All Mail`; Exchange sometimes nests under the
    /// account name. Only the last path component names the role.
    private static func normalize(_ name: String) -> String {
        var value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = value.lastIndex(of: "/") {
            value = String(value[value.index(after: slash)...])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
