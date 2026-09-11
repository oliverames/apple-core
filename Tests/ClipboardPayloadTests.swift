import Foundation
import Testing

@Suite("Typed clipboard and snapshot restore")
struct ClipboardPayloadTests {
    @Test("Formats map to and from pasteboard types")
    func formatMapping() {
        #expect(ClipboardFormat.matching(pasteboardType: "public.utf8-plain-text") == .text)
        #expect(ClipboardFormat.matching(pasteboardType: "com.adobe.pdf") == .pdf)
        #expect(ClipboardFormat.matching(pasteboardType: "com.acme.private") == nil)
        #expect(ClipboardFormat.text.pasteboardType == "public.utf8-plain-text")
    }

    @Test("Only text-shaped formats are writable, and images are not")
    func writability() {
        #expect(ClipboardFormat.text.isWritable)
        #expect(ClipboardFormat.html.isWritable)
        #expect(!ClipboardFormat.png.isWritable)
        // A file URL is refused on purpose: writing one would let a client
        // fabricate a Finder copy of a path the allowlist never approved.
        #expect(!ClipboardFormat.fileURL.isWritable)
    }

    @Test("An unknown format name is rejected by name")
    func unknownFormat() {
        #expect(throws: ClipboardError.unknownFormat("jpeg2000")) {
            try ClipboardPayload.resolveFormat("jpeg2000")
        }
        let defaulted = try? ClipboardPayload.resolveFormat(nil)
        #expect(defaulted == .text)
    }

    @Test("A payload over the inline limit is refused with a route to a file")
    func inlineLimit() {
        #expect(throws: Never.self) {
            try ClipboardPayload.checkInlineSize(format: .png, sizeBytes: 1024)
        }
        do {
            try ClipboardPayload.checkInlineSize(
                format: .png,
                sizeBytes: ClipboardPayload.maximumInlineBytes + 1
            )
            Issue.record("expected a refusal")
        } catch let error as ClipboardError {
            #expect(error.errorDescription?.contains("savePath") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("A snapshot restores only when nothing has copied since")
    func restoreGuard() {
        let store = ClipboardSnapshotStore()
        let snapshot = store.store(items: [.text: Data("before".utf8)], changeCount: 7)
        #expect(store.decide(token: snapshot.token, currentChangeCount: 7) == .restore)
        #expect(
            store.decide(token: snapshot.token, currentChangeCount: 8)
                == .refusedNewerCopy(currentChangeCount: 8, expectedChangeCount: 7)
        )
    }

    @Test("Apple Core's own write does not invalidate the snapshot it just took")
    func ownWriteKeepsSnapshotValid() {
        let store = ClipboardSnapshotStore()
        let snapshot = store.store(items: [.text: Data("before".utf8)], changeCount: 7)
        store.recordOwnWrite(changeCount: 8)
        #expect(store.decide(token: snapshot.token, currentChangeCount: 8) == .restore)
        // Someone at the Mac copies something: the snapshot stops being
        // restorable, which is the entire point of the guard.
        #expect(
            store.decide(token: snapshot.token, currentChangeCount: 9)
                == .refusedNewerCopy(currentChangeCount: 9, expectedChangeCount: 8)
        )
    }

    @Test("A snapshot expires and is discarded rather than restored late")
    func expiry() {
        let store = ClipboardSnapshotStore(lifetime: 60)
        let start = Date()
        let snapshot = store.store(items: [.text: Data()], changeCount: 1, now: start)
        #expect(
            store.decide(
                token: snapshot.token,
                currentChangeCount: 1,
                now: start.addingTimeInterval(30)
            ) == .restore
        )
        #expect(
            store.decide(
                token: snapshot.token,
                currentChangeCount: 1,
                now: start.addingTimeInterval(120)
            ) == .expired
        )
        #expect(store.snapshot(token: snapshot.token) == nil)
    }

    @Test("An unknown token is refused rather than guessed at")
    func unknownToken() {
        let store = ClipboardSnapshotStore()
        #expect(store.decide(token: "nope", currentChangeCount: 1) == .unknownToken)
    }

    @Test("A used token cannot restore twice")
    func consumed() {
        let store = ClipboardSnapshotStore()
        let snapshot = store.store(items: [.text: Data()], changeCount: 3)
        store.consume(token: snapshot.token)
        #expect(store.decide(token: snapshot.token, currentChangeCount: 3) == .unknownToken)
    }

    @Test("The store holds a bounded number of snapshots, dropping the oldest")
    func boundedStore() {
        let store = ClipboardSnapshotStore()
        let start = Date()
        var tokens: [String] = []
        for index in 0 ..< (ClipboardSnapshotStore.maximumSnapshots + 3) {
            tokens.append(
                store.store(
                    items: [.text: Data()],
                    changeCount: index,
                    now: start.addingTimeInterval(Double(index))
                ).token
            )
        }
        #expect(store.count == ClipboardSnapshotStore.maximumSnapshots)
        #expect(store.snapshot(token: tokens[0]) == nil)
        #expect(store.snapshot(token: tokens.last ?? "") != nil)
    }

    @Test("Every refusal explains itself, and a successful restore has nothing to say")
    func decisionMessages() {
        #expect(ClipboardRestoreDecision.restore.message == nil)
        #expect(
            ClipboardRestoreDecision.refusedNewerCopy(currentChangeCount: 2, expectedChangeCount: 1)
                .message?.contains("discard") == true
        )
        #expect(ClipboardRestoreDecision.expired.message != nil)
        #expect(ClipboardRestoreDecision.unknownToken.message != nil)
    }
}
