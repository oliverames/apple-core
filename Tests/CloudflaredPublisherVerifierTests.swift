import Foundation
import Testing

@Suite("cloudflared publisher verification")
struct CloudflaredPublisherVerifierTests {
    @Test("A binary not signed by Cloudflare is rejected")
    func rejectsOtherPublishers() {
        #expect(throws: (any Error).self) {
            try CloudflaredPublisherVerifier.verify(at: URL(fileURLWithPath: "/bin/echo"))
        }
    }

    @Test("Atomic replacement keeps the verified candidate's executable mode")
    func replacementKeepsCandidateMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = root.appendingPathComponent("candidate")
        let destination = root.appendingPathComponent("cloudflared")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)
        try Data("new".utf8).write(to: candidate)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)

        try CloudflaredBinaryReplacement.install(candidate, at: destination)

        #expect(try Data(contentsOf: destination) == Data("new".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o755)
        #expect(!FileManager.default.fileExists(atPath: candidate.path))
    }

    @Test("A failed replacement preserves the installed binary")
    func failedReplacementPreservesDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingCandidate = root.appendingPathComponent("missing")
        let destination = root.appendingPathComponent("cloudflared")
        try Data("old".utf8).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path)

        #expect(throws: (any Error).self) {
            try CloudflaredBinaryReplacement.install(missingCandidate, at: destination)
        }

        #expect(try Data(contentsOf: destination) == Data("old".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        #expect(permissions == 0o700)
    }
}
