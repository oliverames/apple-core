import Foundation
import JavaScriptCore
import Testing

@Suite("Notes write guards")
struct NotesUpdateGuardTests {

    // MARK: - Snapshot hashing

    @Test("An omitted hash preserves legacy behavior without an extra read")
    func omittedHash() async throws {
        let snapshot = try await NotesUpdateGuard.snapshot(expectedHash: nil) {
            Issue.record("An unguarded update should not read a snapshot")
            return "unused"
        }
        #expect(snapshot == nil)
    }

    @Test("A matching hash captures the exact HTML, including Unicode and line endings")
    func matchingHash() async throws {
        let body = "<div>Café 👩🏽‍💻</div>\r\n<div>second line</div>"
        let snapshot = try await NotesUpdateGuard.snapshot(expectedHash: NotesUpdateGuard.hash(of: body)) { body }
        #expect(snapshot == body)
    }

    @Test("SHA-256 remains compatible with existing bodyHash values")
    func knownHash() {
        #expect(NotesUpdateGuard.hash(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test("Stale and empty hashes produce a named conflict", arguments: ["", "old-hash"])
    func staleHash(expected: String) async {
        do {
            _ = try await NotesUpdateGuard.snapshot(expectedHash: expected) { "new body" }
            Issue.record("A stale hash was accepted")
        } catch {
            #expect(error.localizedDescription.hasPrefix(NotesUpdateGuard.conflictPrefix))
        }
    }

    @Test("A failed snapshot read prevents an update")
    func failedRead() async {
        do {
            _ = try await NotesUpdateGuard.snapshot(expectedHash: "anything") {
                throw NSError(domain: "FixtureReadError", code: 1)
            }
            Issue.record("A failed read was accepted")
        } catch {
            #expect((error as NSError).domain == "FixtureReadError")
        }
    }

    // MARK: - Attachment state

    @Test("A probe count becomes the state it actually means")
    func probeCounts() {
        #expect(NotesUpdateGuard.AttachmentState(probeCount: 0) == .none)
        #expect(NotesUpdateGuard.AttachmentState(probeCount: 3) == .present(3))
        #expect(NotesUpdateGuard.AttachmentState(probeCount: -1) == .unknown)
    }

    @Test("Only an empty note is written without an explicit acceptance of loss")
    func refusals() {
        #expect(
            NotesUpdateGuard.attachmentRefusal(
                for: .none,
                operation: "notes_append",
                allowAttachmentLoss: false
            ) == nil
        )
        let present = NotesUpdateGuard.attachmentRefusal(
            for: .present(2),
            operation: "notes_append",
            allowAttachmentLoss: false
        )
        #expect(present?.hasPrefix(NotesUpdateGuard.attachmentPresentPrefix) == true)
        #expect(present?.contains("2 attachments") == true)
        let unknown = NotesUpdateGuard.attachmentRefusal(
            for: .unknown,
            operation: "notes_update",
            allowAttachmentLoss: false
        )
        #expect(unknown?.hasPrefix(NotesUpdateGuard.attachmentUnknownPrefix) == true)
    }

