import Foundation
import JavaScriptCore
import Testing

@Suite("Notes update concurrency")
struct NotesUpdateGuardTests {
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
            #expect(error.localizedDescription.hasPrefix("notes_update_conflict:"))
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

    @Test("The real update script refuses a body changed after the hash check", arguments: ["changed", "OLD", "old\n"])
    func changedAfterRead(current: String) throws {
        let context = try fixture(body: current)
        context.objectForKeyedSubscript("run").call(withArguments: [["fixture-id", "replacement", "1", "old"]])
        #expect(context.exception?.toString().contains("notes_update_conflict:") == true)
        #expect(context.objectForKeyedSubscript("writes").toInt32() == 0)
        #expect(context.objectForKeyedSubscript("storedBody").toString() == current)
    }

    @Test("The real update script writes matching and unguarded bodies", arguments: [true, false])
    func acceptedUpdate(guarded: Bool) throws {
        let context = try fixture(body: "old")
        let result = context.objectForKeyedSubscript("run").call(
            withArguments: [["fixture-id", "new\nbody", guarded ? "1" : "0", guarded ? "old" : ""]]
        )
        #expect(context.exception == nil)
        #expect(context.objectForKeyedSubscript("writes").toInt32() == 1)
        #expect(context.objectForKeyedSubscript("storedBody").toString() == "new\nbody")
        let output =
            try JSONSerialization.jsonObject(with: Data(try #require(result?.toString()).utf8)) as? [String: String]
        #expect(output == ["id": "fixture-id", "name": "Fixture title", "folderName": "Fixture folder"])
    }

    private func fixture(body: String) throws -> JSContext {
        let context = try #require(JSContext())
        context.setObject(body, forKeyedSubscript: "storedBody" as NSString)
        context.evaluateScript(
            """
            var writes = 0;
            var note = { name: () => 'Fixture title', container: () => ({ name: () => 'Fixture folder' }) };
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
        context.evaluateScript(NotesUpdateGuard.updateScript)
        #expect(context.exception == nil)
        return context
    }
}
