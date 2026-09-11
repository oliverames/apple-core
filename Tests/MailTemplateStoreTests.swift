import Foundation
import Testing

/// The September 10 acceptance sweep reported that `mail_get_template` answers a
/// missing name with an empty result before any template exists, but with a
/// clean `NOT_FOUND` after one is deleted. A caller that has to read "empty" as
/// "absent" cannot tell a missing template from a broken read, so these tests
/// pin the same error in every state.
@Suite("Mail template store")
struct MailTemplateStoreTests {
    private static func makeStore() throws -> MailTemplateStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-mail-templates-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MailTemplateStore(
            fileURL: directory.appendingPathComponent("mail_templates.json")
        )
    }

    @Test("A missing name is not found when the store file was never created")
    func missingNameWithoutStoreFile() throws {
        let store = try Self.makeStore()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(throws: MailTemplateStoreError.notFound("absent")) {
            try store.get(name: "absent")
        }
        #expect(try store.list().isEmpty)
    }

    @Test("A missing name is not found when the store holds other templates")
    func missingNameWithPopulatedStore() throws {
        let store = try Self.makeStore()
        try store.save(name: "seed", subject: "Seed", body: "Body")
        #expect(throws: MailTemplateStoreError.notFound("absent")) {
            try store.get(name: "absent")
        }
    }

    @Test("A saved template round-trips, and is not found again after deletion")
    func saveGetDeleteGet() throws {
        let store = try Self.makeStore()
        try store.save(name: "fixture", subject: "Subject {{code}}", body: "Body {{code}}")

        let fetched = try store.get(name: "fixture")
        #expect(fetched.subject == "Subject {{code}}")
        #expect(fetched.body == "Body {{code}}")

        try store.delete(name: "fixture")

        #expect(throws: MailTemplateStoreError.notFound("fixture")) {
            try store.get(name: "fixture")
        }
        #expect(try store.list().isEmpty)
    }

    @Test("Deleting a name that is not there is not found, not a silent success")
    func deleteMissingName() throws {
        let store = try Self.makeStore()
        #expect(throws: MailTemplateStoreError.notFound("absent")) {
            try store.delete(name: "absent")
        }
    }

    @Test("Overwriting by name keeps the creation timestamp and replaces the content")
    func overwritePreservesCreation() throws {
        let store = try Self.makeStore()
        let first = try store.save(name: "fixture", subject: "One", body: "First")
        let second = try store.save(name: "fixture", subject: "Two", body: "Second")

        #expect(second.createdAt == first.createdAt)
        #expect(second.subject == "Two")
        #expect(second.body == "Second")
        #expect(try store.list().count == 1)
    }

    @Test("The store refuses oversized templates and keeps the existing content")
    func refusesOversizedTemplate() throws {
        let store = try Self.makeStore()
        try store.save(name: "fixture", subject: "Keep", body: "Keep")

        let oversized = String(repeating: "x", count: MailTemplateStore.maximumBytes + 1)
        #expect(throws: MailTemplateStoreError.tooLarge(MailTemplateStore.maximumBytes)) {
            try store.save(name: "fixture", subject: "Replace", body: oversized)
        }
        #expect(try store.get(name: "fixture").body == "Keep")
    }

    @Test("Listing is ordered case insensitively by name")
    func listingOrder() throws {
        let store = try Self.makeStore()
        for name in ["beta", "Alpha", "gamma"] {
            try store.save(name: name, subject: name, body: name)
        }
        #expect(try store.list().map(\.name) == ["Alpha", "beta", "gamma"])
    }

    @Test("The store file is written with owner-only permissions")
    func storePermissions() throws {
        let store = try Self.makeStore()
        try store.save(name: "fixture", subject: "Subject", body: "Body")

        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect(attributes[.posixPermissions] as? NSNumber == 0o600)
    }
}
