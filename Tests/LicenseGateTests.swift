import CryptoKit
import Foundation
import Testing

private final class ReceiptTrustSandbox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL: Data] = [:]

    var store: GumroadReceiptTrust {
        GumroadReceiptTrust(
            read: { [self] url in
                lock.lock()
                defer { lock.unlock() }
                return values[url]
            },
            write: { [self] data, url in
                lock.lock()
                defer { lock.unlock() }
                values[url] = data
            }
        )
    }
}

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
        reply?.resume(
            returning: .success(
                Data(
                    #"{"success":true,"purchase":{"product_id":"H5iMAgmqjSc9_p61iSwApA==","sale_id":"test-sale","price":1500}}"#
                        .utf8
                )
            )
        )
        reply = nil
    }
}

@Suite("License gate persistence and concurrency")
struct LicenseGateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let trust = ReceiptTrustSandbox()

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
        let settings = LicenseGate(
            licenseURL: url,
            publicKey: key.publicKey.rawRepresentation,
            receiptTrust: trust.store
        )
        let server = LicenseGate(licenseURL: url, publicKey: key.publicKey.rawRepresentation, receiptTrust: trust.store)
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
        let gate = LicenseGate(licenseURL: url, publicKey: key.publicKey.rawRepresentation, receiptTrust: trust.store)
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
        let receipt = root.appendingPathComponent("gumroad-license.json")
        try trust.store.write(Data(SHA256.hash(data: Data(contentsOf: receipt))), receipt)
        let url = root.appendingPathComponent("license.txt")
        try Data("damaged".utf8).write(to: url)
        let gate = LicenseGate(licenseURL: url, receiptTrust: trust.store)
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
                verifier: { body in await verifier.verify(body) },
                receiptTrust: trust.store
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
            #expect(document == nil)
        }
    }

    @Test("Deactivation cancels a pending activation")
    func deactivateDuringActivation() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let verifier = SuspendedLicenseVerifier()
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { body in await verifier.verify(body) },
            receiptTrust: trust.store
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
            publicKey: key.publicKey.rawRepresentation,
            receiptTrust: trust.store
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
            verifier: { _ in .success(Data(#"{"success":false}"#.utf8)) },
            receiptTrust: trust.store
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

    @Test("Re-entering a revoked installed key closes its cache but another rejected key does not")
    func manualRevocation() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try record(at: root)
        let receipt = root.appendingPathComponent("gumroad-license.json")
        try trust.store.write(Data(SHA256.hash(data: Data(contentsOf: receipt))), receipt)
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in .success(Data(#"{"success":false}"#.utf8)) },
            receiptTrust: trust.store
        )
        _ = await gate.activateGumroadKey("EEEEEEEE-FFFFFFFF-GGGGGGGG-HHHHHHHH", now: now)
        #expect(await gate.validatedDocument(now: now) != nil)
        _ = await gate.activateGumroadKey("AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD", now: now)
        #expect(await gate.validatedDocument(now: now) == nil)
        let relaunched = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in .failure(URLError(.notConnectedToInternet)) },
            receiptTrust: trust.store
        )
        #expect(await relaunched.validatedDocument(now: now) == nil)
    }

    @Test("Forged and copied JSON cannot activate a Mac, even with a future verification date")
    func forgedRecord() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try record(at: root)
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in .failure(URLError(.notConnectedToInternet)) },
            receiptTrust: trust.store
        )
        #expect(await gate.validatedDocument(now: now) == nil)
        #expect(await !gate.activationState(now: now).isActive)
        #expect(await gate.validatedDocument(now: now.addingTimeInterval(-86_400)) == nil)
    }

    @Test("Verified receipts survive relaunch offline but edits invalidate the Keychain witness")
    func trustedReceipt() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("license.txt")
        let gate = LicenseGate(
            licenseURL: url,
            verifier: { _ in
                .success(
                    Data(
                        #"{"success":true,"purchase":{"product_id":"H5iMAgmqjSc9_p61iSwApA==","sale_id":"test-sale","price":1500}}"#
                            .utf8
                    )
                )
            },
            receiptTrust: trust.store
        )
        guard case .success = await gate.activateGumroadKey("AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD", now: now) else {
            Issue.record("Activation failed")
            return
        }
        let relaunched = LicenseGate(
            licenseURL: url,
            verifier: { _ in .failure(URLError(.notConnectedToInternet)) },
            receiptTrust: trust.store
        )
        #expect(await relaunched.validatedDocument(now: now.addingTimeInterval(3600)) != nil)
        try record(at: root, key: "EEEEEEEE-FFFFFFFF-GGGGGGGG-HHHHHHHH")
        #expect(await relaunched.validatedDocument(now: now) == nil)
    }

    @Test("Legacy receipts migrate only after online verification and witness write failures fail closed")
    func migrationAndTrustFailure() async throws {
        let root = try sandbox()
        defer { try? FileManager.default.removeItem(at: root) }
        try record(at: root)
        let gate = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in
                .success(
                    Data(
                        #"{"success":true,"purchase":{"product_id":"H5iMAgmqjSc9_p61iSwApA==","sale_id":"test-sale","price":1500}}"#
                            .utf8
                    )
                )
            },
            receiptTrust: trust.store
        )
        await gate.reverifyGumroadKey(now: now)
        #expect(await gate.validatedDocument(now: now) != nil)
        let failing = LicenseGate(
            licenseURL: root.appendingPathComponent("license.txt"),
            verifier: { _ in
                .success(
                    Data(
                        #"{"success":true,"purchase":{"product_id":"H5iMAgmqjSc9_p61iSwApA==","sale_id":"test-sale","price":1500}}"#
                            .utf8
                    )
                )
            },
            receiptTrust: GumroadReceiptTrust(read: { _ in nil }, write: { _, _ in throw URLError(.cannotWriteToFile) })
        )
        guard case .failure = await failing.activateGumroadKey("AAAAAAAA-BBBBBBBB-CCCCCCCC-DDDDDDDD", now: now) else {
            Issue.record("Activation succeeded without a trusted receipt")
            return
        }
        #expect(await failing.validatedDocument(now: now) == nil)
    }

}
