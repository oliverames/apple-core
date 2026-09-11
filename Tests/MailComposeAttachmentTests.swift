import Foundation
import Testing

/// Compose used to take a plain-text body and nothing else, so an agent could
/// describe a file but never send one. These tests pin the two bounded ways in
/// — a path inside a shared folder, or inline base64 under a cap — and pin the
/// refusals, because the failure that matters here is an attachment path
/// escaping the folders the user actually shared.
@Suite("Mail compose attachments")
struct MailComposeAttachmentTests {
    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-mail-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Stands in for the shared-root policy: anything under `root` resolves,
    /// anything else is refused, exactly as FilesystemAccess behaves.
    private static func resolver(root: URL) -> (String) throws -> URL {
        { path in
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let base = root.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path == base.path || url.path.hasPrefix(base.path + "/") else {
                throw NSError(
                    domain: "TestRootError",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "outside shared folders"]
                )
            }
            return url
        }
    }

    private static func refusingResolver(_ path: String) throws -> URL {
        throw NSError(
            domain: "TestRootError",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "outside shared folders"]
        )
    }

    // MARK: - Path attachments

    @Test("A file inside a shared folder is attached by reference, with size and MIME type")
    func pathInsideSharedRoot() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.pdf")
        try Data(repeating: 0x41, count: 2048).write(to: file)

        let prepared = try MailComposeAttachments.prepare(
            [MailComposeAttachmentSpec(path: file.path)],
            resolvePath: Self.resolver(root: root)
        )

        #expect(prepared.count == 1)
        #expect(prepared[0].name == "report.pdf")
        #expect(prepared[0].mimeType == "application/pdf")
        #expect(prepared[0].byteCount == 2048)
        #expect(prepared[0].source == .file(file))
    }

    @Test("A path outside every shared folder is refused")
    func pathOutsideSharedRoots() throws {
        #expect(throws: (any Error).self) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(path: "/etc/hosts")],
                resolvePath: Self.refusingResolver
            )
        }
    }

    @Test("A directory is not an attachment")
    func directoryIsRefused() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        #expect(throws: MailComposeAttachmentError.notAFile(nested.path)) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(path: nested.path)],
                resolvePath: Self.resolver(root: root)
            )
        }
    }

    // MARK: - Inline attachments

    @Test("Inline base64 round-trips to the exact bytes the client sent")
    func inlineBase64RoundTrip() throws {
        let payload = Data("column,value\nalpha,1\n".utf8)
        let prepared = try MailComposeAttachments.prepare(
            [
                MailComposeAttachmentSpec(
                    name: "data.csv",
                    base64: payload.base64EncodedString()
                )
            ],
            resolvePath: Self.refusingResolver
        )

        #expect(prepared[0].mimeType == "text/csv")
        #expect(prepared[0].byteCount == payload.count)
        #expect(prepared[0].source == .inline(payload))
    }

    @Test("Inline bytes need a name, because the recipient sees a filename")
    func inlineWithoutName() {
        #expect(throws: MailComposeAttachmentError.missingName) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(base64: "aGVsbG8=")],
                resolvePath: Self.refusingResolver
            )
        }
    }

    @Test("Text that is not base64 is refused rather than attached as garbage")
    func invalidBase64() {
        #expect(throws: MailComposeAttachmentError.invalidBase64("note.txt")) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(name: "note.txt", base64: "not base64 !!!")],
                resolvePath: Self.refusingResolver
            )
        }
    }

    // MARK: - Bounds

    @Test("Exactly one source per attachment")
    func sourceExclusivity() {
        #expect(throws: MailComposeAttachmentError.sourceAmbiguous) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(name: "a.txt", path: "/tmp/a.txt", base64: "aGk=")],
                resolvePath: Self.refusingResolver
            )
        }
        #expect(throws: MailComposeAttachmentError.sourceMissing) {
            try MailComposeAttachments.prepare(
                [MailComposeAttachmentSpec(name: "a.txt")],
                resolvePath: Self.refusingResolver
            )
        }
    }

    @Test("The per-message attachment count is capped")
    func countCap() {
        let specs = (0 ... MailComposeAttachments.maximumCount).map {
            MailComposeAttachmentSpec(name: "f\($0).txt", base64: "aGk=")
        }
        #expect(throws: MailComposeAttachmentError.tooMany(MailComposeAttachments.maximumCount)) {
            try MailComposeAttachments.prepare(specs, resolvePath: Self.refusingResolver)
        }
    }

    @Test("The per-message byte total is capped across several attachments")
    func totalByteCap() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Three files that each clear the per-attachment limit but together do not.
        var specs: [MailComposeAttachmentSpec] = []
        let chunk = MailComposeAttachments.maximumAttachmentBytes
        for index in 0 ..< 3 {
            let file = root.appendingPathComponent("chunk\(index).bin")
            try Data(repeating: 0, count: chunk).write(to: file)
            specs.append(MailComposeAttachmentSpec(path: file.path))
        }

        #expect(throws: (any Error).self) {
            try MailComposeAttachments.prepare(specs, resolvePath: Self.resolver(root: root))
        }
    }

    @Test("Names cannot carry a path component")
    func nameSanitization() {
        #expect(MailComposeAttachments.sanitizedFileName("../../etc/passwd") == "attachment.._.._etc_passwd")
        #expect(MailComposeAttachments.sanitizedFileName("") == "attachment")
        #expect(MailComposeAttachments.sanitizedFileName("report.pdf") == "report.pdf")
    }

    @Test("An unknown extension falls back to a generic MIME type")
    func mimeFallback() {
        #expect(MailComposeAttachments.mimeType(forFileName: "blob") == "application/octet-stream")
        #expect(MailComposeAttachments.mimeType(forFileName: "photo.png") == "image/png")
    }

    // MARK: - Staging

    @Test("Staging writes inline bytes to disk and leaves shared files where they are")
    func staging() throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: existing)

        let staging = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let payload = Data("inline".utf8)
        let prepared = try MailComposeAttachments.prepare(
            [
                MailComposeAttachmentSpec(path: existing.path),
                MailComposeAttachmentSpec(name: "note.txt", base64: payload.base64EncodedString()),
            ],
            resolvePath: Self.resolver(root: root)
        )
        let paths = try MailComposeAttachments.stage(prepared, in: staging)

        #expect(paths[0] == existing.path)
        #expect(paths[1].hasPrefix(staging.path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])) == payload)
        // The shared file was referenced, never copied into staging.
        #expect(!paths[0].hasPrefix(staging.path))
    }

    @Test("Two inline attachments sharing a name both survive staging")
    func stagingKeepsDuplicateNames() throws {
        let staging = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }

        let prepared = try MailComposeAttachments.prepare(
            [
                MailComposeAttachmentSpec(name: "same.txt", base64: Data("one".utf8).base64EncodedString()),
                MailComposeAttachmentSpec(name: "same.txt", base64: Data("two".utf8).base64EncodedString()),
            ],
            resolvePath: Self.refusingResolver
        )
        let paths = try MailComposeAttachments.stage(prepared, in: staging)

        #expect(paths[0] != paths[1])
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[0])) == Data("one".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: paths[1])) == Data("two".utf8))
        #expect(URL(fileURLWithPath: paths[0]).lastPathComponent == "same.txt")
        #expect(URL(fileURLWithPath: paths[1]).lastPathComponent == "same.txt")
    }
}
