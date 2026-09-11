import Foundation
import Testing
import UniformTypeIdentifiers

@Suite("Filesystem metadata")
struct FilesystemMetadataTests {
    @Test("A full quarantine record gives up its agent and its timestamp")
    func parsesQuarantine() throws {
        // 0x68C2A1B3 is 2026-09-11T00:53:07Z.
        let record = try #require(
            FilesystemMetadata.quarantineRecord(
                fromAttribute: "0083;68c2a1b3;Safari;F1B0A7E2-0000-0000-0000-000000000000"
            )
        )
        #expect(record.agentName == "Safari")
        #expect(record.timestamp == Date(timeIntervalSince1970: 0x68C2_A1B3))
    }

    @Test("A record with no agent is still a record")
    func parsesShortQuarantine() throws {
        let record = try #require(FilesystemMetadata.quarantineRecord(fromAttribute: "0001;5f000000"))
        #expect(record.agentName == nil)
        #expect(record.timestamp == Date(timeIntervalSince1970: 0x5F00_0000))
    }

    @Test("A zero or unparseable timestamp is absent rather than 1970")
    func refusesEpochZero() throws {
        let record = try #require(
            FilesystemMetadata.quarantineRecord(fromAttribute: "0083;0;Safari;X")
        )
        #expect(record.timestamp == nil)
        #expect(record.agentName == "Safari")

        let unparseable = try #require(
            FilesystemMetadata.quarantineRecord(fromAttribute: "0083;zzzz;Mail;X")
        )
        #expect(unparseable.timestamp == nil)
    }

    @Test("Empty and malformed attributes are not records")
    func refusesEmpty() {
        #expect(FilesystemMetadata.quarantineRecord(fromAttribute: "") == nil)
        #expect(FilesystemMetadata.quarantineRecord(fromAttribute: "0083") == nil)
    }

    @Test("Where-froms decodes the download URL and its referring page")
    func decodesWhereFroms() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["https://example.com/file.zip", "https://example.com/page"],
            format: .binary,
            options: 0
        )
        #expect(
            FilesystemMetadata.whereFroms(fromAttribute: data)
                == ["https://example.com/file.zip", "https://example.com/page"]
        )
    }

    @Test("An empty referrer is dropped rather than reported as a source")
    func dropsEmptyReferrer() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["https://example.com/file.zip", ""],
            format: .binary,
            options: 0
        )
        #expect(FilesystemMetadata.whereFroms(fromAttribute: data) == ["https://example.com/file.zip"])
    }

    @Test("Data that is not a property list yields no sources")
    func survivesGarbage() {
        #expect(FilesystemMetadata.whereFroms(fromAttribute: Data([0x00, 0x01, 0x02])).isEmpty)
    }

    @Test("Types are grouped by what they conform to, not by extension")
    func categorises() {
        #expect(FilesystemMetadata.category(for: .png) == .image)
        #expect(FilesystemMetadata.category(for: .heic) == .image)
        #expect(FilesystemMetadata.category(for: .pdf) == .pdf)
        #expect(FilesystemMetadata.category(for: .mpeg4Movie) == .video)
        #expect(FilesystemMetadata.category(for: .mp3) == .audio)
        #expect(FilesystemMetadata.category(for: .zip) == .archive)
        #expect(FilesystemMetadata.category(for: .folder) == .folder)
        #expect(FilesystemMetadata.category(for: .applicationBundle) == .application)
        #expect(FilesystemMetadata.category(for: .swiftSource) == .text)
        #expect(FilesystemMetadata.category(for: nil) == .other)
    }

    @Test("An SVG conforms to text but is reported as an image")
    func prefersTheSpecificType() {
        #expect(UTType.svg.conforms(to: .text))
        #expect(FilesystemMetadata.category(for: .svg) == .image)
    }

    @Test("Spotlight keys lose their C prefix in the response")
    func renamesSpotlightKeys() {
        #expect(FilesystemMetadata.responseKey(forSpotlightAttribute: "kMDItemPixelWidth") == "pixelWidth")
        #expect(
            FilesystemMetadata.responseKey(forSpotlightAttribute: "kMDItemFinderComment")
                == "finderComment"
        )
        #expect(FilesystemMetadata.responseKey(forSpotlightAttribute: "custom") == "custom")
    }

    @Test("Extended attributes read back what was written, and absence is nil")
    func readsExtendedAttributes() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-core-xattr-\(UUID().uuidString).txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(FilesystemMetadata.extendedAttribute("com.apple.quarantine", of: file.path) == nil)

        let value = "0083;68c2a1b3;Safari;X"
        let written = value.withCString { bytes in
            setxattr(file.path, "com.apple.quarantine", bytes, strlen(bytes), 0, 0)
        }
        #expect(written == 0)

        let data = try #require(
            FilesystemMetadata.extendedAttribute("com.apple.quarantine", of: file.path)
        )
        #expect(String(decoding: data, as: UTF8.self) == value)
    }
}
