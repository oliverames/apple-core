import Foundation
import Testing

/// Apple Core could read bytes off the Mac and not put them back: there was a
/// `filesystem_read_binary` with no write counterpart. The case that surfaced
/// it was a finished .xlsx that had nowhere to go, so the round trip on real
/// binary bytes is the test that matters here, not the ASCII one.
@Suite("Filesystem binary write")
struct FilesystemBinaryWriteTests {
    private static let limit = 10 * 1024 * 1024

    @Test("Decoded size is known from the encoded length before any buffer is allocated")
    func projectedSize() {
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: "") == 0)
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: "QQ==") == 1)
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: "QUI=") == 2)
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: "QUJD") == 3)
        // Line breaks survive a trip through other tools and must not inflate
        // the projection.
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: "QUJD\nQUJD") == 6)
    }

    @Test("Arbitrary bytes survive the round trip unchanged")
    func roundTripsBinary() throws {
        var bytes = Data((0 ... 255).map { UInt8($0) })
        bytes.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // a zip/xlsx magic number
        let encoded = bytes.base64EncodedString()

        let decoded = try FilesystemBinaryWrite.decode(base64: encoded, limitBytes: Self.limit)
        #expect(decoded == bytes)
    }

    @Test("Base64 split across lines decodes, because other tools wrap it")
    func toleratesLineBreaks() throws {
        let bytes = Data(repeating: 0xAB, count: 300)
        let wrapped = bytes.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])

        #expect(try FilesystemBinaryWrite.decode(base64: wrapped, limitBytes: Self.limit) == bytes)
    }

    @Test("Input that is not base64 is refused rather than decoded loosely")
    func refusesInvalidBase64() {
        // Foundation's .ignoreUnknownCharacters would happily discard these and
        // return a shorter, corrupt file that only fails when something opens it.
        for invalid in ["not base64 at all!", "QUJD$$$", "%%%%"] {
            #expect(throws: FilesystemBinaryWriteError.invalidBase64) {
                try FilesystemBinaryWrite.decode(base64: invalid, limitBytes: Self.limit)
            }
        }
    }

    @Test("An oversized payload is refused from its encoded length, before decoding")
    func refusesOversized() {
        let limit = 1024
        let encoded = Data(repeating: 0x00, count: limit + 64).base64EncodedString()

        #expect(throws: FilesystemBinaryWriteError.self) {
            try FilesystemBinaryWrite.decode(base64: encoded, limitBytes: limit)
        }
        #expect(FilesystemBinaryWrite.decodedByteCount(base64: encoded) > limit)
    }

    @Test("A payload exactly at the limit is accepted")
    func acceptsExactlyAtLimit() throws {
        let limit = 3 * 512
        let bytes = Data(repeating: 0x7F, count: limit)

        let decoded = try FilesystemBinaryWrite.decode(
            base64: bytes.base64EncodedString(),
            limitBytes: limit
        )
        #expect(decoded.count == limit)
    }

    @Test("An empty payload writes an empty file rather than failing")
    func acceptsEmpty() throws {
        #expect(try FilesystemBinaryWrite.decode(base64: "", limitBytes: Self.limit).isEmpty)
    }

    @Test("An atomic write replaces the file whole, so a reader never sees a partial one")
    func atomicWriteReplacesWhole() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-binary-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("fixture.bin")
        let first = Data(repeating: 0x01, count: 4096)
        let second = Data((0 ... 255).map { UInt8($0) })

        try first.write(to: url, options: .atomic)
        try second.write(to: url, options: .atomic)

        #expect(try Data(contentsOf: url) == second)
    }
}
