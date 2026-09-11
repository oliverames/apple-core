import Foundation

/// Templates are Apple Core's own data, because Mail has no template concept.
/// They live as JSON at ~/.config/apple-core/mail_templates.json with 0600
/// permissions. APPLECORE_CONFIG_HOME overrides the directory so tests never
/// touch the real store.
///
/// This lives in Shared so the not-found contract is testable. The September 10
/// acceptance sweep reported that a missing name answered with an empty result
/// before any template existed, but with a clean NOT_FOUND after one was
/// deleted. A caller that has to read "empty" as "absent" cannot tell a missing
/// template from a broken read, so both paths raise the same error here.
struct MailTemplate: Codable, Sendable, Equatable {
    let name: String
    var subject: String
    var body: String
    var createdAt: String
    var updatedAt: String
}

struct MailTemplateSummary: Codable, Sendable, Equatable {
    let name: String
    let subject: String
    let updatedAt: String
}

enum MailTemplateStoreError: LocalizedError, Equatable {
    case notFound(String)
    case tooLarge(Int)
    case storeFull(Int)

    var errorDescription: String? {
        switch self {
        case let .notFound(name):
            return "NOT_FOUND: no template named \(name)"
        case let .tooLarge(limit):
            return "template exceeds the size limit of \(limit) bytes"
        case let .storeFull(limit):
            return "template store is full (limit \(limit))"
        }
    }
}

struct MailTemplateStore: Sendable {
    static let maximumCount = 200
    static let maximumBytes = 64 * 1024

    let fileURL: URL

    /// Resolved per call rather than once, because the environment override is
    /// what lets a test point the store somewhere disposable.
    static var `default`: MailTemplateStore {
        let configDirectory: URL
        if let override = ProcessInfo.processInfo.environment["APPLECORE_CONFIG_HOME"],
            !override.isEmpty
        {
            configDirectory = URL(
                fileURLWithPath: (override as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/apple-core", isDirectory: true)
        }
        return MailTemplateStore(
            fileURL: configDirectory.appendingPathComponent("mail_templates.json")
        )
    }

    func load() throws -> [String: MailTemplate] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return [:]
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([String: MailTemplate].self, from: data)
    }

    func store(_ templates: [String: MailTemplate]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(templates).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    /// Absence is an error in every state, including a store file that was
    /// never created.
    func get(name: String) throws -> MailTemplate {
        guard let template = try load()[name] else {
            throw MailTemplateStoreError.notFound(name)
        }
        return template
    }

    func list() throws -> [MailTemplateSummary] {
        try load().values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { MailTemplateSummary(name: $0.name, subject: $0.subject, updatedAt: $0.updatedAt) }
    }

    @discardableResult
    func save(name: String, subject: String, body: String) throws -> MailTemplate {
        guard subject.utf8.count + body.utf8.count <= Self.maximumBytes else {
            throw MailTemplateStoreError.tooLarge(Self.maximumBytes)
        }
        var templates = try load()
        if templates[name] == nil, templates.count >= Self.maximumCount {
            throw MailTemplateStoreError.storeFull(Self.maximumCount)
        }
        let now = ISO8601DateFormatter().string(from: Date())
        var template =
            templates[name]
            ?? MailTemplate(name: name, subject: subject, body: body, createdAt: now, updatedAt: now)
        template.subject = subject
        template.body = body
        template.updatedAt = now
        templates[name] = template
        try store(templates)
        return template
    }

    func delete(name: String) throws {
        var templates = try load()
        guard templates.removeValue(forKey: name) != nil else {
            throw MailTemplateStoreError.notFound(name)
        }
        try store(templates)
    }
}
