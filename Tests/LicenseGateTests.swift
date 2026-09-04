import CryptoKit
import Foundation
import Testing

private actor SuspendedLicenseVerifier {
    private var reply: CheckedContinuation<Result<Data, Error>, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func verify(_ body: Data) async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            reply = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if reply != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish() {
        reply?.resume(returning: .success(Data(#"{"success":true,"purchase":{}}"#.utf8)))
        reply = nil
    }
}

@Suite("License gate persistence and concurrency")
struct LicenseGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sandbox() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("apple-core-license-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func record(at root: URL, key: String = "AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD") throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = GumroadLicenseRecord(key: key, lastVerifiedAt: now)
        try encoder.encode(record).write(to: root.appendingPathComponent("gumroad-license.json"), options: .atomic)
    }

    private func envelope(using key: Curve25519.Signing.PrivateKey, id: String = "test") throws -> String {
        try LicenseDocumentCodec.encode(
            LicenseDocument(
                licenseID: id,
                product: "apple-core",
                plan: "test",
                licensedTo: "buyer@example.com",
                issuedAt: now,
                expiresAt: nil
            ),
            signingKey: key
        )
    }

    @Test("Cached signed licenses notice replacement and deletion across gate instances")
    func signedFileChanges() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("license.txt")
        let key = Curve25519.Signing.PrivateKey()
        let settings = LicenseGate(licenseURL: url, publicKey: key.publicKey.rawRepresentation)
        let server = LicenseGate(licenseURL: url, publicKey: key.publicKey.rawRepresentation)
        _ = await settings.activate(try envelope(using: key), now: now)
        #expect(await server.validatedDocument(now: now)?.licenseID == "test")
        try Data(envelope(using: key, id: "replacement").utf8).write(to: url, options: .atomic)
        #expect(await server.validatedDocument(now: now)?.licenseID == "replacement")
        try FileManager.default.removeItem(at: url)
        #expect(await server.validatedDocument(now: now) == nil)
    }

    @Test("Signed activation persists a private file")
    func privateFile() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("license.txt")
        let key = Curve25519.Signing.PrivateKey()
        let gate = LicenseGate(licenseURL: url, publicKey: key.publicKey.rawRepresentation)
        let result = await gate.activate(try envelope(using: key), now: now)
        guard case .success = result else { Issue.record("Activation failed"); return }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("A valid Gumroad key keeps Settings and serving consistent beside a damaged envelope")
    func fallbackState() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try record(at: root)
        let url = root.appendingPathComponent("license.txt")
        try Data("damaged".utf8).write(to: url)
        let gate = LicenseGate(licenseURL: url)
        #expect(await gate.validatedDocument(now: now)?.plan == "gumroad")
        #expect(await gate.activationState(now: now).isActive)
    }

    @Test("A verification reply cannot recreate an externally deleted or replaced record")
    func staleReply() async throws {
        for replacement in [false, true] {
            let root = try sandbox()
            defer { try? FileManager.default.removeItem(at: root) }
            try record(at: root)
            let verifier = SuspendedLicenseVerifier()
            let gate = LicenseGate(
                licenseURL: root.appendingPathComponent("license.txt"),
                verifier: { body in await verifier.verify(body) }
            )
            let task = Task { await gate.reverifyGumroadKey(now: now) }
            await verifier.waitUntilStarted()
            if replacement {
                try record(at: root, key: "EEEEEEEE-FFFFFFFF-GGGGGGGG-HHHHHHHH")
            } else {
                try FileManager.default.removeItem(at: root.appendingPathComponent("gumroad-license.json"))
            }
            await verifier.finish()
            await task.value
            let document = await gate.validatedDocument(now: now)
            if replacement {
                #expect(document?.licenseID == "gumroad:…HHHHHHHH")
            } else {
                #expect(document == nil)
            }
        }
    }

    @Test("Deactivation cancels a pending activation")
    func deactivateDuringActivation() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = SuspendedLicenseVerifier()
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { body in await verifier.verify(body) }
        )
        let task = Task { await gate.activateGumroadKey("AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD", now: now) }
        await verifier.waitUntilStarted()
        await gate.deactivate()
        await verifier.finish()
        let result = await task.value
        guard case .failure = result else { Issue.record("Stale activation succeeded"); return }
        #expect(await gate.validatedDocument(now: now) == nil)
    }

    @Test("Signed activation supersedes reverification even when Gumroad file bytes stay unchanged")
    func signedActivationSupersedesReverification() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try record(at: root)
        let url = root.appendingPathComponent("license.txt")
        let recordURL = root.appendingPathComponent("gumroad-license.json")
        let original = try Data(contentsOf: recordURL)
        let verifier = SuspendedLicenseVerifier()
        let key = Curve25519.Signing.PrivateKey()
        let gate = LicenseGate(
            licenseURL: url,
            verifier: { body in await verifier.verify(body) },
            publicKey: key.publicKey.rawRepresentation
        )
        let task = Task { await gate.reverifyGumroadKey(now: now.addingTimeInterval(3600)) }
        await verifier.waitUntilStarted()
        _ = await gate.activate(try envelope(using: key), now: now)
        await verifier.finish()
        await task.value
        #expect(try Data(contentsOf: recordURL) == original)
    }

    @Test("A failed disk write cannot undo a known revocation")
    func revocationWriteFailure() async throws {
        let root = try sandbox()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try record(at: root)
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in .success(Data(#"{"success":false}"#.utf8)) }
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        await gate.reverifyGumroadKey(now: now)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            GumroadLicenseRecord.self,
            from: Data(contentsOf: root.appendingPathComponent("gumroad-license.json"))
        )
        #expect(persisted.cachedValid)
        #expect(await gate.validatedDocument(now: now) == nil)
        #expect(await !gate.activationState(now: now).isActive)
    }
}