    @Test("An explicit acceptance of loss clears every refusal")
    func refusalsWaived() {
        for state in [NotesUpdateGuard.AttachmentState.none, .present(9), .unknown] {
            #expect(
                NotesUpdateGuard.attachmentRefusal(
                    for: state,
                    operation: "notes_update",
                    allowAttachmentLoss: true
                ) == nil
            )
        }
    }

    // MARK: - The real scripts

    @Test("An attachment-bearing note is refused rather than rewritten", arguments: Script.allCases)
    func attachmentPresent(script: Script) throws {
        let context = try fixture(body: "old", attachments: 2, script: script)
        context.run(["fixture-id", "payload", "0", "", "0"])
        #expect(context.failure().contains(NotesUpdateGuard.attachmentPresentPrefix))
        #expect(context.failure().contains("2 attachments"))
        #expect(context.writes == 0)
        #expect(context.storedBody == "old")
    }

    @Test("An unreadable attachment state is refused, not assumed empty", arguments: Script.allCases)
    func attachmentUnknown(script: Script) throws {
        let context = try fixture(body: "old", attachments: nil, script: script)
        context.run(["fixture-id", "payload", "0", "", "0"])
        #expect(context.failure().contains(NotesUpdateGuard.attachmentUnknownPrefix))
        #expect(context.writes == 0)
        #expect(context.storedBody == "old")
    }

    @Test(
        "An explicit acceptance of loss writes an attachment-bearing note",
        arguments: Script.allCases
    )
    func attachmentLossAccepted(script: Script) throws {
        let context = try fixture(body: "old", attachments: 4, script: script)
        context.run(["fixture-id", "+more", "0", "", "1"])
        #expect(context.exception == nil)
        #expect(context.writes == 1)
        #expect(context.storedBody == (script == .append ? "old+more" : "+more"))
    }

    @Test(
        "The attachment guard runs before the snapshot check",
        arguments: Script.allCases
    )
    func attachmentGuardComesFirst(script: Script) throws {
        // Both guards would fire. The attachment refusal is the one that
        // tells the caller their note is about to lose data.
        let context = try fixture(body: "changed", attachments: 1, script: script)
        context.run(["fixture-id", "payload", "1", "old", "0"])
        #expect(context.failure().contains(NotesUpdateGuard.attachmentPresentPrefix))
        #expect(context.writes == 0)
    }

    @Test(
        "A body changed after the hash check is refused",
        arguments: Script.allCases,
        ["changed", "OLD", "old\n"]
    )
    func changedAfterRead(script: Script, current: String) throws {
        let context = try fixture(body: current, attachments: 0, script: script)
        context.run(["fixture-id", "replacement", "1", "old", "0"])
        #expect(context.failure().contains(NotesUpdateGuard.conflictPrefix))
        #expect(context.writes == 0)
        #expect(context.storedBody == current)
    }

    @Test("A stale append leaves the changed body alone")
    func staleAppend() throws {
        // The note gained a line between the client's read and its append.
        // Concatenating onto the body it remembers would drop that line.
        let context = try fixture(body: "<div>old</div><div>theirs</div>", attachments: 0, script: .append)
        context.run(["fixture-id", "<div>mine</div>", "1", "<div>old</div>", "0"])
        #expect(context.failure().contains(NotesUpdateGuard.conflictPrefix))
        #expect(context.writes == 0)
        #expect(context.storedBody == "<div>old</div><div>theirs</div>")
    }

    @Test("An append against a current body concatenates onto the live body")
    func freshAppend() throws {
        let context = try fixture(body: "<div>old</div>", attachments: 0, script: .append)
        let result = context.run(["fixture-id", "<div>new</div>", "1", "<div>old</div>", "0"])
        #expect(context.exception == nil)
        #expect(context.writes == 1)
        #expect(context.storedBody == "<div>old</div><div>new</div>")
        try expectWriteResult(result)
    }

    @Test(
        "Guarded and unguarded writes both land on an attachment-free note",
        arguments: Script.allCases,
        [true, false]
    )
    func acceptedWrite(script: Script, guarded: Bool) throws {
        let context = try fixture(body: "old", attachments: 0, script: script)
        let result = context.run(
            ["fixture-id", "new\nbody", guarded ? "1" : "0", guarded ? "old" : "", "0"]
        )
        #expect(context.exception == nil)
        #expect(context.writes == 1)
        #expect(context.storedBody == (script == .append ? "oldnew\nbody" : "new\nbody"))
        try expectWriteResult(result)
    }

    // MARK: - Fixture

    enum Script: CaseIterable {
        case update
        case append

        var source: String {
            switch self {
            case .update: return NotesUpdateGuard.updateScript
            case .append: return NotesUpdateGuard.appendScript
            }
        }
    }

    private func expectWriteResult(_ result: JSValue?) throws {
        let output =
            try JSONSerialization.jsonObject(with: Data(try #require(result?.toString()).utf8)) as? [String: String]
        #expect(output == ["id": "fixture-id", "name": "Fixture title", "folderName": "Fixture folder"])
    }

    /// A stand-in for the one note the script touches. `attachments: nil`
    /// makes the probe throw, which is how a locked or half-synced note
    /// behaves in practice.
    private func fixture(body: String, attachments: Int?, script: Script) throws -> JSContext {
        let context = try #require(JSContext())
        context.setObject(body, forKeyedSubscript: "storedBody" as NSString)
        context.setObject(attachments ?? -1, forKeyedSubscript: "attachmentCount" as NSString)
        context.setObject(attachments == nil, forKeyedSubscript: "attachmentsThrow" as NSString)
        context.evaluateScript(
            """
            var writes = 0;
            var note = {
                name: () => 'Fixture title',
                container: () => ({ name: () => 'Fixture folder' }),
                attachments: () => {
                    if (attachmentsThrow) { throw new Error('fixture: attachments unavailable'); }
                    return new Array(attachmentCount);
                }
            };
            Object.defineProperty(note, 'body', {
                get: () => () => storedBody,
                set: value => { writes++; storedBody = value; }
            });
            function Application(name) {
                if (name !== 'Notes') throw new Error('Unexpected application');
                return { notes: { byId: id => {
                    if (id !== 'fixture-id') throw new Error('Unexpected note');
                    return note;
                } } };
            }
            """
        )
        context.evaluateScript(script.source)
        #expect(context.exception == nil)
        return context
    }
}

extension JSContext {
    @discardableResult
    fileprivate func run(_ arguments: [String]) -> JSValue? {
        objectForKeyedSubscript("run").call(withArguments: [arguments])
    }

    fileprivate func failure() -> String {
        exception?.toString() ?? "<no exception>"
    }

    fileprivate var writes: Int32 {
        objectForKeyedSubscript("writes").toInt32()
    }

    fileprivate var storedBody: String {
        objectForKeyedSubscript("storedBody").toString()
    }
}
